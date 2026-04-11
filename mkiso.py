#!/usr/bin/env python3
# ===========================================================================
# mkiso.py - Build claudeos.iso using pure Python (pycdlib)
#            Produces a HYBRID ISO that Rufus can write to a USB stick.
#
# What makes it hybrid / Rufus-compatible:
#   ISO 9660 reserves the first 32 KB ("system area") for non-ISO use.
#   We embed an MBR + partition table there so Rufus/dd see a valid MBR
#   disk image and can write it to USB without the "unsupported image" error.
#
# Hybrid MBR layout (first 512 bytes of the ISO):
#   Bytes   0-439  : MBR boot code from build/boot.bin (first 440 bytes).
#                    IMPORTANT: the MBR boot code safe region is bytes 0-439.
#                    The old code incorrectly truncated to 432, which cut off
#                    the DAP structure and part of the stage2 loader code.
#   Bytes 440-443  : Disk timestamp / unique disk ID (zeroed for compat)
#   Bytes 444-445  : Reserved word (zeroed)
#   Bytes 446-461  : Partition entry 0: bootable, type 0x00, LBA 0, full ISO.
#                    Type 0x00 (Empty/Unused) is the correct hybrid ISO
#                    convention (used by isohybrid, xorriso, etc.).
#                    The old type 0x17 (Hidden NTFS) caused CSM firmwares
#                    and some BIOSes to skip the partition entirely.
#   Bytes 462-509  : Partition entries 1-3: empty
#   Bytes 510-511  : 0x55 0xAA (MBR signature)
#
# Install once: pip install pycdlib
# ===========================================================================

import sys
import os
import io
import struct

try:
    import pycdlib
except ImportError:
    print("ERROR: pycdlib not found. Run: pip install pycdlib")
    sys.exit(1)

FLAT_IMG = os.path.join('build', 'claudeos_flat.img')
ISO_OUT  = 'claudeos.iso'
BOOT_BIN = os.path.join('build', 'boot.bin')


def lba_to_chs(lba, heads=64, spt=32):
    """Convert LBA address to 3-byte packed CHS (MBR format)."""
    c = lba // (heads * spt)
    r = lba % (heads * spt)
    h = r // spt
    s = r % spt + 1   # sectors are 1-based
    if c > 1023:
        return bytes([0xFE, 0xFF, 0xFF])
    return bytes([
        h & 0xFF,
        ((c >> 8) & 0x03) << 6 | (s & 0x3F),
        c & 0xFF
    ])


def mbr_partition_entry(bootable, ptype, lba_start, lba_size, heads=64, spt=32):
    """Build a 16-byte MBR partition table entry."""
    return struct.pack('<B3sB3sII',
                       0x80 if bootable else 0x00,
                       lba_to_chs(lba_start, heads, spt),
                       ptype,
                       lba_to_chs(lba_start + lba_size - 1, heads, spt),
                       lba_start,
                       lba_size)


# ---------------------------------------------------------------------------
if not os.path.exists(FLAT_IMG):
    print(f"ERROR: {FLAT_IMG} not found. Run build first.")
    sys.exit(1)

print(f"[mkiso] Building {ISO_OUT} from {FLAT_IMG}")

with open(FLAT_IMG, 'rb') as f:
    flat_data = bytearray(f.read())

# ---------------------------------------------------------------------------
# Step 1: Build ISO with El Torito (CD/DVD boot) via pycdlib
# ---------------------------------------------------------------------------
iso = pycdlib.PyCdlib()
iso.new(
    interchange_level=1,
    sys_ident='',
    vol_ident='CLAUDEOS',
    set_size=1,
    seqnum=1,
    log_block_size=2048,
    vol_set_ident='',
    pub_ident_str='',
    preparer_ident_str='',
    app_ident_str='ClaudeOS',
    copyright_file='',
    abstract_file='',
    bibli_file='',
    vol_expire_date=None,
    app_use='',
    joliet=None,
    rock_ridge=None,
    xa=False,
    udf=None
)

iso.add_fp(
    fp=io.BytesIO(flat_data),
    length=len(flat_data),
    iso_path='/CLAUDEOS.IMG;1'
)

iso.add_eltorito(
    bootfile_path='/CLAUDEOS.IMG;1',
    bootcatfile='/BOOT.CAT;1',
    media_name='noemul',
    boot_load_size=4,
    boot_info_table=False
)

iso.write(ISO_OUT)
iso.close()

iso_size = os.path.getsize(ISO_OUT)
print(f"[mkiso] El Torito ISO written: {iso_size} bytes ({iso_size // 2048} CD-sectors)")

# ---------------------------------------------------------------------------
# Step 2: Inject hybrid MBR into the system area (first 512 bytes)
#
# ISO 9660 guarantees the first 32 KB (system area) are unused by the FS.
# pycdlib leaves them as zeros.  We overwrite the first 512 bytes with a
# valid MBR so that tools like Rufus and dd can treat the ISO as a disk image.
# ---------------------------------------------------------------------------
print("[mkiso] Patching hybrid MBR into system area ...")

with open(ISO_OUT, 'r+b') as f:
    f.seek(0)
    sector0 = bytearray(f.read(512))

    # --- MBR boot code (bytes 0-439) ---
    # The MBR boot code safe zone is bytes 0-439 (440 bytes).
    # Bytes 440-443: optional unique disk ID (we zero it).
    # Bytes 444-445: reserved (zeroed).
    # Bytes 446-509: partition table.
    # Bytes 510-511: 0x55AA signature.
    #
    # CRITICAL FIX: old code used 432 bytes which truncated the boot.asm DAP
    # structure and loader code, causing silent failures on real hardware.
    # We now copy all 440 bytes of boot code.
    BOOT_CODE_SIZE = 440

    if os.path.exists(BOOT_BIN):
        with open(BOOT_BIN, 'rb') as bf:
            boot_bin_data = bf.read(512)  # read full 512

        # Copy boot code (bytes 0-439), preserve partition table area
        boot_code = boot_bin_data[:BOOT_CODE_SIZE]
        sector0[0:BOOT_CODE_SIZE] = boot_code
        print(f"  Boot code: {BOOT_BIN} ({BOOT_CODE_SIZE} bytes embedded)")
    else:
        # Minimal fallback: CLI + INT 18h (try next boot device) + HLT
        stub = bytearray(BOOT_CODE_SIZE)
        # CLI ; INT 18h ; HLT  (3 bytes, rest NOP)
        stub[0:3] = bytes([0xFA, 0xCD, 0x18])
        stub[3:BOOT_CODE_SIZE] = bytes([0xF4] * (BOOT_CODE_SIZE - 3))
        sector0[0:BOOT_CODE_SIZE] = stub
        print("  Boot code: minimal fallback (build/boot.bin not found)")

    # --- Disk signature area (bytes 440-445): zero for Rufus compatibility ---
    # Windows uses bytes 440-443 as a unique disk ID. Rufus checks this and
    # may refuse to flash if it looks like a Windows system disk. Zero it.
    sector0[440:446] = b'\x00' * 6

    # --- Partition table (bytes 446-509) ---
    # Expose the entire ISO as a single bootable partition so Rufus sees
    # a recognisable disk layout.
    # iso_size is in bytes; MBR LBA uses 512-byte sectors.
    iso_512_sectors = (iso_size + 511) // 512

    # Entry 0: bootable, type 0x00 (Empty - correct hybrid ISO convention).
    # Using 0x00 matches what isohybrid, xorriso --grub2-mbr, and syslinux
    # isohybrid all use. Type 0x17 (Hidden NTFS) caused CSM/old-BIOS failures.
    sector0[446:462] = mbr_partition_entry(
        bootable=True, ptype=0x00,
        lba_start=0, lba_size=iso_512_sectors
    )
    # Entries 1-3: empty
    sector0[462:510] = b'\x00' * 48

    # --- MBR boot signature ---
    sector0[510] = 0x55
    sector0[511] = 0xAA

    # Write patched sector back to start of ISO
    f.seek(0)
    f.write(bytes(sector0))

print(f"  Partition 0: bootable, type=0x00 (hybrid), LBA 0, {iso_512_sectors} sectors (512B each)")
print(f"  MBR signature: 0x55AA at offset 510")
print()
print(f"[mkiso] Done.")
print(f"  Output : {ISO_OUT}")
print(f"  Size   : {iso_size} bytes  ({iso_size // 2048} x 2048-byte sectors)")
print()
print("  Supported boot paths:")
print("    CD/DVD  -> El Torito no-emulation  (QEMU -cdrom, real optical drive)")
print("    USB     -> Hybrid MBR              (Rufus DD mode, Balena Etcher, dd)")
print()
print("  Rufus instructions:")
print("    1. Open Rufus")
print("    2. Select your USB drive")
print("    3. Boot selection -> SELECT -> claudeos.iso")
print("    4. Partition scheme: MBR   Target system: BIOS or UEFI-CSM")
print('    5. START  -> choose "Write in DD Image mode" when prompted')
print()
print("  QEMU test:")
print("    qemu-system-x86_64 -cdrom claudeos.iso -boot d -m 64M")
