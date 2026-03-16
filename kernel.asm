; ===========================================================================
; kernel.asm - ClaudeOS Kernel v2.0
;
; Entry point only. Components are %included in two sections:
;
;   16-bit real mode (BIOS-based)
;   ├── core/        hardware abstractions (screen, keyboard, string, utils)
;   ├── drivers/     real-mode driver registry (screen, kbd, rtc, speaker)
;   ├── shell/       prompt, readline, command dispatcher
;   └── commands/    built-in commands + all string data
;
;   32-bit protected mode (no BIOS)
;   └── pm/          PM shell, VGA/kbd/PIT drivers, PM driver registry
;
; Boot flow:
;   kernel_main → drv_rm_init → real-mode shell
;   "pm" command → drv_rm_shutdown → [switch] → pm_drv_init → PM shell
;   "exit" in PM → pm_drv_shutdown → [switch] → drv_rm_init → real-mode shell
;
; Assemble: nasm -f bin -o kernel.bin kernel.asm
; ===========================================================================

[BITS 16]
[ORG 0x8000]

; ---------------------------------------------------------------------------
; Constants (available to all included files)
; ---------------------------------------------------------------------------
ATTR_NORMAL   equ 0x07
ATTR_BRIGHT   equ 0x0F
ATTR_GREEN    equ 0x0A
ATTR_YELLOW   equ 0x0E
ATTR_CYAN     equ 0x0B
ATTR_RED      equ 0x0C
ATTR_MAGENTA  equ 0x0D

FORTUNE_COUNT equ 10

; ---------------------------------------------------------------------------
; Kernel entry point
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

    ; Probe and set VESA framebuffer (must happen in real mode)
    call vbe_init

    ; Boot straight to PM — no RM shell
    call boot_to_pm

    ; Should never return, but halt just in case
    cli
    hlt

; ---------------------------------------------------------------------------
; boot_to_pm
; Switches to 32-bit protected mode unconditionally.
; Mirrors cmd_pm in cmd_system.asm but without the user prompt.
; ---------------------------------------------------------------------------
boot_to_pm:
    ; Enable A20 line
    mov  ah, 0x86
    mov  cx, 0x0007
    mov  dx, 0xA120
    int  0x15

    in   al, 0x92
    or   al, 0x02
    and  al, 0xFE
    out  0x92, al

    cli

    ; Save real-mode stack pointer so pm_exit can restore it
    mov  [rm_sp_save], sp

    lgdt [gdt_descriptor]

    mov  eax, cr0
    or   eax, 1
    mov  cr0, eax

    jmp  0x08:pm_entry      ; far jump flushes prefetch, loads CS=0x08

; ---------------------------------------------------------------------------
; Syscall trampoline — must land at offset 0x100 from ORG 0x8000 = 0x8100
; Pad from here (after kernel_main's ~30 bytes) up to offset 0x100
; ---------------------------------------------------------------------------
times 0x100 - ($ - $$) db 0x90
syscall_entry:
    jmp  syscall_handler

; ---------------------------------------------------------------------------
; 16-bit components  [BITS 16]
; ---------------------------------------------------------------------------
%include "core/screen.asm"
%include "core/string.asm"
%include "core/keyboard.asm"
%include "core/utils.asm"
%include "core/vbe.asm"
%include "core/syscall.asm"
%include "drivers/rm_drivers.asm"
%include "shell/shell.asm"
%include "commands/cmd_basic.asm"
%include "commands/cmd_system.asm"
%include "commands/cmd_tools.asm"
%include "commands/cmd_fun.asm"
%include "commands/cmd_fs.asm"
%include "commands/data.asm"

; ---------------------------------------------------------------------------
; 32-bit components  [BITS 32]  (included last — never reached by 16-bit flow)
; ---------------------------------------------------------------------------
%include "pm/pm_shell.asm"
%include "pm/gfx.asm"
%include "pm/font.asm"
%include "pm/irq.asm"
%include "pm/bios_disk.asm"
%include "pm/fs_data.asm"
%include "pm/wm_screenshot.asm"