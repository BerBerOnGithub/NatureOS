; ===========================================================================
; kernel.asm - NatureOS Kernel v2.0
;
; Entry point only. Components are %included in two sections:
;
;   16-bit real mode (BIOS-based)
;    core/        hardware abstractions (screen, keyboard, string, utils)
;    drivers/     real-mode driver registry (screen, kbd, rtc, speaker)
;    shell/       prompt, readline, command dispatcher
;    commands/    built-in commands + all string data
;
;   32-bit protected mode (no BIOS)
;    pm/          PM shell, VGA/kbd/PIT drivers, PM driver registry
;
; Boot flow:
;   kernel_main -> drv_rm_init -> boot_menu
;   [1] -> vbe_init -> boot_to_pm -> PM desktop
;   [2] -> rm_shell_loop (real-mode text shell)
;   "exit" in PM -> drv_rm_init -> rm_shell_loop
;
; Assemble: nasm -f bin -o kernel.bin kernel.asm
; ===========================================================================

[BITS 16]
[ORG 0x8000]

; -
; Constants (available to all included files)
; -
ATTR_NORMAL   equ 0x07
ATTR_BRIGHT   equ 0x0F
ATTR_GREEN    equ 0x0A
ATTR_YELLOW   equ 0x0E
ATTR_CYAN     equ 0x0B
ATTR_RED      equ 0x0C
ATTR_MAGENTA  equ 0x0D

FORTUNE_COUNT equ 10

; -
; Kernel entry point  -- MUST stay small: everything here counts toward
; the 0x100-byte budget for the syscall trampoline pad below.
; -
kernel_main:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7BF0
    sti

    ; Save boot tick count for uptime
    xor  ah, ah
    int  0x1A
    mov  [boot_ticks_hi], cx
    mov  [boot_ticks_lo], dx

    ; Initialise real-mode drivers (sets text mode, flushes kbd, speaker off)
    call drv_rm_init

    ; Show boot menu - defined after the times pad below
    call boot_menu

    ; Should never return, but halt just in case
    cli
    hlt

; -
; boot_to_pm
; Switches to 32-bit protected mode unconditionally.
;
; A20 is enabled via three methods for maximum hardware compatibility:
;   1. BIOS INT 15h AX=2401h  (works on most modern BIOSes)
;   2. Keyboard controller     (works on old AT-compatible hardware)
;   3. Fast A20 port 0x92     (works on most PC/AT clones)
;
; The original code used INT 15h AH=86h (BIOS Wait / delay) which does
; nothing at all for A20 -- fixed here.
; -
boot_to_pm:
    ; ---- Method 1: BIOS INT 15h AX=2401h (Enable A20) ----
    mov  ax, 0x2401
    int  0x15
    ; ignore carry -- not all BIOSes support this, fall through to methods 2+3

    ; ---- Method 2: Keyboard controller A20 gate ----
    call .kbc_flush
    mov  al, 0xAD           ; disable keyboard interface
    out  0x64, al
    call .kbc_flush

    mov  al, 0xD0           ; read output port command
    out  0x64, al
    call .kbc_read_ready
    in   al, 0x60           ; read current output port value
    push ax                 ; save it

    call .kbc_flush
    mov  al, 0xD1           ; write output port command
    out  0x64, al
    call .kbc_flush
    pop  ax
    or   al, 0x02           ; set A20 bit (bit 1)
    out  0x60, al           ; write new value
    call .kbc_flush

    mov  al, 0xAE           ; re-enable keyboard interface
    out  0x64, al
    call .kbc_flush

    ; ---- Method 3: Fast A20 via port 0x92 ----
    in   al, 0x92
    or   al, 0x02           ; set A20 enable bit
    and  al, 0xFE           ; CLEAR bit 0 (system reset) -- do NOT trigger reset
    out  0x92, al

    ; ---- Short delay to let A20 propagate ----
    ; Some chipsets need a few microseconds
    mov  cx, 0x100
.a20_delay:
    loop .a20_delay

    cli

    ; Save real-mode stack pointer so mode_switch.asm can restore it
    mov  [rm_sp_save], sp

    lgdt [gdt_descriptor]

    mov  eax, cr0
    or   eax, 1
    mov  cr0, eax

    jmp  0x08:pm_entry      ; far jump flushes prefetch, loads CS=0x08

; ---- KBC helper routines (local to boot_to_pm) ----
.kbc_flush:                 ; wait for KBC input buffer empty (bit 1 of status)
    in   al, 0x64
    test al, 0x02
    jnz  .kbc_flush
    ret
.kbc_read_ready:            ; wait for KBC output buffer full (bit 0 of status)
    in   al, 0x64
    test al, 0x01
    jz   .kbc_read_ready
    ret

; -
; Syscall trampoline - must land at offset 0x100 from ORG 0x8000 = 0x8100
; Pad from here up to offset 0x100
; -
times 0x100 - ($ - $$) db 0x90
syscall_entry:
    jmp  syscall_handler

; -
; 16-bit components  [BITS 16]
; -
%include "core/screen.asm"
%include "core/string.asm"
%include "core/keyboard.asm"
%include "core/utils.asm"
%include "core/vbe.asm"
%include "core/syscall.asm"
%include "core/mode_switch.asm"
%include "drivers/rm_drivers.asm"
%include "shell/shell.asm"
%include "commands/cmd_basic.asm"
%include "commands/cmd_system.asm"
%include "commands/cmd_tools.asm"
%include "commands/cmd_fun.asm"
%include "commands/cmd_fs.asm"
%include "commands/data.asm"

; -
; boot_menu - arrow-key selection boot menu
;
; UP/DOWN move highlight bar, Enter confirms, 1/2 still work as shortcuts.
; Selected row renders bright white on blue (shell_attr=0x30).
; Normal row renders with black background (shell_attr=0x00).
;
; Screen layout rows (0-based):
;   15 = option 1 row    (mnu_sel_row_1)
;   17 = option 2 row    (mnu_sel_row_2)
; -
mnu_sel_row_1  equ 15
mnu_sel_row_2  equ 17

boot_menu:
    call screen_clear
    mov  byte [shell_attr], 0x00

    mov  si, str_banner
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_top
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_title
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_sub_a
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_sub_b
    mov  bl, 0x03
    call puts_c
    mov  si, str_mnu_sub_c
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_sep
    mov  bl, ATTR_CYAN
    call puts_c

    ; blank + opt1 placeholder + blank + opt2 placeholder + blank
    mov  si, str_mnu_blank
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_blank
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_blank
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_blank
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_blank
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_sep
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_hint_a
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_hint_b
    mov  bl, ATTR_NORMAL
    call puts_c
    mov  si, str_mnu_hint_c
    mov  bl, ATTR_CYAN
    call puts_c

    mov  si, str_mnu_bot
    mov  bl, ATTR_CYAN
    call puts_c

    ; initial selection = option 1
    mov  byte [mnu_sel], 0
    call mnu_draw_opt1
    call mnu_draw_opt2

    ; hide hardware cursor
    mov  ah, 0x01
    mov  cx, 0x2000
    int  0x10

.key_loop:
    xor  ah, ah
    int  0x16               ; AL=ascii AH=scancode

    cmp  al, 13             ; Enter = confirm
    je   .confirm
    cmp  al, '1'
    je   .pick1
    cmp  al, '2'
    je   .pick2
    test al, al             ; extended key prefix?
    jnz  .key_loop
    cmp  ah, 0x48           ; up arrow
    je   .move_up
    cmp  ah, 0x50           ; down arrow
    je   .move_down
    jmp  .key_loop

.move_up:
    cmp  byte [mnu_sel], 0
    je   .key_loop
    mov  byte [mnu_sel], 0
    call mnu_draw_opt1
    call mnu_draw_opt2
    jmp  .key_loop

.move_down:
    cmp  byte [mnu_sel], 1
    je   .key_loop
    mov  byte [mnu_sel], 1
    call mnu_draw_opt1
    call mnu_draw_opt2
    jmp  .key_loop

.pick1:
    mov  byte [mnu_sel], 0
    call mnu_draw_opt1
    call mnu_draw_opt2
    jmp  .confirm

.pick2:
    mov  byte [mnu_sel], 1
    call mnu_draw_opt1
    call mnu_draw_opt2
    jmp  .confirm

.confirm:
    mov  ah, 0x01           ; restore cursor
    mov  cx, 0x0607
    int  0x10
    mov  byte [shell_attr], ATTR_BRIGHT
    cmp  byte [mnu_sel], 0
    je   .go_pm
    jmp  .go_rm

.go_pm:
    mov  byte [shell_attr], 0x00
    mov  ah, 0x02
    xor  bh, bh
    xor  dx, dx
    int  0x10
    call screen_clear
    mov  byte [shell_attr], ATTR_BRIGHT
    mov  si, str_booting_pm
    mov  bl, ATTR_CYAN
    call puts_c
    call nl
    call vbe_init
    call boot_to_pm
    cli
    hlt

.go_rm:
    ; reset shell_attr and cursor to top-left before clearing
    ; so screen_clear fills black, not blue
    mov  byte [shell_attr], 0x00
    mov  ah, 0x02
    xor  bh, bh
    xor  dx, dx
    int  0x10
    call screen_clear
    mov  byte [shell_attr], ATTR_BRIGHT
    mov  si, str_booting_rm
    mov  bl, ATTR_GREEN
    call puts_c
    call nl
    mov  si, str_banner
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_motd
    mov  bl, ATTR_NORMAL
    call puts_c
    jmp  rm_shell_loop      ; explicit jump - helpers sit between here and the loop

; -
; mnu_draw_opt1 / mnu_draw_opt2 - redraw one option row in-place
; Selected = blue bg (shell_attr 0x30), bright white text
; Normal   = black bg (shell_attr 0x00), yellow key + white desc
; -
mnu_draw_opt1:
    push ax
    push bx
    push dx
    mov  ah, 0x02
    xor  bh, bh
    mov  dh, mnu_sel_row_1
    xor  dl, dl
    int  0x10
    cmp  byte [mnu_sel], 0
    jne  .normal1
    ; selected: border+gap black, arrow+desc on blue bg
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_border
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_gap
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  byte [shell_attr], 0x30
    mov  si, str_mnu_arrow_on
    mov  bl, 0x0F
    call puts_c
    mov  si, str_mnu_o1desc
    mov  bl, 0x0F
    call puts_c
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_opt_r
    mov  bl, ATTR_CYAN
    call puts_c
    jmp  .done1
.normal1:
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_border
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_gap
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_arrow_off
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_o1desc
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_opt_r
    mov  bl, ATTR_CYAN
    call puts_c
.done1:
    mov  byte [shell_attr], 0x00
    pop  dx
    pop  bx
    pop  ax
    ret

mnu_draw_opt2:
    push ax
    push bx
    push dx
    mov  ah, 0x02
    xor  bh, bh
    mov  dh, mnu_sel_row_2
    xor  dl, dl
    int  0x10
    cmp  byte [mnu_sel], 1
    jne  .normal2
    ; selected: border+gap black, arrow+desc on blue bg
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_border
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_gap
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  byte [shell_attr], 0x30
    mov  si, str_mnu_arrow_on
    mov  bl, 0x0F
    call puts_c
    mov  si, str_mnu_o2desc
    mov  bl, 0x0F
    call puts_c
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_opt_r
    mov  bl, ATTR_CYAN
    call puts_c
    jmp  .done2
.normal2:
    mov  byte [shell_attr], 0x00
    mov  si, str_mnu_border
    mov  bl, ATTR_CYAN
    call puts_c
    mov  si, str_mnu_gap
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_arrow_off
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_o2desc
    mov  bl, ATTR_BRIGHT
    call puts_c
    mov  si, str_mnu_opt_r
    mov  bl, ATTR_CYAN
    call puts_c
.done2:
    mov  byte [shell_attr], 0x00
    pop  dx
    pop  bx
    pop  ax
    ret

mnu_sel:  db 0

; -
; rm_shell_loop - real-mode interactive shell
; pm_exit jumps directly here (skipping the boot menu).
; -
rm_shell_loop:
    call shell_prompt
    call shell_readline
    call shell_exec
    jmp  rm_shell_loop

; -
; Boot menu strings  (CP437 double-line box, width=56)
; ╔═54═╗  ║  ╠═╣  ╚═╝   ► = 0x10   • = 0x07
; -

; ╔══════════════════════════════════════════════════════╗
str_mnu_top:
    db 13, 10
    db 201, 205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205, 187, 13, 10, 0

; ║══════ NatureOS Boot Menu ══════║
str_mnu_title:
    db 186, 205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205
    db ' NatureOS Boot Menu '
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205, 186, 13, 10, 0

; ║ (subtitle border - cyan)
str_mnu_sub_a:
    db 186, '            ', 0
; NatureOS v2.0  •  Build 2.0.0  (dark cyan)
str_mnu_sub_b:
    db 'NatureOS v2.0  ', 7, '  Build 2.0.0  ', 0
; closing spaces + ║
str_mnu_sub_c:
    db '           ', 186, 13, 10, 0

; ╠══════════════════════════════════════════════════════╣
str_mnu_sep:
    db 204, 205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205, 185, 13, 10, 0

; ║                                                      ║
str_mnu_blank:
    db 186, '                                                      ', 186, 13, 10, 0

; ║  (border char alone, always black bg)
str_mnu_border:
    db 186, 0
; two spaces printed on highlight bg for selected row
str_mnu_gap:
    db ' ', 0

; ►  selected arrow (yellow) / unselected space
str_mnu_arrow_on:
    db 16, ' ', 0      ; '► '
str_mnu_arrow_off:
    db ' ', ' ', 0     ; '  '

; Graphical desktop  - WM, mouse, network  (description, 48 chars)
str_mnu_o1desc:
    db 'Graphical desktop   - WM, mouse, network          ', 0

; Text-mode shell    - BIOS, FS, apps      (description, 48 chars)
str_mnu_o2desc:
    db 'Text-mode shell     - BIOS, FS, apps              ', 0

;   ║\r\n  (right side of option row - cyan)
str_mnu_opt_r:
    db ' ', 186, 13, 10, 0

; ║           (hint row left border - cyan)
str_mnu_hint_a:
    db 186, '           ', 0
; Use arrows or 1/2.  Enter = confirm.  (hint text - normal grey)
str_mnu_hint_b:
    db 'arrows/1/2 select.  Enter = boot  ', 0
; closing spaces + ║ (cyan)
str_mnu_hint_c:
    db '         ', 186, 13, 10, 0

; ╚══════════════════════════════════════════════════════╝
str_mnu_bot:
    db 200, 205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205, 188, 13, 10, 0
str_booting_pm:
    db ' Booting Protected Mode desktop...', 0
str_booting_rm:
    db ' Booting Real-Mode shell...', 0

; -
; 32-bit components  [BITS 32]  (included last - never reached by 16-bit flow)
; -
%include "pm/pm_shell.asm"
%include "pm/gfx.asm"
%include "pm/font.asm"
%include "pm/irq.asm"
%include "pm/bios_disk.asm"
%include "pm/fs_data.asm"
%include "pm/wm_screenshot.asm"
