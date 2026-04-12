; ===========================================================================
; pm/mouse.asm - PS/2 mouse driver (polling, 3-byte packets)
;
; Public:
;   mouse_init   - call once from pm_entry, after gfx_init
;   mouse_poll   - call in main loop; moves cursor on new packets
;
; State (read-only externally):
;   mouse_x   dd   0..639
;   mouse_y   dd   0..479
;   mouse_btn db   bit0=L, bit1=R, bit2=M
; ===========================================================================

[BITS 32]

%define PORT_DATA   0x60
%define PORT_STATUS 0x64
%define PORT_CMD    0x64

; -
; mouse_init
; -
mouse_init:
    pusha

    mov  dword [mouse_x],       320
    mov  dword [mouse_y],       240
    mov  byte  [mouse_btn],     0
    mov  byte  [mouse_pkt_idx], 0

.flush_loop:
    in   al, PORT_STATUS
    test al, 0x01
    jz   .flush_done
    in   al, PORT_DATA
    jmp  .flush_loop
.flush_done:

    ; enable aux port
    call .kww
    mov  al, 0xA8
    out  PORT_CMD, al

    ; read controller command byte, CLEAR aux-IRQ enable (polling mode), clear aux-clock-disable
    call .kww
    mov  al, 0x20
    out  PORT_CMD, al
    call .kwr
    in   al, PORT_DATA
    and  al, 0xFD              ; CLEAR bit 1 (IRQ12 enable) - polling mode!
    and  al, 0xDF              ; clear bit 5 (aux-clock-disable)
    and  al, 0xFE              ; clear bit 0 (IRQ1 enable) - polling mode for keyboard too!
    push eax
    call .kww
    mov  al, 0x60
    out  PORT_CMD, al
    call .kww
    pop  eax
    out  PORT_DATA, al

    jmp  $+2
    jmp  $+2

    ; send 0xF4 (enable data reporting) to mouse
    call .kww
    mov  al, 0xD4
    out  PORT_CMD, al
    call .kww
    mov  al, 0xF4
    out  PORT_DATA, al
    call .kwr
    in   al, PORT_DATA          ; discard ACK

    call cursor_draw
    popa
    ret

; wait until 8042 input buffer empty (ok to write)
.kww:
    in   al, PORT_STATUS
    test al, 0x02
    jnz  .kww
    ret

; wait until 8042 output buffer full (ok to read)
.kwr:
    in   al, PORT_STATUS
    test al, 0x01
    jz   .kwr
    ret

; -
; mouse_poll  " call every iteration of main loop
; -
mouse_poll:
    pusha
.again:
    in   al, PORT_STATUS
    test al, 0x01           ; any data?
    jz   .out
    test al, 0x20           ; aux data specifically?
    jz   .out
    in   al, PORT_DATA

    movzx ebx, byte [mouse_pkt_idx]
    mov   [mouse_pkt + ebx], al
    inc   bl
    cmp   bl, 3
    jl    .store
    mov   byte [mouse_pkt_idx], 0
    call  .process
    jmp   .again
.store:
    mov   [mouse_pkt_idx], bl
    jmp   .again
.out:
    popa
    ret

.process:
    ; erase cursor at CURRENT position before updating coords
    call cursor_erase

    ; buttons
    mov  al, [mouse_pkt]
    and  al, 0x07
    mov  [mouse_btn], al

    ; X (signed, bit4 of flags = overflow sign)
    movsx eax, byte [mouse_pkt+1]
    test  byte [mouse_pkt], 0x10
    jz    .xp
    or    eax, 0xFFFFFF00
.xp:
    add   eax, [mouse_x]
    cmp   eax, 0 
    jge   .xnn
    xor   eax, eax
.xnn:
    cmp   eax, 639
    jle   .xok
    mov   eax, 639
.xok:
    mov   [mouse_x], eax

    ; Y (inverted)
    movsx eax, byte [mouse_pkt+2]
    test  byte [mouse_pkt], 0x20
    jz    .yp
    or    eax, 0xFFFFFF00
.yp:
    neg   eax
    add   eax, [mouse_y]
    cmp   eax, 0
    jge   .ynn
    xor   eax, eax
.ynn:
    cmp   eax, 479
    jle   .yok
    mov   eax, 479
.yok:
    mov   [mouse_y], eax

    ; draw cursor at NEW position (cursor_draw saves bg first)
    call  cursor_draw
    ret

; -
; cursor_size  "  returns cursor dimension in EAX (12 or 16)
cursor_size:
    cmp  byte [cursor_use_bmp], 1
    jne  .small
    mov  eax, 16
    ret
.small:
    mov  eax, 12
    ret

; -
; cursor_save_bg  " save pixels under cursor into cursor_bg
; Size depends on cursor_use_bmp (12 or 16).
; -
cursor_save_bg:
    pusha
    call cursor_size
    mov  [.sz], eax
    xor  esi, esi            ; row
.srow:
    mov  eax, [.sz]
    cmp  esi, eax
    jge  .sdone

    mov  eax, [mouse_y]
    add  eax, esi
    cmp  eax, 479
    jg   .snext
    mov  edx, [gfx_fb_pitch]
    mul  edx
    add  eax, [gfx_fb_base]
    add  eax, [mouse_x]

    xor  ecx, ecx
.scol:
    mov  edx, [.sz]
    cmp  ecx, edx
    jge  .snext
    mov  ebx, [mouse_x]
    add  ebx, ecx
    cmp  ebx, 639
    jg   .snext

    push eax
    mov  bl, [eax + ecx]
    mov  eax, esi
    mov  edx, [.sz]
    imul eax, edx
    add  eax, ecx
    mov  [cursor_bg + eax], bl
    pop  eax

    inc  ecx
    jmp  .scol
.snext:
    inc  esi
    jmp  .srow
.sdone:
    popa
    ret
.sz: dd 12

cursor_erase:
    pusha
    call cursor_size
    mov  [cursor_save_bg.sz], eax   ; reuse the size var
    xor  esi, esi
.erow:
    mov  eax, [cursor_save_bg.sz]
    cmp  esi, eax
    jge  .edone
    mov  eax, [mouse_y]
    add  eax, esi
    cmp  eax, 479
    jg   .enext
    mov  edx, [gfx_fb_pitch]
    mul  edx
    add  eax, [gfx_fb_base]
    add  eax, [mouse_x]

    xor  ecx, ecx
.ecol:
    mov  edx, [cursor_save_bg.sz]
    cmp  ecx, edx
    jge  .enext
    mov  ebx, [mouse_x]
    add  ebx, ecx
    cmp  ebx, 639
    jg   .enext

    push eax
    mov  eax, esi
    mov  edx, [cursor_save_bg.sz]
    imul eax, edx
    add  eax, ecx
    mov  bl, [cursor_bg + eax]
    pop  eax
    mov  [eax + ecx], bl

    inc  ecx
    jmp  .ecol
.enext:
    inc  esi
    jmp  .erow
.edone:
    popa
    ret

; -
; cursor_load_bmp  "  load cursor pixels from "cursor" file in ClaudeFS
;
; Reads a 16x16 8bpp BMP.  On success sets cursor_use_bmp=1 and fills
; cursor_bmp_pixels[256] with the 16x16 palette-index pixels (top row first).
; Transparent colour index is stored in cursor_bmp_transp.
;
; BMP on-disk layout:
;   bytes  0-1   'BM'
;   bytes  2-5   file size
;   bytes 10-13  pixel data offset
;   bytes 14-53  BITMAPINFOHEADER (40 bytes)
;     +0  dword  header size = 40
;     +4  dword  width
;     +8  dword  height  (positive = bottom-up)
;    +28  word   bits per pixel (must be 8)
;   After header: 256-4 byte palette, then pixel rows (bottom-up)
; -
cursor_load_bmp:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; ask fs_pm_find for file named "cursor"
    mov  esi, cursor_bmp_name
    call fs_pm_find
    jc   .fail              ; not found

    ; EAX = ptr to BMP data, ECX = file size
    mov  edi, eax           ; EDI = BMP base

    ; validate BM magic
    cmp  word [edi], 0x4D42         ; 'BM'
    jne  .fail

    ; must be 8bpp
    cmp  word [edi + 14 + 14], 8    ; biPlanes=2 offset from DIB header
    ; actually biBitCount is at DIB+14 = file offset 28
    cmp  word [edi + 28], 8
    jne  .fail

    ; width and height must be 16
    cmp  dword [edi + 18], 16       ; biWidth
    jne  .fail
    ; biHeight may be negative (top-down) " we only handle positive (bottom-up)
    mov  eax, [edi + 22]            ; biHeight
    cmp  eax, 16
    jne  .fail

    ; pixel data offset
    mov  eax, [edi + 10]            ; bfOffBits
    add  eax, edi                   ; absolute pointer to pixel rows

    ; BMP rows are bottom-up: row 0 on disk = bottom row of image.
    ; We want top row first in cursor_bmp_pixels, so read rows in reverse.
    ; Row i on disk starts at: pixel_base + (15-i)*16
    mov  ecx, 0             ; destination row (0=top)
.rowloop:
    cmp  ecx, 16
    jge  .loaded

    ; source row = row (15 - ecx) in BMP  = bottom-up
    mov  edx, 15
    sub  edx, ecx
    imul edx, 16            ; byte offset within pixel data
    add  edx, eax           ; edx = source ptr for this row

    ; destination in cursor_bmp_pixels
    push eax
    mov  edi, cursor_bmp_pixels
    push ecx
    imul ecx, 16
    add  edi, ecx           ; edi = destination row ptr
    pop  ecx

    ; copy 16 bytes raw " cursor uses system colours 0-15, no remap needed
    push ecx
    push esi
    mov  esi, edx
    mov  ecx, 16
    rep  movsb
    pop  esi
    pop  ecx
    pop  eax

    inc  ecx
    jmp  .rowloop

.loaded:
    ; The transparent colour index is the desktop background colour (0x01 = dark blue).
    ; Store it so cursor_draw_bmp can skip transparent pixels.
    mov  byte [cursor_bmp_transp], 0x01  ; index 1 = dark blue = transparent
    mov  byte [cursor_use_bmp],    1
    jmp  .done

.fail:
    mov  byte [cursor_use_bmp], 0  ; fall back to built-in arrow

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; cursor_draw " save bg then blit cursor (bitmap if loaded, else arrow)
; -
cursor_draw:
    call cursor_save_bg

    cmp  byte [cursor_use_bmp], 1
    je   cursor_draw_bmp

    ; - built-in 12-12 two-pass arrow -
    pusha
    mov  dword [cursor_draw_colour], 0x00
    mov  esi, cursor_outline
    call cursor_blit
    mov  dword [cursor_draw_colour], 0x0F
    mov  esi, cursor_fill
    call cursor_blit
    popa
    ret

; -
; cursor_draw_bmp  "  blit 16-16 indexed pixels from cursor_bmp_pixels
; Skips pixels whose index == cursor_bmp_transp
; -
cursor_draw_bmp:
    pusha
    xor  esi, esi               ; row index (0 = top)
.brow:
    cmp  esi, 16
    jge  .bdone

    mov  eax, [mouse_y]
    add  eax, esi
    cmp  eax, 479
    jg   .bnext

    mov  edx, [gfx_fb_pitch]
    mul  edx
    add  eax, [gfx_fb_base]
    add  eax, [mouse_x]         ; eax = &fb[mouse_y+row][mouse_x]

    xor  ecx, ecx               ; col
.bcol:
    cmp  ecx, 16
    jge  .bnext

    mov  edx, [mouse_x]
    add  edx, ecx
    cmp  edx, 639
    jg   .bnext

    ; get pixel index from cursor_bmp_pixels
    push eax
    mov  edi, esi
    imul edi, 16
    add  edi, ecx
    movzx ebx, byte [cursor_bmp_pixels + edi]
    pop  eax

    ; skip transparent
    cmp  bl, [cursor_bmp_transp]
    je   .bskip

    mov  [eax + ecx], bl        ; write palette index directly to framebuffer

.bskip:
    inc  ecx
    jmp  .bcol

.bnext:
    inc  esi
    jmp  .brow

.bdone:
    popa
    ret

; cursor_blit: ESI = 12-byte bitmask, colour = [cursor_draw_colour]
cursor_blit:
    pusha
    xor  edi, edi            ; row
.row:
    cmp  edi, 12
    jge  .done

    mov  eax, [mouse_y]
    add  eax, edi
    cmp  eax, 479
    jg   .next

    mov  edx, [gfx_fb_pitch]
    mul  edx
    add  eax, [gfx_fb_base]
    add  eax, [mouse_x]      ; eax = &fb[y+row][x]

    movzx ebx, byte [esi + edi]  ; bitmap byte for this row

    xor  ecx, ecx            ; col
.col:
    cmp  ecx, 12
    jge  .next

    mov  edx, [mouse_x]
    add  edx, ecx
    cmp  edx, 639
    jg   .next

    ; test bit (7-col), only 8 bits wide so cols 8-11 are always 0
    cmp  ecx, 8
    jge  .skip
    mov  edx, 7
    sub  edx, ecx
    bt   ebx, edx
    jnc  .skip

    mov  dl, [cursor_draw_colour]
    mov  [eax + ecx], dl

.skip:
    inc  ecx
    jmp  .col

.next:
    inc  edi
    jmp  .row

.done:
    popa
    ret

; -
; Data
; -
mouse_x:            dd 320
mouse_y:            dd 240
mouse_btn:          db 0
mouse_pkt_idx:      db 0
                    dw 0
mouse_pkt:          db 0, 0, 0
                    db 0
cursor_draw_colour: dd 0

cursor_bg:  times 256 db 0   ; up to 16-16 saved background

; - BMP cursor data -
cursor_use_bmp:      db 0           ; 1 = use bitmap cursor, 0 = use arrow
cursor_bmp_transp:   db 0x01       ; palette index treated as transparent
                     dw 0           ; align
cursor_bmp_pixels:   times 256 db 0 ; 16-16 palette-index pixel data (top-row first)
cursor_bmp_name:     db 'cursor', 0 ; ClaudeFS filename to search

; 12x12 arrow cursor
; Row by row, MSB=leftmost, 8 bits used (cols 0-7), rows 0-11
;
; Outline (black border):  Fill (white interior):
; X-             -
; XX-             X-
; X0X-             X0-
; X00X-             X00-
; X000X-             X000-
; X0000X-             X0000-
; X00000X-             X00000-
; X000000X-             X000000-
; X0000XXX-             X0000-
; X00X.X-             X00-
; X0X..X-             X0-
; XX...XX-             -

cursor_outline:
    db 10000000b  ; row  0  X
    db 11000000b  ; row  1  XX
    db 10100000b  ; row  2  X X
    db 10010000b  ; row  3  X  X
    db 10001000b  ; row  4  X   X
    db 10000100b  ; row  5  X    X
    db 10000010b  ; row  6  X     X
    db 10011110b  ; row  7  X  XXXX
    db 10110000b  ; row  8  X XX
    db 11010000b  ; row  9  XX X
    db 10001000b  ; row 10  X   X
    db 00000000b  ; row 11

cursor_fill:
    db 00000000b  ; row  0
    db 00000000b  ; row  1
    db 00000000b  ; row  2
    db 01100000b  ; row  3   **
    db 00110000b  ; row  4    **
    db 00011000b  ; row  5     **
    db 00001100b  ; row  6      **
    db 00000000b  ; row  7
    db 00000000b  ; row  8
    db 00000000b  ; row  9
    db 00000000b  ; row 10
    db 00000000b  ; row 11
