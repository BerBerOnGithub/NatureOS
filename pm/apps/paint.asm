; ===========================================================================
; pm/apps/paint.asm - Simple pixel drawing application
;
; Opens a window with a canvas. Click and drag to draw pixels.
; Palette bar at bottom switches colors; first swatch is eraser (black).
; F2 = Load canvas.bmp, F3 = Save canvas.bmp (8-bit indexed BMP)
; ===========================================================================
[BITS 32]

PAINT_W     equ 400
PAINT_H     equ 300
PAINT_CW    equ PAINT_W
PAINT_CH    equ 236
PAINT_BUF   equ 0x660000
PAINT_PAL_H equ 30
PAINT_SW    equ 22
PAINT_SH    equ 22
PAINT_NUM   equ 8
PAINT_TB_H  equ 16

; BMP scratch buffer placed after canvas (0x660000 + 400*236 = 0x676F40 -> use 0x677000)
PAINT_BMP_BUF   equ 0x677000
; BMP layout: 14 (BITMAPFILEHEADER) + 40 (BITMAPINFOHEADER) + 1024 (palette) + pixels
PAINT_BMP_HDR   equ 54
PAINT_BMP_PAL   equ 1024
PAINT_BMP_OFF   equ (PAINT_BMP_HDR + PAINT_BMP_PAL)   ; pixel data offset = 1078
PAINT_BMP_PIX   equ (PAINT_CW * PAINT_CH)             ; pixel bytes (400*236=94400, already DWORD-aligned)
PAINT_BMP_SIZE  equ (PAINT_BMP_OFF + PAINT_BMP_PIX)   ; total file size

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

    ; --- toolbar ---
    mov  eax, [paint_tmp_x]
    mov  ebx, [paint_tmp_y]
    mov  ecx, PAINT_W
    mov  edx, PAINT_TB_H
    mov  esi, 0x07
    call fb_fill_rect

    mov  esi, paint_str_help
    mov  ebx, [paint_tmp_x]
    add  ebx, 4
    mov  ecx, [paint_tmp_y]
    add  ecx, 4
    mov  dl, 0x00
    mov  dh, 0x07
    call fb_draw_string

    ; blit canvas buffer to shadow framebuffer
    mov  dword [paint_tmp_row], 0
.blit:
    mov  eax, [paint_tmp_row]
    cmp  eax, PAINT_CH
    jge  .blit_done
    mov  edi, [gfx_fb_base]
    mov  ebx, [paint_tmp_y]
    add  ebx, PAINT_TB_H
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
    add  ebx, PAINT_TB_H
    mov  ecx, PAINT_W
    mov  edx, PAINT_PAL_H
    mov  esi, 0x07
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
    add  ebx, PAINT_TB_H
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
    add  ecx, PAINT_TB_H
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

    ; --- keyboard: F2=load, F3=save ---
.keyloop:
    call pm_getkey
    or   ax, ax
    jz   .keys_done
    cmp  al, 0
    jne  .keyloop           ; ignore ASCII keys
    cmp  ah, 0x3C           ; F2 = Load
    je   .load
    cmp  ah, 0x3D           ; F3 = Save
    je   .save
    jmp  .keyloop
.load:
    mov  esi, paint_filename
    call fsd_find
    jc   .keyloop
    ; read BMP into scratch buffer
    mov  edi, PAINT_BMP_BUF
    call fsd_read_file
    ; decode: pixel data starts at PAINT_BMP_OFF, stored bottom-up
    ; row 0 of canvas = last row in BMP, row (CH-1) = first row in BMP
    mov  dword [paint_tmp_row], 0
.load_row:
    mov  eax, [paint_tmp_row]
    cmp  eax, PAINT_CH
    jge  .load_done
    ; src: BMP row (CH-1-row) from pixel data area
    mov  ebx, PAINT_CH - 1
    sub  ebx, eax
    imul ebx, PAINT_CW
    add  ebx, PAINT_BMP_BUF + PAINT_BMP_OFF
    ; dst: canvas row 'row'
    mov  ecx, eax
    imul ecx, PAINT_CW
    add  ecx, PAINT_BUF
    ; copy one row
    push esi
    push edi
    mov  esi, ebx
    mov  edi, ecx
    mov  ecx, PAINT_CW
    rep  movsb
    pop  edi
    pop  esi
    inc  dword [paint_tmp_row]
    jmp  .load_row
.load_done:
    mov  ecx, [paint_tmp_id]
    call wm_invalidate
    jmp  .keyloop
.save:
    ; --- build BMP in scratch buffer ---
    ; zero the header area
    mov  edi, PAINT_BMP_BUF
    mov  ecx, PAINT_BMP_OFF / 4
    xor  eax, eax
    rep  stosd
    ; BITMAPFILEHEADER (14 bytes)
    ;   bfType      = 'BM'  (0x4D42)
    ;   bfSize      = total file size
    ;   bfReserved1 = 0
    ;   bfReserved2 = 0
    ;   bfOffBits   = offset to pixel data = PAINT_BMP_OFF
    mov  word  [PAINT_BMP_BUF + 0],  0x4D42
    mov  dword [PAINT_BMP_BUF + 2],  PAINT_BMP_SIZE
    mov  dword [PAINT_BMP_BUF + 6],  0
    mov  dword [PAINT_BMP_BUF + 10], PAINT_BMP_OFF
    ; BITMAPINFOHEADER (40 bytes) at offset 14
    ;   biSize          = 40
    ;   biWidth         = PAINT_CW
    ;   biHeight        = PAINT_CH  (positive = bottom-up)
    ;   biPlanes        = 1
    ;   biBitCount      = 8
    ;   biCompression   = 0 (BI_RGB)
    ;   biSizeImage     = 0 (allowed for BI_RGB)
    ;   biXPelsPerMeter = 0
    ;   biYPelsPerMeter = 0
    ;   biClrUsed       = 256
    ;   biClrImportant  = 0
    mov  dword [PAINT_BMP_BUF + 14], 40
    mov  dword [PAINT_BMP_BUF + 18], PAINT_CW
    mov  dword [PAINT_BMP_BUF + 22], PAINT_CH
    mov  word  [PAINT_BMP_BUF + 26], 1
    mov  word  [PAINT_BMP_BUF + 28], 8
    mov  dword [PAINT_BMP_BUF + 30], 0
    mov  dword [PAINT_BMP_BUF + 34], 0
    mov  dword [PAINT_BMP_BUF + 38], 0
    mov  dword [PAINT_BMP_BUF + 42], 0
    mov  dword [PAINT_BMP_BUF + 46], 256
    mov  dword [PAINT_BMP_BUF + 50], 0
    ; --- write 256-color CGA palette (BGRA, 4 bytes each) at offset 54 ---
    ; Each entry: B G R 0x00
    ; We only define 16 CGA colors; entries 16-255 stay zero (black)
    mov  esi, paint_cga_palette
    mov  edi, PAINT_BMP_BUF + PAINT_BMP_HDR
    mov  ecx, 16
.pal_loop:
    mov  al, [esi]       ; B
    mov  [edi+0], al
    mov  al, [esi+1]     ; G
    mov  [edi+1], al
    mov  al, [esi+2]     ; R
    mov  [edi+2], al
    mov  byte [edi+3], 0 ; reserved
    add  esi, 3
    add  edi, 4
    loop .pal_loop
    ; remaining 240 entries already zeroed
    ; --- write pixel data bottom-up ---
    ; BMP row 0 = canvas row (CH-1), BMP row (CH-1) = canvas row 0
    mov  dword [paint_tmp_row], 0
.save_row:
    mov  eax, [paint_tmp_row]
    cmp  eax, PAINT_CH
    jge  .save_pixels_done
    ; src canvas row: (CH-1 - paint_tmp_row)
    mov  ebx, PAINT_CH - 1
    sub  ebx, eax
    imul ebx, PAINT_CW
    add  ebx, PAINT_BUF
    ; dst BMP pixel row
    mov  ecx, eax
    imul ecx, PAINT_CW
    add  ecx, PAINT_BMP_BUF + PAINT_BMP_OFF
    push esi
    push edi
    mov  esi, ebx
    mov  edi, ecx
    mov  ecx, PAINT_CW
    rep  movsb
    pop  edi
    pop  esi
    inc  dword [paint_tmp_row]
    jmp  .save_row
.save_pixels_done:
    ; --- write BMP file ---
    mov  esi, paint_filename
    call fsd_delete
    mov  esi, paint_filename
    mov  dword [fsd_create_data], PAINT_BMP_BUF
    mov  ecx, PAINT_BMP_SIZE
    call fsd_create
    jmp  .keyloop
.keys_done:
    ; re-derive edi (FS calls may have clobbered it)
    mov  ecx, [paint_tmp_id]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    test byte [mouse_btn], 0x01
    jz   .done
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    sub  eax, [edi+0]
    sub  ebx, [edi+4]
    sub  ebx, WM_TITLE_H
    sub  ebx, PAINT_TB_H
    cmp  ebx, PAINT_CH
    jge  .palette
    cmp  ebx, 0
    jl   .done
    cmp  eax, 0
    jl   .done
    cmp  eax, PAINT_CW
    jge  .done
    ; draw line from last position to current position (Bresenham)
    mov  [paint_cur_x], eax
    mov  [paint_cur_y], ebx
    ; if no previous point, seed it
    cmp  byte [paint_has_prev], 0
    je   .seed_prev
    jmp  .do_line
.seed_prev:
    mov  eax, [paint_cur_x]
    mov  [paint_prev_x], eax
    mov  eax, [paint_cur_y]
    mov  [paint_prev_y], eax
    mov  byte [paint_has_prev], 1
.do_line:
    ; Bresenham setup: x0=[paint_prev_x] y0=[paint_prev_y] x1=[paint_cur_x] y1=[paint_cur_y]
    mov  eax, [paint_prev_x]
    mov  [paint_bx0], eax
    mov  eax, [paint_prev_y]
    mov  [paint_by0], eax
    mov  eax, [paint_cur_x]
    mov  [paint_bx1], eax
    mov  eax, [paint_cur_y]
    mov  [paint_by1], eax
    ; dx = abs(x1-x0)
    mov  eax, [paint_bx1]
    sub  eax, [paint_bx0]
    mov  [paint_bdx], eax
    jge  .dx_pos
    neg  eax
    mov  [paint_bdx], eax
    mov  dword [paint_bsx], -1
    jmp  .dy_calc
.dx_pos:
    mov  dword [paint_bsx], 1
.dy_calc:
    ; dy = abs(y1-y0)
    mov  eax, [paint_by1]
    sub  eax, [paint_by0]
    mov  [paint_bdy], eax
    jge  .dy_pos
    neg  eax
    mov  [paint_bdy], eax
    mov  dword [paint_bsy], -1
    jmp  .err_calc
.dy_pos:
    mov  dword [paint_bsy], 1
.err_calc:
    ; err = dx - dy
    mov  eax, [paint_bdx]
    sub  eax, [paint_bdy]
    mov  [paint_berr], eax
    ; current position = x0, y0
    mov  eax, [paint_bx0]
    mov  [paint_bpx], eax
    mov  eax, [paint_by0]
    mov  [paint_bpy], eax
.bline_loop:
    ; plot pixel at (paint_bpx, paint_bpy)
    mov  eax, [paint_bpy]
    cmp  eax, 0
    jl   .bline_skip
    cmp  eax, PAINT_CH
    jge  .bline_skip
    mov  ebx, [paint_bpx]
    cmp  ebx, 0
    jl   .bline_skip
    cmp  ebx, PAINT_CW
    jge  .bline_skip
    imul eax, PAINT_CW
    add  eax, ebx
    add  eax, PAINT_BUF
    movzx ebx, byte [paint_color]
    mov  bl, [paint_colors + ebx]
    mov  [eax], bl
.bline_skip:
    ; check if reached x1,y1
    mov  eax, [paint_bpx]
    cmp  eax, [paint_bx1]
    jne  .bline_cont
    mov  eax, [paint_bpy]
    cmp  eax, [paint_by1]
    je   .bline_done
.bline_cont:
    ; e2 = 2*err
    mov  eax, [paint_berr]
    add  eax, eax
    mov  [paint_be2], eax
    ; if e2 > -dy: err -= dy, x += sx
    mov  ebx, [paint_bdy]
    neg  ebx
    cmp  eax, ebx
    jle  .skip_x
    mov  ebx, [paint_bdy]
    sub  [paint_berr], ebx
    mov  ebx, [paint_bsx]
    add  [paint_bpx], ebx
.skip_x:
    ; if e2 < dx: err += dx, y += sy
    mov  eax, [paint_be2]
    cmp  eax, [paint_bdx]
    jge  .skip_y
    mov  ebx, [paint_bdx]
    add  [paint_berr], ebx
    mov  ebx, [paint_bsy]
    add  [paint_bpy], ebx
.skip_y:
    jmp  .bline_loop
.bline_done:
    ; update prev to cur
    mov  eax, [paint_cur_x]
    mov  [paint_prev_x], eax
    mov  eax, [paint_cur_y]
    mov  [paint_prev_y], eax
    mov  ecx, [paint_tmp_id]
    call wm_invalidate
    jmp  .done
.palette:
    cmp  ebx, PAINT_CH + PAINT_PAL_H + PAINT_TB_H
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
    ; clear prev point when mouse released
    test byte [mouse_btn], 0x01
    jnz  .keep_prev
    mov  byte [paint_has_prev], 0
.keep_prev:
    popa
    ret

; Data
paint_str_help:  db '[F2] Load  [F3] Save  File: canvas.bmp', 0
paint_filename:  db 'canvas.bmp', 0
paint_colors:   db 0x00, 0x0C, 0x0A, 0x01, 0x0E, 0x0B, 0x0D, 0x0F

; CGA 16-color palette in BGR order (for BMP palette table)
; Index: 0=black 1=blue 2=green 3=cyan 4=red 5=magenta 6=brown 7=lt.gray
;        8=dk.gray 9=lt.blue 10=lt.green 11=lt.cyan 12=lt.red 13=lt.magenta 14=yellow 15=white
paint_cga_palette:
    db 0x00, 0x00, 0x00   ; 0  black
    db 0xAA, 0x00, 0x00   ; 1  blue
    db 0x00, 0xAA, 0x00   ; 2  green
    db 0xAA, 0xAA, 0x00   ; 3  cyan
    db 0x00, 0x00, 0xAA   ; 4  red
    db 0xAA, 0x00, 0xAA   ; 5  magenta
    db 0x00, 0x55, 0xAA   ; 6  brown
    db 0xAA, 0xAA, 0xAA   ; 7  light gray
    db 0x55, 0x55, 0x55   ; 8  dark gray
    db 0xFF, 0x55, 0x55   ; 9  light blue
    db 0x55, 0xFF, 0x55   ; 10 light green
    db 0xFF, 0xFF, 0x55   ; 11 light cyan
    db 0x55, 0x55, 0xFF   ; 12 light red
    db 0xFF, 0x55, 0xFF   ; 13 light magenta
    db 0x55, 0xFF, 0xFF   ; 14 yellow
    db 0xFF, 0xFF, 0xFF   ; 15 white
paint_tmp_id:   dd 0
paint_tmp_x:    dd 0
paint_tmp_y:    dd 0
paint_tmp_row:  dd 0
paint_tmp_i:    dd 0
paint_tmp_sx:   dd 0
paint_tmp_sy:   dd 0
paint_color:    db 7
; Bresenham line drawing state
paint_has_prev: db 0
paint_prev_x:   dd 0
paint_prev_y:   dd 0
paint_cur_x:    dd 0
paint_cur_y:    dd 0
paint_bx0:      dd 0
paint_by0:      dd 0
paint_bx1:      dd 0
paint_by1:      dd 0
paint_bdx:      dd 0
paint_bdy:      dd 0
paint_bsx:      dd 0
paint_bsy:      dd 0
paint_berr:     dd 0
paint_be2:      dd 0
paint_bpx:      dd 0
paint_bpy:      dd 0
