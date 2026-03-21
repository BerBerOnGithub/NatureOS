; ===========================================================================
; shell/shell.asm - Prompt display and command dispatcher
; ===========================================================================

; -
; shell_prompt - print the shell prompt
; -
shell_prompt:
    push ax
    push bx
    push si
    mov  si, str_prompt_a
    mov  bl, ATTR_GREEN
    call puts_c
    mov  si, str_prompt_b
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_prompt_c
    mov  bl, [shell_attr]
    call puts_c
    mov  si, str_prompt_d
    mov  bl, ATTR_BRIGHT
    call puts_c
    pop  si
    pop  bx
    pop  ax
    ret

; -
; shell_exec - dispatch the command in cmd_buf
; -
shell_exec:
    cmp  byte [cmd_len], 0
    je   .done

    ; - Exact-match commands -
    mov  si, str_cmd_help
    call strcmp_buf
    je   cmd_help

    mov  si, str_cmd_clear
    call strcmp_buf
    je   cmd_clear

    mov  si, str_cmd_reboot
    call strcmp_buf
    je   cmd_reboot

    mov  si, str_cmd_halt
    call strcmp_buf
    je   cmd_halt

    mov  si, str_cmd_date
    call strcmp_buf
    je   cmd_date

    mov  si, str_cmd_time
    call strcmp_buf
    je   cmd_time

    mov  si, str_cmd_sys
    call strcmp_buf
    je   cmd_sys

    mov  si, str_cmd_beep
    call strcmp_buf
    je   cmd_beep

    mov  si, str_cmd_fortune
    call strcmp_buf
    je   cmd_fortune

    mov  si, str_cmd_colors
    call strcmp_buf
    je   cmd_colors

    mov  si, str_cmd_guess
    call strcmp_buf
    je   cmd_guess

    mov  si, str_cmd_pm
    call strcmp_buf
    je   cmd_pm

    mov  si, str_cmd_probe
    call strcmp_buf
    je   cmd_probe

    mov  si, str_cmd_drivers
    call strcmp_buf
    je   cmd_drivers

    mov  si, str_cmd_setdate
    call strcmp_buf
    je   cmd_setdate

    mov  si, str_cmd_settime
    call strcmp_buf
    je   cmd_settime

    mov  si, str_cmd_ls
    call strcmp_buf
    je   cmd_ls

    ; - Prefix-matched commands -
    mov  si, str_pfx_echo
    call startswith
    je   cmd_echo

    mov  si, str_cmd_color_bare  ; "color" with no arg +' palette
    call strcmp_buf
    je   cmd_color

    mov  si, str_pfx_color
    call startswith
    je   cmd_color

    mov  si, str_pfx_calc
    call startswith
    je   cmd_calc

    mov  si, str_pfx_run
    call startswith
    je   cmd_run

    ; - Unknown command -
    mov  si, str_err_pre
    mov  bl, ATTR_RED
    call puts_c
    lea  si, [cmd_buf]
    mov  bl, ATTR_YELLOW
    call puts_c
    mov  si, str_err_suf
    mov  bl, ATTR_RED
    call puts_c
    call nl

.done:
    ret