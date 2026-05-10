#!/usr/bin/env python3
# ===========================================================================
# inject.py  -  FAT16 Data disk tool
#
# Reads and writes files on data.img using the FAT16 filesystem format.
#
# Usage:
#   python inject.py list                  - list all files
#   python inject.py put <file> [name]     - add file (name defaults to 8.3 filename)
#   python inject.py get <name> [outfile]  - extract a file
#   python inject.py del <name>            - delete a file
#   python inject.py format                - wipe all files (re-init FATs/Root)
#
# ===========================================================================

import sys
import os
import struct

DISK = 'data.img'
SECTOR_SIZE = 512

def read_sector(f, lba, count=1):
    f.seek(lba * SECTOR_SIZE)
    return bytearray(f.read(SECTOR_SIZE * count))

def write_sector(f, lba, data):
    f.seek(lba * SECTOR_SIZE)
    f.write(data)

class FAT16:
    def __init__(self, f):
        self.f = f
        # Read BPB
        bpb = read_sector(f, 0)
        self.bytes_per_sec = struct.unpack_from('<H', bpb, 11)[0]
        self.sec_per_clus = struct.unpack_from('<B', bpb, 13)[0]
        self.res_sec_cnt = struct.unpack_from('<H', bpb, 14)[0]
        self.num_fats = struct.unpack_from('<B', bpb, 16)[0]
        self.root_ent_cnt = struct.unpack_from('<H', bpb, 17)[0]
        self.tot_sec = struct.unpack_from('<H', bpb, 19)[0]
        if self.tot_sec == 0:
            self.tot_sec = struct.unpack_from('<I', bpb, 32)[0]
        self.fat_sz = struct.unpack_from('<H', bpb, 22)[0]
        
        self.fat_lba = self.res_sec_cnt
        self.root_lba = self.fat_lba + (self.num_fats * self.fat_sz)
        self.root_sects = (self.root_ent_cnt * 32 + self.bytes_per_sec - 1) // self.bytes_per_sec
        self.data_lba = self.root_lba + self.root_sects
        
        # Load first FAT
        self.fat = list(struct.unpack(f'<{self.fat_sz * self.bytes_per_sec // 2}H', 
                                     read_sector(f, self.fat_lba, self.fat_sz)))

    def flush_fats(self):
        fat_data = struct.pack(f'<{len(self.fat)}H', *self.fat)
        for i in range(self.num_fats):
            write_sector(self.f, self.fat_lba + (i * self.fat_sz), fat_data)

    def get_cluster_lba(self, clus):
        return self.data_lba + (clus - 2) * self.sec_per_clus

    def read_root(self):
        return read_sector(self.f, self.root_lba, self.root_sects)

    def write_root(self, data):
        write_sector(self.f, self.root_lba, data)

    def name_to_83(self, name):
        name = name.upper()
        if '.' in name:
            base, ext = name.split('.', 1)
        else:
            base, ext = name, ''
        return base[:8].ljust(8) + ext[:3].ljust(3)

    def name_from_83(self, raw):
        base = raw[:8].decode('ascii', errors='replace').strip()
        ext = raw[8:11].decode('ascii', errors='replace').strip()
        return f"{base}.{ext}" if ext else base

    def find_free_cluster(self):
        for i in range(2, len(self.fat)):
            if self.fat[i] == 0:
                return i
        return None

    def alloc_chain(self, size):
        needed = (size + self.sec_per_clus * self.bytes_per_sec - 1) // (self.sec_per_clus * self.bytes_per_sec)
        chain = []
        for _ in range(needed):
            c = self.find_free_cluster()
            if c is None: return None
            if chain: self.fat[chain[-1]] = c
            chain.append(c)
            self.fat[c] = 0xFFFF # End of chain marker
        return chain

def cmd_list():
    with open(DISK, 'rb') as f:
        fs = FAT16(f)
        root = fs.read_root()
        print(f'FAT16 Data - {DISK}')
        print(f'  {"Name":<12}  {"Size":>8}  {"Cluster":>6}')
        print(f'  {"-"*12}  {"-"*8}  {"-"*6}')
        found = False
        for i in range(fs.root_ent_cnt):
            entry = root[i*32 : (i+1)*32]
            if entry[0] == 0: break
            if entry[0] == 0xE5: continue
            if entry[11] & 0x18: continue # skip subdir/label
            name = fs.name_from_83(entry[:11])
            size = struct.unpack_from('<I', entry, 28)[0]
            clus = struct.unpack_from('<H', entry, 26)[0]
            print(f'  {name:<12}  {size:>8}  {clus:>6}')
            found = True
        if not found: print('  (empty)')

def cmd_put(filepath, name=None):
    if not os.path.exists(filepath):
        print(f'ERROR: {filepath} not found'); sys.exit(1)
    if name is None: name = os.path.basename(filepath)
    with open(filepath, 'rb') as f: data = f.read()
    
    with open(DISK, 'r+b') as f:
        fs = FAT16(f)
        root = fs.read_root()
        target_name_83 = fs.name_to_83(name).encode('ascii')
        
        # Check if exists
        free_idx = None
        for i in range(fs.root_ent_cnt):
            entry = root[i*32 : (i+1)*32]
            if entry[0] == 0 or entry[0] == 0xE5:
                if free_idx is None: free_idx = i
                if entry[0] == 0: break
                continue
            if entry[:11] == target_name_83:
                print(f'ERROR: "{name}" already exists'); sys.exit(1)
        
        if free_idx is None: print('ERROR: Root directory full'); sys.exit(1)
        
        # Alloc clusters
        chain = fs.alloc_chain(len(data))
        if chain is None: print('ERROR: Disk full'); sys.exit(1)
        
        # Write data
        for i, clus in enumerate(chain):
            chunk = data[i * fs.sec_per_clus * fs.bytes_per_sec : (i+1) * fs.sec_per_clus * fs.bytes_per_sec]
            chunk = chunk.ljust(fs.sec_per_clus * fs.bytes_per_sec, b'\x00')
            for s in range(fs.sec_per_clus):
                write_sector(f, fs.get_cluster_lba(clus) + s, chunk[s*512:(s+1)*512])

        # Write dir entry
        off = free_idx * 32
        root[off : off+11] = target_name_83
        root[off+11] = 0x20 # Archive attr
        # zero out times/dates for simplicity
        root[off+12 : off+26] = b'\x00' * 14
        struct.pack_into('<H', root, off+26, chain[0])
        struct.pack_into('<I', root, off+28, len(data))
        fs.write_root(root)
        fs.flush_fats()
        print(f'  + {name:<12}  {len(data):>8} bytes  cluster {chain[0]}')

def cmd_get(name, outfile=None):
    if outfile is None: outfile = name
    with open(DISK, 'rb') as f:
        fs = FAT16(f)
        root = fs.read_root()
        target_name_83 = fs.name_to_83(name).encode('ascii')
        
        idx = None
        for i in range(fs.root_ent_cnt):
            entry = root[i*32 : (i+1)*32]
            if entry[0] == 0: break
            if entry[:11] == target_name_83:
                idx = i; break
        if idx is None: print(f'ERROR: "{name}" not found'); sys.exit(1)
        
        entry = root[idx*32 : (idx+1)*32]
        size = struct.unpack_from('<I', entry, 28)[0]
        clus = struct.unpack_from('<H', entry, 26)[0]
        
        data = bytearray()
        while clus >= 2 and clus < 0xFFF7:
            data.extend(read_sector(f, fs.get_cluster_lba(clus), fs.sec_per_clus))
            clus = fs.fat[clus]
        
        with open(outfile, 'wb') as out: out.write(data[:size])
        print(f'  Extracted "{name}" -> {outfile} ({len(data[:size])} bytes)')

def cmd_del(name):
    with open(DISK, 'r+b') as f:
        fs = FAT16(f)
        root = fs.read_root()
        target_name_83 = fs.name_to_83(name).encode('ascii')
        
        idx = None
        for i in range(fs.root_ent_cnt):
            entry = root[i*32 : (i+1)*32]
            if entry[0] == 0: break
            if entry[:11] == target_name_83:
                idx = i; break
        if idx is None: print(f'ERROR: "{name}" not found'); sys.exit(1)
        
        clus = struct.unpack_from('<H', root, idx*32 + 26)[0]
        # Free chain
        while clus >= 2 and clus < 0xFFF7:
            next_clus = fs.fat[clus]
            fs.fat[clus] = 0
            clus = next_clus
        
        # Mark as deleted
        root[idx*32] = 0xE5
        fs.write_root(root)
        fs.flush_fats()
        print(f'  Deleted "{name}"')

def cmd_format():
    ans = input(f'Format {DISK} to empty FAT16? [y/N] ')
    if ans.lower() != 'y': return
    # Reuse mkdata.py logic or just zero FATs/Root
    import subprocess
    subprocess.run([sys.executable, 'mkdata.py'])

def usage():
    print('FAT16 Data disk tool\n\nUsage:\n  inject.py list\n  inject.py put <file> [name]\n  inject.py get <name> [out]\n  inject.py del <name>\n  inject.py format')
    sys.exit(1)

if __name__ == '__main__':
    if not os.path.exists(DISK): print(f'ERROR: {DISK} not found. Run mkdata.py first.'); sys.exit(1)
    if len(sys.argv) < 2: usage()
    cmd = sys.argv[1].lower()
    if cmd == 'list': cmd_list()
    elif cmd == 'put': 
        if len(sys.argv) < 3: usage()
        cmd_put(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == 'get':
        if len(sys.argv) < 3: usage()
        cmd_get(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == 'del':
        if len(sys.argv) < 3: usage()
        cmd_del(sys.argv[2])
    elif cmd == 'format': cmd_format()
    else: usage()