; ===========================================================================
; pm/pm_commands.asm - 32-bit PM shell command implementations
;   help, ver, clear, echo, calc
;
; Mirrors commands/ structure for the PM environment.
; Calls pm_screen, pm_string helpers. No BIOS.
; ===========================================================================
SCR_CAPTURE equ 0x600000
SCR_BUF     equ 0x300000
SCR_W       equ 640
SCR_H       equ 480
SCR_PIX     equ 307200
BMP_HDR_SZ  equ 1078
BMP_FILE_SZ equ 308278


[BITS 32]

; ---------------------------------------------------------------------------
; pm_cmd_help
; ---------------------------------------------------------------------------
pm_cmd_help:
    push esi
    push ebx
    mov  esi, pm_str_help_text
    mov  bl, 0x0B            ; cyan
    call pm_puts
    pop  ebx
    pop  esi
    ret

; ---------------------------------------------------------------------------
; pm_cmd_ver
; ---------------------------------------------------------------------------
pm_cmd_ver:
    push esi
    push ebx
    mov  esi, pm_str_ver_text
    mov  bl, 0x0B
    call pm_puts
    pop  ebx
    pop  esi
    ret

; ---------------------------------------------------------------------------
; pm_cmd_clear
; ---------------------------------------------------------------------------
pm_cmd_clear:
    pusha
    ; zero the entire terminal buffer (64 cols * 48 rows * 2 bytes)
    mov  edi, term_buf
    mov  ecx, (64 * 48 * 2 + 3) / 4
    xor  eax, eax
    rep  stosd
    ; reset cursor to top-left
    mov  dword [term_col], 0
    mov  dword [term_row], 0
    ; redraw terminal window
    call term_redraw
    popa
    ret

; ---------------------------------------------------------------------------
; pm_cmd_echo  -  print everything after "echo "
; ---------------------------------------------------------------------------
pm_cmd_echo:
    push esi
    push ebx
    mov  esi, pm_input_buf
    add  esi, 5              ; skip "echo "
    mov  bl, 0x0F
    call pm_puts
    call pm_newline
    pop  ebx
    pop  esi
    ret

; ---------------------------------------------------------------------------
; pm_cmd_calc  -  calc <num> <op> <num>
; Signed 32-bit integers. Operators: + - * /
; Multiplication result capped at 32 bits (overflow flagged).
; ---------------------------------------------------------------------------
pm_cmd_calc:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    mov  esi, pm_input_buf
    add  esi, 5              ; skip "calc "
    call pm_skip_spaces
    mov  al, [esi]
    or   al, al
    jz   .usage

    ; parse operand 1
    call pm_parse_int
    mov  [pm_calc_n1], eax

    call pm_skip_spaces
    mov  al, [esi]
    or   al, al
    jz   .usage
    mov  [pm_calc_op], al
    inc  esi

    call pm_skip_spaces

    ; parse operand 2
    call pm_parse_int
    mov  [pm_calc_n2], eax

    ; echo expression
    call pm_newline
    mov  eax, [pm_calc_n1]
    call pm_print_int
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    mov  al, [pm_calc_op]
    mov  bl, 0x0E
    call pm_putc
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    mov  eax, [pm_calc_n2]
    call pm_print_int
    mov  esi, pm_str_eq
    mov  bl, 0x0E
    call pm_puts

    ; dispatch
    cmp  byte [pm_calc_op], '+'
    je   .add
    cmp  byte [pm_calc_op], '-'
    je   .sub
    cmp  byte [pm_calc_op], '*'
    je   .mul
    cmp  byte [pm_calc_op], '/'
    je   .div
    jmp  .badop

.add:
    mov  eax, [pm_calc_n1]
    mov  ebx, [pm_calc_n2]
    add  eax, ebx
    jo   .overflow
    call pm_print_int
    jmp  .nl

.sub:
    mov  eax, [pm_calc_n1]
    mov  ebx, [pm_calc_n2]
    sub  eax, ebx
    jo   .overflow
    call pm_print_int
    jmp  .nl

.mul:
    ; 32x32 signed: use imul which gives 64-bit in EDX:EAX
    mov  eax, [pm_calc_n1]
    mov  ebx, [pm_calc_n2]
    imul ebx                 ; EDX:EAX = result
    ; overflow if EDX != sign-extension of EAX
    mov  ecx, eax
    sar  ecx, 31             ; ECX = all sign bits of EAX
    cmp  edx, ecx
    jne  .overflow
    call pm_print_int
    jmp  .nl

.div:
    mov  ebx, [pm_calc_n2]
    test ebx, ebx
    jz   .divzero
    mov  eax, [pm_calc_n1]
    cdq                      ; sign-extend EAX into EDX:EAX
    idiv ebx                 ; EAX=quotient, EDX=remainder
    call pm_print_int
    ; show remainder if nonzero
    test edx, edx
    jz   .nl
    push eax
    push edx
    mov  esi, pm_str_rem
    mov  bl, 0x0B
    call pm_puts
    pop  eax                 ; remainder was in EDX
    call pm_print_int
    mov  al, ')'
    mov  bl, 0x0B
    call pm_putc
    pop  eax
    jmp  .nl

.overflow:
    mov  esi, pm_str_overflow
    mov  bl, 0x0C
    call pm_puts
    jmp  .end

.divzero:
    mov  esi, pm_str_divzero
    mov  bl, 0x0C
    call pm_puts
    jmp  .end

.badop:
    mov  esi, pm_str_badop
    mov  bl, 0x0C
    call pm_puts
    jmp  .end

.usage:
    mov  esi, pm_str_calc_usage
    mov  bl, 0x0E
    call pm_puts
    jmp  .end

.nl:
    call pm_newline
.end:
    call pm_newline
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; pm_cmd_exit - switch back to 16-bit real mode
;
; Sequence (per OSDev wiki / tutorial):
;   1. Print message
;   2. Disable interrupts
;   3. Far jump to 16-bit PM code selector (0x18) â€” still PM, but 16-bit
;   4. Load 16-bit data selectors (0x20)
;   5. Clear CR0.PE (and CR0.PG just in case)
;   6. Far jump to real-mode segment 0x0000 to flush prefetch queue
;   7. Reload all real-mode segments to zero
;   8. Restore saved SP
;   9. Reload real-mode IDT (BIOS IVT at 0x0000)
;  10. STI â€” BIOS interrupts live again
;  11. Clear screen so BIOS cursor is at a known position
;  12. Jump back into the 16-bit shell loop
; ---------------------------------------------------------------------------
pm_cmd_exit:
    ; print farewell while we still have PM screen
    mov  esi, pm_str_exit_msg
    mov  bl, 0x0E
    call pm_puts

    ; Shut down PM drivers before handing back to real mode
    call pm_drv_shutdown

    cli

    ; â”€â”€ Step 3: far jump to 16-bit code selector (0x18) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    ; This loads CS with a 16-bit descriptor while still in PM.
    ; From this point the assembler switches to [BITS 16].
    jmp  0x18:pm_exit_16bit

[BITS 16]
pm_exit_16bit:
    ; â”€â”€ Step 4: load 16-bit data selectors â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    mov  ax, 0x20
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax

    ; â”€â”€ Step 5: clear CR0.PE and CR0.PG â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    mov  eax, cr0
    and  eax, 0x7FFFFFFE     ; clear bit 0 (PE) and bit 31 (PG)
    mov  cr0, eax

    ; â”€â”€ Step 6: far jump to flush prefetch queue, enter real mode â”€â”€â”€â”€â”€â”€â”€â”€â”€
    jmp  0x0000:pm_exit_realmode

pm_exit_realmode:
    ; â”€â”€ Step 7: reload real-mode segments â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax

    ; â”€â”€ Step 8: restore saved stack pointer â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    mov  sp, [rm_sp_save]

    ; â”€â”€ Step 9: reload real-mode IDT (BIOS IVT at 0x0000:0x03FF) â”€â”€â”€â”€â”€â”€â”€â”€
    lidt [rm_idtr]

    ; â”€â”€ Step 10: re-enable interrupts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    sti

    ; â”€â”€ Step 11: reinitialise real-mode drivers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    call drv_rm_init

    ; â”€â”€ Step 12: clear screen and reset BIOS cursor â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    call screen_clear

    ; â”€â”€ Step 12: far jump back into the 16-bit shell loop â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    db  0xEA                 ; far jump opcode (16-bit form)
    dw  kernel_main    ; 16-bit offset (already includes 0x8000)
    dw  0x0000               ; segment

; Real-mode IDT descriptor: limit=0x03FF (1024 bytes), base=0x00000000
rm_idtr:
    dw 0x03FF
    dd 0x00000000

[BITS 32]

; ---------------------------------------------------------------------------
; pm_cmd_probe - 32-bit mode prover
;
; Writes 0xDEADBEEF to 0x00100000 (above 1MB) then reads it back.
; Uses EDI exclusively for the address â€” avoids ECX conflict with loop/print.
; ---------------------------------------------------------------------------
pm_cmd_probe:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    push esi

    call pm_newline
    mov  esi, pm_str_probe_hdr
    mov  bl, 0x0B
    call pm_puts

    ; â”€â”€ Write 0xDEADBEEF x16 to 0x100000 â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    mov  edi, 0x00100000
    mov  ecx, 16
    mov  eax, 0xDEADBEEF
.write:
    mov  [edi], eax
    add  edi, 4
    loop .write

    ; â”€â”€ Read back and print using EDI as address â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    mov  esi, pm_str_probe_written
    mov  bl, 0x07
    call pm_puts

    mov  edi, 0x00100000
    mov  dword [pm_probe_rows], 4

.row:
    mov  eax, edi
    call pm_print_hex32
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    mov  al, ' '
    call pm_putc

    mov  dword [pm_probe_cols], 4
.col:
    mov  eax, [edi]
    call pm_print_hex32
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    add  edi, 4
    dec  dword [pm_probe_cols]
    jnz  .col

    call pm_newline
    dec  dword [pm_probe_rows]
    jnz  .row

    ; â”€â”€ Verify â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    call pm_newline
    mov  eax, [0x00100000]
    cmp  eax, 0xDEADBEEF
    jne  .fail

    mov  esi, pm_str_probe_pass
    mov  bl, 0x0A
    call pm_puts
    jmp  .done

.fail:
    mov  esi, pm_str_probe_fail
    mov  bl, 0x0C
    call pm_puts
    mov  eax, [0x00100000]
    call pm_print_hex32
    call pm_newline

.done:
    call pm_newline
    pop  esi
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; pm_print_hex32 - print EAX as 8 hex digits
; ---------------------------------------------------------------------------
pm_print_hex32:
    push eax
    push ebx
    push ecx
    push edx
    mov  ecx, 8
.loop:
    rol  eax, 4
    mov  edx, eax
    and  edx, 0x0F
    cmp  edx, 10
    jl   .digit
    add  dl, 'A' - 10
    jmp  .out
.digit:
    add  dl, '0'
.out:
    push eax
    mov  al, dl
    mov  bl, 0x0F
    call pm_putc
    pop  eax
    loop .loop
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; pm_cmd_savescr - build BMP from 0x600000 and write to data disk
; 0x600000 was filled by wm_screenshot_capture from GFX_SHADOW (shadow buf)
; BMP is bottom-up: row 479 first (screen top), row 0 last (screen bottom)
; ---------------------------------------------------------------------------
pm_cmd_savescr:
    pusha
    ; EARLY CHECK: print 0x600000[50*640] at entry to savescr
    push eax
    push edx
    movzx eax, byte [0x600000 + 50*640]
    push eax
    shr al,4
    and al,0xF
    add al,'0'
    cmp al,'9'
    jbe .es1
    add al,7
.es1: mov ah,al
    mov dx,0x3FD
.esw1: in al,dx
    test al,0x20
    jz .esw1
    mov dx,0x3F8
    mov al,ah
    out dx,al
    pop eax
    and al,0xF
    add al,'0'
    cmp al,'9'
    jbe .es2
    add al,7
.es2: mov ah,al
    mov dx,0x3FD
.esw2: in al,dx
    test al,0x20
    jz .esw2
    mov dx,0x3F8
    mov al,ah
    out dx,al
    mov dx,0x3FD
.esn: in al,dx
    test al,0x20
    jz .esn
    mov dx,0x3F8
    mov al,10
    out dx,al
    pop edx
    pop eax

    cmp  byte [scr_pending], 1
    jne  .no_pending
    mov  byte [scr_pending], 0

    ; BMP file header (14 bytes) at 0x300000
    mov  edi, 0x300000
    mov  word  [edi+0],  0x4D42
    mov  dword [edi+2],  308278
    mov  dword [edi+6],  0
    mov  dword [edi+10], 1078
    add  edi, 14

    ; BITMAPINFOHEADER (40 bytes)
    mov  dword [edi+0],  40
    mov  dword [edi+4],  640
    mov  dword [edi+8],  480
    mov  word  [edi+12], 1
    mov  word  [edi+14], 8
    mov  dword [edi+16], 0
    mov  dword [edi+20], 307200
    mov  dword [edi+24], 2835
    mov  dword [edi+28], 2835
    mov  dword [edi+32], 256
    mov  dword [edi+36], 256
    add  edi, 40

    ; Palette: 256 entries from VGA DAC, B G R 0 order
    cli
    mov  dx, 0x3C6
    mov  al, 0xFF
    out  dx, al
    xor  al, al
    mov  dx, 0x3C7
    out  dx, al
    xor  ecx, ecx
.pal:
    mov  dx, 0x3C9
    in   al, dx
    shl  al, 2
    mov  [edi+2], al
    in   al, dx
    shl  al, 2
    mov  [edi+1], al
    in   al, dx
    shl  al, 2
    mov  [edi+0], al
    mov  byte [edi+3], 0
    add  edi, 4
    inc  ecx
    cmp  ecx, 256
    jl   .pal
    sti

    ; â”€â”€ DIAGNOSTIC: print first bytes of 0x600000 rows 0, 50, 302 â”€â”€â”€â”€
    ; If row 50 == row 302, we have the loop bug
    push eax
    push edx
    push esi
    mov  esi, scr_dbg_prefix
    call serial_print
    ; print byte at 0x600000 + 50*640
    movzx eax, byte [0x600000 + 50*640]
    call scr_serial_hex_byte
    mov  dx, 0x3FD
.sd1: in al, dx
    test al, 0x20
    jz   .sd1
    mov  dx, 0x3F8
    mov  al, '/'
    out  dx, al
    ; print byte at 0x600000 + 302*640
    movzx eax, byte [0x600000 + 302*640]
    call scr_serial_hex_byte
    mov  dx, 0x3FD
.sd2: in al, dx
    test al, 0x20
    jz   .sd2
    mov  dx, 0x3F8
    mov  al, 10
    out  dx, al
    pop  esi
    pop  edx
    pop  eax

    ; SHADOW PERIOD DIAGNOSTIC
    push eax
    push edx
    ; hex-print shadow[177*640] byte 0
    movzx eax, byte [0x500000 + 177*640]
    call scr_serial_hex_byte
    mov  dx, 0x3FD
.dp1: in al, dx
    test al, 0x20
    jz   .dp1
    mov  dx, 0x3F8
    mov  al, '/'
    out  dx, al
    ; hex-print shadow[429*640] byte 0
    movzx eax, byte [0x500000 + 429*640]
    call scr_serial_hex_byte
    mov  dx, 0x3FD
.dp2: in al, dx
    test al, 0x20
    jz   .dp2
    mov  dx, 0x3F8
    mov  al, 10
    out  dx, al
    pop  edx
    pop  eax

    ; Pixel data: BMP bottom-up = write row 479 first, row 0 last
    ; Pixel data: BMP bottom-up = write row 479 first, row 0 last
    mov  ecx, 480
.row:
    dec  ecx
    mov  eax, 640
    imul eax, ecx
    mov  esi, 0x500000    ; read directly from GFX_SHADOW
    add  esi, eax
    push ecx
    mov  ecx, 160
    rep  movsd
    pop  ecx
    test ecx, ecx
    jnz  .row

    ; generate filename scr0001..scr9999
    inc  dword [scr_counter]
    mov  eax, [scr_counter]
    cmp  eax, 9999
    jle  .nc
    mov  eax, 9999
    mov  dword [scr_counter], 9999
.nc:
    mov  ebx, 1000
    mov  edi, scr_name + 3
    xor  edx, edx
    div  ebx
    add  al, '0'
    mov  [edi], al
    inc  edi
    mov  eax, edx
    mov  ebx, 100
    xor  edx, edx
    div  ebx
    add  al, '0'
    mov  [edi], al
    inc  edi
    mov  eax, edx
    mov  ebx, 10
    xor  edx, edx
    div  ebx
    add  al, '0'
    mov  [edi], al
    inc  edi
    add  dl, '0'
    mov  [edi], dl

    ; write to disk
    mov  esi, scr_name
    mov  dword [fsd_create_data], 0x300000
    mov  ecx, 308278
    call fsd_create
    jc   .full

    mov  esi, scr_msg_ok_save
    call wm_notify
    jmp  .done

.full:
    mov  esi, scr_msg_full
    call wm_notify
    jmp  .done

.no_pending:
    mov  esi, savescr_str_none
    mov  bl, 0x0C
    call term_puts
    call term_newline

.done:
    popa
    ret

savescr_str_none: db 'No screenshot pending. Press PrtSc first!', 13, 10, 0
scr_dbg_prefix:   db 'CAP row50/302: ', 0

; scr_serial_hex_byte: print AL as 2 hex chars to serial. Trashes EAX,EDX.
scr_serial_hex_byte:
    push ecx
    mov  ecx, 2
    rol  eax, 4
.shb:
    push eax
    and  al, 0x0F
    add  al, '0'
    cmp  al, '9'
    jbe  .shbok
    add  al, 7
.shbok:
    mov  ah, al
    mov  dx, 0x3FD
.shbw: in al, dx
    test al, 0x20
    jz   .shbw
    mov  dx, 0x3F8
    mov  al, ah
    out  dx, al
    pop  eax
    rol  eax, 4
    loop .shb
    pop  ecx
    ret
