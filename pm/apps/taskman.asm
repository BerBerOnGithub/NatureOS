; ===========================================================================
; pm/apps/taskman.asm - Grouped GUI Task Manager (Perfectly Aligned)
; ===========================================================================
[BITS 32]

taskman_draw:
    pusha
    ; ECX = window id
    mov  [tm_draw_id], ecx
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    
    ; white background client area
    mov  eax, [edi+0]    ; x
    mov  ebx, [edi+4]    ; y
    add  ebx, WM_TITLE_H
    mov  ecx, [edi+8]    ; w
    mov  edx, [edi+12]   ; h
    sub  edx, WM_TITLE_H
    mov  esi, 0x07       ; light grey/white-ish
    call fb_fill_rect
    
    ; header - Name
    mov  ebx, [edi+0]
    add  ebx, 15
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 5
    mov  esi, tm_str_header_name
    mov  dl,  0x00       ; black text
    mov  dh,  0xFF       ; transparent bg
    call fb_draw_string
    
    ; header - Status (Aligned to x+380)
    mov  ebx, [edi+0]
    add  ebx, 380
    mov  esi, tm_str_header_status
    call fb_draw_string
    
    ; --- Grouped Loop ---
    mov  dword [tm_y_ptr], 35
    mov  esi, tm_type_list
.type_loop:
    movzx eax, byte [esi]
    cmp  al, 0xFF
    je   .done
    mov  [tm_curr_type], al
    inc  esi
    mov  [tm_curr_title], esi
    
    ; skip title in list to find next entry later
.skip:
    lodsb
    test al, al
    jnz  .skip
    mov  [tm_next_item], esi
    
    ; count instances
    call tm_count_instances
    cmp  eax, 0
    je   .next_type
    
    ; -- Draw Line --
    imul edi, [tm_draw_id], WM_STRIDE
    add  edi, wm_table
    mov  ebx, [edi+0]
    add  ebx, 15
    mov  eax, [edi+4]
    add  eax, WM_TITLE_H
    add  eax, [tm_y_ptr]
    mov  [tm_curr_y], eax
    
    ; Title
    mov  esi, [tm_curr_title]
    mov  ecx, [tm_curr_y]
    mov  dl,  0x00
    mov  dh,  0xFF
    call fb_draw_string  ; ebx is now after the title
    
    ; Suffix (n) - only if > 1
    cmp  dword [tm_cnt_total], 1
    jbe  .no_suffix
    
    add  ebx, 4          ; tiny gap after title
    mov  esi, tm_str_sfx_open
    call fb_draw_string  ; draws '(' and moves ebx by 8
    
    mov  eax, [tm_cnt_total]
    call tm_draw_dec     ; draws number and moves ebx by 8 (or more)
    
    mov  esi, tm_str_sfx_close
    call fb_draw_string  ; draws ')' and moves ebx by 8

.no_suffix:
    ; Status Aligned to x+380
    imul edi, [tm_draw_id], WM_STRIDE
    add  edi, wm_table
    mov  ebx, [edi+0]
    add  ebx, 380
    
    cmp  byte [tm_any_active], 1
    jne  .no_active
    mov  esi, tm_str_active
    mov  dl,  0x09
    mov  ecx, [tm_curr_y]
    call fb_draw_string
    mov  dl,  0x00
.no_active:

    add  dword [tm_y_ptr], 13

.next_type:
    mov  esi, [tm_next_item]
    jmp  .type_loop

.done:
    popa
    ret

; -
tm_count_instances:
    pusha
    mov  dword [tm_cnt_total], 0
    mov  byte [tm_any_active], 0
    xor  ecx, ecx
.loop:
    cmp  ecx, WM_MAX_WINS
    jge  .done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1    ; open?
    jne  .next
    movzx eax, byte [edi+16]
    cmp  al, [tm_curr_type]
    jne  .next
    inc  dword [tm_cnt_total]
    cmp  byte [edi+18], 1    ; focused?
    jne  .next
    mov  byte [tm_any_active], 1
.next:
    inc  ecx
    jmp  .loop
.done:
    popa
    mov  eax, [tm_cnt_total]
    ret

; -
tm_draw_dec:
    ; EBX is preserved? No, it should be updated by our count
    mov  edi, tm_numbuf
    cmp  eax, 9
    jbe  .single
    mov  byte [edi], '+'
    jmp  .stored
.single:
    add  al, '0'
    mov  [edi], al
.stored:
    mov  byte [edi+1], 0
    mov  esi, tm_numbuf
    mov  ecx, [tm_curr_y]
    mov  dl,  0x00
    mov  dh,  0xFF
    call fb_draw_string
    ret

; --- Data ---
tm_draw_id_v: dd 0
tm_draw_id    equ tm_draw_id_v
tm_y_p:       dd 0
tm_y_ptr      equ tm_y_p

tm_curr_y:    dd 0
tm_curr_type: db 0
tm_curr_title: dd 0
tm_next_item: dd 0
tm_cnt_total: dd 0
tm_any_active: db 0
tm_numbuf:    db 0, 0

tm_str_header_name:   db 'Application Name (Instances)', 0
tm_str_header_status: db 'Status', 0
tm_str_active:        db '[Active]', 0
tm_str_sfx_open:      db '(', 0
tm_str_sfx_close:     db ')', 0

tm_type_list:
    db 0, 'Terminal', 0
    db 1, 'Stopwatch', 0
    db 2, 'Files', 0
    db 3, 'About NatureOS', 0
    db 4, 'Simple Browser', 0
    db 5, 'Task Manager', 0
    db 6, 'Notepad', 0
    db 7, 'Paint', 0
    db 0xFF
