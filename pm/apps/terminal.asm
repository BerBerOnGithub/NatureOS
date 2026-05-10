; ===========================================================================
; pm/terminal.asm - terminal with backing text buffer, clean register usage
; ===========================================================================
[BITS 32]

%define TERM_BUF_COLS  64
%define TERM_BUF_ROWS  48
%define TERM_FG        0x0A
%define TERM_BG        0x00
%define TERM_PROMPT_C  0x0B
%define TERM_MAX_WINS  8

; -
; term_init
; -
term_init:
    ; ECX = window id
    pusha
    mov  [term_active_id], ecx
    mov  eax, TERM_BUF_COLS * TERM_BUF_ROWS * 2
    imul eax, ecx
    mov  edi, term_buf
    add  edi, eax
    mov  ecx, (TERM_BUF_COLS * TERM_BUF_ROWS * 2 + 3) / 4
    xor  eax, eax
    rep  stosd
    
    mov  ecx, [term_active_id]
    imul ebx, ecx, 4
    mov  dword [term_col + ebx], 0
    mov  dword [term_row + ebx], 0
    mov  dword [term_input_len + ebx], 0
    
    call term_update_coords

    ; fill client area black before printing anything
    mov  edi, [term_active_id]
    imul edi, 4
    mov  eax, [term_cx + edi]
    mov  ebx, [term_cy + edi]
    mov  ecx, [term_cw + edi]
    mov  edx, [term_ch + edi]
    mov  esi, TERM_BG
    call fb_fill_rect

    mov  esi, term_str_banner
    call term_puts
    call term_newline

    ; show data disk status
    cmp  byte [bd_ready], 1
    jne  .no_disk
    mov  esi, term_str_disk_ok
    call term_puts
    call term_newline
    jmp  .disk_done
.no_disk:
    mov  esi, term_str_disk_no
    call term_puts
    call term_newline
.disk_done:

    call term_draw_prompt
    popa
    ret

; -
; term_update_coords
; -
term_update_coords:
    pusha
    ; ECX = window id
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  eax, [edi + 0]    ; win_x
    mov  ebx, [edi + 4]    ; win_y
    push ecx               ; save win_id
    mov  ecx, [edi + 8]    ; win_w
    mov  edx, [edi + 12]   ; win_h
    add  eax, 2
    add  ebx, WM_TITLE_H + 1
    sub  ecx, 4
    sub  edx, WM_TITLE_H + 3
    
    pop  edi               ; edi = win_id
    push edi               ; save again
    imul edi, 4
    mov  [term_cx + edi], eax
    mov  [term_cy + edi], ebx
    mov  [term_cw + edi], ecx
    mov  [term_ch + edi], edx
    shr  ecx, 3
    shr  edx, 3
    cmp  ecx, TERM_BUF_COLS
    jbe  .cols_ok
    mov  ecx, TERM_BUF_COLS
.cols_ok:
    cmp  edx, TERM_BUF_ROWS
    jbe  .rows_ok
    mov  edx, TERM_BUF_ROWS
.rows_ok:
    pop  edi               ; edi = win_id
    imul edi, 4
    mov  [term_cols + edi], ecx
    mov  [term_rows + edi], edx
    popa
    ret

; -
; term_buf_write
; -
term_buf_write:
    pusha
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ecx, [term_row + esi]
    imul ecx, TERM_BUF_COLS * 2
    mov  edi, [term_col + esi]
    imul edi, 2
    add  ecx, edi
    
    mov  edi, TERM_BUF_COLS * TERM_BUF_ROWS * 2
    imul edi, ebx
    add  ecx, edi
    
    mov  edi, term_buf
    add  edi, ecx
    mov  [edi],   al
    mov  [edi+1], dl
    popa
    ret

; -
; term_buf_scroll
; -
term_buf_scroll:
    pusha
    mov  ebx, [term_active_id]
    mov  eax, TERM_BUF_COLS * TERM_BUF_ROWS * 2
    imul eax, ebx
    
    mov  esi, term_buf + (TERM_BUF_COLS * 2)
    add  esi, eax
    mov  edi, term_buf
    add  edi, eax
    mov  ecx, (TERM_BUF_ROWS - 1) * TERM_BUF_COLS * 2 / 4
    rep  movsd
    
    mov  edi, term_buf + ((TERM_BUF_ROWS - 1) * TERM_BUF_COLS * 2)
    add  edi, eax
    mov  ecx, TERM_BUF_COLS * 2 / 4
    xor  eax, eax
    rep  stosd
    popa
    ret

; -
; term_redraw
; -
term_redraw:
    pusha
    ; ECX is already win_id from wm_draw_dirty
    mov  [term_draw_id], ecx
    call term_update_coords

    ; fill client area black
    mov  esi, [term_draw_id]
    imul esi, 4
    mov  eax, [term_cx + esi]
    mov  ebx, [term_cy + esi]
    mov  ecx, [term_cw + esi]
    mov  edx, [term_ch + esi]
    mov  esi, TERM_BG
    call fb_fill_rect

    ; replay
    mov  dword [term_ri], 0
.rrow:
    mov  esi, [term_draw_id]
    imul esi, 4
    mov  eax, [term_rows + esi]
    cmp  [term_ri], eax
    jge  .rdone
    mov  dword [term_ci], 0
.rcol:
    mov  esi, [term_draw_id]
    imul esi, 4
    mov  eax, [term_cols + esi]
    cmp  [term_ci], eax
    jge  .rnext_row

    ; buf address = term_buf + win*SIZE + ri*COLS*2 + ci*2
    mov  eax, [term_ri]
    imul eax, TERM_BUF_COLS * 2
    mov  ecx, [term_ci]
    imul ecx, 2
    add  eax, ecx
    
    mov  ecx, [term_draw_id]
    imul ecx, TERM_BUF_COLS * TERM_BUF_ROWS * 2
    add  eax, ecx
    
    add  eax, term_buf

    mov  cl,  [eax]             ; CL = char
    test cl, cl
    jz   .rskip

    mov  [term_tmp_char], cl
    
    mov  eax, [term_ri]
    imul eax, TERM_BUF_COLS * 2
    mov  ecx, [term_ci]
    imul ecx, 2
    add  eax, ecx
    mov  ecx, [term_draw_id]
    imul ecx, TERM_BUF_COLS * TERM_BUF_ROWS * 2
    add  eax, ecx
    add  eax, term_buf + 1
    mov  dl, [eax]              ; DL = colour

    mov  esi, [term_draw_id]
    imul esi, 4
    mov  ebx, [term_ci]
    imul ebx, 8
    add  ebx, [term_cx + esi]

    mov  ecx, [term_ri]
    imul ecx, 8
    add  ecx, [term_cy + esi]

    mov  al,  [term_tmp_char]
    mov  dh,  TERM_BG
    call fb_draw_char

.rskip:
    inc  dword [term_ci]
    jmp  .rcol
.rnext_row:
    inc  dword [term_ri]
    jmp  .rrow
.rdone:
    popa
    ret

; -
; term_tick
; -
term_tick:
    pusha
    mov  ecx, 0
.fwin:
    cmp  ecx, WM_MAX_WINS
    jge  .no_focus
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+16], WM_TERM
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
    mov  [term_win_id], ecx
    mov  [term_active_id], ecx
    mov  byte [term_changed_this_tick], 0
.handle_loop:
    call pm_getkey
    or   al, al
    jz   .done
    cmp  al, 0xFF            ; Print Screen sentinel
    jne  .not_prtsc
    call wm_screenshot_capture
    jmp  .handle_loop
.not_prtsc:
    cmp  al, 13
    je   .enter
    cmp  al, 8
    je   .backspace
    cmp  al, 0x80            ; UP
    je   .up
    cmp  al, 0x81            ; DOWN
    je   .down
    cmp  al, 32
    jl   .done
    cmp  al, 127
    jge  .done

    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ecx, [term_cols + esi]
    sub  ecx, 3
    cmp  [term_input_len + esi], ecx
    jge  .done

    mov  edi, term_input_buf
    mov  ecx, 128
    imul ecx, ebx
    add  edi, ecx
    add  edi, [term_input_len + esi]
    mov  [edi], al
    inc  dword [term_input_len + esi]
    push edx
    mov  dl, TERM_FG
    call term_putchar_col
    pop  edx
    mov  byte [term_changed_this_tick], 1
    mov  byte [pm_hist_active], 0
    jmp  .handle_loop

.backspace:
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    cmp  dword [term_input_len + esi], 0
    je   .done
    dec  dword [term_input_len + esi]
    dec  dword [term_col + esi]
    push eax
    push edx
    xor  al, al
    mov  dl, TERM_BG
    call term_buf_write
    
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ebx, [term_col + esi]
    imul ebx, 8
    add  ebx, [term_cx + esi]
    
    push ebx
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ecx, [term_row + esi]
    imul ecx, 8
    add  ecx, [term_cy + esi]
    pop  ebx
    
    mov  al, ' '
    mov  dl, TERM_BG
    mov  dh, TERM_BG
    call fb_draw_char
    pop  edx
    pop  eax
    mov  byte [term_changed_this_tick], 1
    mov  byte [pm_hist_active], 0
    jmp  .handle_loop

.enter:
    call term_newline
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  edi, term_input_buf
    mov  eax, 128
    imul eax, ebx
    add  edi, eax
    
    mov  eax, [term_input_len + esi]
    mov  byte [edi + eax], 0
    
    ; save to history
    push esi
    mov  esi, edi
    call pm_hist_save
    pop  esi
    
    mov  esi, edi
    mov  edi, pm_input_buf
    
    mov  ebx, [term_active_id]
    imul ebx, 4
    mov  ecx, [term_input_len + ebx]
    mov  [pm_input_len], ecx
    rep  movsb
    mov  byte [edi], 0
    mov  byte [pm_hist_active], 0
    call pm_exec
    
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  dword [term_input_len + esi], 0
    mov  dword [term_col + esi], 0
    call term_draw_prompt
    mov  byte [term_changed_this_tick], 1
    jmp  .handle_loop

.up:
    mov  ebx, [term_active_id]
    mov  edi, term_input_buf
    mov  eax, 128
    imul eax, ebx
    add  edi, eax
    mov  esi, edi
    call pm_hist_up
    jc   .handle_loop
    
    call term_clear_input
    
    ; copy from history[view] to term_input_buf[win]
    pusha
    mov  eax, [pm_hist_view]
    imul eax, PM_HIST_LEN
    add  eax, pm_hist_buffer
    mov  esi, eax
    
    mov  ebx, [term_active_id]
    mov  edi, term_input_buf
    mov  ecx, 128
    imul ecx, ebx
    add  edi, ecx
    
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa
    
    ; redraw input
    jmp  .redraw_input

.down:
    call pm_hist_down
    jc   .handle_loop
    
    call term_clear_input
    
    cmp  byte [pm_hist_active], 0
    je   .restore_temp
    
    ; copy from history[view]
    pusha
    mov  eax, [pm_hist_view]
    imul eax, PM_HIST_LEN
    add  eax, pm_hist_buffer
    mov  esi, eax
    
    mov  ebx, [term_active_id]
    mov  edi, term_input_buf
    mov  ecx, 128
    imul ecx, ebx
    add  edi, ecx
    
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa
    jmp  .redraw_input

.restore_temp:
    pusha
    mov  esi, pm_hist_temp
    mov  ebx, [term_active_id]
    mov  edi, term_input_buf
    mov  ecx, 128
    imul ecx, ebx
    add  edi, ecx
    mov  ecx, PM_HIST_LEN / 4
    rep  movsd
    popa

.redraw_input:
    mov  ebx, [term_active_id]
    imul ebx, 4
    mov  edi, term_input_buf
    mov  eax, 128
    shr  ebx, 2              ; back to win id
    imul eax, ebx
    add  edi, eax
    mov  esi, edi
    call pm_strlen
    
    mov  ebx, [term_active_id]
    imul edx, ebx, 4
    mov  [term_input_len + edx], eax
    
    mov  esi, edi
    call term_puts
    mov  byte [term_changed_this_tick], 1
    jmp  .handle_loop
.done:
    cmp  byte [term_changed_this_tick], 1
    jne  .no_inval
    mov  ecx, [term_win_id]
    call wm_invalidate
.no_inval:
    popa
    ret

; -
; term_clear_input
; Erases the currently typed characters from screen and buffer.
; -
term_clear_input:
    pusha
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
.cl_lp:
    cmp  dword [term_input_len + esi], 0
    je   .done
    
    dec  dword [term_input_len + esi]
    dec  dword [term_col + esi]
    
    xor  al, al
    mov  dl, TERM_BG
    call term_buf_write
    
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ebx, [term_col + esi]
    shl  ebx, 3
    add  ebx, [term_cx + esi]
    
    mov  ecx, [term_row + esi]
    shl  ecx, 3
    add  ecx, [term_cy + esi]
    
    mov  al, ' '
    mov  dl, TERM_BG
    mov  dh, TERM_BG
    call fb_draw_char
    jmp  .cl_lp

.done:
    popa
    ret

term_changed_this_tick: db 0
term_win_id: dd 0

; -
; term_draw_prompt
; -
term_draw_prompt:
    pusha
    mov  esi, term_str_prompt
    mov  dl, TERM_PROMPT_C
    call term_puts_colour
    popa
    ret

; -
; term_putchar
; -
term_putchar:
    push edx
    mov  dl, TERM_FG
    call term_putchar_col
    pop  edx
    ret

term_putchar_col:
    pusha
    push edx
    push eax
    mov  dx, 0x3FD
    in   al, dx
    test al, 0x20
    jz   .skip_serial_pm
    mov  dx, 0x3F8
    pop  eax
    push eax
    out  dx, al
.skip_serial_pm:
    pop  eax
    pop  edx

    cmp  al, 10
    je   .nl
    cmp  al, 13
    je   .cr

    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ecx, [term_cols + esi]
    dec  ecx
    cmp  [term_col + esi], ecx
    jge  .wrap

    call term_buf_write

    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ebx, [term_col + esi]
    imul ebx, 8
    add  ebx, [term_cx + esi]
    
    push ebx
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  ecx, [term_row + esi]
    imul ecx, 8
    add  ecx, [term_cy + esi]
    pop  ebx
    
    mov  dh, TERM_BG
    call fb_draw_char

    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    inc  dword [term_col + esi]
    jmp  .done

.wrap:
    call term_newline
    popa
    jmp  term_putchar_col
.nl:
    call term_newline
    jmp  .done
.cr:
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  dword [term_col + esi], 0
.done:
    popa
    ret

; -
; term_puts
; -
term_puts:
    push edx
    mov  dl, TERM_FG
    call term_puts_colour
    pop  edx
    ret

term_puts_colour:
    push eax
.loop:
    mov  al, [esi]
    test al, al
    jz   .done
    cmp  al, 10
    je   .nl
    cmp  al, 13
    je   .cr
    call term_putchar_col
    inc  esi
    jmp  .loop
.nl:
    call term_newline
    inc  esi
    jmp  .loop
.cr:
    push ebx
    push esi
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  dword [term_col + esi], 0
    pop  esi
    pop  ebx
    inc  esi
    jmp  .loop
.done:
    pop  eax
    ret

; -
; term_newline
; -
term_newline:
    pusha
    mov  ebx, [term_active_id]
    imul esi, ebx, 4
    mov  dword [term_col + esi], 0
    inc  dword [term_row + esi]
    mov  eax, [term_rows + esi]
    cmp  [term_row + esi], eax
    jl   .done

    call term_buf_scroll
    call cursor_erase

    mov  ebx, [term_active_id]
    imul edi, ebx, 4
    mov  eax, [term_ch + edi]
    sub  eax, 8
    mov  [term_scroll_lim], eax
    xor  esi, esi
.sloop:
    cmp  esi, [term_scroll_lim]
    jge  .clrlast

    mov  ebx, [term_active_id]
    imul edi, ebx, 4
    
    mov  eax, [term_cy + edi]
    add  eax, 8
    add  eax, esi
    mul  dword [gfx_fb_pitch]
    add  eax, [gfx_fb_base]
    add  eax, [term_cx + edi]
    
    mov  [term_ci], eax

    mov  eax, [term_cy + edi]
    add  eax, esi
    mul  dword [gfx_fb_pitch]
    add  eax, [gfx_fb_base]
    add  eax, [term_cx + edi]

    push esi
    mov  esi, [term_ci]
    mov  edi, eax
    mov  ebx, [term_active_id]
    imul ebx, 4
    mov  ecx, [term_cw + ebx]
    rep  movsb
    pop  esi
    inc  esi
    jmp  .sloop

    ; mark entire terminal client area dirty
    push eax
    push ebx
    push edi
    mov  edi, [term_active_id]
    shl  edi, 2
    mov  eax, [term_cy + edi]
    mov  ebx, eax
    add  ebx, [term_ch + edi]
    call gfx_mark_dirty
    pop  edi
    pop  ebx
    pop  eax

.clrlast:
    mov  ebx, [term_active_id]
    imul edi, ebx, 4
    mov  eax, [term_cx + edi]
    mov  ebx, [term_cy + edi]
    add  ebx, [term_ch + edi]
    sub  ebx, 8
    mov  ecx, [term_cw + edi]
    mov  edx, 8
    mov  esi, TERM_BG
    call fb_fill_rect

    mov  ebx, [term_active_id]
    imul edi, ebx, 4
    mov  eax, [term_rows + edi]
    dec  eax
    mov  [term_row + edi], eax

    call cursor_save_bg
    call cursor_draw

.done:
    popa
    ret

; -
; Data
; -
term_active_id:   dd 0
term_draw_id:     dd 0
term_col:         times 8 dd 0
term_row:         times 8 dd 0
term_input_len:   times 8 dd 0
term_input_buf:   times 8*128 db 0

term_cx:          times 8 dd 2
term_cy:          times 8 dd 20
term_cw:          times 8 dd 476
term_ch:          times 8 dd 318
term_cols:        times 8 dd 58
term_rows:        times 8 dd 39

term_ri:          dd 0
term_ci:          dd 0
term_tmp_char:    db 0
term_scroll_lim:  dd 0

term_buf          equ 0x134000

term_str_banner:  db OS_NAME, ' v', OS_VERSION, ' - type help for commands', 0
term_str_disk_ok: db 'Data disk: OK', 0
term_str_disk_no: db 'Data disk: not found (no -drive attached?)', 0
term_str_prompt:  db '> ', 0
