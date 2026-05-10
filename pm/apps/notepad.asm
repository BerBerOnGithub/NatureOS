; ===========================================================================
; pm/apps/notepad.asm - Simple GUI text editor
; ===========================================================================
[BITS 32]

; - notepad_init
notepad_init:
    pusha
    mov  dword [notepad_len], 0
    popa
    ret

; - notepad_draw
notepad_draw:
    pusha
    ; ECX has win_id from wm_draw_dirty/wm_draw_all
    call term_update_coords   ; reuse terminal logic to populate term_cx/cy/cw/ch

    ; get window coords
    imul edi, ecx, 4
    mov  eax, [term_cx + edi]
    mov  ebx, [term_cy + edi]
    mov  ecx, [term_cw + edi]
    mov  edx, [term_ch + edi]
    
    ; white background
    mov  esi, 0x0F
    call fb_fill_rect

    ; Draw top bar (Grey height 16)
    push eax
    push ebx
    push ecx
    push edx
    mov  edx, 16
    mov  esi, 0x07  ; Light Grey
    call fb_fill_rect
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; Draw help string
    ; fb_draw_string In: ESI=str EBX=x ECX=y DL=fg DH=bg
    push eax
    push ebx
    push ecx
    push edx
    mov  esi, np_str_help
    mov  ecx, ebx
    add  ecx, 4     ; y+4
    mov  ebx, eax
    add  ebx, 4     ; x+4
    mov  dl,  0x00  ; black text
    mov  dh,  0x07  ; grey background
    call fb_draw_string
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; Coordinate tracker for character plotting (Client area starts at y + 16)
    mov  edi, eax
    add  edi, 2     ; start_x = win_x + 2
    mov  [np_cur_x], edi
    mov  edi, ebx
    add  edi, 18    ; start_y = win_y + 18 (2px padding below toolbar)
    mov  [np_cur_y], edi
    
    ; Save window bounds for wrap logic
    mov  [np_win_x], eax
    mov  [np_win_w], ecx

    mov  esi, notepad_buf
    mov  edi, [notepad_len]

.txt_loop:
    test edi, edi
    jz   .draw_cursor
    
    mov  cl, [esi]
    cmp  cl, 10       ; newline
    je   .newline
    
    mov  al, cl
    mov  ebx, [np_cur_x]
    mov  ecx, [np_cur_y]
    mov  dl, 0x00     ; black text
    mov  dh, 0x0F     ; white bg
    call fb_draw_char
    
    add  dword [np_cur_x], 8
    
    ; Wrap to next line
    mov  eax, [np_win_x]
    add  eax, [np_win_w]
    sub  eax, 8
    cmp  [np_cur_x], eax
    jge  .newline

.next_char:
    inc  esi
    dec  edi
    jmp  .txt_loop

.newline:
    mov  eax, [np_win_x]
    add  eax, 2
    mov  [np_cur_x], eax
    add  dword [np_cur_y], 8
    jmp  .next_char

.draw_cursor:
    ; Blink cursor based on system boot ticks
    mov  eax, [boot_ticks_lo]
    test eax, 8
    jz   .done

    mov  eax, [np_cur_x]
    mov  ebx, [np_cur_y]
    mov  ecx, 8
    mov  edx, 8
    mov  esi, 0x00
    call fb_fill_rect

.done:
    popa
    ret

; - notepad_tick
notepad_tick:
    pusha
    mov  ecx, 0
.fwin:
    cmp  ecx, WM_MAX_WINS
    jge  .no_focus
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+16], WM_NOTEPAD
    jne  .fnext
    cmp  byte [edi+17], 1       ; open
    jne  .fnext
    cmp  byte [edi+18], 1       ; focused
    je   .handle
.fnext:
    inc  ecx
    jmp  .fwin

.no_focus:
    popa
    ret

.handle:
    mov [notepad_active_id], ecx
    mov byte [np_changed_this_tick], 0
    
.keyloop:
    call pm_getkey
    or   ax, ax
    jz   .done
    
    test al, al             ; Extended scancode flag? (Wait, pm_getkey returns 0 if no key)
    ; Actually, pm_getkey returns scancode in AH, ASCII in AL.
    ; My previous logic was slightly weird, let's fix it too.
    
    cmp  al, 0
    jne  .ascii
    
    cmp  ah, 0x3C           ; F2 Key -> Load
    je   .load
    cmp  ah, 0x3D           ; F3 Key -> Save
    je   .save
    jmp  .keyloop

.ascii:
    cmp  al, 8              ; Backspace
    je   .backspace
    cmp  al, 13             ; Enter -> convert to Linux newline
    je   .enter
    cmp  al, 32
    jl   .keyloop           ; Discard other controls
    cmp  al, 127
    jge  .keyloop           ; Discard non-ascii
    
    mov  ebx, [notepad_len]
    cmp  ebx, 4095
    jge  .keyloop
    
    mov  edi, notepad_buf
    add  edi, ebx
    mov  [edi], al
    inc  dword [notepad_len]
    mov  byte [np_changed_this_tick], 1
    jmp  .keyloop

.enter:
    mov  ebx, [notepad_len]
    cmp  ebx, 4095
    jge  .keyloop
    mov  edi, notepad_buf
    add  edi, ebx
    mov  byte [edi], 10
    inc  dword [notepad_len]
    mov  byte [np_changed_this_tick], 1
    jmp  .keyloop

.backspace:
    mov  ebx, [notepad_len]
    cmp  ebx, 0
    je   .keyloop
    dec  dword [notepad_len]
    mov  byte [np_changed_this_tick], 1
    jmp  .keyloop

.load:
    mov  esi, np_filename
    call fsd_find
    jc   .keyloop           ; file doesn't exist
    mov  edi, notepad_buf
    call fsd_read_file
    mov  [notepad_len], ecx
    mov  byte [np_changed_this_tick], 1
    jmp  .keyloop

.save:
    mov  esi, np_filename
    call fsd_delete         ; blind fire delete to clear space
    mov  esi, np_filename
    mov  dword [fsd_create_data], notepad_buf
    mov  ecx, [notepad_len]
    call fsd_create
    mov  byte [np_changed_this_tick], 1
    jmp  .keyloop

.done:
    ; mark dirty natively via WM to force re-render if updated
    cmp  byte [np_changed_this_tick], 1
    jne  .no_inval
    mov  ecx, [notepad_active_id]
    call wm_invalidate
.no_inval:
    ; Blink the cursor even if nothing was typed recently!
    ; (Wait, invalidate every tick is expensive but ok for now if focused)
    mov  ecx, [notepad_active_id]
    call wm_invalidate
    popa
    ret

; - Data
notepad_active_id: dd 0
np_changed_this_tick: db 0
np_cur_x: dd 0
np_cur_y: dd 0
np_win_x: dd 0
np_win_w: dd 0
notepad_len:  dd 0
notepad_buf:  times 4096 db 0
np_str_help:   db '[F2] Load   [F3] Save    File: note.txt', 0
np_filename:   db 'note.txt', 0
