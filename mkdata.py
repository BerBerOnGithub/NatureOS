#!/usr/bin/env python3
# ===========================================================================
# mkdata.py - Create a blank FAT16 Data disk image (data.img)
#
# Layout (FAT16 4MB):
#   Sector 0:       BPB (Boot Parameter Block)
#   Sector 1-8:     FAT1
#   Sector 9-16:    FAT2
#   Sector 17-48:   Root Directory (512 entries * 32 bytes = 16KB = 32 sectors)
#   Sector 49+:     Data area
#
# ===========================================================================
import struct, os

OUTPUT = 'data.img'
TOTAL_SECTS  = 8192   # 4MB
IMG_SIZE     = TOTAL_SECTS * 512

# FAT16 BPB Parameters
BS_jmpBoot      = b'\xEB\x3C\x90'
BS_OEMName      = b'MSDOS5.0'
BPB_BytsPerSec  = 512
BPB_SecPerClus  = 4
BPB_RsvdSecCnt  = 1
BPB_NumFATs      = 2
BPB_RootEntCnt  = 512
BPB_TotSec16    = 8192
BPB_Media       = 0xF8
BPB_FATSz16     = 8
BPB_SecPerTrk   = 32
BPB_NumHeads    = 64
BPB_HiddSec     = 0
BPB_TotSec32    = 0
BS_DrvNum       = 0x80
BS_Reserved1    = 0
BS_BootSig      = 0x29
BS_VolID        = 0x12345678
BS_VolLab       = b'NATURE DATA'
BS_FilSysType   = b'FAT16   '

if os.path.exists(OUTPUT):
    print(f'[mkdata] {OUTPUT} already exists - overwriting with FAT16')

img = bytearray(IMG_SIZE)

# Sector 0: BPB
struct.pack_into('<3s8sHBHBHHBHHHIIBBBI11s8s', img, 0,
    BS_jmpBoot,
    BS_OEMName,
    BPB_BytsPerSec,
    BPB_SecPerClus,
    BPB_RsvdSecCnt,
    BPB_NumFATs,
    BPB_RootEntCnt,
    BPB_TotSec16,
    BPB_Media,
    BPB_FATSz16,
    BPB_SecPerTrk,
    BPB_NumHeads,
    BPB_HiddSec,
    BPB_TotSec32,
    BS_DrvNum,
    BS_Reserved1,
    BS_BootSig,
    BS_VolID,
    BS_VolLab,
    BS_FilSysType
)

# Boot signature 0xAA55
img[510] = 0x55
img[511] = 0xAA

# Initialize FATs (Sector 0: Media byte + 0xFFFF)
for fat_start in [1 * 512, 9 * 512]:
    img[fat_start : fat_start + 4] = struct.pack('<BBH', BPB_Media, 0xFF, 0xFFFF)

with open(OUTPUT, 'wb') as f:
    f.write(img)

print(f'[mkdata] Created FAT16 {OUTPUT} ({IMG_SIZE} bytes, {TOTAL_SECTS} sectors)')
print(f'         FATs: 1-8, 9-16  Root Dir: 17-48  Data: 49+')