; ===========================================================================
; pm/apps/paint.asm - Simple pixel drawing application
;
; Opens a window with a canvas. Click and drag to draw pixels.
; Palette bar at bottom switches colors; first swatch is eraser (black).
; ===========================================================================
[BITS 32]

PAINT_W     equ 400
PAINT_H     equ 300
PAINT_CW    equ PAINT_W
PAINT_CH    equ 280
PAINT_BUF   equ 0x660000
PAINT_PAL_H equ 20
PAINT_SW    equ 20
PAINT_SH    equ 18
PAINT_NUM   equ 8

; - paint_init
paint_init:
    pusha
    mov  edi, PAINT_BUF
    mov  ecx, (PAINT_CW * PAINT_CH) / 4
    xor  eax, eax
    rep  stosd
    mov  byte [paint_color], 7
    popa
    ret

; - paint_draw
; ECX = window id
paint_draw:
    pusha
    mov  [paint_tmp_id], ecx
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    mov  eax, [edi+0]
    mov  [paint_tmp_x], eax
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H
    mov  [paint_tmp_y], ebx

    ; blit canvas buffer to shadow framebuffer
    mov  dword [paint_tmp_row], 0
.blit:
    mov  eax, [paint_tmp_row]
    cmp  eax, PAINT_CH
    jge  .blit_done
    mov  edi, [gfx_fb_base]
    mov  ebx, [paint_tmp_y]
    add  ebx, eax
    imul ebx, 640
    add  edi, ebx
    add  edi, [paint_tmp_x]
    mov  esi, PAINT_BUF
    mov  ebx, [paint_tmp_row]
    imul ebx, PAINT_CW
    add  esi, ebx
    push ecx
    mov  ecx, PAINT_CW
    rep  movsb
    pop  ecx
    inc  dword [paint_tmp_row]
    jmp  .blit
.blit_done:

    ; palette bar background
    mov  eax, [paint_tmp_x]
    mov  ebx, [paint_tmp_y]
    add  ebx, PAINT_CH
    mov  ecx, PAINT_W
    mov  edx, PAINT_PAL_H
    mov  esi, 0x08
    call fb_fill_rect

    ; draw color swatches
    mov  dword [paint_tmp_i], 0
.sw:
    mov  eax, [paint_tmp_i]
    cmp  eax, PAINT_NUM
    jge  .sw_done
    mov  ebx, eax
    imul ebx, (PAINT_SW + 2)
    add  ebx, [paint_tmp_x]
    add  ebx, 4
    mov  [paint_tmp_sx], ebx
    mov  ebx, [paint_tmp_y]
    add  ebx, PAINT_CH
    add  ebx, 1
    mov  [paint_tmp_sy], ebx
    mov  ebx, paint_colors
    add  ebx, [paint_tmp_i]
    movzx esi, byte [ebx]
    mov  eax, [paint_tmp_sx]
    mov  ebx, [paint_tmp_sy]
    mov  ecx, PAINT_SW
    mov  edx, PAINT_SH
    call fb_fill_rect
    ; highlight selected color
    mov  al, [paint_color]
    cmp  al, [paint_tmp_i]
    jne  .no_hl
    mov  eax, [paint_tmp_sx]
    dec  eax
    mov  ebx, [paint_tmp_sy]
    dec  ebx
    mov  ecx, PAINT_SW + 2
    mov  edx, PAINT_SH + 2
    mov  esi, 0x0F
    call fb_draw_rect_outline
.no_hl:
    inc  dword [paint_tmp_i]
    jmp  .sw
.sw_done:

    ; eraser label on first swatch
    mov  al, 'E'
    mov  ebx, [paint_tmp_x]
    add  ebx, 8
    mov  ecx, [paint_tmp_y]
    add  ecx, PAINT_CH
    add  ecx, 6
    mov  dl, 0x0F
    mov  dh, 0x00
    call fb_draw_char

    popa
    ret

; - paint_tick
; Handles drawing when left mouse button is held.
paint_tick:
    pusha
    xor  ecx, ecx
.find:
    cmp  ecx, WM_MAX_WINS
    jge  .done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+16], WM_PAINT
    jne  .next
    cmp  byte [edi+17], 1
    jne  .next
    cmp  byte [edi+18], 1
    je   .handle
.next:
    inc  ecx
    jmp  .find
.handle:
    mov  [paint_tmp_id], ecx
    test byte [mouse_btn], 0x01
    jz   .done
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    sub  eax, [edi+0]
    sub  ebx, [edi+4]
    sub  ebx, WM_TITLE_H
    cmp  ebx, PAINT_CH
    jge  .palette
    cmp  ebx, 0
    jl   .done
    cmp  eax, 0
    jl   .done
    cmp  eax, PAINT_CW
    jge  .done
    ; draw pixel into canvas buffer
    imul ebx, PAINT_CW
    add  ebx, eax
    add  ebx, PAINT_BUF
    movzx eax, byte [paint_color]
    mov  al, [paint_colors + eax]
    mov  [ebx], al
    mov  ecx, [paint_tmp_id]
    call wm_invalidate
    jmp  .done
.palette:
    cmp  ebx, PAINT_CH + PAINT_PAL_H
    jge  .done
    sub  eax, 4
    js   .done
    xor  edx, edx
    mov  ecx, (PAINT_SW + 2)
    div  ecx
    cmp  eax, PAINT_NUM
    jge  .done
    mov  [paint_color], al
    mov  ecx, [paint_tmp_id]
    call wm_invalidate
.done:
    popa
    ret

; Data
paint_colors:   db 0x00, 0x0C, 0x0A, 0x01, 0x0E, 0x0B, 0x0D, 0x0F
paint_tmp_id:   dd 0
paint_tmp_x:    dd 0
paint_tmp_y:    dd 0
paint_tmp_row:  dd 0
paint_tmp_i:    dd 0
paint_tmp_sx:   dd 0
paint_tmp_sy:   dd 0
paint_color:    db 7
