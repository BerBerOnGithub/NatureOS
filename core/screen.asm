; ===========================================================================
; core/screen.asm - VGA screen output routines
; ===========================================================================

; -
; screen_clear - clear screen and home cursor
; -
screen_clear:
    push ax
    push bx
    push cx
    push dx
    mov  ah, 0x06
    xor  al, al
    mov  bh, [shell_attr]    ; fill with current shell colour
    xor  cx, cx
    mov  dx, 0x184F
    int  0x10
    mov  ah, 0x02
    xor  bh, bh
    xor  dx, dx
    int  0x10
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; -
; nl - print CR+LF using putc_color so shell_attr is respected on scroll
; -
nl:
    push ax
    push bx
    mov  bl, [shell_attr]
    mov  al, 13
    call putc_color
    mov  al, 10
    call putc_color
    pop  bx
    pop  ax
    ret

; -
; do_scroll - scroll screen up one line, fill new row with shell_attr
; -
do_scroll:
    push ax
    push bx
    push cx
    push dx
    mov  ah, 0x06
    mov  al, 1
    mov  bh, [shell_attr]    ; fill new blank row with current colour
    xor  cx, cx
    mov  dx, 0x184F
    int  0x10
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; -
; putc_color - write char AL with attribute BL, advance cursor
;
; BL is treated as the FOREGROUND nibble only (low 4 bits used).
; The background nibble is always taken from [shell_attr] high nibble,
; so typed characters never paint a black box over the current background.
; -
putc_color:
    push ax
    push bx
    push cx
    push dx

    ; --- serial output (non-blocking) ---
    push dx
    push ax
    mov  al, [mt_active]
    test al, al
    jnz  .no_serial
    mov  dx, 0x3FD
    in   al, dx
    test al, 0x20
    jz   .no_serial
    mov  dx, 0x3F8
    pop  ax
    push ax
    out  dx, al
.no_serial:
    pop  ax
    pop  dx
    ; ---------------------

    cmp  al, 13
    je   .do_cr
    cmp  al, 10
    je   .do_lf
    cmp  al, 8
    je   .do_bs

    ; - Always use shell_attr for the full attribute (bg + fg) -
    ; Caller's BL is used only for special strings that need specific fg
    ; colours (e.g. error red, header cyan). We preserve the bg from
    ; shell_attr in all cases so no black boxes appear.
    mov  bh, [shell_attr]
    and  bh, 0xF0            ; bg nibble from shell_attr
    and  bl, 0x0F            ; fg nibble from caller
    or   bl, bh              ; BL = bg:shell_attr | fg:caller
    xor  bh, bh              ; BH = page 0 for INT 10h
    mov  ah, 0x09
    mov  cx, 1
    int  0x10

    mov  ah, 0x03
    xor  bh, bh
    int  0x10
    inc  dl
    cmp  dl, 80
    jl   .set_cursor
    xor  dl, dl
    inc  dh
    cmp  dh, 25
    jl   .set_cursor
    call do_scroll
    mov  dh, 24
    jmp  .set_cursor

.do_cr:
    mov  ah, 0x03
    xor  bh, bh
    int  0x10
    xor  dl, dl
    jmp  .set_cursor

.do_lf:
    mov  ah, 0x03
    xor  bh, bh
    int  0x10
    inc  dh
    cmp  dh, 25
    jl   .set_cursor
    call do_scroll
    mov  dh, 24
    jmp  .set_cursor

.do_bs:
    mov  ah, 0x03
    xor  bh, bh
    int  0x10
    or   dl, dl
    jz   .pc_done
    dec  dl
    mov  ah, 0x02
    xor  bh, bh
    int  0x10
    push bx
    mov  ah, 0x09
    mov  al, ' '
    xor  bh, bh
    mov  bl, [shell_attr]    ; erase with full current attribute (bg+fg)
    mov  cx, 1
    int  0x10
    pop  bx
    jmp  .pc_done

.set_cursor:
    mov  ah, 0x02
    xor  bh, bh
    int  0x10

.pc_done:
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; -
; puts - print null-terminated string at SI using shell_attr color
; -
puts:
    push ax
    push bx
    push si
    mov  bl, [shell_attr]
.lp:
    lodsb
    or   al, al
    jz   .done
    call putc_color
    jmp  .lp
.done:
    pop  si
    pop  bx
    pop  ax
    ret

; -
; puts_c - print null-terminated string at SI with explicit color in BL
; -
puts_c:
    push ax
    push bx
    push si
.lp:
    lodsb
    or   al, al
    jz   .done
    call putc_color
    jmp  .lp
.done:
    pop  si
    pop  bx
    pop  ax
    ret

; -
; show_banner / show_motd - boot graphics
; -
show_banner:
    push si
    push bx
    mov  si, str_banner
    mov  bl, ATTR_CYAN
    call puts_c
    pop  bx
    pop  si
    ret

show_motd:
    push si
    push bx
    mov  si, str_motd
    mov  bl, ATTR_NORMAL
    call puts_c
    pop  bx
    pop  si
    ret
