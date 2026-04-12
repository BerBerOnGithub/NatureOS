; ===========================================================================
; pm/pm_data.asm - 32-bit PM shell variables and strings
;
; Mirrors commands/data.asm for the PM environment.
; All labels prefixed with pm_ to avoid conflicts with 16-bit side.
; ===========================================================================

[BITS 32]

; -
; Variables
; -
pm_cursor_x:    dd 0
pm_cursor_y:    dd 0
pm_input_len:   dd 0
pm_input_buf:   times 128 db 0
pm_shift:       db 0         ; 1 if shift currently held
pm_e0:          db 0         ; 1 if last scancode was E0 prefix

pm_calc_n1:     dd 0
pm_calc_n2:     dd 0
pm_calc_op:     db 0
pm_probe_rows:  dd 0
pm_probe_cols:  dd 0
gfx_dirty:  db 0
scr_pending:  db 0

; -
; PS/2 scan code +' ASCII tables
; Unshifted (scan codes 0x00-0x39)
; -
pm_scancode_table:
    db 0,   27,  '1', '2', '3', '4', '5', '6'   ; 00-07
    db '7', '8', '9', '0', '-', '=', 8,   9      ; 08-0F
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i'   ; 10-17
    db 'o', 'p', '[', ']', 13,  0,   'a', 's'    ; 18-1F
    db 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'   ; 20-27
    db 39,  '`', 0,   92,  'z', 'x', 'c', 'v'   ; 28-2F
    db 'b', 'n', 'm', ',', '.', '/', 0,   '*'    ; 30-37
    db 0,   ' '                                   ; 38-39
    db 0,   0,   0,   0,   0,   0,   0,   0      ; 3A-41 (caps/F1-F8)
    db 0,   0,   0,   0,   0,   '7', '8', '9'    ; 42-49 (F9/F10/NumLk/ScLk/num7/8/9)
    db '-', '4', '5', '6', '+', '1', '2', '3'    ; 4A-51 (num-/4/5/6/+/1/2/3)
    db '0', '.'                                   ; 52-53 (num0/.)

; Shifted (scan codes 0x00-0x39)
pm_scancode_shift:
    db 0,   27,  '!', '@', '#', '$', '%', '^'   ; 00-07
    db '&', '*', '(', ')', '_', '+', 8,   9      ; 08-0F
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I'   ; 10-17
    db 'O', 'P', '{', '}', 13,  0,   'A', 'S'    ; 18-1F
    db 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':'   ; 20-27
    db 34,  '~', 0,   '|', 'Z', 'X', 'C', 'V'   ; 28-2F
    db 'B', 'N', 'M', '<', '>', '?', 0,   '*'    ; 30-37
    db 0,   ' '                                   ; 38-39
    db 0,   0,   0,   0,   0,   0,   0,   0      ; 3A-41 (caps/F1-F8)
    db 0,   0,   0,   0,   0,   '7', '8', '9'    ; 42-49 (F9/F10/NumLk/ScLk/num7/8/9)
    db '-', '4', '5', '6', '+', '1', '2', '3'    ; 4A-51 (num-/4/5/6/+/1/2/3)
    db '0', '.'                                   ; 52-53 (num0/.)

; -
; Shell strings
; -
pm_banner:
    db 13, 10
    db ' +----------------------+----------------------------+', 13, 10
    db ' |   NatureOS v2.0 - 32-bit Protected Mode Shell   |', 13, 10
    db ' |   No BIOS. Direct hardware access.              |', 13, 10
    db ' -', 13, 10
    db ' Type "help" for commands.', 13, 10, 10, 0

pm_prompt:          db 'PM> ', 0

; Command keyword strings
pm_str_cmd_help:    db 'help', 0
pm_str_cmd_clear:   db 'clear', 0
pm_str_cmd_exit:    db 'exit', 0
pm_str_pfx_echo:    db 'echo ', 0
pm_str_pfx_calc:    db 'calc ', 0
pm_str_cmd_probe:   db 'probe', 0
pm_str_cmd_drivers: db 'drivers', 0
pm_str_cmd_pci:     db 'pci', 0
pm_str_cmd_ifconfig: db 'ifconfig', 0
pm_str_cmd_arp:      db 'arp', 0
pm_str_pfx_arping:   db 'arping ', 0
pm_str_pfx_ping:     db 'ping ', 0
pm_str_cmd_term:     db 'term', 0
pm_str_cmd_helpwin:  db 'helpwin', 0
pm_str_cmd_sw:       db 'stopwatch', 0
pm_str_pfx_timer:    db 'timer ', 0
pm_str_cmd_files:    db 'files', 0
pm_str_sw_reset:     db 'reset', 0
pm_str_timer_usage:  db 'Usage: timer MM:SS', 0
pm_str_cmd_savescr:  db 'savescr', 0
pm_str_pfx_dns:      db 'dns ', 0
pm_str_pfx_tcpget:   db 'tcpget ', 0
pm_str_cmd_ls:       db 'ls', 0
pm_str_pfx_cat:      db 'cat ', 0
pm_str_pfx_rm:       db 'rm ', 0
pm_str_pfx_hexdump:  db 'hexdump ', 0
pm_str_cmd_bioscall: db 'bioscall', 0
pm_str_cmd_sysinfo:  db 'sysinfo', 0
pm_str_cmd_browser:  db 'browser', 0

; Window manager strings
pm_str_wm_full:      db 'Max windows open (close one first).', 0

; Mouse button edge-detection
pm_prev_btn:         db 0

; Error strings
pm_str_unknown:
    db ' Unknown command. Type "help" for list.', 13, 10, 0

; -
; Command output strings
; -
pm_str_exit_msg:
    db 13, 10
    db ' Returning to real mode...', 13, 10, 0

pm_str_help_text:
    db 13, 10
    db ' +----------------------+----------------------------+', 13, 10
    db ' |  NatureOS v2.0  PM   |  Command Reference         |', 13, 10
    db ' +----------------------+----------------------------+', 13, 10
    db ' | help                 | this screen                |', 13, 10
    db ' | clear                | clear terminal             |', 13, 10
    db ' | echo <text>          | print text                 |', 13, 10
    db ' | calc <n> <op> <n>    | calculator (+,-,*,/)       |', 13, 10
    db ' | probe                | verify 32-bit PM           |', 13, 10
    db ' | drivers              | show loaded PM drivers     |', 13, 10
    db ' | pci                  | list all PCI devices       |', 13, 10
    db ' | ifconfig             | NIC MAC + link status      |', 13, 10
    db ' | arp                  | show ARP cache             |', 13, 10
    db ' | arping <ip>          | send ARP request           |', 13, 10
    db ' | ping <ip>            | ICMP echo (4 packets)      |', 13, 10
    db ' | dns <hostname>       | resolve hostname via DNS   |', 13, 10
    db ' | tcpget <ip> <p> <path>| HTTP GET via TCP           |', 13, 10
    db ' | stopwatch            | stopwatch window           |', 13, 10
    db ' | timer MM:SS          | countdown timer            |', 13, 10
    db ' | term / files         | open window                |', 13, 10
    db ' | ls                   | list files                 |', 13, 10
    db ' | cat <name>           | print file contents        |', 13, 10
    db ' | rm <name>            | delete file                |', 13, 10
    db ' | hexdump <name>       | hex dump of a file         |', 13, 10
    db ' | savescr              | save screenshot to disk    |', 13, 10
    db ' | sysinfo              | show system information    |', 13, 10
    db ' | exit                 | return to real mode        |', 13, 10
    db ' +----------------------+----------------------------+', 13, 10, 10, 0

; Calc strings
pm_str_eq:          db ' = ', 0
pm_str_rem:         db '  (remainder: ', 0
pm_str_overflow:    db 'Overflow', 13, 10, 0
pm_str_divzero:     db 'Division by zero', 13, 10, 0
pm_str_badop:       db 'Unknown operator. Use + - * /', 13, 10, 0
pm_str_calc_usage:
    db ' Usage: calc <num> <op> <num>', 13, 10
    db ' Example: calc -5 * 12', 13, 10, 0

; probe strings (32-bit)
pm_str_probe_hdr:
    db 13, 10
    db ' [PROBE] 32-bit Protected Mode Verification', 13, 10
    db ' Writing 0xDEADBEEF to 0x00100000 (above 1MB)...', 13, 10, 0
pm_str_probe_written:
    db ' Readback:', 13, 10, 0
pm_str_probe_pass:
    db ' Pattern verified! You are in PROTECTED MODE.', 13, 10, 0
pm_str_probe_fail:
    db ' Pattern mismatch - something is wrong.', 13, 10, 0
pm_str_novbe:
    db '[PM] VBE framebuffer unavailable. Text-mode shell active.', 13, 10, 0