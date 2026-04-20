; ===========================================================================
; commands/data.asm - All variables and string data
; ===========================================================================

; -
; Boot menu strings  (CP437 double-line box with shadow effect)
; ╔════╗  ║  ╠══╣  ╚════╝   ► = 0x10   • = 0x07   ░ = 0xB0  ▒ = 0xB1  ▓ = 0xB2
; -
str_mnu_top:      db 201, 205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205, 187, 0 ; 50 '='

str_mnu_title:    db '                NatureOS Boot Menu                ', 0 ; 50 chars

str_mnu_sub:      db '           NatureOS v2.0  ', 7, '  Build 2.0.0          ', 0 ; 50 chars
str_mnu_sep:      db 204, 205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205, 185, 0 ; 50 '='

str_mnu_blank:    db '                                                  ', 0 ; 50 spaces

str_mnu_border_l:
    db 186, 0
str_mnu_border_r:
    db 186, 0

str_mnu_arrow_on:
    db 16, ' ', 0      ; '► '
str_mnu_arrow_off:
    db '  ', 0         ; '  '

str_mnu_o1desc:
    db 'Graphical desktop   - WM, mouse, network        ', 0  ; 48 chars
str_mnu_o2desc:
    db 'Text-mode shell     - BIOS, FS, apps            ', 0  ; 48 chars
str_mnu_o3desc:
    db 'Memory tester       - RAM check, hardware       ', 0  ; 48 chars

str_mnu_bot_main: db 200, 205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205,205, 188, 0 ; 50 '='
str_mnu_shadow_bot: db 219, 219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219,219, 0 ; 53 characters
str_mnu_hint:
    db '            arrows/1/2/3 select.  Enter = boot            ', 0

str_mt_title:    db ' *** NatureOS Memory Tester v1.0 ***', 0
str_mt_test:     db ' Running Test: ', 0
str_mt_t0:       db '#0 [Address: Walking 1s] ', 0
str_mt_t1:       db '#1 [Address: Own Addr]   ', 0
str_mt_t2:       db '#2 [MI: Ones & Zeros]    ', 0
str_mt_t3:       db '#3 [MI: 8-bit Pattern]   ', 0
str_mt_t4:       db '#4 [MI: Random Pattern]  ', 0
str_mt_t5:       db '#5 [Block Move Test]     ', 0
str_mt_t6:       db '#6 [Random Sequence]     ', 0
str_mt_pattern:  db ' Current Pattern: 0x', 0

str_mt_addr:     db ' Scanned: ', 0
str_mt_errors:   db ' Total Errors:    ', 0
str_mt_pass_lbl: db '  Pass: ', 0
str_mt_mb:       db ' MB', 0
str_mt_esc:      db ' Press ESC to exit to menu', 0

; -
; Variables
; -
shell_attr:      db ATTR_BRIGHT
boot_ticks_hi:   dw 0
boot_ticks_lo:   dw 0
guess_secret:    db 0
guess_tries:     db 0
sd_century: db 0
sd_year:    db 0
sd_month:   db 0
sd_day:     db 0
mt_errors:      dw 0
mt_pass:        dw 0
mt_cur_pattern: dd 0
calc_n1_lo:      dw 0
calc_n2_lo:      dw 0
calc_op:         db 0
rm_sp_save:      dw 0     ; real-mode SP saved before PM switch
mnu_sel:         db 0
mnu_row_base:    db 0
mt_cur_addr:    dd 0
mt_test_id:     dw 0
mt_seed:        dd 0x12345678
mt_active:       db 0      ; 1 if memory tester is running
mt_ram_size:     dd 0x04000000 ; Limit in bytes (default 64MB)

; -
; Prompt strings
; -
str_prompt_a:    db 'root', 0
str_prompt_b:    db '@', 0
str_prompt_c:    db 'NatureOS:~', 0
str_prompt_d:    db '# ', 0

; -
; Command keyword strings
; -
str_cmd_help:        db 'help', 0
str_cmd_ver:         db 'ver', 0
str_cmd_clear:       db 'clear', 0
str_cmd_reboot:      db 'reboot', 0
str_cmd_halt:        db 'halt', 0
str_cmd_uname:       db 'uname', 0
str_cmd_whoami:      db 'whoami', 0
str_cmd_mem:         db 'mem', 0
str_cmd_date:        db 'date', 0
str_cmd_time:        db 'time', 0
str_cmd_beep:        db 'beep', 0
str_cmd_fortune:     db 'fortune', 0
str_cmd_colors:      db 'colors', 0
str_cmd_sys:         db 'sys', 0
str_cmd_guess:       db 'guess', 0
str_quit:            db 'quit', 0

str_cmd_pm:          db 'pm', 0
str_cmd_probe:       db 'probe', 0
str_cmd_drivers:     db 'drivers', 0
str_cmd_setdate:     db 'setdate', 0
str_cmd_settime:     db 'settime', 0
str_pfx_echo:    db 'echo ', 0
str_pfx_color:   db 'color ', 0
str_pfx_calc:    db 'calc ', 0
str_cmd_color_bare: db 'color', 0

; -
; Error / misc strings
; -
str_err_pre:    db 'Unknown command: ', 0
str_err_suf:    db '  (type "help")', 0
str_rebooting:  db 'Rebooting...', 0
str_halting:    db 'System halted. Power off safely.', 0
str_exec_pre:   db '[kernel] Executing: hello.com', 0
str_exec_post:  db '[kernel] Process exited with code 0', 0
str_rtc_fail:   db ' RTC not available.', 0
str_na:         db 'N/A', 0
str_seconds:    db ' seconds', 0

; -
; Command-specific strings
; -
str_date_set_ok:   db ' Date updated.', 0
str_time_set_ok:   db ' Time updated.', 0
str_pm_warn1:    db ' !! WARNING: ENTERING PROTECTED MODE !!', 13, 10
                 db ' This is a ONE-WAY operation.', 13, 10
                 db ' The real-mode shell will be gone forever.', 13, 10
                 db ' You will NOT be able to switch back.', 13, 10
                 db ' A minimal 32-bit PM shell will take over.', 13, 10, 0
str_pm_warn2:    db ' To return: close QEMU and restart.', 13, 10, 0
str_pm_prompt:   db ' CONTINUE? (Y/N): ', 0
str_pm_abort:    db ' Aborted. Staying in real mode.', 0
str_pm_switching: db ' Switching to protected mode...', 0
str_sd_current:    db ' Current date: ', 0
str_sd_prompt:     db ' New date (YYYY-MM-DD, blank=cancel): ', 0
str_sd_fmt_err:    db ' Invalid date. Use YYYY-MM-DD (month 1-12, day 1-31)', 0
str_st_current:    db ' Current time: ', 0
str_st_prompt:     db ' New time (HH:MM:SS, blank=cancel): ', 0
str_st_fmt_err:    db ' Invalid time. Use HH:MM:SS (HH 0-23, MM/SS 0-59)', 0
str_no_change:     db ' No change.', 0
str_date_lbl:    db ' Date: ', 0
str_time_lbl:    db ' Time: ', 0

str_beeped:      db ' *BEEP*', 0

str_eq:          db ' = ', 0
str_rem:         db '  (remainder: ', 0
str_overflow:    db 'Overflow (range: -32768 to 32767)', 0
str_divzero:     db 'Division by zero', 0
str_badop:       db 'Unknown operator. Use +  -  *  /', 0
str_calc_usage:  db ' Usage: calc <num> <op> <num>', 13, 10
                 db ' Range: -32768 to 32767', 13, 10
                 db ' Example: calc -10 + 3', 13, 10, 0

str_color_ok:    db ' Shell color set. Try typing something!', 0
str_color_merge_warn:
    db ' WARNING: foreground and background are the same colour.', 13, 10
    db ' Text will be invisible against the background.', 13, 10, 0
str_color_merge_prompt:
    db ' Continue anyway? (y/n): ', 0
str_color_merge_abort:
    db ' Colour change cancelled.', 0
str_color_usage: db ' Usage: color [XX]  e.g. color 0a  color 0f  color 1e', 13, 10
                 db ' No argument: show color palette', 13, 10
                 db ' High nibble=background, low=foreground (VGA attributes)', 13, 10, 0

str_fortune_hdr: db ' "', 0

str_colors_hdr:  db ' VGA Color Table (bg=black)', 0
str_clr_sample:  db '  NatureOS v2.0  ', 0

str_sys_hdr:     db ' System Information', 13, 10
                 db ' -', 13, 10, 0
str_sys_sep:     db ' -', 13, 10, 0
str_sys_os:      db ' OS:      ', 0
str_sys_arch:    db ' Arch:    ', 0
str_sys_user:    db ' User:    ', 0
str_sys_date:    db ' Date:    ', 0
str_sys_time:    db ' Time:    ', 0
str_sys_up:      db ' Uptime:  ~', 0
str_sys_kern:    db ' Kernel:  ', 0
str_sys_color:   db ' Color:   0x', 0
str_ver_short:   db 'NatureOS 2.0.0-stable', 0

str_guess_intro:  db 13, 10
                  db ' Guess the Number!', 13, 10
                  db ' I am thinking of a number between 1 and 100.', 13, 10
                  db ' Type "quit" to give up.', 13, 10, 13, 10, 0
str_guess_prompt: db ' Your guess: ', 0
str_too_high:     db ' Too high! Try lower.', 13, 10, 0
str_too_low:      db ' Too low! Try higher.', 13, 10, 0
str_g_correct:    db 13, 10, ' Correct! You got it in ', 0
str_g_tries:      db ' tries!', 13, 10, 0
str_g_invalid:    db ' Please enter a number between 1 and 100.', 13, 10, 0
str_g_quit:       db ' The number was: ', 0

str_ascii_hdr:   db ' ASCII Table (32-126)', 13, 10, 0

; -
; Help text - page 1 (rows used: 1 blank + 3 header + 10 cmds + 1 blank = 15)
; -
str_help_pg1:
    db 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db ' |      NatureOS v2.0         |  Command Reference  (1 of 2)  |', 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db ' | help                       | this screen (paged)           |', 13, 10
    db ' | echo <text>                | print text to screen          |', 13, 10
    db ' | clear                      | clear the screen              |', 13, 10
    db ' | reboot                     | reboot the machine            |', 13, 10
    db ' | halt                       | halt the CPU                  |', 13, 10
    db ' | calc <n> <op> <n>          | calculator  + - * /  signed   |', 13, 10
    db ' | color [XX]                 | set color or show palette     |', 13, 10
    db ' | beep                       | sound the PC speaker          |', 13, 10
    db ' | fortune                    | display a random quote        |', 13, 10
    db ' | guess                      | number guessing game (1-100)  |', 13, 10
    db ' | colors                     | show all 16 colour swatches   |', 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db 13, 10
    db 0

; "Press any key" prompt (shown at bottom of page 1)
str_help_more:
    db ' -- Press any key for page 2 --', 13, 10, 0

; -
; Help text - page 2 (rows used: 1 blank + 3 header + 9 cmds + 1 blank = 14)
; -
str_help_pg2:
    db 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db ' |      NatureOS v2.0         |  Command Reference  (2 of 2)  |', 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db ' | sys                        | full system snapshot          |', 13, 10
    db ' | date                       | show RTC date                 |', 13, 10
    db ' | time                       | show RTC time                 |', 13, 10
    db ' | setdate                    | set the RTC date              |', 13, 10
    db ' | settime                    | set the RTC time              |', 13, 10
    db ' | guess                      | number guessing game (1-100)  |', 13, 10
    db ' | colors                     | show all 16 colour swatches   |', 13, 10
    db ' | ls                         | list filesystem files         |', 13, 10
    db ' | run <name>                 | run an app from ClaudeFS      |', 13, 10
    db ' | probe                      | verify you are in real mode   |', 13, 10
    db ' | drivers                    | show loaded RM drivers        |', 13, 10
    db ' | pm                         | switch to 32-bit prot. mode   |', 13, 10
    db ' +----------------------------+--------------------------------+', 13, 10
    db 13, 10
    db 0

; -
; Ver text
; -
str_ver_text:
    db 13, 10
    db ' NatureOS version 2.0', 13, 10
    db ' Kernel:       1.0.0-stable (real mode)', 13, 10
    db ' Architecture: x86 16-bit', 13, 10
    db ' Build date:   2026-02-28', 13, 10
    db ' Author:       Claude (Anthropic)', 13, 10
    db 13, 10
    db 0

str_uname_text:  db 'NatureOS 1.0.0-stable x86 real-mode', 0
str_whoami_text: db 'root', 0

; -
; Memory map text
; -
str_mem_text:
    db 13, 10
    db ' Memory Map:', 13, 10
    db ' 0x00000-0x003FF IVT', 13, 10
    db ' 0x00400-0x004FF BDA', 13, 10
    db ' 0x00500-0x07BFF Stack/Free', 13, 10
    db ' 0x07C00-0x07DFF Bootloader', 13, 10
    db ' 0x08000-0x17FFF NatureOS Kernel', 13, 10
    db ' 0x0C000-0x9FFFF Conv.RAM', 13, 10
    db ' 0xB8000-0xBFFFF VGA Buffer', 13, 10
    db ' 0xC0000-0xFFFFF ROM/BIOS', 13, 10
    db 13, 10
    db 0

; -
; Hello World output
; -
str_hello_out:
    db 13, 10
    db '  Hello World from NatureOS v2.0', 13, 10
    db '  Booted on bare metal. No OS beneath us.', 13, 10
    db 13, 10
    db 0


; -
; Banner
; -
str_banner:
    db 13, 10
    db '     ', 219,219,219,187, '   ', 219,219,187, ' ', 219,219,219,219,219,187, ' ', 219,219,219,219,219,219,219,219,187, 219,219,187, '   ', 219,219,187, 219,219,219,219,219,219,187, ' ', 219,219,219,219,219,219,219,187, ' ', 219,219,219,219,219,219,187, ' ', 219,219,219,219,219,219,219,187, 13, 10
    db '     ', 219,219,219,219,187, '  ', 219,219,186, 219,219,201,205,205,219,219,187, 200,205,205,219,219,201,205,205,188, 219,219,186, '   ', 219,219,186, 219,219,201,205,205,219,219,187, 219,219,201,205,205,205,205,188, 219,219,201,205,205,205,219,219,187, 219,219,201,205,205,205,205,188, 13, 10
    db '     ', 219,219,201,219,219,187, ' ', 219,219,186, 219,219,219,219,219,219,219,186, '   ', 219,219,186, '   ', 219,219,186, '   ', 219,219,186, 219,219,219,219,219,219,201,188, 219,219,219,219,219,187, '  ', 219,219,186, '   ', 219,219,186, 219,219,219,219,219,219,219,187, 13, 10
    db '     ', 219,219,186, 200,219,219,187, 219,219,186, 219,219,201,205,205,219,219,186, '   ', 219,219,186, '   ', 219,219,186, '   ', 219,219,186, 219,219,201,205,205,219,219,187, 219,219,201,205,205,188, '  ', 219,219,186, '   ', 219,219,186, 200,205,205,205,205,219,219,186, 13, 10
    db '     ', 219,219,186, ' ', 200,219,219,219,219,186, 219,219,186, '  ', 219,219,186, '   ', 219,219,186, '   ', 200,219,219,219,219,219,219,201,188, 219,219,186, '  ', 219,219,186, 219,219,219,219,219,219,219,187, 200,219,219,219,219,219,219,201,188, 219,219,219,219,219,219,219,186, 13, 10
    db '     ', 200,205,188, '  ', 200,205,205,205,188, 200,205,188, '  ', 200,205,188, '   ', 200,205,188, '    ', 200,205,205,205,205,205,188, ' ', 200,205,188, '  ', 200,205,188, 200,205,205,205,205,205,205,188, ' ', 200,205,205,205,205,205,188, ' ', 200,205,205,205,205,205,205,188, 13, 10
    db 13, 10
    db '                              v2.0  |  Real-Mode x86  |  2026', 13, 10
    db 0

; -
; MOTD
; -
str_motd:
    db 13, 10
    db ' Welcome to NatureOS v2.0.  Type "help" for commands.', 13, 10
    db 13, 10
    db 0

; -
; Fortune table and strings
; -
fortune_table:
    dw fort0, fort1, fort2, fort3, fort4
    dw fort5, fort6, fort7, fort8, fort9

fort0: db 'The best way to predict the future is to invent it.', 13, 10
       db '   - Alan Kay', 0
fort1: db 'Any sufficiently advanced technology is indistinguishable from magic.', 13, 10
       db '   - Arthur C. Clarke', 0
fort2: db 'First, solve the problem. Then, write the code.', 13, 10
       db '   - John Johnson', 0
fort3: db 'Programs must be written for people to read, and only incidentally', 13, 10
       db '   for machines to execute.  - Abelson & Sussman', 0
fort4: db 'It is not enough to do your best; you must know what to do,', 13, 10
       db '   and then do your best.  - W. Edwards Deming', 0
fort5: db 'The only way to go fast is to go well.', 13, 10
       db '   - Robert C. Martin', 0
fort6: db 'Simplicity is the soul of efficiency.', 13, 10
       db '   - Austin Freeman', 0
fort7: db 'Good code is its own best documentation.', 13, 10
       db '   - Steve McConnell', 0
fort8: db 'In theory there is no difference between theory and practice.', 13, 10
       db '   In practice there is.  - Jan L.A. van de Snepscheut', 0
fort9: db 'The computer was born to solve problems that did not exist before.', 13, 10
       db '   - Bill Gates', 0

; probe command strings (16-bit)
str_probe_hdr:   db ' [PROBE] 16-bit Real Mode Verification', 13, 10
                 db ' -', 13, 10, 0
str_probe_t1:    db ' Test 1: INT 10h (BIOS video)... ', 0
str_probe_t2:    db ' Test 2: INT 1Ah (BIOS timer)... ', 0
str_probe_cur:   db 'cursor=', 0
str_probe_ticks: db 'ticks=', 0
str_probe_ok:    db '  OK', 0
str_probe_pass:  db ' RESULT: All BIOS calls succeeded. You are in REAL MODE.', 0

; -
; GDT - lives here so [ORG 0x8000] is unambiguously applied to all labels.
; Referenced by lgdt in cmd_system.asm and the far jump to pm_entry.
; -
gdt_start:
    dq 0                     ; null descriptor

    ; selector 0x08: code 32-bit, base=0, limit=4GB, execute/read
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xCF
    db 0x00

    ; selector 0x10: data 32-bit, base=0, limit=4GB, read/write
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00

    ; selector 0x18: code 16-bit, base=0, limit=64KB, execute/read (D=0)
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0x0F
    db 0x00

    ; selector 0x20: data 16-bit, base=0, limit=64KB, read/write (D=0)
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0x0F
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start