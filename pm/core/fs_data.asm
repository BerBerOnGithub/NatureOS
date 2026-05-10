; ===========================================================================
; pm/fs_data.asm  -  NatureFS Data Disk (read/write, ATA drive 1)
;
; Disk layout (matches mkdata.py):
;   Sector 0:       Header (512 bytes)
;     +0   4 bytes  magic "CLFD"

;     +4   2 bytes  version
;     +6   2 bytes  max entries (64)
;     +8   4 bytes  data start sector (5)
;     +12  4 bytes  total sectors
;     +16  4 bytes  used file count
;   Sectors 1-4:    Directory (64 x 32 bytes)
;     +0  16 bytes  filename (null-padded)
;     +16  4 bytes  start sector
;     +20  4 bytes  file size in bytes
;     +24  4 bytes  flags (0=free, 1=used)
;     +28  4 bytes  reserved
;   Sectors 5+:     File data
;
; Public:
;   fsd_init        - read header+dir from disk into RAM cache
;   fsd_find        - ESI=name - - CF=0: EAX=entry ptr; CF=1: not found
;   fsd_read_file   - EAX=entry ptr, EDI=dest - - ECX=bytes read
;   fsd_create      - ESI=name, EDI=data, ECX=size - - CF=0 ok, CF=1 full/err
;   fsd_delete      - ESI=name - - CF=0 ok, CF=1 not found
;   fsd_list        - EDI=callback(entry_ptr): called for each used entry
;   fsd_ready       db - 1 if disk found and valid
; ===========================================================================

[BITS 32]

FSD_MAGIC       equ FS_DATA_MAGIC_VAL
FSD_MAX_ENT     equ 64

FSD_ENT_SZ      equ 32
FSD_NAME_LEN    equ 16
FSD_DIR_SECTS   equ 4            ; sectors 1-4
FSD_DIR_LBA     equ 1
FSD_DATA_START  equ 5
FSD_HDR_LBA     equ 0
FSD_ALLOC_UNIT  equ 8            ; allocate in 8-sector (4KB) chunks

; Entry flags
FSD_FLAG_FREE   equ 0
FSD_FLAG_USED   equ 1

; FAT16 BPB Offsets
BPB_SECTS_PER_CLUS equ 13
BPB_RES_SECTS      equ 14
BPB_FAT_COUNT      equ 16
BPB_ROOT_ENTRIES   equ 17
BPB_SECTS_PER_FAT  equ 22

; - fsd_init -
; Read header + directory into RAM. Sets fsd_ready.
fsd_init:
    pusha
    mov  byte [fsd_ready], 0
    mov  byte [fsd_type], FSTYPE_NONE

    cmp  byte [bd_ready], 1
    jne  .done

    ; get storage info from safe BIOS ICA area (set by stage2)
    movzx eax, byte [0x04F0]
    mov  [bd_drive], al
    movzx eax, byte [0x04F1]
    mov  [fsd_type], al

    cmp  al, FSTYPE_FAT16
    je   .init_fat16
    cmp  al, FSTYPE_CLFD
    je   .init_clfd
    jmp  .done

.init_fat16:
    call fsd_init_fat16
    jmp  .done

.init_clfd:
    call fsd_init_clfd
    jmp  .done

.done:
    popa
    ret

; - fsd_init_clfd -
fsd_init_clfd:
    pusha
    ; reload header (sector 0) from disk
    mov  eax, FSD_HDR_LBA
    mov  ecx, 1
    mov  edi, fsd_hdr_buf
    call bios_disk_read
    jc   .err

    ; verify magic
    cmp  dword [fsd_hdr_buf], FSD_MAGIC
    jne  .err

    ; cache used count
    mov  eax, [fsd_hdr_buf + 16]
    mov  [fsd_used], eax

    ; reload directory (4 sectors) from disk
    mov  eax, FSD_DIR_LBA
    mov  ecx, FSD_DIR_SECTS
    mov  edi, fsd_dir_buf
    call bios_disk_read
    jc   .err

    mov  byte [fsd_ready], 1
.err:
    popa
    ret


; - fsd_flush_dir -
; Write directory + header back to disk. Internal.
fsd_flush_dir:
    pusha

    ; update used count in header buf
    mov  eax, [fsd_used]
    mov  [fsd_hdr_buf + 16], eax

    ; write header
    mov  eax, FSD_HDR_LBA
    mov  ecx, 1
    mov  esi, fsd_hdr_buf
    call bios_disk_write

    ; write directory
    mov  eax, FSD_DIR_LBA
    mov  ecx, FSD_DIR_SECTS
    mov  esi, fsd_dir_buf
    call bios_disk_write

    popa
    ret

; - fsd_find -
; In:  ESI = null-terminated filename
; Out: CF=0 EAX = pointer to directory entry in fsd_dir_buf
;      CF=1 not found
fsd_find:
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   fsd_find_fat16
    cmp  byte [fsd_type], FSTYPE_CLFD
    je   fsd_find_clfd
    stc
    ret

; - fsd_list -
; Call EDI for each used entry. EDI = callback(EAX=entry_ptr).
fsd_list:
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   fsd_list_fat16
    cmp  byte [fsd_type], FSTYPE_CLFD
    je   fsd_list_clfd
    ret

; - fsd_list_clfd -
fsd_list_clfd:
    push eax
    push ebx
    push ecx
    push esi

    cmp  byte [bd_ready], 1
    jne  .done

    mov  esi, fsd_dir_buf
    mov  ebx, FSD_MAX_ENT
.loop:
    test ebx, ebx
    jz   .done
    cmp  dword [esi + 24], FSD_FLAG_USED
    jne  .next
    mov  eax, esi
    call edi
.next:
    add  esi, FSD_ENT_SZ
    dec  ebx
    jmp  .loop
.done:
    pop  esi
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - fsd_find_clfd -
fsd_find_clfd:
    push ebx
    push ecx
    push esi
    push edi

    cmp  byte [bd_ready], 1
    jne  .notfound

    mov  edi, fsd_dir_buf
    mov  ebx, FSD_MAX_ENT
.scan:
    test ebx, ebx
    jz   .notfound

    ; skip free entries
    cmp  dword [edi + 24], FSD_FLAG_USED
    jne  .next

    ; compare name
    push esi
    push edi
    mov  ecx, FSD_NAME_LEN
.cmp:
    mov  al, [esi]
    mov  ah, [edi]
    cmp  al, ah
    jne  .cmpfail
    test al, al
    jz   .cmpmatch
    inc  esi
    inc  edi
    loop .cmp
.cmpmatch:
    pop  edi
    pop  esi
    mov  eax, edi
    clc
    jmp  .done
.cmpfail:
    pop  edi
    pop  esi

.next:
    add  edi, FSD_ENT_SZ
    dec  ebx
    jmp  .scan

.notfound:
    stc
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  ebx
    ret

; - fsd_read_file -
; In:  EAX = pointer to directory entry
;      EDI = destination buffer
; Out: ECX = bytes read
fsd_read_file:
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   fsd_read_file_fat16
    cmp  byte [fsd_type], FSTYPE_CLFD
    je   fsd_read_file_clfd
    xor  ecx, ecx
    ret

; - fsd_read_file_clfd -
fsd_read_file_clfd:
    push eax
    push ebx
    push edx
    push esi

    mov  ebx, [eax + 16]    ; start sector
    mov  ecx, [eax + 20]    ; file size in bytes
    push ecx                ; save for return

    ; calculate sectors needed
    mov  edx, ecx
    add  edx, 511
    shr  edx, 9             ; ceil(size/512)

    mov  eax, ebx           ; LBA
    mov  ecx, edx           ; sector count
    call bios_disk_read            ; fills EDI

    pop  ecx                ; return byte count

    pop  esi
    pop  edx
    pop  ebx
    pop  eax
    ret

; - fsd_alloc_sector -
; Find a free run of sectors starting at FSD_DATA_START.
; In:  ECX = sectors needed
; Out: EAX = start sector, CF=1 if disk full
fsd_alloc_sector:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; build a simple bitmap of used sectors by scanning directory
    ; for now: linear allocation - find highest used sector + 1
    mov  eax, FSD_DATA_START
    mov  esi, fsd_dir_buf
    mov  ebx, FSD_MAX_ENT
.scan:
    test ebx, ebx
    jz   .found
    cmp  dword [esi + 24], FSD_FLAG_USED
    jne  .snext

    ; end of this file = start + ceil(size/512)
    mov  edx, [esi + 20]    ; size
    add  edx, 511
    shr  edx, 9             ; sectors used
    mov  edi, [esi + 16]    ; start sector
    add  edi, edx           ; end sector
    cmp  edi, eax
    jle  .snext
    mov  eax, edi           ; new high water mark

.snext:
    add  esi, FSD_ENT_SZ
    dec  ebx
    jmp  .scan

.found:
    ; check if we fit within total sectors
    mov  edx, [fsd_hdr_buf + 12]  ; total sectors
    mov  ebx, eax
    add  ebx, ecx
    cmp  ebx, edx
    jg   .full
    clc
    jmp  .done
.full:
    stc
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - fsd_create -
; Create a new file on the data disk.
; In:  ESI = null-terminated filename (max 15 chars)
;      EDI = data buffer
;      ECX = file size in bytes
; Out: CF=0 ok, CF=1 error (disk full, dir full, already exists)
; - fsd_create -
; In:  ESI = filename
;      ECX = file size in bytes
; Out: CF=0 ok, CF=1 error (disk full, dir full, already exists)
fsd_create:
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   fsd_create_fat16
    cmp  byte [fsd_type], FSTYPE_CLFD
    je   fsd_create_clfd
    stc
    ret

; - fsd_create_clfd -
fsd_create_clfd:
    pusha

    cmp  byte [bd_ready], 1
    jne  .err

    ; check name doesn't already exist
    push esi
    call fsd_find
    pop  esi
    jnc  .err               ; already exists

    ; find a free directory entry
    mov  edi, fsd_dir_buf
    mov  ebx, FSD_MAX_ENT
.find_free:
    test ebx, ebx
    jz   .err               ; directory full
    cmp  dword [edi + 24], FSD_FLAG_FREE
    je   .got_entry
    add  edi, FSD_ENT_SZ
    dec  ebx
    jmp  .find_free

.got_entry:
    ; EDI = free entry, ECX = file size
    push edi                ; save entry ptr
    push ecx                ; save size
    push esi                ; save name ptr

    ; allocate sectors
    mov  edx, ecx
    add  edx, 511
    shr  edx, 9             ; sectors needed
    mov  ecx, edx
    call fsd_alloc_sector
    jc   .err_pop3

    ; EAX = start sector
    pop  esi                ; restore name
    pop  ecx                ; restore size
    pop  edi                ; restore entry ptr

    ; fill directory entry
    push eax                ; save start sector
    push ecx                ; save size

    ; copy filename
    push esi
    push edi
    mov  ecx, FSD_NAME_LEN
    xor  eax, eax
    rep  stosb              ; zero the name field first
    pop  edi
    pop  esi
    push edi
.cpyname:
    mov  al, [esi]
    mov  [edi], al
    test al, al
    jz   .name_done
    inc  esi
    inc  edi
    jmp  .cpyname
.name_done:
    pop  edi

    pop  ecx                ; restore size
    pop  eax                ; restore start sector
    mov  [edi + 16], eax    ; start sector
    mov  [edi + 20], ecx    ; file size
    mov  dword [edi + 24], FSD_FLAG_USED
    mov  dword [edi + 28], 0

    ; write file data to disk
    push eax
    push ecx
    ; ESI still points to name - need original data ptr
    ; data is in fsd_write_buf (caller copies there first)
    ; actually: EDI was entry ptr, data ptr in fsd_create_data
    mov  esi, [fsd_create_data]
    mov  ecx, [edi + 20]
    add  ecx, 511
    shr  ecx, 9
    call bios_disk_write_multi    ; EAX=LBA, ECX=sectors, ESI=buf (chunked)
    pop  ecx
    pop  eax

    ; update used count
    inc  dword [fsd_used]

    ; flush directory to disk
    call fsd_flush_dir

    popa
    clc
    ret

.err_pop3:
    add  esp, 12
.err:
    popa
    stc
    ret

; - fsd_delete -
; In:  ESI = filename
; Out: CF=0 ok, CF=1 error (not found, etc)
fsd_delete:
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   fsd_delete_fat16
    cmp  byte [fsd_type], FSTYPE_CLFD
    je   fsd_delete_clfd
    stc
    ret

; - fsd_delete_clfd -
fsd_delete_clfd:
    pusha
    call fsd_find
    jc   .notfound

    ; EAX = entry ptr - zero the flags to mark free
    mov  dword [eax + 24], FSD_FLAG_FREE
    ; zero the name too
    push eax
    push ecx
    push edi
    mov  edi, eax
    mov  ecx, FSD_ENT_SZ / 4
    xor  eax, eax
    rep  stosd
    pop  edi
    pop  ecx
    pop  eax

    dec  dword [fsd_used]
    call fsd_flush_dir

    popa
    clc
    ret

.notfound:
    popa
    stc
    ret

; --- FAT16 Implementations ---

; - fsd_init_fat16 -
fsd_init_fat16:
    pusha
    ; reload BPB (sector 0) from disk
    mov  eax, 0
    mov  ecx, 1
    mov  edi, fsd_hdr_buf
    call bios_disk_read
    jc   .err

    ; simple sanity check (0xAA55 signature already checked by stage2)
    ; calculate Root Directory start LBA
    ; LBA_Root = RsvdSecCnt + (NumFATs * FATSz16)
    movzx eax, word [fsd_hdr_buf + BPB_RES_SECTS]
    movzx ecx, byte [fsd_hdr_buf + BPB_FAT_COUNT]
    movzx edx, word [fsd_hdr_buf + BPB_SECTS_PER_FAT]
    imul  ecx, edx
    add   eax, ecx
    mov   [bit16_root_lba], eax

    ; Root dir size in sectors = (RootEntCnt * 32) / 512
    movzx eax, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
    shl   eax, 5              ; * 32
    shr   eax, 9              ; / 512
    mov   [bit16_root_sects], eax

    ; Data area starts after root directory
    mov   ebx, [bit16_root_lba]
    add   ebx, eax
    mov   [bit16_data_lba], ebx

    ; Read root directory into fsd_dir_buf
    mov  eax, [bit16_root_lba]
    mov  ecx, [bit16_root_sects]
    cmp  ecx, FSD_DIR_SECTS   ; don't overflow our 2KB buffer
    jbe  .read_dir
    mov  ecx, FSD_DIR_SECTS
.read_dir:
    mov  edi, fsd_dir_buf
    call bios_disk_read
    jc   .err
    ; Read FAT into fsd_fat_buf
    movzx eax, word [fsd_hdr_buf + BPB_RES_SECTS]
    movzx ecx, word [fsd_hdr_buf + BPB_SECTS_PER_FAT]
    cmp  ecx, 8              ; don't overflow our 4KB buffer
    jbe  .read_fat
    mov  ecx, 8
.read_fat:
    mov  edi, fsd_fat_buf
    call bios_disk_read
    jc   .err
    ; Count used entries in root dir and set fsd_used
    mov  esi, fsd_dir_buf
    movzx ecx, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
    xor  eax, eax
.count_loop:
    mov  dl, [esi]
    test dl, dl
    jz   .count_done
    cmp  dl, 0xE5
    je   .count_next
    mov  dl, [esi + 11]
    test dl, 0x18            ; label or subdir
    jnz  .count_next
    inc  eax
.count_next:
    add  esi, 32
    loop .count_loop
.count_done:
    mov  [fsd_used], eax
    
    mov  byte [fsd_ready], 1
    popa
    clc
    ret

.err:
    popa
    stc
    ret

; - fsd_find_fat16 -
fsd_find_fat16:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    
    ; Convert null-terminated ESI to 11-byte 8.3 name in fat16_name_tmp
    mov  edi, fat16_name_tmp
    call fsd_name_to_83
    
    ; Scan root directory (fsd_dir_buf)
    mov  edi, fsd_dir_buf
    movzx ebx, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
.scan:
    test ebx, ebx
    jz   .notfound
    
    ; check first byte of entry
    mov  al, [edi]
    test al, al
    jz   .notfound           ; end of directory
    cmp  al, 0xE5
    je   .next               ; deleted
    
    ; skip volume labels or subdirs (for now we only support simple files)
    mov  al, [edi + 11]      ; attributes
    test al, 0x18            ; label or directory?
    jnz  .next
    
    ; compare 11-byte name
    push edi
    push esi
    mov  esi, fat16_name_tmp
    mov  ecx, 11
    repe cmpsb
    pop  esi
    pop  edi
    je   .found
    
.next:
    add  edi, 32
    dec  ebx
    jmp  .scan

.found:
    mov  eax, edi
    clc
    jmp  .done
.notfound:
    stc
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - fsd_read_file_fat16 -
; In: EAX = entry ptr, EDI = dest
fsd_read_file_fat16:
    pusha
    mov  ebx, eax            ; EBX = directory entry ptr
    movzx eax, word [ebx + 26] ; First cluster
    mov  [bit16_cur_clus], ax
    mov  ecx, [ebx + 28]      ; File size
    mov  [bit16_bytes_left], ecx
    push ecx                 ; save for return value
    
.cluster_loop:
    movzx eax, word [bit16_cur_clus]
    cmp  eax, 2              ; clusters start at 2
    jb   .done
    cmp  eax, 0xFFF7        ; end of chain mark
    jae  .done
    
    ; Convert cluster to LBA: DataLBA + (Clus-2) * SecPerClus
    sub  eax, 2
    movzx ecx, byte [fsd_hdr_buf + BPB_SECTS_PER_CLUS]
    imul eax, ecx
    add  eax, [bit16_data_lba]
    
    ; Read cluster
    ; ECX still contains SecPerClus
    call bios_disk_read      ; fills EDI
    
    ; advance EDI
    movzx edx, byte [fsd_hdr_buf + BPB_SECTS_PER_CLUS]
    shl  edx, 9              ; * 512
    add  edi, edx
    
    ; get next cluster from FAT
    movzx eax, word [bit16_cur_clus]
    call fsd_get_fat_entry
    mov  [bit16_cur_clus], ax
    jmp  .cluster_loop

.done:
    pop  ecx                 ; return size in ECX
    mov  [esp + 20], ecx     ; pusha's ECX slot
    popa
    ret

; - fsd_get_fat_entry -
; In: AX = cluster
; Out: AX = next cluster
fsd_get_fat_entry:
    push ebx
    movzx ebx, ax
    shl  ebx, 1
    movzx eax, word [fsd_fat_buf + ebx]
    pop  ebx
    ret

; - fsd_name_to_83 -
; In: ESI = "test.txt"
; Out: 11 bytes at EDI = "TEST    TXT"
fsd_name_to_83:
    pusha
    mov  ecx, 11
    mov  al, ' '
    rep  stosb               ; fill with spaces
    sub  edi, 11
    
    mov  cx, 8               ; max name part
.copy_name:
    lodsb
    test al, al
    jz   .done
    cmp  al, '.'
    je   .extension
    
    ; uppercase
    cmp  al, 'a'
    jb   .not_lower
    cmp  al, 'z'
    ja   .not_lower
    sub  al, 32
.not_lower:
    stosb
    dec  cx
    jnz  .copy_name
    ; skip to dot
.find_dot:
    lodsb
    test al, al
    jz   .done
    cmp  al, '.'
    jne  .find_dot

.extension:
    add  edi, ecx            ; hop to extension part
    mov  cx, 3
.copy_ext:
    lodsb
    test al, al
    jz   .done
    
    ; uppercase
    cmp  al, 'a'
    jb   .not_lower2
    cmp  al, 'z'
    ja   .not_lower2
    sub  al, 32
.not_lower2:
    stosb
    dec  cx
    jnz  .copy_ext
    
.done:
    popa
    ret

; - fsd_list_fat16 -
fsd_list_fat16:
    pusha
    mov  esi, fsd_dir_buf
    movzx ebx, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
.loop:
    test ebx, ebx
    jz   .done
    mov  al, [esi]
    test al, al
    jz   .done
    cmp  al, 0xE5
    je   .next
    mov  al, [esi + 11]
    test al, 0x18            ; label or subdir
    jnz  .next
    mov  eax, esi
    call edi                 ; call callback(entry_ptr)
.next:
    add  esi, 32
    dec  ebx
    jmp  .loop
.done:
    popa
    ret

; - fsd_83_to_name -
; In: ESI = 11-byte 8.3 "TEST    TXT"
; Out: 13-byte null-terminated at EDI = "test.txt"
fsd_83_to_name:
    pusha
    mov  ecx, 8              ; name part
.name_lp:
    mov  al, [esi]
    cmp  al, ' '
    je   .name_done
    
    ; lowercase
    cmp  al, 'A'
    jb   .not_upper
    cmp  al, 'Z'
    ja   .not_upper
    add  al, 32
.not_upper:
    stosb
    inc  esi
    loop .name_lp
    jmp  .ext_start
.name_done:
    add  esi, ecx            ; skip remaining spaces in name part
.ext_start:
    ; check if there is an extension
    mov  al, [esi]
    cmp  al, ' '
    je   .done
    
    mov  byte [edi], '.'
    inc  edi
    
    mov  ecx, 3
.ext_lp:
    mov  al, [esi]
    cmp  al, ' '
    je   .done
    
    ; lowercase
    cmp  al, 'A'
    jb   .not_upper2
    cmp  al, 'Z'
    ja   .not_upper2
    add  al, 32
.not_upper2:
    stosb
    inc  esi
    loop .ext_lp

.done:
    mov  byte [edi], 0
    popa
    ret

; --- FAT16 Write Implementations ---

; - fsd_serial_puts - write ESI string to COM1, trashes nothing
fsd_serial_puts:
    push eax
    push edx
    push esi
.sp_loop:
    mov  al, [esi]
    test al, al
    jz   .sp_done
.sp_wait:
    mov  dx, 0x3FD
    in   al, dx
    test al, 0x20
    jz   .sp_wait
    mov  dx, 0x3F8
    mov  al, [esi]
    out  dx, al
    inc  esi
    jmp  .sp_loop
.sp_done:
    pop  esi
    pop  edx
    pop  eax
    ret

; - fsd_create_fat16 -
fsd_create_fat16:
    pusha
    push esi
    mov  esi, fsd_dbg_create
    call fsd_serial_puts
    pop  esi
    
    cmp  byte [bd_ready], 1
    jne  .err
    
    ; 1. Check if exists
    push esi
    call fsd_find_fat16
    pop  esi
    jnc  .err                ; Already exists
    
    ; 2. Find free root directory entry
    mov  edi, fsd_dir_buf
    movzx ebx, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
    cmp  ebx, 64             ; Limit to our 2KB buffer
    jbe  .scan_dir
    mov  ebx, 64
.scan_dir:
    mov  al, [edi]
    test al, al
    jz   .got_entry
    cmp  al, 0xE5
    je   .got_entry
    add  edi, 32
    dec  ebx
    jnz  .scan_dir
    jmp  .err                ; Directory full
    
.got_entry:
    ; EDI = entry ptr
    push edi
    
    ; Stack at this point (36 bytes deep: pusha=32 + push edi=4):
    ; pusha pushes EAX,ECX,EDX,EBX,ESP,EBP,ESI,EDI (EDI last = [esp+0])
    ; [esp+ 0] = push edi (entry ptr)
    ; [esp+ 4] = pusha EDI
    ; [esp+ 8] = pusha ESI  <- original ESI (name ptr)
    ; [esp+12] = pusha EBP
    ; [esp+16] = pusha ESP
    ; [esp+20] = pusha EBX
    ; [esp+24] = pusha EDX
    ; [esp+28] = pusha ECX  <- original ECX (file size)
    ; [esp+32] = pusha EAX
    
    ; 3. Allocate clusters
    push esi
    mov  esi, fsd_dbg_alloc
    call fsd_serial_puts
    pop  esi
    mov  ecx, [esp + 28]      ; original ECX = file size
    call fsd_alloc_chain_fat16
    jc   .err_pop1
    
    ; EAX = first cluster
    mov  [bit16_start_clus], ax
    
    ; 4. Write data to clusters
    push esi
    mov  esi, fsd_dbg_wclus
    call fsd_serial_puts
    pop  esi
    mov  esi, [fsd_create_data]
    mov  ecx, [esp + 28]      ; original ECX = file size
    call fsd_write_clusters_fat16
    
    ; 5. Update directory entry
    pop  edi                 ; restore entry ptr  (esp now at pusha depth = 32)
    push edi                 ; repush            (esp back to 36)
    
    ; [esp+8] = pusha ESI = original name ptr
    mov  esi, [esp + 8]      ; original ESI (name ptr)
    call fsd_name_to_83
    
    pop  edi                 ; esp now at pusha depth = 32
    mov  al, 0x20            ; Archive
    mov  [edi + 11], al
    mov  ax, [bit16_start_clus]
    mov  [edi + 26], ax
    ; At pusha depth (32): ECX at [esp+24]
    mov  eax, [esp + 24]     ; original ECX = file size
    mov  [edi + 28], eax
    
    ; 6. Flush everything
    push esi
    mov  esi, fsd_dbg_flush
    call fsd_serial_puts
    pop  esi
    call fsd_flush_fat_fat16
    call fsd_flush_root_fat16
    
    inc  dword [fsd_used]
    clc
    popa
    ret

.err_pop1:
    pop  eax
.err:
    stc
    popa
    ret

; - fsd_alloc_chain_fat16 -
; In: ECX = total size in bytes
; Out: AX = first cluster, CF=0
fsd_alloc_chain_fat16:
    push ebx
    push ecx
    push edx
    push esi
    
    mov  ebx, ecx
    push dword 0xFFFF        ; placeholder
    
    ; Calculate needed clusters
    movzx esi, byte [fsd_hdr_buf + BPB_SECTS_PER_CLUS]
    test esi, esi
    jz   .disk_full          ; guard: sectors_per_cluster=0 means bad BPB
    
    push esi
    mov  esi, fsd_dbg_spc
    call fsd_serial_puts
    pop  esi
    shl  esi, 9              ; ESI = bytes/cluster
    
    mov  eax, ebx
    xor  edx, edx
    ; guard: if eax > 64MB something is very wrong, bail
    cmp  eax, 0x04000000
    ja   .disk_full
    div  esi
    test edx, edx
    jz   .even
    inc  eax                 ; EAX = num clusters needed
.even:
    mov  ebx, eax            ; EBX = count
    
    xor  esi, esi            ; ESI = first cluster
    mov  edx, 0xFFFF         ; EDX = previous cluster
    
.loop:
    test ebx, ebx
    jz   .done
    
    ; Find free cluster in fsd_fat_buf
    mov  ecx, 2              ; Skip reserved 0,1
.find:
    cmp  ecx, 2048           ; Limit for our 4MB disk
    jae  .disk_full
    cmp  word [fsd_fat_buf + ecx*2], 0
    je   .found
    inc  ecx
    jmp  .find

.found:
    mov  word [fsd_fat_buf + ecx*2], 0xFFFF ; mark as used (end of chain)
    
    test esi, esi
    jnz  .not_first
    mov  esi, ecx            ; save first cluster
    jmp  .linked
.not_first:
    mov  word [fsd_fat_buf + edx*2], cx ; link previous to this
.linked:
    mov  edx, ecx            ; current becomes previous
    dec  ebx
    jmp  .loop

.done:
    mov  eax, esi
    clc
    jmp  .ret
.disk_full:
    stc
.ret:
    add  esp, 4              ; remove placeholder
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - fsd_write_clusters_fat16 -
; In: EAX = first cluster, ESI = data, ECX = size
fsd_write_clusters_fat16:
    pusha
    mov  ebx, eax            ; EBX = current cluster
    mov  [bit16_bytes_left], ecx
    
.loop:
    cmp  ebx, 0xFFF7
    jae  .done
    
    ; Write one cluster
    ; LBA = DataLBA + (Clus-2) * SecPerClus
    mov  eax, ebx
    sub  eax, 2
    movzx ecx, byte [fsd_hdr_buf + BPB_SECTS_PER_CLUS]
    imul eax, ecx
    add  eax, [bit16_data_lba]
    
    ; ECX = SecPerClus
    ; BIOS disk write from [ESI]
    call bios_disk_write_multi ; ESI advanced automatically
    
    movzx edx, byte [fsd_hdr_buf + BPB_SECTS_PER_CLUS]
    shl  edx, 9              ; * 512 = bytes per cluster
    add  esi, edx

    ; Get next cluster
    movzx eax, bx
    cmp  eax, 2048           ; Limit for our 4MB disk (FAT cache size)
    jae  .done
    mov  ax, [fsd_fat_buf + eax*2]
    mov  bx, ax
    jmp  .loop

.done:
    popa
    ret

; - fsd_flush_fat_fat16 -
fsd_flush_fat_fat16:
    pusha
    movzx eax, word [fsd_hdr_buf + BPB_RES_SECTS] ; FAT1 LBA
    movzx ecx, word [fsd_hdr_buf + BPB_SECTS_PER_FAT]
    mov  esi, fsd_fat_buf
    call bios_disk_write_multi
    
    ; Flush FAT2 if exists
    cmp  byte [fsd_hdr_buf + BPB_FAT_COUNT], 2
    jb   .done
    movzx eax, word [fsd_hdr_buf + BPB_RES_SECTS]
    movzx edx, word [fsd_hdr_buf + BPB_SECTS_PER_FAT]
    add  eax, edx            ; FAT2 LBA
    mov  ecx, edx
    mov  esi, fsd_fat_buf
    call bios_disk_write_multi
.done:
    popa
    ret

; - fsd_flush_root_fat16 -
fsd_flush_root_fat16:
    pusha
    mov  eax, [bit16_root_lba]
    mov  ecx, [bit16_root_sects]
    cmp  ecx, FSD_DIR_SECTS
    jbe  .ok
    mov  ecx, FSD_DIR_SECTS
.ok:
    mov  esi, fsd_dir_buf
    call bios_disk_write_multi
    popa
    ret

; - fsd_delete_fat16 -
fsd_delete_fat16:
    pusha
    call fsd_find_fat16
    jc   .err
    
    ; EAX = entry ptr
    mov  ebx, eax
    
    ; Free cluster chain
    movzx eax, word [ebx + 26] ; first cluster
.free_lp:
    cmp  ax, 2
    jb   .free_done
    cmp  ax, 0xFFF7
    jae  .free_done
    
    movzx ecx, ax
    mov  ax, [fsd_fat_buf + ecx*2] ; next
    mov  word [fsd_fat_buf + ecx*2], 0 ; free current
    jmp  .free_lp

.free_done:
    ; Mark dir entry as deleted
    mov  byte [ebx], 0xE5
    
    call fsd_flush_fat_fat16
    call fsd_flush_root_fat16
    
    dec  dword [fsd_used]
    clc
    popa
    ret
.err:
    stc
    popa
    ret

; --- Standard FAT16 Data ---
bit16_root_lba:   dd 0
bit16_root_sects: dd 0
bit16_data_lba:   dd 0
bit16_cur_clus:   dw 0
bit16_start_clus: dw 0
bit16_bytes_left: dd 0
fat16_name_tmp:   times 12 db 0

; - data -
fsd_type:       db 0
fsd_ready:      db 0
fsd_used:       dd 0
fsd_create_data: dd 0

fsd_dbg_create: db '[FSD] create_fat16 entry',13,10,0
fsd_dbg_alloc:  db '[FSD] alloc_chain',13,10,0
fsd_dbg_wclus:  db '[FSD] write_clusters',13,10,0
fsd_dbg_flush:  db '[FSD] flush',13,10,0
fsd_dbg_spc:    db '[FSD] sects_per_clus check',13,10,0

fsd_hdr_buf:    times 512  db 0             ; sector 0 cache (BPB for FAT16)
fsd_dir_buf:    times (FSD_DIR_SECTS*512) db 0  ; directory cache (Root Dir for FAT16)
fsd_fat_buf:    times 4096 db 0             ; FAT cache (8 sectors/4KB)
