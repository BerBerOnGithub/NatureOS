; ===========================================================================
; pm/fs_data.asm  -  ClaudeFS Data Disk (read/write, ATA drive 1)
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
;   fsd_init        — read header+dir from disk into RAM cache
;   fsd_find        — ESI=name → CF=0: EAX=entry ptr; CF=1: not found
;   fsd_read_file   — EAX=entry ptr, EDI=dest → ECX=bytes read
;   fsd_create      — ESI=name, EDI=data, ECX=size → CF=0 ok, CF=1 full/err
;   fsd_delete      — ESI=name → CF=0 ok, CF=1 not found
;   fsd_list        — EDI=callback(entry_ptr): called for each used entry
;   fsd_ready       db — 1 if disk found and valid
; ===========================================================================

[BITS 32]

FSD_MAGIC       equ 0x44464C43   ; 'CLFD' little-endian
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

; ── fsd_init ──────────────────────────────────────────────────────────────────
; Read header + directory into RAM. Sets fsd_ready.
fsd_init:
    pusha
    mov  byte [fsd_ready], 0

    cmp  byte [bd_ready], 1
    jne  .done

    ; header and directory already loaded by stage2 into 0x40000
    ; copy header (512 bytes) into fsd_hdr_buf
    mov  esi, 0x80000
    mov  edi, fsd_hdr_buf
    mov  ecx, 512 / 4
    rep  movsd

    ; verify magic
    cmp  dword [fsd_hdr_buf], FSD_MAGIC
    jne  .done

    ; cache used count
    mov  eax, [fsd_hdr_buf + 16]
    mov  [fsd_used], eax

    ; copy directory (4 sectors = 2048 bytes) into fsd_dir_buf
    mov  esi, 0x80200           ; stage2 put dir at header+512
    mov  edi, fsd_dir_buf
    mov  ecx, 2048 / 4
    rep  movsd

    mov  byte [fsd_ready], 1

.done:
    popa
    ret

; ── fsd_flush_dir ─────────────────────────────────────────────────────────────
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

; ── fsd_find ──────────────────────────────────────────────────────────────────
; In:  ESI = null-terminated filename
; Out: CF=0 EAX = pointer to directory entry in fsd_dir_buf
;      CF=1 not found
fsd_find:
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

; ── fsd_read_file ─────────────────────────────────────────────────────────────
; In:  EAX = pointer to directory entry (from fsd_find)
;      EDI = destination buffer
; Out: ECX = bytes read
fsd_read_file:
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

; ── fsd_alloc_sector ──────────────────────────────────────────────────────────
; Find a free run of sectors starting at FSD_DATA_START.
; In:  ECX = sectors needed
; Out: EAX = start sector, CF=1 if disk full
fsd_alloc_sector:
    push ebx
    push ecx
    push edx
    push esi

    ; build a simple bitmap of used sectors by scanning directory
    ; for now: linear allocation — find highest used sector + 1
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
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; ── fsd_create ────────────────────────────────────────────────────────────────
; Create a new file on the data disk.
; In:  ESI = null-terminated filename (max 15 chars)
;      EDI = data buffer
;      ECX = file size in bytes
; Out: CF=0 ok, CF=1 error (disk full, dir full, already exists)
fsd_create:
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
    ; ESI still points to name — need original data ptr
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

; ── fsd_delete ────────────────────────────────────────────────────────────────
; Delete a file by name.
; In:  ESI = null-terminated filename
; Out: CF=0 ok, CF=1 not found
fsd_delete:
    pusha
    call fsd_find
    jc   .notfound

    ; EAX = entry ptr — zero the flags to mark free
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

; ── fsd_list ──────────────────────────────────────────────────────────────────
; Call EDI for each used entry. EDI = callback(EAX=entry_ptr).
fsd_list:
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

; ── data ──────────────────────────────────────────────────────────────────────
fsd_ready:      db 0
fsd_used:       dd 0
fsd_create_data: dd 0                       ; set before calling fsd_create

fsd_hdr_buf:    times 512  db 0             ; sector 0 cache
fsd_dir_buf:    times (FSD_DIR_SECTS*512) db 0  ; directory cache (2048 bytes)