; ===========================================================================
; commands/cmd_system.asm - System information commands
;   date, time, setdate, settime, sys, pm, probe
; ===========================================================================

; -
; date - read RTC date via INT 1Ah AH=04h
; -
cmd_date:
    push ax
    push bx
    push cx
    push dx
    push si
    mov  ah, 0x04
    int  0x1A
    jc   .date_fail
    call nl
    mov  si, str_date_lbl
    mov  bl, ATTR_CYAN
    call puts_c
    mov  al, ch              ; century BCD
    call print_bcd
    mov  al, cl              ; year BCD
    call print_bcd
    mov  al, '-'
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  al, dh              ; month BCD
    call print_bcd
    mov  al, '-'
    call putc_color
    mov  al, dl              ; day BCD
    call print_bcd
    call nl
    call nl
    jmp  .date_end
.date_fail:
    mov  si, str_rtc_fail
    mov  bl, ATTR_RED
    call puts_c
    call nl
.date_end:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

; -
; time - read RTC time via INT 1Ah AH=02h
; -
cmd_time:
    push ax
    push bx
    push cx
    push dx
    push si
    mov  ah, 0x02
    int  0x1A
    jc   .time_fail
    call nl
    mov  si, str_time_lbl
    mov  bl, ATTR_CYAN
    call puts_c
    mov  al, ch              ; hours BCD
    call print_bcd
    mov  al, ':'
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  al, cl              ; minutes BCD
    call print_bcd
    mov  al, ':'
    call putc_color
    mov  al, dh              ; seconds BCD
    call print_bcd
    call nl
    call nl
    jmp  .time_end
.time_fail:
    mov  si, str_rtc_fail
    mov  bl, ATTR_RED
    call puts_c
    call nl
.time_end:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

; -
; setdate - interactively set RTC date (YYYY-MM-DD)
; -
cmd_setdate:
    push ax
    push bx
    push cx
    push dx
    push si

    call nl
    mov  si, str_sd_current
    mov  bl, ATTR_CYAN
    call puts_c
    mov  ah, 0x04
    int  0x1A
    jc   .sd_no_current
    mov  al, ch
    call print_bcd
    mov  al, cl
    call print_bcd
    mov  al, '-'
    mov  bl, ATTR_BRIGHT
    call putc_color
    mov  al, dh
    call print_bcd
    mov  al, '-'
    call putc_color
    mov  al, dl
    call print_bcd
    call nl
    jmp  .sd_prompt
.sd_no_current:
    mov  si, str_na
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

.sd_prompt:
    mov  si, str_sd_prompt
    mov  bl, ATTR_YELLOW
    call puts_c
    call shell_readline

    cmp  byte [cmd_len], 0
    je   .sd_cancel

    lea  si, [cmd_buf]
    call parse_uint16
    cmp  ax, 1
    jb   .sd_bad
    cmp  ax, 9999
    ja   .sd_bad
    xor  dx, dx
    mov  bx, 100
    div  bx
    push dx
    call .sd_to_bcd
    mov  [sd_century], al
    pop  ax
    call .sd_to_bcd
    mov  [sd_year], al

    cmp  byte [si], '-'
    jne  .sd_bad
    inc  si

    call parse_uint16
    cmp  ax, 1
    jb   .sd_bad
    cmp  ax, 12
    ja   .sd_bad
    call .sd_to_bcd
    mov  [sd_month], al

    cmp  byte [si], '-'
    jne  .sd_bad
    inc  si

    call parse_uint16
    cmp  ax, 1
    jb   .sd_bad
    cmp  ax, 31
    ja   .sd_bad
    call .sd_to_bcd
    mov  [sd_day], al

    mov  ch, [sd_century]
    mov  cl, [sd_year]
    mov  dh, [sd_month]
    mov  dl, [sd_day]
    mov  ah, 0x05
    int  0x1A

    mov  si, str_date_set_ok
    mov  bl, ATTR_GREEN
    call puts_c
    call nl
    call nl
    jmp  .sd_end

.sd_bad:
    mov  si, str_sd_fmt_err
    mov  bl, ATTR_RED
    call puts_c
    call nl
    jmp  .sd_end

.sd_cancel:
    mov  si, str_no_change
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

.sd_end:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

.sd_to_bcd:
    push bx
    push dx
    xor  dx, dx
    mov  bx, 10
    div  bx
    shl  al, 4
    or   al, dl
    pop  dx
    pop  bx
    ret

; -
; settime - interactively set RTC time (HH:MM:SS)
; -
cmd_settime:
    push ax
    push bx
    push cx
    push dx
    push si

    call nl
    mov  si, str_st_current
    mov  bl, ATTR_CYAN
    call puts_c
    mov  ah, 0x02
    int  0x1A
    jc   .st_no_current
    mov  al, ch
    call print_bcd
    mov  al, ':'
    mov  bl, ATTR_BRIGHT
    call putc_color
    mov  al, cl
    call print_bcd
    mov  al, ':'
    call putc_color
    mov  al, dh
    call print_bcd
    call nl
    jmp  .st_prompt
.st_no_current:
    mov  si, str_na
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

.st_prompt:
    mov  si, str_st_prompt
    mov  bl, ATTR_YELLOW
    call puts_c
    call shell_readline

    cmp  byte [cmd_len], 0
    je   .st_cancel

    lea  si, [cmd_buf]
    call parse_uint16
    cmp  ax, 23
    ja   .st_bad
    call .st_to_bcd
    mov  ch, al

    cmp  byte [si], ':'
    jne  .st_bad
    inc  si

    call parse_uint16
    cmp  ax, 59
    ja   .st_bad
    call .st_to_bcd
    mov  cl, al

    cmp  byte [si], ':'
    jne  .st_bad
    inc  si

    call parse_uint16
    cmp  ax, 59
    ja   .st_bad
    call .st_to_bcd
    mov  dh, al

    xor  dl, dl
    mov  ah, 0x03
    int  0x1A

    mov  si, str_time_set_ok
    mov  bl, ATTR_GREEN
    call puts_c
    call nl
    call nl
    jmp  .st_end

.st_bad:
    mov  si, str_st_fmt_err
    mov  bl, ATTR_RED
    call puts_c
    call nl
    jmp  .st_end

.st_cancel:
    mov  si, str_no_change
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

.st_end:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

.st_to_bcd:
    push bx
    push dx
    xor  dx, dx
    mov  bx, 10
    div  bx
    shl  al, 4
    or   al, dl
    pop  dx
    pop  bx
    ret

; -
; sys - full system snapshot: identity, clock, uptime, memory map
; -
cmd_sys:
    push ax
    push bx
    push cx
    push dx
    push si

    call nl
    mov  si, str_sys_hdr
    mov  bl, ATTR_CYAN
    call puts_c

    ; - Version / identity -
    mov  si, str_sys_os
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  si, str_ver_short
    mov  bl, ATTR_BRIGHT
    call puts_c
    call nl

    mov  si, str_sys_arch
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  si, str_uname_text
    mov  bl, ATTR_BRIGHT
    call puts_c
    call nl

    mov  si, str_sys_user
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  si, str_whoami_text
    mov  bl, ATTR_BRIGHT
    call puts_c
    call nl

    mov  si, str_sys_color
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  al, [shell_attr]
    mov  bl, ATTR_BRIGHT
    call print_hex_byte
    call nl

    ; - Separator -
    mov  si, str_sys_sep
    mov  bl, ATTR_CYAN
    call puts_c

    ; - Date -
    mov  si, str_sys_date
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  ah, 0x04
    int  0x1A
    jc   .sys_nd
    mov  al, ch
    call print_bcd
    mov  al, cl
    call print_bcd
    mov  al, '-'
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  al, dh
    call print_bcd
    mov  al, '-'
    call putc_color
    mov  al, dl
    call print_bcd
    call nl
    jmp  .sys_time
.sys_nd:
    mov  si, str_na
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

    ; - Time -
.sys_time:
    mov  si, str_sys_time
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  ah, 0x02
    int  0x1A
    jc   .sys_nt
    mov  al, ch
    call print_bcd
    mov  al, ':'
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  al, cl
    call print_bcd
    mov  al, ':'
    call putc_color
    mov  al, dh
    call print_bcd
    call nl
    jmp  .sys_uptime
.sys_nt:
    mov  si, str_na
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

    ; - Uptime -
.sys_uptime:
    mov  si, str_sys_up
    mov  bl, ATTR_YELLOW
    call puts_c
    xor  ah, ah
    int  0x1A
    sub  dx, [boot_ticks_lo]
    sbb  cx, [boot_ticks_hi]
    mov  ax, dx
    xor  dx, dx
    mov  bx, 18
    div  bx
    call print_uint
    mov  si, str_seconds
    mov  bl, ATTR_NORMAL
    call puts_c
    call nl

    ; - Separator -
    mov  si, str_sys_sep
    mov  bl, ATTR_CYAN
    call puts_c

    ; - Memory map -
    mov  si, str_mem_text
    mov  bl, ATTR_NORMAL
    call puts_c

    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done

; -
; cmd_pm - switch to 32-bit protected mode
; -
cmd_pm:
    push ax
    push bx
    push si

    call nl
    mov  si, str_pm_switching
    mov  bl, ATTR_CYAN
    call puts_c
    call nl

    call drv_rm_shutdown
    call vbe_init            ; must happen in real mode before PM switch
    pop  si
    pop  bx
    pop  ax
    call boot_to_pm          ; does A20, GDT, CR0, far jump - does not return

; -
; cmd_probe - 16-bit mode verifier
; -
cmd_probe:
    push ax
    push bx
    push cx
    push dx
    push si

    call nl
    mov  si, str_probe_hdr
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_probe_t1
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  ah, 0x03
    xor  bh, bh
    int  0x10
    mov  si, str_probe_cur
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  al, dh
    xor  ah, ah
    call print_uint
    mov  al, ','
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  al, dl
    xor  ah, ah
    call print_uint
    mov  si, str_probe_ok
    mov  bl, ATTR_GREEN
    call puts_c
    call nl

    mov  si, str_probe_t2
    mov  bl, ATTR_YELLOW
    call puts_c
    xor  ah, ah
    int  0x1A
    mov  si, str_probe_ticks
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  ax, cx
    call print_uint
    mov  al, ':'
    mov  bl, ATTR_NORMAL
    call putc_color
    mov  ax, dx
    call print_uint
    mov  si, str_probe_ok
    mov  bl, ATTR_GREEN
    call puts_c
    call nl

    call nl
    mov  si, str_probe_pass
    mov  bl, ATTR_GREEN
    call puts_c
    call nl
    call nl

    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    jmp  shell_exec.done