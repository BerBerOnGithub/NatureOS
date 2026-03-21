#!/usr/bin/env python3
# ===========================================================================
# inject.py  -  ClaudeFS Data disk tool
#
# Reads and writes files on data.img using the CLFD filesystem format.
#
# Usage:
#   python inject.py list                  - list all files
#   python inject.py put <file> [name]     - add file (name defaults to filename)
#   python inject.py get <name> [outfile]  - extract a file
#   python inject.py del <name>            - delete a file
#   python inject.py format                - wipe all files (keep header)
#
# CLFD layout (matches mkdata.py and fs_data.asm):
#   Sector 0:       Header
#     +0   4 bytes  magic "CLFD"
#     +4   2 bytes  version
#     +6   2 bytes  max entries (64)
#     +8   4 bytes  data start sector (5)
#     +12  4 bytes  total sectors
#     +16  4 bytes  used count
#   Sectors 1-4:    Directory (64 x 32 bytes)
#     +0  16 bytes  filename (null-padded)
#     +16  4 bytes  start sector
#     +20  4 bytes  file size in bytes
#     +24  4 bytes  flags (0=free, 1=used)
#     +28  4 bytes  reserved
#   Sectors 5+:     File data
# ===========================================================================

import sys
import os
import struct

DISK        = 'data.img'
MAGIC       = b'CLFD'
SECTOR      = 512
MAX_ENT     = 64
ENT_SZ      = 32
NAME_LEN    = 16
DIR_LBA     = 1
DIR_SECTS   = 4
DATA_START  = 5
HDR_LBA     = 0
FLAG_FREE   = 0
FLAG_USED   = 1

# - helpers -

def read_sector(f, lba, count=1):
    f.seek(lba * SECTOR)
    return bytearray(f.read(SECTOR * count))

def write_sector(f, lba, data):
    f.seek(lba * SECTOR)
    f.write(data)

def read_header(f):
    raw = read_sector(f, HDR_LBA)
    if raw[:4] != MAGIC:
        raise ValueError(f'Bad magic: {raw[:4]!r} (expected {MAGIC!r})')
    version, max_ent, data_start, total_sects, used = struct.unpack_from('<HHIII', raw, 4)
    return {'version': version, 'max_ent': max_ent, 'data_start': data_start,
            'total_sects': total_sects, 'used': used, 'raw': raw}

def write_header(f, hdr):
    raw = bytearray(hdr['raw'])
    struct.pack_into('<HHIII', raw, 4,
        hdr['version'], hdr['max_ent'], hdr['data_start'],
        hdr['total_sects'], hdr['used'])
    write_sector(f, HDR_LBA, bytes(raw))

def read_dir(f):
    raw = read_sector(f, DIR_LBA, DIR_SECTS)
    entries = []
    for i in range(MAX_ENT):
        off = i * ENT_SZ
        name_b, start, size, flags, _ = struct.unpack_from('<16sIII4s', raw, off)
        name = name_b.rstrip(b'\x00').decode('ascii', errors='replace')
        entries.append({'name': name, 'start': start, 'size': size,
                        'flags': flags, 'idx': i})
    return entries, raw

def write_dir(f, raw_dir):
    write_sector(f, DIR_LBA, bytes(raw_dir))

def set_entry(raw_dir, idx, name, start, size, flags):
    off = idx * ENT_SZ
    name_b = name.encode('ascii')[:NAME_LEN-1].ljust(NAME_LEN, b'\x00')
    struct.pack_into('<16sIII4s', raw_dir, off,
        name_b, start, size, flags, b'\x00\x00\x00\x00')

def alloc_sector(entries, total_sects):
    """Find first free sector after DATA_START by high-watermark"""
    high = DATA_START
    for e in entries:
        if e['flags'] == FLAG_USED:
            end = e['start'] + (e['size'] + SECTOR - 1) // SECTOR
            if end > high:
                high = end
    return high

def sizeof_fmt(n):
    if n < 1024:
        return f'{n}b'
    elif n < 1024*1024:
        return f'{n//1024}Kb'
    else:
        return f'{n//(1024*1024)}Mb'

# - commands -

def cmd_list():
    with open(DISK, 'rb') as f:
        hdr = read_header(f)
        entries, _ = read_dir(f)
    used = [e for e in entries if e['flags'] == FLAG_USED]
    print(f'ClaudeFS Data - {DISK}')
    print(f'  {hdr["used"]} file(s) used, {hdr["total_sects"]} sectors total '
          f'({hdr["total_sects"]*SECTOR//1024}Kb disk)')
    print()
    if not used:
        print('  (empty)')
        return
    print(f'  {"Name":<16}  {"Size":>8}  {"Sector":>6}')
    print(f'  {"-"*16}  {"-"*8}  {"-"*6}')
    for e in used:
        print(f'  {e["name"]:<16}  {sizeof_fmt(e["size"]):>8}  {e["start"]:>6}')

def cmd_put(filepath, name=None):
    if not os.path.exists(filepath):
        print(f'ERROR: {filepath} not found')
        sys.exit(1)

    if name is None:
        name = os.path.splitext(os.path.basename(filepath))[0]
    name = name[:NAME_LEN-1]

    with open(filepath, 'rb') as f:
        data = f.read()

    with open(DISK, 'r+b') as f:
        hdr = read_header(f)
        entries, raw_dir = read_dir(f)

        # check not already exists
        for e in entries:
            if e['flags'] == FLAG_USED and e['name'] == name:
                print(f'ERROR: "{name}" already exists. Delete it first.')
                sys.exit(1)

        # find free directory slot
        free_slot = None
        for e in entries:
            if e['flags'] == FLAG_FREE:
                free_slot = e['idx']
                break
        if free_slot is None:
            print('ERROR: directory full (64 files max)')
            sys.exit(1)

        # allocate sectors
        start_lba = alloc_sector(entries, hdr['total_sects'])
        sects_needed = (len(data) + SECTOR - 1) // SECTOR
        if start_lba + sects_needed > hdr['total_sects']:
            print(f'ERROR: disk full (need {sects_needed} sectors, '
                  f'{hdr["total_sects"] - start_lba} free)')
            sys.exit(1)

        # write file data
        padded = data + b'\x00' * (sects_needed * SECTOR - len(data))
        for i, lba in enumerate(range(start_lba, start_lba + sects_needed)):
            write_sector(f, lba, padded[i*SECTOR:(i+1)*SECTOR])

        # write directory entry
        set_entry(raw_dir, free_slot, name, start_lba, len(data), FLAG_USED)
        write_dir(f, raw_dir)

        # update header
        hdr['used'] += 1
        write_header(f, hdr)

    print(f'  + {name:<16}  {sizeof_fmt(len(data)):>8}  sector {start_lba}')

def cmd_get(name, outfile=None):
    if outfile is None:
        outfile = name + '.bin'
    with open(DISK, 'rb') as f:
        hdr = read_header(f)
        entries, _ = read_dir(f)
        entry = next((e for e in entries if e['flags'] == FLAG_USED and e['name'] == name), None)
        if entry is None:
            print(f'ERROR: "{name}" not found')
            sys.exit(1)
        sects = (entry['size'] + SECTOR - 1) // SECTOR
        raw = read_sector(f, entry['start'], sects)
        data = bytes(raw[:entry['size']])

    with open(outfile, 'wb') as f:
        f.write(data)
    print(f'  Extracted "{name}" -> {outfile} ({sizeof_fmt(len(data))})')

def cmd_del(name):
    with open(DISK, 'r+b') as f:
        hdr = read_header(f)
        entries, raw_dir = read_dir(f)
        entry = next((e for e in entries if e['flags'] == FLAG_USED and e['name'] == name), None)
        if entry is None:
            print(f'ERROR: "{name}" not found')
            sys.exit(1)
        # zero the directory entry
        off = entry['idx'] * ENT_SZ
        raw_dir[off:off+ENT_SZ] = b'\x00' * ENT_SZ
        write_dir(f, raw_dir)
        hdr['used'] = max(0, hdr['used'] - 1)
        write_header(f, hdr)
    print(f'  Deleted "{name}"')

def cmd_format():
    ans = input(f'Wipe all files from {DISK}? [y/N] ')
    if ans.lower() != 'y':
        print('Aborted.')
        return
    with open(DISK, 'r+b') as f:
        # zero directory
        write_sector(f, DIR_LBA, b'\x00' * (DIR_SECTS * SECTOR))
        # reset used count
        hdr = read_header(f)
        hdr['used'] = 0
        write_header(f, hdr)
    print('  Formatted. All files removed.')

# - main -

def usage():
    print('ClaudeFS Data disk tool')
    print()
    print('Usage:')
    print('  inject.py list')
    print('  inject.py put <file> [stored_name]')
    print('  inject.py get <name> [output_file]')
    print('  inject.py del <name>')
    print('  inject.py format')
    sys.exit(1)

if __name__ == '__main__':
    if not os.path.exists(DISK):
        print(f'ERROR: {DISK} not found. Run mkdata.py first.')
        sys.exit(1)

    if len(sys.argv) < 2:
        usage()

    cmd = sys.argv[1].lower()

    try:
        if cmd == 'list':
            cmd_list()
        elif cmd == 'put':
            if len(sys.argv) < 3:
                usage()
            name = sys.argv[3] if len(sys.argv) > 3 else None
            cmd_put(sys.argv[2], name)
        elif cmd == 'get':
            if len(sys.argv) < 3:
                usage()
            out = sys.argv[3] if len(sys.argv) > 3 else None
            cmd_get(sys.argv[2], out)
        elif cmd == 'del':
            if len(sys.argv) < 3:
                usage()
            cmd_del(sys.argv[2])
        elif cmd == 'format':
            cmd_format()
        else:
            usage()
    except ValueError as e:
        print(f'ERROR: {e}')
        sys.exit(1)