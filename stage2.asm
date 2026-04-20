; ===========================================================================
; stage2.asm - NatureOS Stage 2 Bootloader
;
; CD-ROM INT 13h AH=0x42 uses 2048-byte sectors (not 512).
; Layout is aligned to 2048-byte boundaries:
;   2048-LBA 0: boot.bin + stage2 (first 2048 bytes, preloaded by El Torito)
;   2048-LBA 1: kernel (50 x 2048-byte blocks = 100KB)
;   2048-LBA 51: FS    (400 x 2048-byte blocks = 800KB)
;
; The flat image base LBA is read dynamically from the El Torito Boot Record
; (CD-LBA 17) so this works regardless of how pycdlib lays out the ISO.
; ===========================================================================

[BITS 16]
[ORG 0x7E00]

KERNEL_OFFSET equ 1    ; flat-image-relative: kernel at base+1
FS_OFFSET     equ 201  ; flat-image-relative: FS at base+201
KERNEL_COUNT  equ 48   ; 48 * 2048 = 96KB max (kernel end must stay below FS at 0x20000)
FS_COUNT      equ 400

SCRATCH_SEG   equ 0x0600
SCRATCH_OFF   equ 0x0000

stage2_start:
    jmp  stage2_main

; -
; Variables and Strings (Under 512 bytes total size to avoid kernel overlap)
; -
boot_drive:       db 0
data_drv:         db 0
lba:              dd 0
count:            dw 0

dap:
.size:    db 0x10
.res:     db 0
.count:   dw 1
.buf_off: dw 0
.buf_seg: dw 0
.lba_lo:  dd 0
.lba_hi:  dd 0

; Shortened strings to save space
msg_hello:    db 'NatureOS Stage 2', 13, 10, 0
msg_kernel:   db 'Kernel...', 0
msg_fs:       db ' FS...', 0
msg_ok:       db 'OK', 13, 10, 0
msg_error:    db 'ERR', 13, 10, 0
msg_data_ok:  db 'Disk OK', 13, 10, 0

puts:
    pusha
.lp:
    lodsb
    test al, al
    jz   .done
    mov  ah, 0x0E
    int  0x10
    jmp  .lp
.done:
    popa
    ret

stage2_main:
    cld                      ; Direction flag forward
    mov  [boot_drive], dl
    mov  si, msg_hello
    call puts

    ; Find flat image base
    mov  ax, SCRATCH_SEG
    mov  es, ax
    mov  dword [lba], 17     ; ET VD
    call load_one_scratch
    mov  eax, [es:0x47]      ; catalog LBA
    mov  [lba], eax
    call load_one_scratch
    mov  eax, [es:0x20 + 0x08]; image base LBA
    mov  ebx, eax            ; ebx = base LBA

    ; Load kernel
    mov  si, msg_kernel
    call puts
    mov  ax, 0x0000
    mov  es, ax
    mov  eax, ebx
    inc  eax                 ; KERNEL_OFFSET
    mov  [lba], eax
    mov  word [count], 48    ; KERNEL_COUNT
    mov  di, 0x8000          ; buf_off
    call load_blocks
    jc   stage2_err

    ; Load FS
    mov  si, msg_fs
    call puts
    mov  ax, 0x2000
    mov  es, ax
    mov  eax, ebx
    add  eax, 201            ; FS_OFFSET
    mov  [lba], eax
    mov  word [count], 400   ; FS_COUNT
    mov  di, 0x0000          ; buf_off
    call load_blocks
    jc   stage2_err

    ; Probe data disk (0x80..0x83, skipping boot drive)
    mov  byte [data_drv], 0x80
.probe:
    cmp  byte [data_drv], 0x84
    jge  .no_data
    mov  al, [data_drv]
    cmp  al, [boot_drive]
    je   .next
    mov  ah, 0x42
    mov  si, dap
    mov  word [dap.count], 5
    mov  word [dap.buf_off], 0
    mov  word [dap.buf_seg], 0x8000
    mov  dword [dap.lba_lo], 0
    mov  dl, [data_drv]
    int  0x13
    jc   .next
    mov  ax, 0x8000
    mov  es, ax
    cmp  dword [es:0], 0x44464C43 ; CLFD magic
    jne  .next
    mov  al, [data_drv]
    mov  [es:20], al         ; store drive num
    mov  si, msg_data_ok
    call puts
    jmp  .finish
.next:
    inc  byte [data_drv]
    jmp  .probe
.no_data:
    mov  ax, 0x8000
    mov  es, ax
    mov  dword [es:0], 0
.finish:
    mov  si, msg_ok
    call puts
    mov  dl, [boot_drive]
    jmp  0x0000:0x8000

stage2_err:
    mov  si, msg_error
    call puts
    cli
    hlt

load_one_scratch:
    mov  di, SCRATCH_OFF
load_one_block:
    mov  ax, 1
    mov  [dap.count], ax
    mov  [dap.buf_off], di
    mov  ax, es
    mov  [dap.buf_seg], ax
    mov  eax, [lba]
    mov  [dap.lba_lo], eax
    mov  si, dap
    mov  ah, 0x42
    mov  dl, [boot_drive]
    int  0x13
    ret

load_blocks:
.lp:
    cmp  word [count], 0
    je   .done
    call load_one_block
    jc   .err
    inc  dword [lba]
    dec  word [count]
    mov  ax, es
    add  ax, 0x80            ; advance 2048 bytes
    mov  es, ax
    jmp  .lp
.done:
    clc
    ret
.err:
    stc
    ret
