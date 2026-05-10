; ===========================================================================
; pm/gui/wm_taskbar.asm  -  Taskbar and Start Menu Rendering
; ===========================================================================

[BITS 32]

; - wm_str_len - count chars in null-terminated string at ESI -> EAX
wm_str_len:
    push esi
    xor  eax, eax
.wsl_loop:
    cmp  byte [esi], 0
    je   .wsl_done
    inc  eax
    inc  esi
    jmp  .wsl_loop
.wsl_done:
    pop  esi
    ret

; - wm_btn_width - pixel width for title at ESI: strlen*8+16, min 60
wm_btn_width:
    call wm_str_len
    shl  eax, 3
    add  eax, 16
    cmp  eax, 60
    jge  .wbw_ok
    mov  eax, 60
.wbw_ok:
    ret

; - wm_draw_taskbar_btns -
wm_draw_taskbar_btns:
    pusha
    mov  dword [wm_tbx], 90
    mov  dword [wm_i],   0
.loop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .done

    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .next

    ; dynamic button width from title
    mov  esi, [edi+20]
    call wm_btn_width
    mov  [wm_cur_btn_w], eax

    ; button fill
    mov  eax, [wm_tbx]
    mov  ebx, WM_TASKBAR_Y + 2
    mov  ecx, [wm_cur_btn_w]
    mov  edx, WM_TASKBAR_H - 4
    mov  esi, 0x07
    cmp  byte [edi+18], 1
    jne  .bbg
    mov  esi, 0x09
.bbg:
    call fb_fill_rect

    ; button border
    mov  eax, [wm_tbx]
    mov  ebx, WM_TASKBAR_Y + 2
    mov  ecx, [wm_cur_btn_w]
    mov  edx, WM_TASKBAR_H - 4
    mov  esi, 0x0F
    call fb_draw_rect_outline

    ; button label
    mov  esi, [edi+20]
    mov  ebx, [wm_tbx]
    add  ebx, 8
    mov  ecx, WM_TASKBAR_Y + 6
    mov  dl,  0x0F
    mov  dh,  0x07
    cmp  byte [edi+18], 1
    jne  .blbl
    mov  dh, 0x09
.blbl:
    call fb_draw_string

    ; advance by width + 4px gap
    mov  eax, [wm_cur_btn_w]
    add  eax, 4
    add  [wm_tbx], eax

.next:
    inc  dword [wm_i]
    jmp  .loop
.done:
    call wm_draw_taskbar_clock
    popa
    ret

; - wm_draw_taskbar_clock -
; Draws HH:MM:SS and YYYY-MM-DD right-aligned in the taskbar.
wm_draw_taskbar_clock:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; read RTC Time
    mov  al, 0x04
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_hh], eax

    mov  al, 0x02
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_mm], eax

    mov  al, 0x00
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_ss], eax

    ; read RTC Date
    mov  al, 0x09
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_yy], eax
    
    mov  al, 0x08
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_mo], eax
    
    mov  al, 0x07
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    mov  [wm_clk_dd], eax

    ; build "HH:MM:SS" in wm_clk_buf
    mov  edi, wm_clk_buf
    mov  eax, [wm_clk_hh]
    call wm_d2
    mov  byte [edi], ':'
    inc  edi
    mov  eax, [wm_clk_mm]
    call wm_d2
    mov  byte [edi], ':'
    inc  edi
    mov  eax, [wm_clk_ss]
    call wm_d2
    mov  byte [edi], 0

    ; build "20YY-MM-DD" in wm_dat_buf
    mov  edi, wm_dat_buf
    mov  byte [edi], '2'
    inc  edi
    mov  byte [edi], '0'
    inc  edi
    mov  eax, [wm_clk_yy]
    call wm_d2
    mov  byte [edi], '-'
    inc  edi
    mov  eax, [wm_clk_mo]
    call wm_d2
    mov  byte [edi], '-'
    inc  edi
    mov  eax, [wm_clk_dd]
    call wm_d2
    mov  byte [edi], 0

    ; erase old clock area
    ; max width needed is for date: 10 chars * 8px = 80px wide
    ; right-aligned with 8px margin: x = 640 - 80 - 8 = 552
    mov  eax, 552
    mov  ebx, WM_TASKBAR_Y + 1
    mov  ecx, 80
    mov  edx, WM_TASKBAR_H - 2
    mov  esi, WM_C_TBAR
    call fb_fill_rect

    ; draw time string (8 chars = 64px). align perfectly centered above date: 552 + 8 = 560
    mov  esi, wm_clk_buf
    mov  ebx, 560
    mov  ecx, WM_TASKBAR_Y + 1
    mov  dl,  0x0F              ; white
    mov  dh,  WM_C_TBAR
    call fb_draw_string

    ; draw date string (10 chars = 80px) exactly below time at y=9
    mov  esi, wm_dat_buf
    mov  ebx, 552
    mov  ecx, WM_TASKBAR_Y + 9
    mov  dl,  0x0F              ; white
    mov  dh,  WM_C_TBAR
    call fb_draw_string

    ; mark taskbar row dirty for gfx_flush
    mov  eax, WM_TASKBAR_Y
    mov  ebx, 479
    call gfx_mark_dirty

    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; helper: BCD byte in EAX -> binary in EAX
wm_bcd2bin:
    push ecx
    mov  ecx, eax
    shr  ecx, 4
    imul ecx, 10
    and  eax, 0x0F
    add  eax, ecx
    pop  ecx
    ret

; helper: write 2-digit decimal of EAX to [EDI], advance EDI by 2
wm_d2:
    ; write EAX (0-99) as exactly 2 ASCII digits at [EDI], advance EDI += 2
    push eax
    push edx
    xor  edx, edx
    mov  ecx, 10
    div  ecx            ; EAX = tens, EDX = units
    add  al, '0'
    mov  [edi], al
    inc  edi
    mov  al, dl
    add  al, '0'
    mov  [edi], al
    inc  edi
    pop  edx
    pop  eax
    ret

; Start menu layout: x=2, y=TASKBAR_Y-(SM_H), w=140
SM_X      equ 2
SM_W      equ 140
SM_ITEM_H equ 22
SM_ITEMS  equ 4
SM_HDR_H  equ 16                    ; header bar height
SM_H      equ SM_HDR_H + (SM_ITEM_H * SM_ITEMS) + 2  ; 16+88+2 = 106

; - wm_draw_startmenu -
wm_draw_startmenu:
    pusha
    ; background + border
    mov  eax, SM_X
    mov  ebx, WM_TASKBAR_Y - SM_H
    mov  ecx, SM_W
    mov  edx, SM_H
    mov  esi, 0x01              ; dark blue
    call fb_fill_rect
    mov  eax, SM_X
    mov  ebx, WM_TASKBAR_Y - SM_H
    mov  ecx, SM_W
    mov  edx, SM_H
    mov  esi, 0x0F
    call fb_draw_rect_outline

    ; header bar
    mov  eax, SM_X + 1
    mov  ebx, WM_TASKBAR_Y - SM_H + 1
    mov  ecx, SM_W - 2
    mov  edx, 14
    mov  esi, 0x09              ; blue header
    call fb_fill_rect
    mov  esi, wm_s_brand
    mov  ebx, SM_X + 4
    mov  ecx, WM_TASKBAR_Y - SM_H + 4
    mov  dl,  0x0F
    mov  dh,  0x09
    call fb_draw_string

    ; draw 4 menu items
    mov  dword [wm_i], 0
.item_loop:
    mov  ecx, [wm_i]
    cmp  ecx, SM_ITEMS
    jge  .done

    ; item y = menu_top + 15 + i*SM_ITEM_H
    mov  eax, WM_TASKBAR_Y - SM_H
    add  eax, 15
    mov  edx, SM_ITEM_H
    imul edx, ecx
    add  eax, edx               ; y of this item

    ; hover highlight
    cmp  ecx, [sm_hover]
    jne  .no_hl
    push eax
    mov  ebx, eax
    mov  eax, SM_X + 2
    mov  ecx, SM_W - 4
    mov  edx, SM_ITEM_H - 2
    mov  esi, 0x03
    call fb_fill_rect
    pop  eax
.no_hl:
    ; item label
    mov  ecx, [wm_i]
    mov  esi, [sm_labels + ecx*4]
    mov  ebx, SM_X + 6
    mov  ecx, eax
    add  ecx, 4
    mov  dl, 0x0F
    mov  dh, 0x01
    cmp  dword [sm_hover], -1
    je   .draw_lbl
    ; check if this item hovered
    mov  eax, [wm_i]
    cmp  eax, [sm_hover]
    jne  .draw_lbl
    mov  dh, 0x03
.draw_lbl:
    call fb_draw_string

    inc  dword [wm_i]
    jmp  .item_loop
.done:
    ; mark Start Menu region dirty for gfx_flush
    mov  eax, WM_TASKBAR_Y - SM_H
    mov  ebx, WM_TASKBAR_Y
    call gfx_mark_dirty
    popa
    ret

wm_hide_startmenu:
    pusha
    mov  byte [sm_open], 0
    mov  dword [sm_hover], -1
    call wm_draw_all
    popa
    ret