; ===========================================================================
; pm/pm_shell.asm - 32-bit Protected Mode entry point and shell dispatcher
; ===========================================================================

; -
; 32-bit entry point - jumped to from cmd_system.asm after CR0.PE is set
; -
[BITS 32]

pm_entry:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, 0x9e000
    call bios_disk_init     ; detect data drive via BIOS INT 13h
    call fsd_init           ; read ClaudeFS data directory into RAM
    call pm_drv_init        ; init NIC before interrupts are enabled
    call irq_init           ; remap PIC, install IDT, enable IRQ0 at 100Hz
    call scr_counter_init ; seed screenshot counter from existing files on disk
    call gfx_init


    ; If VBE failed, skip the graphical WM entirely and use text-mode shell
    cmp  byte [vbe_ok], 1
    jne  .text_shell

    ; initialise window manager (draws desktop + taskbar)
    call wm_init

    ; load wallpaper first ,! populates WP_REMAP used by icons + cursor
    call wallpaper_load

    ; try to load bitmap cursor from ClaudeFS
    call cursor_load_bmp

    ; load desktop icons from ClaudeFS
    call icons_init

    ; open the initial Terminal window ,! offset right to leave icon column
    mov  al,  WM_TERM
    mov  ebx, 110           ; x: leave 110px for icon column
    mov  ecx, 50
    mov  edx, 520           ; width: fills to x=630
    mov  esi, 340
    call wm_open            ; ECX = window index (ignored here)

    call wm_draw_all

    call term_init
    call mouse_init

.loop:
    call mouse_poll

    ; update icon hover state (for future use)
    call icons_hover

    ; check for window manager mouse events
    mov  al, [mouse_btn]
    mov  bl, [pm_prev_btn]

    ; left button just pressed?
    test al, 0x01
    jz   .check_drag
    test bl, 0x01
    jnz  .check_drag        ; was already held
    ; fresh press ,! check icons first
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    call icons_click
    jc   .btn_done          ; icon handled it
    mov  eax, [mouse_x]    ; reload ,! icons_click clobbers EAX/EBX
    mov  ebx, [mouse_y]
    call wm_on_click
    jmp  .btn_done

.check_drag:
    ; left held = drag
    test al, 0x01
    jz   .check_release
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    call wm_on_drag
    jmp  .btn_done

.check_release:
    test bl, 0x01
    jz   .btn_done
    call wm_on_release

.btn_done:
    mov  al, [mouse_btn]
    mov  [pm_prev_btn], al

    ; refresh live window content (clock ticks, etc.)
    call wm_update_contents
    call term_tick
    cmp  byte [scr_pending], 1
    jne  .no_scr
.no_scr:
    jmp  .loop

; -
; .text_shell ,! VBE unavailable; run text-mode PM shell instead
; -
.text_shell:
    call pm_cls
    mov  esi, pm_str_novbe
    mov  bl,  0x0C
    call pm_puts
    call pm_newline

pm_shell_loop:
    mov  esi, pm_prompt
    mov  bl, 0x0A
    call pm_puts
    call pm_readline
    call pm_exec
    jmp  pm_shell_loop

; pm_gfx_test removed - window manager (wm.asm) now handles all drawing
; -
; pm_run_command ,! copy ESI string into pm_input_buf and execute it
; Used by the start menu to launch commands programmatically.
pm_run_command:
    push esi
    push edi
    push ecx
    mov  edi, pm_input_buf
    xor  ecx, ecx
.copy:
    mov  al, [esi + ecx]
    mov  [edi + ecx], al
    inc  ecx
    test al, al
    jnz  .copy
    dec  ecx
    mov  [pm_input_len], ecx
    pop  ecx
    pop  edi
    pop  esi
    call pm_exec
    ret

; pm_exec - dispatch command in pm_input_buf
; -
pm_exec:
    push esi
    push edi
    push ebx

    cmp  dword [pm_input_len], 0
    je   .done

    ; exact matches
    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_help
    call pm_strcmp
    je   .help

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_clear
    call pm_strcmp
    je   .clear

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_exit
    call pm_strcmp
    je   .exit

    ; prefix matches
    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_echo
    call pm_startswith
    je   .echo

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_calc
    call pm_startswith
    je   .calc

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_probe
    call pm_strcmp
    je   .probe

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_drivers
    call pm_strcmp
    je   .drivers

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_pci
    call pm_strcmp
    je   .pci

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_ifconfig
    call pm_strcmp
    je   .ifconfig

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_arp
    call pm_strcmp
    je   .arp

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_arping
    call pm_startswith
    je   .arping

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_ping
    call pm_startswith
    je   .ping

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_term
    call pm_strcmp
    je   .term

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_helpwin
    call pm_strcmp
    je   .helpwin

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_sw
    call pm_strcmp
    je   .stopwatch

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_timer
    call pm_startswith
    je   .timer

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_files
    call pm_strcmp
    je   .files

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_savescr
    call pm_strcmp
    je   .savescr

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_dns
    call pm_startswith
    je   .dns

    mov  esi, pm_input_buf
    mov  edi, pm_str_cmd_ls
    call pm_strcmp
    je   .ls

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_cat
    call pm_startswith
    je   .cat

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_rm
    call pm_startswith
    je   .rm

    mov  esi, pm_input_buf
    mov  edi, pm_str_pfx_hexdump
    call pm_startswith
    je   .hexdump

    ; unknown
    mov  esi, pm_str_unknown
    mov  bl, 0x0C
    call pm_puts
    jmp  .done

.help:  call pm_cmd_help
    jmp  .done
.clear: call pm_cmd_clear
    jmp  .done
.echo:  call pm_cmd_echo
    jmp  .done
.calc:  call pm_cmd_calc
    jmp  .done
.probe: call pm_cmd_probe
    jmp  .done
.drivers: call pm_cmd_drivers
    jmp  .done
.pci:       call cmd_pci
    jmp  .done
.ifconfig:  call cmd_ifconfig
    jmp  .done
.arp:       call cmd_arp
    jmp  .done
.arping:    call cmd_arping
    jmp  .done
.ping:      call cmd_ping
    jmp  .done
.stopwatch: call pm_cmd_stopwatch
    jmp  .done
.term:      call pm_cmd_term
    jmp  .done
.helpwin:   call pm_cmd_helpwin
    jmp  .done
.timer:     call pm_cmd_timer
    jmp  .done
.files:     call pm_cmd_files
    jmp  .done
.savescr:   call pm_cmd_savescr
    jmp  .done
.dns:       call cmd_dns
    jmp  .done
.ls:        call pm_cmd_ls
    jmp  .done
.cat:       call pm_cmd_cat
    jmp  .done
.rm:        call pm_cmd_rm
    jmp  .done
.hexdump:   call pm_cmd_hexdump
    jmp  .done
.exit:  call pm_cmd_exit       ; does not return to here

.done:
    pop  ebx
    pop  edi
    pop  esi
    ret

; -
; -
; pm_cmd_stopwatch ,! open stopwatch window, or start/stop/reset if open
; Usage: stopwatch          -> open window in stopwatch mode
;        stopwatch          -> if window open: toggle start/stop
;        stopwatch reset    -> reset to 00:00.00
; -

; -
; pm_cmd_term ,! open a new Terminal window
; -
pm_cmd_term:
    pusha
    mov  al,  WM_TERM
    mov  ebx, 110
    mov  ecx, 50
    mov  edx, 520
    mov  esi, 340
    call wm_open
    jc   .full
    push ecx
    call wm_draw_all
    call term_init
    pop  ecx
    jmp  .done
.full:
    mov  esi, pm_str_wm_full
    call term_puts
    call term_newline
.done:
    popa
    ret

; -
; pm_cmd_helpwin ,! open About/Help window
; -
pm_cmd_helpwin:
    pusha
    mov  al,  WM_HELP
    mov  ebx, 150
    mov  ecx, 100
    mov  edx, 300
    mov  esi, 210
    call wm_open
    jc   .full
    push ecx
    call wm_draw_all
    pop  ecx
    call wm_draw_help
    jmp  .done
.full:
    mov  esi, pm_str_wm_full
    call term_puts
    call term_newline
.done:
    popa
    ret

pm_cmd_stopwatch:
    pusha
    ; check if a stopwatch window is already open
    mov  dword [wm_i], 0
.sw_find:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .sw_open_new
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .sw_next
    cmp  byte [edi+16], WM_CLOCK
    je   .sw_found
.sw_next:
    inc  dword [wm_i]
    jmp  .sw_find

.sw_found:
    ; check for 'reset' argument
    mov  esi, pm_input_buf + 10  ; after "stopwatch "
    cmp  byte [esi-1], ' '
    jne  .sw_toggle
    mov  edi, pm_str_sw_reset
    call pm_strcmp
    jne  .sw_toggle
    ; reset
    mov  dword [sw_ticks], 0
    mov  byte  [sw_running], 0
    mov  ecx, [wm_i]
    call wm_draw_clock
    jmp  .sw_done

.sw_toggle:
    ; toggle running state
    xor  byte [sw_running], 1
    mov  ecx, [wm_i]
    call wm_draw_clock
    jmp  .sw_done

.sw_open_new:
    mov  byte [sw_mode], SW_MODE_SW
    mov  dword [sw_ticks], 0
    mov  dword [sw_cs_count], 0
    mov  dword [sw_start_offset], 0
    mov  byte  [sw_running], 0
    mov  al,  WM_CLOCK
    mov  ebx, 190
    mov  ecx, 150
    mov  edx, 220
    mov  esi, 100
    call wm_open
    jc   .sw_full
    push ecx
    call wm_draw_all
    pop  ecx
    call wm_draw_clock
    jmp  .sw_done
.sw_full:
    mov  esi, pm_str_wm_full
    call term_puts
    call term_newline
.sw_done:
    popa
    ret

; -
; pm_cmd_timer ,! open countdown timer window
; Usage: timer MM:SS        -> open timer window counting down from MM:SS
; -
pm_cmd_timer:
    pusha

    ; parse "timer MM:SS" ,! skip "timer " prefix (6 chars)
    mov  esi, pm_input_buf
    add  esi, 6

    ; parse MM
    xor  eax, eax
    xor  ecx, ecx
.mm_loop:
    movzx ebx, byte [esi]
    cmp  bl, ':'
    je   .mm_done
    cmp  bl, 0
    je   .parse_err
    sub  bl, '0'
    imul eax, 10
    add  eax, ebx
    inc  esi
    jmp  .mm_loop
.mm_done:
    mov  [wm_clk_mm], eax
    inc  esi                    ; skip ':'

    ; parse SS
    xor  eax, eax
.ss_loop:
    movzx ebx, byte [esi]
    cmp  bl, 0
    je   .ss_done
    sub  bl, '0'
    imul eax, 10
    add  eax, ebx
    inc  esi
    jmp  .ss_loop
.ss_done:
    mov  [wm_clk_ss], eax

    ; convert MM:SS to ticks (100Hz)
    mov  eax, [wm_clk_mm]
    imul eax, 60
    add  eax, [wm_clk_ss]
    ; store in SECONDS (RTC-based timer uses seconds, not centiseconds)
    mov  [sw_ticks_end], eax
    mov  dword [sw_ticks], 0
    mov  dword [sw_rtc_secs], 0     ; reset RTC elapsed counter
    mov  byte  [sw_mode],    SW_MODE_TIMER
    mov  byte  [sw_running], 1

    ; open or reuse window
    mov  al,  WM_CLOCK
    mov  ebx, 190
    mov  ecx, 150
    mov  edx, 220
    mov  esi, 100
    call wm_open
    jc   .timer_full
    push ecx
    call wm_draw_all
    pop  ecx
    call wm_draw_clock
    jmp  .timer_done
.timer_full:
    mov  esi, pm_str_wm_full
    call term_puts
    call term_newline
    jmp  .timer_done
.parse_err:
    mov  esi, pm_str_timer_usage
    call term_puts
    call term_newline
.timer_done:
    popa
    ret

; -
; pm_cmd_files  ,! open a Files window
; -
pm_cmd_files:
    pusha
    mov  al,  WM_FILES
    mov  ebx, 160
    mov  ecx, 80
    mov  edx, 300
    mov  esi, 280
    call wm_open            ; returns new index in ECX
    jc   .full
    push ecx                ; save window index
    call wm_draw_all
    pop  ecx                ; restore for wm_draw_files
    call wm_draw_files
    jmp  .done
.full:
    mov  esi, pm_str_wm_full
    call term_puts
    call term_newline
.done:
    popa
    ret

; -
; Sub-modules
; -
%include "pm/pm_screen.asm"
%include "pm/pm_keyboard.asm"
%include "pm/pm_string.asm"
%include "pm/pm_commands.asm"
%include "pm/pm_drivers.asm"
%include "pm/pm_data.asm"
%include "pm/mouse.asm"
%include "pm/terminal.asm"
%include "pm/fs_pm.asm"
%include "pm/wm.asm"
%include "pm/icons.asm"
%include "pm/wallpaper.asm"