; ===========================================================================
; pm/pm_keyboard.asm - 32-bit PS/2 keyboard driver
;
; No BIOS. Polls port 0x64 (status) and reads port 0x60 (data).
; Translates scan codes to ASCII via pm_scancode_table.
; Handles two shift keys for uppercase/symbols.
;
; Public interface:
;   pm_getkey   → AL = ASCII (0 = ignore/non-printable)
;   pm_readline → reads line into pm_input_buf, sets pm_input_len
; ===========================================================================

[BITS 32]

; ---------------------------------------------------------------------------
; pm_getkey - NON-BLOCKING key check. Returns AL=0 if no key ready.
; Only reads keyboard (not mouse) data. Returns 0xFF for PrtSc.
; ---------------------------------------------------------------------------
pm_getkey:
    push ebx
    ; Check if keyboard data is available (bit 0 set, bit 5 clear = keyboard)
    in   al, 0x64
    test al, 0x01
    jz   .no_key             ; nothing in buffer
    test al, 0x20
    jnz  .no_key             ; it's mouse data, not keyboard
    in   al, 0x60            ; read scan code

    ; E0 extended prefix
    cmp  al, 0xE0
    jne  .not_e0
    mov  byte [pm_e0], 1
    xor  al, al              ; return 0, caller will poll again next tick
    pop  ebx
    ret

.not_e0:
    cmp  byte [pm_e0], 1
    jne  .normal
    mov  byte [pm_e0], 0

    cmp  al, 0x2A            ; fake shift from PrtSc press — ignore
    je   .no_key
    cmp  al, 0xAA            ; fake shift release — ignore
    je   .no_key
    cmp  al, 0xB7            ; PrtSc release — ignore
    je   .no_key
    cmp  al, 0x37            ; PrtSc press — signal
    jne  .no_key
    mov  al, 0xFF
    pop  ebx
    ret

.normal:
    cmp  al, 0x2A
    je   .shift_on
    cmp  al, 0x36
    je   .shift_on
    cmp  al, 0xAA
    je   .shift_off
    cmp  al, 0xB6
    je   .shift_off

    test al, 0x80            ; key release — ignore
    jnz  .no_key

    movzx ebx, al
    cmp  ebx, 58
    jae  .no_key

    cmp  byte [pm_shift], 0
    jne  .shifted
    mov  al, [pm_scancode_table + ebx]
    jmp  .done
.shifted:
    mov  al, [pm_scancode_shift + ebx]

.done:
    pop  ebx
    ret

.shift_on:
    mov  byte [pm_shift], 1
.no_key:
    xor  al, al
    pop  ebx
    ret
.shift_off:
    mov  byte [pm_shift], 0
    xor  al, al
    pop  ebx
    ret

; ---------------------------------------------------------------------------
; pm_getkey_block - BLOCKING version (used by text-mode shell only)
; ---------------------------------------------------------------------------
pm_getkey_block:
    push ebx
.wait:
    call pm_getkey
    test al, al
    jz   .wait
    pop  ebx
    ret

; ---------------------------------------------------------------------------
; pm_readline - read line from keyboard into pm_input_buf
; Result: pm_input_buf = null-terminated string, pm_input_len = length
; ---------------------------------------------------------------------------
pm_readline:
    push eax
    push edi

    mov  edi, pm_input_buf
    mov  dword [pm_input_len], 0

.loop:
    call pm_getkey_block
    or   al, al
    jz   .loop

    cmp  al, 13              ; Enter
    je   .enter
    cmp  al, 8               ; Backspace
    je   .bs

    cmp  dword [pm_input_len], 127
    jge  .loop

    mov  [edi], al
    inc  edi
    inc  dword [pm_input_len]
    mov  bl, 0x0F
    call pm_putc
    jmp  .loop

.bs:
    cmp  dword [pm_input_len], 0
    je   .loop
    dec  edi
    mov  byte [edi], 0
    dec  dword [pm_input_len]
    dec  dword [pm_cursor_x]
    push eax
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    dec  dword [pm_cursor_x]
    call pm_update_cursor
    pop  eax
    jmp  .loop

.enter:
    mov  byte [edi], 0
    call pm_newline
    call pm_update_cursor
    pop  edi
    pop  eax
    ret