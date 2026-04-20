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
mnu_sel_row_1  equ 12
mnu_sel_row_2  equ 13

boot_menu:
    call screen_clear
    mov  byte [shell_attr], 0x00

    mov  si, str_banner
    mov  bl, 0x0B           ; Cyan
    call puts_c

    ; Start of box (Row 8)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 8              ; Box Top Row
    mov  dl, 14
    int  0x10
    mov  byte [shell_attr], 0x1F ; White on Blue
    mov  si, str_mnu_top
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c
    mov  byte [shell_attr], 0x00 ; Reset for shadow
    call .shad_spc          ; Alignment space (no shad on row 1)

    ; Row 9 (Title)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 9
    mov  dl, 14
    int  0x10
    mov  byte [shell_attr], 0x1F ; Enforce Blue BG for this row
    mov  si, str_mnu_border_l
    mov  bl, 0x1B           ; Cyan on Blue
    call puts_c
    mov  si, str_mnu_title
    mov  bl, 0x1F           ; White on Blue
    call puts_c
    mov  si, str_mnu_border_r
    mov  bl, 0x1B
    call puts_c
    mov  byte [shell_attr], 0x00
    call .shad              ; Shadow pixel

    ; Row 10 (Sub)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 10
    mov  dl, 14
    int  0x10
    mov  byte [shell_attr], 0x1F
    mov  si, str_mnu_border_l
    mov  bl, 0x1B
    call puts_c
    mov  si, str_mnu_sub
    mov  bl, 0x1F
    call puts_c
    mov  si, str_mnu_border_r
    mov  bl, 0x1B
    call puts_c
    mov  byte [shell_attr], 0x00
    call .shad

    ; Row 11 (Separator)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 11
    mov  dl, 14
    int  0x10
    mov  byte [shell_attr], 0x1F
    mov  si, str_mnu_sep
    mov  bl, 0x1B
    call puts_c
    mov  byte [shell_attr], 0x00
    call .shad

    ; Capture Row 12 (Option 1)
    mov  byte [mnu_row_base], 12

    ; Initial selection draw
    mov  byte [mnu_sel], 0
    call mnu_draw_opt1
    call mnu_draw_opt2
    call mnu_draw_opt3

    ; Row 14 (Option 3)
    call mnu_draw_opt3

    ; Row 15 (Bottom Border)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 15             ; mnu_row_base + 3
    mov  dl, 14
    int  0x10
    mov  byte [shell_attr], 0x1F
    mov  si, str_mnu_bot_main
    mov  bl, 0x1B
    call puts_c
    mov  byte [shell_attr], 0x00
    call .shad

    ; Row 16 (Shadow Bar)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 16             ; Shadow bar row
    mov  dl, 15             ; indent 15
    int  0x10
    mov  si, str_mnu_shadow_bot
    mov  bl, 0x08           ; Dark grey shadow
    call puts_c

    ; Row 23 (Centered Instructions, avoiding BIOS scroll trigger at 24)
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 23             ; Row 23
    mov  dl, 24             ; Indent to center (80-32)/2
    int  0x10
    mov  si, str_mnu_hint
    mov  bl, 0x0E           ; Yellow hint
    call puts_c

    ; initial selection = option 1
    mov  byte [mnu_sel], 0
    call mnu_draw_opt1
    call mnu_draw_opt2
    call mnu_draw_opt3
    jmp  .cursor_hide_only

.shad:
    pusha
    mov  ah, 0x09
    mov  al, 219            ; Solid block
    mov  bh, 0
    mov  bl, 0x08           ; Dark grey shadow
    mov  cx, 2              ; TWO characters wide
    int  0x10
    call nl
    popa
    ret

.shad_spc:
    pusha
    mov  ah, 0x0E
    mov  al, ' '            ; Dummy space for alignment
    int  0x10
    call nl
    popa
    ret

.cursor_hide_only:
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
    cmp  al, '3'
    je   .pick3
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
    dec  byte [mnu_sel]
    call mnu_draw_opt1
    call mnu_draw_opt2
    call mnu_draw_opt3
    jmp  .key_loop

.move_down:
    cmp  byte [mnu_sel], 2
    je   .key_loop
    inc  byte [mnu_sel]
    call mnu_draw_opt1
    call mnu_draw_opt2
    call mnu_draw_opt3
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
    cmp  byte [mnu_sel], 0
    je   .go_pm
    cmp  byte [mnu_sel], 1
    je   .go_rm
    jmp  .go_memtest

.pick3:
    mov  byte [mnu_sel], 2
    call mnu_draw_opt1
    call mnu_draw_opt2
    call mnu_draw_opt3
    jmp  .confirm

.go_memtest:
    mov  byte [mt_active], 1     ; Suppress serial output
    mov  byte [shell_attr], 0x1F ; Blue BG
    call screen_clear
    call mem_tester
    mov  byte [mt_active], 0     ; Re-enable serial
    mov  byte [shell_attr], 0x00 ; Reset to Black BG for boot menu
    jmp  boot_menu

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
    pusha
    mov  ah, 0x02           ; set cursor
    mov  bh, 0
    mov  dh, [mnu_row_base]
    mov  dl, 14             ; Start at Column 14
    int  0x10
    mov  byte [shell_attr], 0x1F ; Enforce Blue BG for this row

    mov  si, str_mnu_border_l
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c

    cmp  byte [mnu_sel], 0
    jne  .normal1
    ; Selected
    mov  byte [shell_attr], 0x1F ; White on Blue
    mov  si, str_mnu_arrow_on
    call puts
    mov  si, str_mnu_o1desc
    call puts
    jmp  .border1
.normal1:
    mov  byte [shell_attr], 0x10 ; Blue bg
    mov  si, str_mnu_arrow_off
    call puts
    mov  si, str_mnu_o1desc
    mov  bl, 0x17           ; Silver on Blue
    call puts_c

.border1:
    mov  byte [shell_attr], 0x10 ; Maintain Blue bg before border
    mov  si, str_mnu_border_r
    mov  bl, 0x1B
    call puts_c

    ; Shadow (Two chars wide)
    mov  byte [shell_attr], 0x00 ; Reset for shadow!
    mov  ah, 0x09
    mov  al, 219
    mov  bh, 0
    mov  bl, 0x08
    mov  cx, 2
    int  0x10
    popa
    ret

mnu_draw_opt2:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, [mnu_row_base]
    inc  dh
    mov  dl, 14             ; Column 14
    int  0x10
    mov  byte [shell_attr], 0x1F ; Enforce Blue BG for this row

    mov  si, str_mnu_border_l
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c

    cmp  byte [mnu_sel], 1
    jne  .normal2
    ; Selected
    mov  byte [shell_attr], 0x1F ; White on Blue
    mov  si, str_mnu_arrow_on
    call puts
    mov  si, str_mnu_o2desc
    call puts
    jmp  .border2
.normal2:
    mov  byte [shell_attr], 0x10 ; Blue bg
    mov  si, str_mnu_arrow_off
    call puts
    mov  si, str_mnu_o2desc
    mov  bl, 0x17           ; Silver on Blue
    call puts_c

.border2:
    mov  byte [shell_attr], 0x10 ; Maintain Blue bg before border
    mov  si, str_mnu_border_r
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c

    ; Shadow (Two chars wide)
    mov  byte [shell_attr], 0x00 ; Reset for shadow!
    mov  ah, 0x09
    mov  al, 219
    mov  bh, 0
    mov  bl, 0x08
    mov  cx, 2
    int  0x10
    popa
    ret

mnu_draw_opt3:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, [mnu_row_base]
    add  dh, 2              ; Row 14
    mov  dl, 14             ; Column 14
    int  0x10
    mov  byte [shell_attr], 0x1F ; Enforce Blue BG for this row

    mov  si, str_mnu_border_l
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c

    cmp  byte [mnu_sel], 2
    jne  .normal3
    ; Selected
    mov  byte [shell_attr], 0x1F ; White on Blue
    mov  si, str_mnu_arrow_on
    call puts
    mov  si, str_mnu_o3desc
    call puts
    jmp  .border3
.normal3:
    mov  byte [shell_attr], 0x10 ; Blue bg
    mov  si, str_mnu_arrow_off
    call puts
    mov  si, str_mnu_o3desc
    mov  bl, 0x17           ; Silver on Blue
    call puts_c

.border3:
    mov  byte [shell_attr], 0x10 ; Maintain Blue bg before border
    mov  si, str_mnu_border_r
    mov  bl, 0x1B           ; Bright Cyan on Blue
    call puts_c

    ; Shadow (Two chars wide)
    mov  byte [shell_attr], 0x00 ; Reset for shadow!
    mov  ah, 0x09
    mov  al, 219
    mov  bh, 0
    mov  bl, 0x08
    mov  cx, 2
    int  0x10
    popa
    ret

; -

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

str_booting_pm:
    db ' Booting Protected Mode desktop...', 0
str_booting_rm:
    db ' Booting Real-Mode shell...', 0

; -
; Memory Tester (Memtest86 style)
; -
mem_tester:
    pusha
    call unreal_init
    call .detect_ram
    mov  word [mt_errors], 0
    mov  word [mt_pass], 0
    mov  ah, 0x01
    mov  cx, 0x2000
    int  0x10
    call .draw_mt_ui
    
.main_loop:
    inc  word [mt_pass]
    call .update_pass_ui
    
    ; Test 0: Address - Walking 1s
    mov  word [mt_test_id], 0
    call .update_test_ui
    call .run_walking_bit
    jc   .quit
    
    ; Test 1: Address - Own Address
    mov  word [mt_test_id], 1
    call .update_test_ui
    call .run_address_test
    jc   .quit
    
    ; Test 2: MI - Ones & Zeros
    mov  word [mt_test_id], 2
    call .update_test_ui
    mov  dword [mt_cur_pattern], 0x00000000
    call .run_moving_inv
    jc   .quit
    mov  dword [mt_cur_pattern], 0xFFFFFFFF
    call .run_moving_inv
    jc   .quit

    ; Test 3: MI - 8-bit Pattern
    mov  word [mt_test_id], 3
    call .update_test_ui
    mov  dword [mt_cur_pattern], 0x55555555
    call .run_moving_inv
    jc   .quit
    mov  dword [mt_cur_pattern], 0xAAAAAAAA
    call .run_moving_inv
    jc   .quit
    
    ; Test 4: MI - Random Pattern
    mov  word [mt_test_id], 4
    call .update_test_ui
    call .run_random_inv
    jc   .quit
    
    ; Test 5: Block Move
    mov  word [mt_test_id], 5
    call .update_test_ui
    call .run_block_move
    jc   .quit
    
    ; Test 6: Random Sequence
    mov  word [mt_test_id], 6
    call .update_test_ui
    call .run_random_seq
    jc   .quit
    
    jmp  .main_loop

.quit:
    mov  ah, 0x01           ; Restore cursor
    mov  cx, 0x0607
    int  0x10
    popa
    ret

; - Test Hubs -

.run_address_test:
    mov  edi, 0x00100000
.at_loop:
    mov  [mt_cur_addr], edi
    test edi, 0xFFFFFF      ; Update UI every 16MB
    jnz  .at_no_ui
    call .update_addr_ui
    call .check_esc
    jc   .at_quit
.at_no_ui:
    mov  [ds:edi], edi
    cmp  [ds:edi], edi
    je   .at_ok
    inc  word [mt_errors]
    call .update_error_ui
.at_ok:
    add  edi, 4
    cmp  edi, [mt_ram_size]
    jl   .at_loop
    clc
    ret
.at_quit:
    stc
    ret

.run_moving_inv:
    call .update_pattern_ui
    mov  edi, 0x00100000
    mov  eax, [mt_cur_pattern]
.mi_loop:
    mov  [mt_cur_addr], edi
    test edi, 0xFFFFFF      ; Update UI every 16MB
    jnz  .mi_no_ui
    call .update_addr_ui
    call .check_esc
    jc   .mi_quit
.mi_no_ui:
    mov  [ds:edi], eax
    cmp  [ds:edi], eax
    je   .mi_ok
    inc  word [mt_errors]
    call .update_error_ui
.mi_ok:
    add  edi, 4
    cmp  edi, [mt_ram_size]
    jl   .mi_loop
    clc
    ret
.mi_quit:
    stc
    ret

.run_random_inv:
    call .random_next
    mov  [mt_cur_pattern], eax
    call .update_pattern_ui
    call .run_moving_inv
    ret

.run_random_seq:
    mov  edi, 0x00100000
.rs_loop:
    mov  [mt_cur_addr], edi
    test edi, 0xFFFFFF      ; Update UI every 16MB
    jnz  .rs_no_ui
    call .update_addr_ui
    call .check_esc
    jc   .rs_quit
.rs_no_ui:
    call .random_next
    mov  [ds:edi], eax
    cmp  [ds:edi], eax
    je   .rs_ok
    inc  word [mt_errors]
    call .update_error_ui
.rs_ok:
    add  edi, 4
    cmp  edi, [mt_ram_size]
    jl   .rs_loop
    clc
    ret
.rs_quit:
    stc
    ret

.run_block_move:
    ; Pattern fill 0x55
    mov  dword [mt_cur_pattern], 0x55555555
    call .run_moving_inv
    jc   .bm_quit
    
    ; Block move: move 1MB chunks to 2MB etc.
    mov  esi, 0x00100000
    mov  edi, 0x00200000
    mov  ecx, 0x00E00000 / 4 ; ~3.5MB roughly
    rep  movsd               ; Fast move
    
    clc
    ret
.bm_quit:
    stc
    ret

.random_next:
    mov  eax, [mt_seed]
    mov  edx, 1103515245
    mul  edx
    add  eax, 12345
    mov  [mt_seed], eax
    ret

.run_walking_bit:
    ; --- Phase 1: Walking Ones ---
    mov  eax, 1
.wb_ones:
    push eax
    mov  [mt_cur_pattern], eax
    call .update_pattern_ui
    call .run_wb_inner
    pop  eax
    jc   .wb_quit
    shl  eax, 1
    jnz  .wb_ones
    
    ; --- Phase 2: Walking Zeros ---
    mov  eax, 0xFFFFFFFE
.wb_zeros:
    push eax
    mov  [mt_cur_pattern], eax
    call .update_pattern_ui
    call .run_wb_inner
    pop  eax
    jc   .wb_quit
    rol  eax, 1
    cmp  eax, 0xFFFFFFFE
    jne  .wb_zeros
    
    clc
    ret
.wb_quit:
    stc
    ret

.run_wb_inner:
    mov  edi, 0x00100000
    mov  ebx, [mt_cur_pattern]
.wb_i_loop:
    mov  [mt_cur_addr], edi
    test edi, 0xFFFFFF      ; every 16MB
    jnz  .wb_i_no_ui
    call .update_addr_ui
    call .check_esc
    jc   .wb_i_quit
.wb_i_no_ui:
    mov  [ds:edi], ebx
    cmp  [ds:edi], ebx
    je   .wb_i_ok
    inc  word [mt_errors]
    call .update_error_ui
.wb_i_ok:
    add  edi, 4
    cmp  edi, [mt_ram_size]
    jl   .wb_i_loop
    clc
    ret
.wb_i_quit:
    stc
    ret

.check_esc:
    push ax
    mov  ah, 0x01
    int  0x16
    jz   .ce_no
    xor  ah, ah
    int  0x16
    cmp  al, 27
    je   .ce_quit
.ce_no:
    pop  ax
    clc
    ret
.ce_quit:
    pop  ax
    stc
    ret

.detect_ram:
    pusha
    
    ; Try BIOS E801h
    xor  cx, cx
    xor  dx, dx
    mov  ax, 0xE801
    int  0x15
    jc   .dr_cmos           ; Fallback to CMOS if carry set
    
    ; Returned:
    ; AX/CX = KB above 1MB, up to 16MB
    ; BX/DX = 64KB blocks above 16MB
    test ax, ax
    jnz  .use_ax
    mov  ax, cx
    mov  bx, dx
.use_ax:
    test ax, ax
    jz   .dr_cmos           ; Fail if both are zero
    
    ; EAX = AX * 1024
    movzx eax, ax
    shl  eax, 10
    ; EBX = BX * 64 * 1024
    movzx ebx, bx
    shl  ebx, 16
    
    add  eax, ebx
    add  eax, 0x00100000    ; Add the 1MB base
    mov  [mt_ram_size], eax
    jmp  .dr_done

.dr_cmos:
    ; Fallback to CMOS
    mov  al, 0x34
    out  0x70, al
    in   al, 0x71
    movzx ecx, al
    mov  al, 0x35
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    shl  eax, 8
    or   eax, ecx
    
    test eax, eax
    jnz  .dr_cmos_high
    
    mov  al, 0x30
    out  0x70, al
    in   al, 0x71
    movzx ecx, al
    mov  al, 0x31
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    shl  eax, 8
    or   eax, ecx
    shl  eax, 10
    add  eax, 0x00100000
    mov  [mt_ram_size], eax
    jmp  .dr_done

.dr_cmos_high:
    shl  eax, 16                ; blocks * 64KB
    add  eax, 0x01000000        ; + 16MB base
    mov  [mt_ram_size], eax

.dr_done:
    popa
    ret

; - Serial Logging Helpers (Ignore mt_active) -

.serial_log:
    pusha
.sl_lp:
    lodsb
    or   al, al
    jz   .sl_dn
    mov  cl, al
.sl_wait:
    mov  dx, 0x3FD
    in   al, dx
    test al, 0x20
    jz   .sl_wait
    mov  dx, 0x3F8
    mov  al, cl
    out  dx, al
    jmp  .sl_lp
.sl_dn:
    popa
    ret

.serial_log_nl:
    push si
    mov  si, .nl_str
    call .serial_log
    pop  si
    ret
.nl_str: db 13, 10, 0

.serial_log_uint:
    pusha
    mov  cx, 0
    mov  bx, 10
.slu_div:
    xor  dx, dx
    div  bx
    push dx
    inc  cx
    test ax, ax
    jnz  .slu_div
.slu_pr:
    pop  ax
    add  al, '0'
    mov  byte [.tmp_c], al
    push si
    mov  si, .tmp_c
    call .serial_log
    pop  si
    loop .slu_pr
    popa
    ret
.tmp_c: db 0, 0

.update_pattern_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 4
    mov  dl, 25
    int  0x10
    mov  eax, [mt_cur_pattern]
    push eax
    shr  eax, 16
    mov  cl, al
    mov  al, ah
    mov  bl, 0x1F
    call print_hex_byte
    mov  al, cl
    call print_hex_byte
    pop  eax
    mov  cl, al
    mov  al, ah
    mov  bl, 0x1F
    call print_hex_byte
    mov  al, cl
    call print_hex_byte
    popa
    ret

.update_pass_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 2
    mov  dl, 5
    int  0x10
    mov  si, str_mt_title
    mov  bl, 0x1E           ; Yellow on Blue
    call puts_c
    mov  si, str_mt_pass_lbl
    call puts_c
    mov  ax, [mt_pass]
    call print_uint
    popa
    ret

.update_error_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 7
    mov  dl, 23
    int  0x10
    mov  ax, [mt_errors]
    call print_uint
    popa
    ret

.update_addr_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 5
    mov  dl, 25
    int  0x10
    mov  eax, [mt_cur_addr]
    shr  eax, 20             ; MB
    call print_uint
    mov  si, str_mt_mb
    call puts_c
    popa
    ret

.draw_mt_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 4
    mov  dl, 5
    int  0x10
    mov  si, str_mt_pattern
    mov  bl, 0x1F
    call puts_c
    mov  dh, 5
    int  0x10
    mov  si, str_mt_addr
    call puts_c
    mov  dh, 7
    int  0x10
    mov  si, str_mt_errors
    call puts_c
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 10
    int  0x10
    mov  si, str_mt_esc
    mov  bl, 0x1B
    call puts_c
    popa
    ret

.update_test_ui:
    pusha
    mov  ah, 0x02
    mov  bh, 0
    mov  dh, 2
    mov  dl, 35
    int  0x10
    mov  si, str_mt_test
    mov  bl, 0x1F
    call puts_c
    mov  ax, [mt_test_id]
    cmp  ax, 0
    je   .t0
    cmp  ax, 1
    je   .t1
    cmp  ax, 2
    je   .t2
    cmp  ax, 3
    je   .t3
    cmp  ax, 4
    je   .t4
    cmp  ax, 5
    je   .t5
    cmp  ax, 6
    je   .t6
    jmp  .ud_ret
.t0: mov si, str_mt_t0
     jmp .show
.t1: mov si, str_mt_t1
     jmp .show
.t2: mov si, str_mt_t2
     jmp .show
.t3: mov si, str_mt_t3
     jmp .show
.t4: mov si, str_mt_t4
     jmp .show
.t5: mov si, str_mt_t5
     jmp .show
.t6: mov si, str_mt_t6
.show:
    call puts_c
.ud_ret:
    popa
    ret


; -
; unreal_init - Enter Unreal Mode (4GB segment limits in Real Mode)
; -
unreal_init:
    pusha
    cli                     ; Disable interrupts
    push ds                 ; Save DS
    
    lgdt [gdt_descriptor]   ; Load GDT

    mov  eax, cr0
    or   al, 1              ; Enter PM
    mov  cr0, eax

    jmp  $+2                ; Flush prefetch
    
    mov  bx, 0x10           ; 4GB data selector (index 2 in GDT)
    mov  ds, bx
    mov  es, bx             ; Load hidden segment limits into registers
    
    mov  eax, cr0
    and  al, 0xFE           ; Back to RM
    mov  cr0, eax
    
    pop  ds                 ; Restore DS (segment limits remain 4GB!)
    mov  ax, ds
    mov  es, ax             ; Sync ES
    sti                     ; Re-enable interrupts
    popa
    ret

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
