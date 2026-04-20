; ===========================================================================
; pm/terminal.asm " terminal with backing text buffer, clean register usage
; ===========================================================================
[BITS 32]

%define TERM_BUF_COLS  64
%define TERM_BUF_ROWS  48
%define TERM_FG        0x0A
%define TERM_BG        0x00
%define TERM_PROMPT_C  0x0B

; -
; term_init
; -
term_init:
    pusha
    mov  edi, term_buf
    mov  ecx, (TERM_BUF_COLS * TERM_BUF_ROWS * 2 + 3) / 4
    xor  eax, eax
    rep  stosd
    mov  dword [term_col], 0
    mov  dword [term_row], 0
    mov  dword [term_input_len], 0
    call term_update_coords

    ; fill client area black before printing anything
    mov  eax, [term_cx]
    mov  ebx, [term_cy]
    mov  ecx, [term_cw]
    mov  edx, [term_ch]
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
; term_update_coords " recompute pixel coords and row/col counts from wm_table[0]
; -
term_update_coords:
    pusha
    mov  eax, [wm_table + 0]    ; win_x
    mov  ebx, [wm_table + 4]    ; win_y
    mov  ecx, [wm_table + 8]    ; win_w
    mov  edx, [wm_table + 12]   ; win_h
    add  eax, 2
    add  ebx, WM_TITLE_H + 1
    sub  ecx, 4
    sub  edx, WM_TITLE_H + 3
    mov  [term_cx], eax
    mov  [term_cy], ebx
    mov  [term_cw], ecx
    mov  [term_ch], edx
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
    mov  [term_cols], ecx
    mov  [term_rows], edx
    popa
    ret

; -
; term_buf_write " write AL=char DL=colour at [term_row][term_col]
; -
term_buf_write:
    pusha
    ; offset = row*TERM_BUF_COLS*2 + col*2
    mov  ecx, [term_row]
    imul ecx, TERM_BUF_COLS * 2
    mov  edi, [term_col]
    imul edi, 2
    add  ecx, edi
    mov  edi, term_buf
    add  edi, ecx
    mov  [edi],   al
    mov  [edi+1], dl
    popa
    ret

; -
; term_buf_scroll " shift all rows up by 1, zero last row
; -
term_buf_scroll:
    pusha
    mov  esi, term_buf + (TERM_BUF_COLS * 2)
    mov  edi, term_buf
    mov  ecx, (TERM_BUF_ROWS - 1) * TERM_BUF_COLS * 2 / 4
    rep  movsd
    mov  edi, term_buf + ((TERM_BUF_ROWS - 1) * TERM_BUF_COLS * 2)
    mov  ecx, TERM_BUF_COLS * 2 / 4
    xor  eax, eax
    rep  stosd
    popa
    ret

; -
; term_redraw " recompute coords, fill black, replay buffer to screen
; -
term_redraw:
    pusha
    call term_update_coords

    ; fill client area black
    mov  eax, [term_cx]
    mov  ebx, [term_cy]
    mov  ecx, [term_cw]
    mov  edx, [term_ch]
    mov  esi, TERM_BG
    call fb_fill_rect

    ; replay: row = 0..term_rows-1, col = 0..term_cols-1
    mov  dword [term_ri], 0
.rrow:
    mov  eax, [term_rows]
    cmp  [term_ri], eax
    jge  .rdone
    mov  dword [term_ci], 0
.rcol:
    mov  eax, [term_cols]
    cmp  [term_ci], eax
    jge  .rnext_row

    ; buf address = term_buf + ri*TERM_BUF_COLS*2 + ci*2
    mov  eax, [term_ri]
    imul eax, TERM_BUF_COLS * 2
    mov  ecx, [term_ci]
    imul ecx, 2
    add  eax, ecx
    add  eax, term_buf          ; EAX = cell ptr

    mov  al,  [eax]             ; AL = char  (NOTE: destroys upper EAX " that's ok, buf ptr no longer needed)
    test al, al
    jz   .rskip

    mov  [term_tmp_char], al    ; save char to memory " avoids ALL register aliasing
    mov  dl, [eax+1]            ; wait " eax upper bytes corrupted. use offset calc instead.

    ; EAX upper bytes were trashed by "mov al, [eax]" " recalculate ptr for colour byte
    mov  eax, [term_ri]
    imul eax, TERM_BUF_COLS * 2
    mov  ecx, [term_ci]
    imul ecx, 2
    add  eax, ecx
    add  eax, term_buf + 1      ; +1 = colour byte
    mov  dl, [eax]              ; DL = colour

    ; pixel x = ci*8 + term_cx
    mov  ebx, [term_ci]
    imul ebx, 8
    add  ebx, [term_cx]

    ; pixel y = ri*8 + term_cy
    mov  ecx, [term_ri]
    imul ecx, 8
    add  ecx, [term_cy]

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
; term_tick " non-blocking key handler
; -
term_tick:
    pusha
    ; search for focused terminal window
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
    cmp  al, 32
    jl   .done
    cmp  al, 127
    jge  .done

    ; check input buffer not full
    mov  ecx, [term_cols]
    sub  ecx, 3
    cmp  [term_input_len], ecx
    jge  .done

    ; store in input buffer and echo
    mov  edi, term_input_buf
    add  edi, [term_input_len]
    mov  [edi], al
    inc  dword [term_input_len]
    push edx
    mov  dl, TERM_FG
    call term_putchar_col
    pop  edx
    mov  byte [term_changed_this_tick], 1
    jmp  .handle_loop

.backspace:
    cmp  dword [term_input_len], 0
    je   .done
    dec  dword [term_input_len]
    dec  dword [term_col]
    ; clear buffer cell
    push eax
    push edx
    xor  al, al
    mov  dl, TERM_BG
    call term_buf_write
    ; erase on screen
    mov  ebx, [term_col]
    imul ebx, 8
    add  ebx, [term_cx]
    mov  ecx, [term_row]
    imul ecx, 8
    add  ecx, [term_cy]
    mov  al, ' '
    mov  dl, TERM_BG
    mov  dh, TERM_BG
    call fb_draw_char
    pop  edx
    pop  eax
    mov  byte [term_changed_this_tick], 1
    jmp  .handle_loop

.enter:
    call term_newline
    mov  edi, term_input_buf
    mov  eax, [term_input_len]
    mov  byte [edi + eax], 0
    mov  esi, term_input_buf
    mov  edi, pm_input_buf
    mov  ecx, [term_input_len]
    mov  [pm_input_len], ecx
    rep  movsb
    mov  byte [edi], 0
    call pm_exec
    mov  dword [term_input_len], 0
    mov  dword [term_col], 0
    call term_draw_prompt
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

; local var for term_tick
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
; term_putchar  AL=char (TERM_FG)
; -
term_putchar:
    push edx
    mov  dl, TERM_FG
    call term_putchar_col
    pop  edx
    ret

; term_putchar_col  AL=char  DL=colour
term_putchar_col:
    pusha

    ; --- serial output (non-blocking) ---
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
    ; ---------------------

    cmp  al, 10
    je   .nl
    cmp  al, 13
    je   .cr

    ; wrap if at end of line
    mov  ecx, [term_cols]
    dec  ecx
    cmp  [term_col], ecx
    jge  .wrap

    ; write to buffer
    call term_buf_write

    ; draw to screen: EBX=x ECX=y AL=char DL=fg DH=bg
    mov  ebx, [term_col]
    imul ebx, 8
    add  ebx, [term_cx]
    mov  ecx, [term_row]
    imul ecx, 8
    add  ecx, [term_cy]
    mov  dh, TERM_BG
    call fb_draw_char

    inc  dword [term_col]
    jmp  .done

.wrap:
    call term_newline
    popa
    jmp  term_putchar_col
.nl:
    call term_newline
    jmp  .done
.cr:
    mov  dword [term_col], 0
.done:
    popa
    ret

; -
; term_puts  ESI=string (TERM_FG)
; -
term_puts:
    push edx
    mov  dl, TERM_FG
    call term_puts_colour
    pop  edx
    ret

term_puts_colour:    ; ESI=str  DL=colour
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
    mov  dword [term_col], 0
    inc  esi
    jmp  .loop
.done:
    pop  eax
    ret

; -
; term_newline " advance row, scroll buffer+pixels when row reaches term_rows
; -
term_newline:
    pusha
    mov  dword [term_col], 0
    inc  dword [term_row]
    mov  eax, [term_rows]
    cmp  [term_row], eax
    jl   .done

    ; scroll buffer
    call term_buf_scroll

    ; erase cursor BEFORE pixel scroll so it doesn't get baked into framebuffer
    call cursor_erase

    ; scroll pixels up 8px: copy rows cy+8..cy+ch-1 to cy..cy+ch-9
    ; EDX must NOT be used as loop limit across mul " save to memory
    mov  eax, [term_ch]
    sub  eax, 8
    mov  [term_scroll_lim], eax  ; pixel rows to copy
    xor  esi, esi                ; pixel row offset
.sloop:
    cmp  esi, [term_scroll_lim]
    jge  .clrlast

    ; src ptr = fb[cy + 8 + esi][cx]
    mov  eax, [term_cy]
    add  eax, 8
    add  eax, esi
    mul  dword [gfx_fb_pitch]   ; EDX trashed here " that's fine now
    add  eax, [gfx_fb_base]
    add  eax, [term_cx]
    mov  edi, eax               ; save src ptr

    ; dst ptr = fb[cy + esi][cx]
    mov  eax, [term_cy]
    add  eax, esi
    mul  dword [gfx_fb_pitch]   ; EDX trashed again " fine
    add  eax, [gfx_fb_base]
    add  eax, [term_cx]

    push esi
    mov  esi, edi               ; esi = src
    mov  edi, eax               ; edi = dst
    mov  ecx, [term_cw]
    rep  movsb
    pop  esi

    inc  esi
    jmp  .sloop

.clrlast:
    mov  eax, [term_cx]
    mov  ebx, [term_cy]
    add  ebx, [term_ch]
    sub  ebx, 8
    mov  ecx, [term_cw]
    mov  edx, 8
    mov  esi, TERM_BG
    call fb_fill_rect

    mov  eax, [term_rows]
    dec  eax
    mov  [term_row], eax

    ; redraw cursor at its current position after scroll
    call cursor_save_bg
    call cursor_draw

.done:
    popa
    ret

; -
; Data
; -
term_col:         dd 0
term_row:         dd 0
term_input_len:   dd 0
term_input_buf:   times 128 db 0

term_cx:          dd 2
term_cy:          dd 20
term_cw:          dd 476
term_ch:          dd 318
term_cols:        dd 58
term_rows:        dd 39

; loop counter temporaries (avoids register aliasing in replay)
term_ri:          dd 0
term_ci:          dd 0
term_tmp_char:    db 0
term_scroll_lim:  dd 0

term_buf          equ 0x134000

term_str_banner:  db 'NatureOS v2.0 - type help for commands', 0
term_str_disk_ok: db 'Data disk: OK', 0
term_str_disk_no: db 'Data disk: not found (no -drive attached?)', 0
term_str_prompt:  db '> ', 0
