#!/usr/bin/env python3
# ===========================================================================
# mkdata.py - Create a blank ClaudeFS Data disk image (data.img)
#
# Layout:
#   Sector 0:       FS header (512 bytes)
#     +0   4 bytes  magic = 0x434C4644 ("CLFD")
#     +4   2 bytes  version = 1
#     +6   2 bytes  max file entries = 64
#     +8   4 bytes  data area start sector = 1 + ceil(64*32/512) = 5
#     +12  4 bytes  total sectors = 8192 (4MB)
#     +16  4 bytes  used file count = 0
#     +20  492 bytes padding
#   Sectors 1-4:    Directory (64 entries x 32 bytes = 2048 bytes)
#     Each entry:
#     +0   16 bytes filename (null-padded)
#     +16   4 bytes start sector (0 = free)
#     +20   4 bytes file size in bytes
#     +24   4 bytes flags (0=free, 1=used)
#     +28   4 bytes reserved
#   Sectors 5+:     File data
#
# ===========================================================================
import struct, os

MAGIC        = b'CLFD'
VERSION      = 1
MAX_ENTRIES  = 64
ENTRY_SIZE   = 32
DIR_SECTORS  = (MAX_ENTRIES * ENTRY_SIZE + 511) // 512   # = 4
DATA_START   = 1 + DIR_SECTORS                           # = 5
TOTAL_SECTS  = 8192   # 4MB
IMG_SIZE     = TOTAL_SECTS * 512

OUTPUT = 'data.img'

if os.path.exists(OUTPUT):
    print(f'[mkdata] {OUTPUT} already exists — skipping (delete to recreate)')
else:
    img = bytearray(IMG_SIZE)

    # Sector 0: header
    struct.pack_into('<4sHHIIII', img, 0,
        MAGIC,
        VERSION,
        MAX_ENTRIES,
        DATA_START,
        TOTAL_SECTS,
        0,          # used count
        0           # reserved
    )

    # Sectors 1-4: blank directory (already zero)

    with open(OUTPUT, 'wb') as f:
        f.write(img)

    print(f'[mkdata] Created {OUTPUT} ({IMG_SIZE} bytes, {TOTAL_SECTS} sectors)')
    print(f'         Directory: sectors 1-{DIR_SECTORS} ({MAX_ENTRIES} entries x {ENTRY_SIZE} bytes)')
    print(f'         Data area: sector {DATA_START} onwards')