#!/usr/bin/env python3
# ===========================================================================
# mkiso.py - Build claudeos.iso using pure Python (pycdlib)
# No xorriso, no Cygwin, no WSL needed.
# Install once: pip install pycdlib
# ===========================================================================

import sys
import os
import struct

try:
    import pycdlib
except ImportError:
    print("ERROR: pycdlib not found. Run: pip install pycdlib")
    sys.exit(1)

FLAT_IMG = os.path.join('build', 'claudeos_flat.img')
ISO_OUT  = 'claudeos.iso'

if not os.path.exists(FLAT_IMG):
    print(f"ERROR: {FLAT_IMG} not found. Run build first.")
    sys.exit(1)

print(f"[mkiso] Building {ISO_OUT} from {FLAT_IMG}")

with open(FLAT_IMG, 'rb') as f:
    flat_data = f.read()

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

# Add the flat image as a file in the ISO root
import io
iso.add_fp(
    fp=io.BytesIO(flat_data),
    length=len(flat_data),
    iso_path='/CLAUDEOS.IMG;1'
)

# Set up El Torito no-emulation boot
# boot_info_table=False - that patch overwrites bytes 8-55 of the boot image
# which is fine for ISOLINUX/GRUB but destroys our raw MBR code
iso.add_eltorito(
    bootfile_path='/CLAUDEOS.IMG;1',
    bootcatfile='/BOOT.CAT;1',
    media_name='noemul',
    boot_load_size=4,
    boot_info_table=False
)

iso.write(ISO_OUT)
iso.close()

size = os.path.getsize(ISO_OUT)
print(f"[mkiso] Done. {ISO_OUT} = {size} bytes ({size//2048} sectors)")