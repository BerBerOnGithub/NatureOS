; ===========================================================================
; pm/pm_keyboard.asm - 32-bit PS/2 keyboard driver
;
; No BIOS. Polls port 0x64 (status) and reads port 0x60 (data).
; Translates scan codes to ASCII via pm_scancode_table.
; Handles two shift keys for uppercase/symbols.
;
; Public interface:
;   pm_getkey   +' AL = ASCII (0 = ignore/non-printable)
;   pm_readline +' reads line into pm_input_buf, sets pm_input_len
; ===========================================================================

[BITS 32]

; -
; pm_kb_poll - Drain ALL available keyboard data from 8042 hardware.
; If NOTHING is focused, keys are discarded. If SOMETHING is focused,
; keys are pushed into the RAM buffer (pm_kb_queue).
; -
pm_kb_poll:
    pusha

    ; check if ANY window is focused (bit +18 in wm_table entries)
    xor  ecx, ecx
.fchk:
    cmp  ecx, WM_MAX_WINS
    jge  .no_focus
    imul ebx, ecx, 32        ; WM_STRIDE
    cmp  byte [wm_table + ebx + 18], 1
    je   .focused_loop
    inc  ecx
    jmp  .fchk

.no_focus:
    ; nothing focused: clear RAM buffer and drain hardware
    mov  dword [pm_kb_q_head], 0
    mov  dword [pm_kb_q_tail], 0
.drain_loop:
    in   al, 0x64
    test al, 0x01
    jz   .done
    test al, 0x20
    jnz  .done
    in   al, 0x60            ; discard
    jmp  .drain_loop

.focused_loop:
    in   al, 0x64
    test al, 0x01
    jz   .done               ; nothing in hardware buffer
    test al, 0x20
    jnz  .done               ; it's mouse data, leave it for mouse_poll

    in   al, 0x60            ; read scan code from hardware

    ; push to ring buffer: [head] = al, head = (head + 1) % 32
    mov  ebx, [pm_kb_q_head]
    mov  ecx, ebx
    inc  ecx
    and  ecx, 31             ; modulo 32
    cmp  ecx, [pm_kb_q_tail] ; buffer full?
    je   .done               ; drop key if full

    mov  [pm_kb_queue + ebx], al
    mov  [pm_kb_q_head], ecx
    jmp  .focused_loop
.done:
    popa
    ret

; -
; pm_getkey - NON-BLOCKING key check. Returns AL=0 if no key ready.
; Now pulls from the RAM ring buffer (pm_kb_queue).
; -
pm_getkey:
    push ebx
    push ecx
.next_key:
    ; is buffer empty? (head == tail)
    mov  ebx, [pm_kb_q_tail]
    cmp  ebx, [pm_kb_q_head]
    je   .no_key

    ; pull from tail
    mov  al, [pm_kb_queue + ebx]
    inc  ebx
    and  ebx, 31
    mov  [pm_kb_q_tail], ebx

    ; E0 extended prefix
    cmp  al, 0xE0
    jne  .not_e0
    mov  byte [pm_e0], 1
    jmp  .next_key

.not_e0:
    cmp  byte [pm_e0], 1
    jne  .normal
    mov  byte [pm_e0], 0

    cmp  al, 0x2A            ; fake shift from PrtSc press " ignore
    je   .next_key
    cmp  al, 0xAA            ; fake shift release " ignore
    je   .next_key
    cmp  al, 0xB7            ; PrtSc release " ignore
    je   .next_key
    cmp  al, 0x35            ; numpad /  (E0 prefix)
    jne  .not_numdiv
    mov  al, '/'
    pop  ecx
    pop  ebx
    ret
.not_numdiv:
    cmp  al, 0x37            ; PrtSc press -- signal
    je   .prtsc
    cmp  al, 0x48            ; Up
    jne  .not_up
    mov  al, 0x80
    jmp  .done
.not_up:
    cmp  al, 0x50            ; Down
    jne  .next_key
    mov  al, 0x81
    jmp  .done
.prtsc:
    mov  al, 0xFF
    pop  ecx
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

    ; Ctrl / Alt modifier keys - absorb without producing a character
    cmp  al, 0x1D            ; Ctrl make
    je   .next_key
    cmp  al, 0x9D            ; Ctrl release
    je   .next_key
    cmp  al, 0x38            ; Alt make
    je   .next_key
    cmp  al, 0xB8            ; Alt release
    je   .next_key

    test al, 0x80            ; key release - ignore
    jnz  .next_key

    movzx ebx, al            ; EBX = scancode
    push ebx
    cmp  ebx, 84             ; scan code limit
    jae  .no_ascii
    
    cmp  byte [pm_shift], 0
    jne  .shifted
    mov  al, [pm_scancode_table + ebx]
    jmp  .got_ascii
.shifted:
    mov  al, [pm_scancode_shift + ebx]
    jmp  .got_ascii

.no_ascii:
    xor  al, al

.got_ascii:
    pop  ebx
    mov  ah, bl              ; AH = scancode
    jmp  .done

.done:
    pop  ecx
    pop  ebx
    ret

.shift_on:
    mov  byte [pm_shift], 1
    jmp  .next_key
.no_key:
    xor  eax, eax            ; AX = 0 means no key
    pop  ecx
    pop  ebx
    ret
.shift_off:
    mov  byte [pm_shift], 0
    jmp  .next_key

; -
; pm_getkey_block - BLOCKING version (used by text-mode shell only)
; -
pm_getkey_block:
    push ebx
.wait:
    call pm_getkey
    test al, al
    jz   .wait
    pop  ebx
    ret

; -
; pm_readline - read line from keyboard into pm_input_buf
; Result: pm_input_buf = null-terminated string, pm_input_len = length
; -
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
    cmp  al, 0x80            ; UP arrow
    je   .up
    cmp  al, 0x81            ; DOWN arrow
    je   .down

    cmp  dword [pm_input_len], 127
    jge  .loop

    ; if we were browsing history, we now commit to this line as a "new" line
    mov  byte [pm_hist_active], 0
    
    mov  [edi], al
    inc  edi
    inc  dword [pm_input_len]
    mov  bl, 0x0F
    call pm_putc
    jmp  .loop

.up:
    call pm_hist_up
    jc   .loop
    
    call .clear_line
    
    ; copy from history[view] to input_buf
    pusha
    mov  eax, [pm_hist_view]
    imul eax, PM_HIST_LEN
    add  eax, pm_hist_buffer
    mov  esi, eax
    mov  edi, pm_input_buf
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa
    
    ; update length and edi
    mov  esi, pm_input_buf
    call pm_strlen
    mov  [pm_input_len], eax
    mov  edi, pm_input_buf
    add  edi, eax
    
    ; print the line
    mov  esi, pm_input_buf
    mov  bl, 0x0F
    call pm_puts
    call pm_update_cursor
    jmp  .loop

.down:
    call pm_hist_down
    jc   .loop
    
    call .clear_line
    
    cmp  byte [pm_hist_active], 0
    je   .at_bottom_restore
    
    ; copy from history[view]
    pusha
    mov  eax, [pm_hist_view]
    imul eax, PM_HIST_LEN
    add  eax, pm_hist_buffer
    mov  esi, eax
    mov  edi, pm_input_buf
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa
    jmp  .down_done

.at_bottom_restore:
    ; restore from temp
    pusha
    mov  esi, pm_hist_temp
    mov  edi, pm_input_buf
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa

.down_done:
    mov  esi, pm_input_buf
    call pm_strlen
    mov  [pm_input_len], eax
    mov  edi, pm_input_buf
    add  edi, eax
    
    mov  esi, pm_input_buf
    mov  bl, 0x0F
    call pm_puts
    call pm_update_cursor
    jmp  .loop

.clear_line:
    pusha
    ; move cursor back by pm_input_len
    mov  ecx, [pm_input_len]
    test ecx, ecx
    jz   .cl_done
.cl_lp:
    dec  dword [pm_cursor_x]
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    dec  dword [pm_cursor_x]
    loop .cl_lp
    call pm_update_cursor
.cl_done:
    popa
    ret

.bs:
    cmp  dword [pm_input_len], 0
    je   .loop
    mov  byte [pm_hist_active], 0    ; typing now
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
    
    ; save to history
    mov  esi, pm_input_buf
    call pm_hist_save
    
    mov  byte [pm_hist_active], 0
    call pm_newline
    call pm_update_cursor
    pop  edi
    pop  eax
    ret

; ===========================================================================
; History Helpers (Shared between pm_readline and terminal.asm)
; ===========================================================================

; pm_hist_save - save string in ESI to history
pm_hist_save:
    pusha
    call pm_strlen
    test eax, eax
    jz   .done
    
    mov  eax, [pm_hist_head]
    imul eax, PM_HIST_LEN
    add  eax, pm_hist_buffer
    mov  edi, eax
    ; esi is already source
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    
    mov  eax, [pm_hist_head]
    inc  eax
    and  eax, 0x0F
    mov  [pm_hist_head], eax
    
    inc  dword [pm_hist_num]
    cmp  dword [pm_hist_num], 16
    jle  .num_ok
    mov  dword [pm_hist_num], 16
.num_ok:
.done:
    popa
    ret

; pm_hist_up - prepare to cycle UP. Returns CF=0 if display update needed.
; ESI must point to current input buffer (for initial save to temp)
pm_hist_up:
    cmp  dword [pm_hist_num], 0
    jz   .fail
    
    cmp  byte [pm_hist_active], 1
    je   .continue
    
    ; first press: save current line
    pusha
    mov  edi, pm_hist_temp
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa
    
    mov  byte [pm_hist_active], 1
    mov  eax, [pm_hist_head]
    mov  [pm_hist_view], eax
    
.continue:
    mov  eax, [pm_hist_view]
    dec  eax
    and  eax, 0x0F
    mov  [pm_hist_view], eax
    clc
    ret
.fail:
    stc
    ret

; pm_hist_down - prepare to cycle DOWN. Returns CF=0 if display update needed.
pm_hist_down:
    cmp  byte [pm_hist_active], 0
    je   .fail
    
    mov  eax, [pm_hist_view]
    inc  eax
    and  eax, 0x0F
    mov  [pm_hist_view], eax
    
    mov  ebx, [pm_hist_head]
    cmp  eax, ebx
    je   .bottom
    clc
    ret
.bottom:
    mov  byte [pm_hist_active], 0
    clc
    ret
.fail:
    stc
    ret
