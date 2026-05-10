; ===========================================================================
; pm/fs_pm.asm  -  Protected-mode ', FS_NAME, ' reader
;
; The FS blob is loaded by stage2 to physical 0x30000 (formerly 0x20000).
; In 32-bit flat mode that is simply address 0x30000.
;
; ', FS_NAME, ' layout (matches cmd_fs.asm / mkfs.py):
;   +0   4 bytes  magic "', FS_MAGIC, '"

;   +4   2 bytes  file count  (word, little-endian)
;   +6   N-24 bytes directory entries
;        +0  16 bytes  filename (null-padded, no path)
;       +16   4 bytes  file offset from start of fs.bin  (dword)
;       +20   4 bytes  file size in bytes                (dword)
;
; Public:
;   fs_pm_find  ESI = null-terminated name
;               +' CF=0  EAX = pointer to raw file data
;                        ECX = file size in bytes
;               +' CF=1  not found (or bad magic)
;
; Preserves: EBX, EDX, ESI, EDI
; ===========================================================================

[BITS 32]

FS_PM_BASE   equ  0x30000
FS_ENT_SZ    equ  24
FS_NAME_LEN  equ  16

; -
fs_pm_find:
    push ebx
    push edx
    push esi
    push edi

    ; check magic
    cmp  dword [FS_PM_BASE], FS_MAGIC_VAL
    jne  .notfound


    movzx ecx, word [FS_PM_BASE + 4]      ; file count
    test ecx, ecx
    jz   .notfound

    mov  edi, FS_PM_BASE + 6              ; pointer to first directory entry

.scan:
    ; compare ESI (search name) with [EDI] (stored name), up to FS_NAME_LEN
    push ecx
    push esi
    push edi
    mov  ecx, FS_NAME_LEN
.cmploop:
    mov  al, [esi]
    mov  bl, [edi]
    cmp  al, bl
    jne  .cmpfail
    test al, al
    jz   .cmpmatch      ; both null -> match
    inc  esi
    inc  edi
    loop .cmploop
    ; fell through FS_NAME_LEN bytes without mismatch = match
.cmpmatch:
    pop  edi
    pop  esi
    pop  ecx
    ; EDI points to the matched entry
    mov  eax, [edi + 16]   ; file offset within fs.bin
    add  eax, FS_PM_BASE   ; -> absolute address
    mov  ecx, [edi + 20]   ; file size
    clc
    jmp  .done

.cmpfail:
    pop  edi
    pop  esi
    pop  ecx
    add  edi, FS_ENT_SZ
    dec  ecx
    jnz  .scan

.notfound:
    stc

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ebx
    ret
