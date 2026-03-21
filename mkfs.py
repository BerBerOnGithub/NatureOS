#!/usr/bin/env python3
# ===========================================================================
# mkfs.py - ClaudeOS Filesystem Packer
#
# Scans the apps/ folder for .bin files and packs them into fs.bin.
#
# Filesystem format (ClaudeFS):
#   Offset 0:   4 bytes  magic       = 0x434C4653 ("CLFS")
#   Offset 4:   2 bytes  file count
#   Offset 6:   N * 24 bytes directory entries:
#       +0:  16 bytes  filename (null-padded, no extension)
#       +16:  4 bytes  offset from start of fs.bin  (uint32 LE)
#       +20:  4 bytes  file size in bytes            (uint32 LE)
#   After directory: file data packed sequentially
#
# Usage:
#   python mkfs.py              reads apps/*.bin, writes build/fs.bin
# ===========================================================================

import os
import sys
import struct
import subprocess
import glob

APPS_DIR   = 'apps'
OUTPUT     = os.path.join('build', 'fs.bin')
MAGIC      = b'CLFS'
MAX_FILES  = 32
NAME_LEN   = 16
ENTRY_SIZE = NAME_LEN + 4 + 4   # 24 bytes

def assemble_apps():
    """Find all .asm files in apps/ (recursively) and assemble them to .bin"""
    asm_files = glob.glob(os.path.join(APPS_DIR, '**', '*.asm'), recursive=True)
    if not asm_files:
        return
    for asm_path in sorted(asm_files):
        bin_path = os.path.splitext(asm_path)[0] + '.bin'
        # skip if .bin is already newer than .asm
        if os.path.exists(bin_path) and os.path.getmtime(bin_path) >= os.path.getmtime(asm_path):
            print(f'  ~ {os.path.basename(asm_path)} (up to date)')
            continue
        print(f'  * assembling {os.path.basename(asm_path)}...')
        result = subprocess.run(
            ['nasm', '-f', 'bin', '-o', bin_path, asm_path],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f'ERROR assembling {asm_path}:')
            print(result.stderr)
            sys.exit(1)
        print(f'    -> {os.path.basename(bin_path)} ({os.path.getsize(bin_path)} bytes)')

def main():
    if not os.path.isdir(APPS_DIR):
        print(f'  No {APPS_DIR}/ folder found - creating empty fs.bin')
        files = []
    else:
        assemble_apps()
        files = sorted([
            f for f in os.listdir(APPS_DIR)
            if f.lower().endswith('.bin') or f.lower().endswith('.bmp')
        ])

    if len(files) > MAX_FILES:
        print(f'ERROR: too many files (max {MAX_FILES})')
        sys.exit(1)

    print(f'[mkfs] Packing {len(files)} file(s) into {OUTPUT}')

    # - calculate offsets -
    dir_size    = 6 + len(files) * ENTRY_SIZE   # header + directory
    data_offset = dir_size
    entries = []
    blobs   = []

    for fname in files:
        path = os.path.join(APPS_DIR, fname)
        with open(path, 'rb') as f:
            data = f.read()
        # strip extension for stored name
        name = os.path.splitext(fname)[0][:NAME_LEN - 1]
        name_bytes = name.encode('ascii') + b'\x00' * (NAME_LEN - len(name))
        entries.append((name_bytes, data_offset, len(data)))
        blobs.append(data)
        print(f'  + {fname:<20} {len(data):>6} bytes  offset=0x{data_offset:04X}')
        data_offset += len(data)

    # - write fs.bin -
    os.makedirs('build', exist_ok=True)
    with open(OUTPUT, 'wb') as out:
        # header
        out.write(MAGIC)
        out.write(struct.pack('<H', len(files)))
        # directory
        for (name_bytes, offset, size) in entries:
            out.write(name_bytes)
            out.write(struct.pack('<I', offset))
            out.write(struct.pack('<I', size))
        # file data
        for blob in blobs:
            out.write(blob)

    total = os.path.getsize(OUTPUT)
    print(f'[mkfs] Done. fs.bin = {total} bytes ({(total+511)//512} sectors)')

if __name__ == '__main__':
    main()