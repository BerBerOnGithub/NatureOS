; ===========================================================================
; stage2.asm - ClaudeOS Stage 2 Bootloader
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
FS_OFFSET     equ 51   ; flat-image-relative: FS at base+51
KERNEL_COUNT  equ 50
FS_COUNT      equ 400

SCRATCH_SEG   equ 0x0600
SCRATCH_OFF   equ 0x0000

stage2_start:
    mov  [boot_drive], dl
    mov  si, msg_hello
    call puts

    ; Verify INT 13h extensions
    mov  ah, 0x41
    mov  bx, 0x55AA
    mov  dl, [boot_drive]
    int  0x13
    jc   .no_ext
    cmp  bx, 0xAA55
    jne  .no_ext
    jmp  .ext_ok
.no_ext:
    mov  si, msg_noext
    call puts
    cli
    hlt
.ext_ok:

    ; -----------------------------------------------------------------------
    ; Step 1: Read El Torito Boot Record VD at CD-LBA 17
    ;         to find the boot catalog LBA (at offset 0x47)
    ; -----------------------------------------------------------------------
    mov  ax, SCRATCH_SEG
    mov  es, ax
    mov  word [buf_off], SCRATCH_OFF
    mov  dword [lba], 17
    call load_one_block
    jc   .err

    mov  eax, [es:SCRATCH_OFF + 0x47]
    mov  [boot_catalog_lba], eax

    ; -----------------------------------------------------------------------
    ; Step 2: Read boot catalog to find flat image base LBA
    ;         Initial/Default entry at catalog+0x20, LBA field at +0x08
    ; -----------------------------------------------------------------------
    mov  word [buf_off], SCRATCH_OFF
    mov  eax, [boot_catalog_lba]
    mov  [lba], eax
    call load_one_block
    jc   .err

    mov  eax, [es:SCRATCH_OFF + 0x20 + 0x08]
    mov  [base_lba], eax

    ; -----------------------------------------------------------------------
    ; Step 3: Load kernel → 0x0000:0x8000
    ; -----------------------------------------------------------------------
    mov  si, msg_kernel
    call puts
    mov  ax, 0x0000
    mov  es, ax
    mov  word [buf_off], 0x8000
    mov  eax, [base_lba]
    add  eax, KERNEL_OFFSET
    mov  [lba], eax
    mov  word [count], KERNEL_COUNT
    call load_blocks
    jc   .err

    ; -----------------------------------------------------------------------
    ; Step 4: Load FS → 0x2000:0x0000 = physical 0x20000
    ; -----------------------------------------------------------------------
    mov  si, msg_fs
    call puts
    mov  ax, 0x2000
    mov  es, ax
    mov  word [buf_off], 0x0000
    mov  eax, [base_lba]
    add  eax, FS_OFFSET
    mov  [lba], eax
    mov  word [count], FS_COUNT
    call load_blocks
    jc   .err

    ; -----------------------------------------------------------------------
    ; Step 5: Probe data disk for CLFD magic — try drives 0x80..0x83
    ;         Skip the boot drive. Load 5 sectors → 0x4000:0 = 0x40000
    ; -----------------------------------------------------------------------
    mov  byte [data_drv], 0x80
.probe_drive:
    cmp  byte [data_drv], 0x84
    jge  .no_data_disk

    ; skip boot drive
    mov  al, [data_drv]
    cmp  al, [boot_drive]
    je   .next_drive

    ; try reading 5 sectors from this drive into 0x40000
    mov  byte  [dap.size],    0x10
    mov  byte  [dap.res],     0
    mov  word  [dap.count],   5
    mov  word  [dap.buf_off], 0x0000
    mov  word  [dap.buf_seg], 0x8000
    mov  dword [dap.lba_lo],  0
    mov  dword [dap.lba_hi],  0
    mov  ah, 0x42
    mov  dl, [data_drv]
    mov  si, dap
    int  0x13
    jc   .next_drive

    ; check magic
    mov  ax, 0x8000
    mov  es, ax
    cmp  dword [es:0], 0x44464C43
    jne  .next_drive

    ; found! store drive number at offset 20
    mov  al, [data_drv]
    mov  byte [es:20], al
    mov  si, msg_data_ok
    call puts
    jmp  .data_done

.next_drive:
    inc  byte [data_drv]
    jmp  .probe_drive

.no_data_disk:
    ; zero the magic so kernel knows no disk
    mov  ax, 0x8000
    mov  es, ax
    mov  word [es:0], 0

.data_done:

    mov  si, msg_ok
    call puts
    mov  dl, [boot_drive]
    jmp  0x0000:0x8000

.err:
    mov  si, msg_error
    call puts
    cli
    hlt

; ---------------------------------------------------------------------------
; load_one_block: load 1 block from [lba] into ES:[buf_off]
load_one_block:
    mov  byte  [dap.size],    0x10
    mov  byte  [dap.res],     0
    mov  word  [dap.count],   1
    mov  ax,   [buf_off]
    mov  [dap.buf_off], ax
    mov  ax, es
    mov  [dap.buf_seg], ax
    mov  eax, [lba]
    mov  [dap.lba_lo], eax
    mov  dword [dap.lba_hi], 0
    mov  ah, 0x42
    mov  dl, [boot_drive]
    mov  si, dap
    int  0x13
    ret

; ---------------------------------------------------------------------------
; load_blocks: read [count] x 2048-byte blocks starting at [lba]
;              into ES:[buf_off], advancing ES by 0x80 each block
load_blocks:
.loop:
    cmp  word [count], 0
    je   .done
    call load_one_block
    jc   .err
    add  dword [lba], 1
    sub  word  [count], 1
    mov  ax, es
    add  ax, 0x80
    mov  es, ax
    jmp  .loop
.done:
    clc
    ret
.err:
    stc
    ret

; ---------------------------------------------------------------------------
puts:
    push ax
    push bx
.lp:
    lodsb
    or   al, al
    jz   .done
    mov  ah, 0x0E
    xor  bx, bx
    int  0x10
    jmp  .lp
.done:
    pop  bx
    pop  ax
    ret

; ---------------------------------------------------------------------------
boot_drive:       db 0
data_drv:         db 0
boot_catalog_lba: dd 0
base_lba:         dd 0
lba:              dd 0
count:            dw 0
buf_off:          dw 0

dap:
.size:    db 0x10
.res:     db 0
.count:   dw 1
.buf_off: dw 0
.buf_seg: dw 0
.lba_lo:  dd 0
.lba_hi:  dd 0

msg_hello:  db 'ClaudeOS stage2', 13, 10, 0
msg_noext:  db 'ERROR: No INT13 ext', 13, 10, 0
msg_kernel: db 'Loading kernel...', 13, 10, 0
msg_fs:     db 'Loading FS...', 13, 10, 0
msg_ok:     db 'OK', 13, 10, 0
msg_error:  db 'ERROR: load failed', 13, 10, 0
msg_data_ok: db 'Data disk found', 13, 10, 0