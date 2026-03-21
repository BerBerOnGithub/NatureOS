; ===========================================================================
; commands/cmd_fs.asm - ClaudeFS filesystem commands
;
; ls        - list all files
; run <n>   - execute a file by name
;
; FS blob loaded at physical 0x20000 = segment 0x2000, offset 0.
;
; ClaudeFS layout (little-endian):
;   +0   4 bytes  magic "CLFS"
;   +4   2 bytes  file count
;   +6   N*24 bytes directory entries:
;       +0  16 bytes  filename (null-padded)
;       +16  4 bytes  offset from start of fs.bin (uint32)
;       +20  4 bytes  file size in bytes (uint32)
; ===========================================================================

FS_SEG      equ 0x2000
ENTRY_SIZE  equ 24
NAME_LEN    equ 16
DIR_OFFSET  equ 6
RUN_SEG     equ 0x0C00      ; physical 0xC000 " scratch area for apps

; -
; fs_valid " sets ZF=1 if FS magic is present
; -
fs_valid:
    push ax
    push bx
    push es
    mov  ax, FS_SEG
    mov  es, ax
    cmp  byte [es:0], 'C'
    jne  .bad
    cmp  byte [es:1], 'L'
    jne  .bad
    cmp  byte [es:2], 'F'
    jne  .bad
    cmp  byte [es:3], 'S'
    jne  .bad
    pop  es
    pop  bx
    pop  ax
    xor  ax, ax          ; ZF=1
    ret
.bad:
    pop  es
    pop  bx
    pop  ax
    or   ax, 1           ; ZF=0
    test ax, ax
    ret

; -
; cmd_ls " list files
; -
cmd_ls:
    push ax
    push bx
    push cx
    push si
    push es

    call fs_valid
    jnz  .no_fs

    mov  ax, FS_SEG
    mov  es, ax

    mov  cx, [es:4]          ; file count
    test cx, cx
    jz   .empty

    call nl
    mov  si, str_ls_hdr
    mov  bl, ATTR_CYAN
    call puts_c
    call nl

    mov  si, DIR_OFFSET      ; SI = offset of first entry in FS_SEG

.row:
    ; copy filename into local buffer
    push cx
    push si
    mov  cx, NAME_LEN
    mov  bx, 0
.copy_name:
    mov  al, [es:si]
    mov  [fs_name_buf+bx], al
    inc  si
    inc  bx
    loop .copy_name

    ; read size (dword at entry+20, si is now at entry+16 after name copy)
    mov  ax, [es:si+4]       ; low word of size  (entry+20)
    mov  dx, [es:si+6]       ; high word of size (entry+22)
    mov  [fs_tmp_size],   ax ; save low word
    mov  [fs_tmp_size+2], dx ; save high word

    pop  si                  ; restore entry start
    pop  cx

    ; print name
    push si
    push cx
    mov  si, fs_name_buf
    mov  bl, ATTR_BRIGHT
    call puts_c

    ; print size using 32-bit print (DX:AX)
    mov  si, str_ls_sep
    mov  bl, ATTR_NORMAL
    call puts_c
    mov  ax, [fs_tmp_size]
    mov  dx, [fs_tmp_size+2]
    call print_uint32
    mov  si, str_ls_bytes
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

    pop  cx
    pop  si
    add  si, ENTRY_SIZE
    loop .row

    call nl
    jmp  .done

.empty:
    mov  si, str_ls_empty
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl
    jmp  .done

.no_fs:
    mov  si, str_fs_bad
    mov  bl, ATTR_RED
    call puts_c
    call nl

.done:
    pop  es
    pop  si
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

; -
; cmd_run " run <name>
; -
cmd_run:
    push ax
    push bx
    push cx
    push si
    push di
    push es

    call fs_valid
    jnz  .no_fs

    ; skip "run " prefix (4 chars)
    lea  si, [cmd_buf + 4]

    mov  ax, FS_SEG
    mov  es, ax
    mov  cx, [es:4]          ; file count
    test cx, cx
    jz   .not_found

    mov  di, DIR_OFFSET      ; DI = current entry offset

.search:
    ; compare input (DS:SI) with stored name (ES:DI)
    push si
    push di
    push cx
    mov  cx, NAME_LEN
.cmp:
    mov  al, [si]
    mov  ah, [es:di]
    cmp  al, ah
    jne  .cmp_fail
    test al, al
    jz   .cmp_ok             ; both null = match
    inc  si
    inc  di
    loop .cmp
.cmp_ok:
    pop  cx
    pop  di
    pop  si
    jmp  .found
.cmp_fail:
    pop  cx
    pop  di
    pop  si
    add  di, ENTRY_SIZE
    loop .search
    jmp  .not_found

.found:
    ; DI = matching entry. Read offset (dword at DI+16) and size (dword at DI+20)
    mov  ax, [es:di+16]      ; file offset low word
    mov  [fs_tmp_off],  ax
    mov  ax, [es:di+20]      ; file size low word
    mov  [fs_tmp_size], ax

    ; copy file from FS_SEG:[offset] to RUN_SEG:0 byte by byte
    mov  si, [fs_tmp_off]    ; source offset within FS_SEG
    mov  cx, [fs_tmp_size]

    push es                  ; save FS segment
    mov  ax, RUN_SEG
    mov  es, ax
    xor  di, di              ; ES:DI = RUN_SEG:0

    push ds
    mov  ax, FS_SEG
    mov  ds, ax              ; DS:SI = FS_SEG:offset

.copy:
    mov  al, [si]
    mov  [es:di], al
    inc  si
    inc  di
    loop .copy

    pop  ds                  ; restore DS=0
    pop  es                  ; restore ES

    mov  si, str_run_exec
    mov  bl, ATTR_GREEN
    call puts_c
    call nl

    ; far call to RUN_SEG:0
    call far [run_vec]

    xor  ax, ax
    mov  ds, ax          ; restore DS=0 after app returns

    mov  si, str_run_done
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl
    jmp  .done

.not_found:
    mov  si, str_run_notfound
    mov  bl, ATTR_RED
    call puts_c
    call nl
    jmp  .done

.no_fs:
    mov  si, str_fs_bad
    mov  bl, ATTR_RED
    call puts_c
    call nl

.done:
    pop  es
    pop  di
    pop  si
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

; -
; Data
; -
fs_name_buf:   times NAME_LEN db 0
fs_tmp_size:   dd 0
fs_tmp_off:    dw 0
run_vec:       dw 0x0000, RUN_SEG    ; far pointer offset:seg

str_ls_hdr:       db ' Filename        Size', 13, 10
                  db ' -', 0
str_ls_sep:       db '   ', 0
str_ls_bytes:     db ' bytes', 0
str_ls_empty:     db ' (no files)', 0
str_fs_bad:       db ' No filesystem loaded.', 0
str_run_exec:     db ' Executing...', 0
str_run_done:     db ' Program returned.', 0
str_run_notfound: db ' File not found.', 0
str_cmd_ls:       db 'ls', 0
str_pfx_run:      db 'run ', 0