; ===========================================================================
; pm/gfx.asm - Framebuffer graphics primitives
;
; SHADOW FRAMEBUFFER ARCHITECTURE:
;   All drawing goes to GFX_SHADOW (RAM at 0x500000).
;   gfx_flush() blits shadow -> MMIO hardware framebuffer.
;   Screenshots read from GFX_SHADOW - never touch MMIO for reads.
;
; gfx_init sets:
;   gfx_fb_base  = GFX_SHADOW  (all draw calls write here)
;   gfx_hw_base  = vbe_physbase (MMIO, write-only destination for flush)
;   gfx_fb_pitch = 640          (hardcoded - shadow is always 640 wide)
;
; Public interface:
;   gfx_init          - initialise shadow buffer, call once after PM entry
;   gfx_flush         - blit shadow -> MMIO, call after every complete draw
;   fb_fill_rect      - EAX=x, EBX=y, ECX=w, EDX=h, ESI=colour
;   fb_draw_pixel     - EAX=x, EBX=y, CL=colour
;   fb_hline          - EAX=x, EBX=y, EDX=width, CL=colour
;   fb_vline          - EAX=x, EBX=y, EDX=height, CL=colour
;   fb_clear          - AL=colour, fills entire 640x480
;   gfx_row_ptr       - EAX=x, EBX=y -> EDI=shadow address of pixel
; ===========================================================================

[BITS 32]

GFX_SHADOW   equ 0x500000    ; 640*480 = 307200 bytes RAM shadow buffer
GFX_W        equ 640
GFX_H        equ 480
GFX_PIX      equ GFX_W * GFX_H

; -
; gfx_init
; -
gfx_init:
    push eax
    push ecx
    push edi

    ; cache MMIO address for flush (write-only)
    mov  eax, [vbe_physbase]
    mov  [gfx_hw_base], eax

    ; drawing always goes to shadow buffer in RAM
    mov  dword [gfx_fb_base],  GFX_SHADOW
    mov  dword [gfx_fb_pitch], GFX_W      ; shadow pitch is always exactly 640

    ; zero shadow buffer
    mov  edi, GFX_SHADOW
    mov  ecx, GFX_PIX / 4
    xor  eax, eax
    rep  stosd

    ; zero MMIO only if vbe_physbase is valid (above 1MB) - never zero low memory
    mov  edi, [gfx_hw_base]
    cmp  edi, 0x100000       ; sanity check: must be above 1MB
    jb   .skip_mmio_zero
    mov  ecx, GFX_PIX / 4
    xor  eax, eax
    rep  stosd
.skip_mmio_zero:
    pop  edi
    pop  ecx
    pop  eax
    ret

; -
; gfx_flush - blit only dirty rows from GFX_SHADOW -> MMIO hardware framebuffer
; Uses gfx_dirty_y0 / gfx_dirty_y1 to limit what gets copied.
; Call gfx_mark_dirty before drawing to expand the dirty region.
; Call gfx_flush_full for a guaranteed full blit (e.g. after wm_draw_all).
; -
gfx_flush:
    push eax
    push ecx
    push esi
    push edi
    ; if nothing dirty, skip
    mov  eax, [gfx_dirty_y0]
    cmp  eax, 480
    jge  .gf_done
    ; clamp y1
    mov  ecx, [gfx_dirty_y1]
    cmp  ecx, 480
    jle  .gf_y1ok
    mov  ecx, 480
.gf_y1ok:
    ; rows to copy = y1 - y0
    sub  ecx, eax
    jle  .gf_done
    ; src = GFX_SHADOW + y0*640
    mov  esi, GFX_SHADOW
    imul eax, 640
    add  esi, eax
    ; dst = gfx_hw_base + y0*640
    mov  edi, [gfx_hw_base]
    mov  eax, [gfx_dirty_y0]
    imul eax, 640
    add  edi, eax
    ; copy ecx rows * 640 bytes = ecx*160 dwords
    imul ecx, 160
    rep  movsd
    ; reset dirty region
    mov  dword [gfx_dirty_y0], 480
    mov  dword [gfx_dirty_y1], 0
.gf_done:
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

; gfx_flush_full - blit entire shadow buffer to MMIO (use after wm_draw_all)
gfx_flush_full:
    push eax
    push ecx
    push esi
    push edi
    mov  esi, GFX_SHADOW
    mov  edi, [gfx_hw_base]
    mov  ecx, GFX_PIX / 4
    rep  movsd
    mov  dword [gfx_dirty_y0], 480
    mov  dword [gfx_dirty_y1], 0
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

; gfx_mark_dirty - expand dirty region to include rows EAX..EBX (inclusive)
; In: EAX=y_top, EBX=y_bottom
gfx_mark_dirty:
    push eax
    push ebx
    cmp  eax, [gfx_dirty_y0]
    jge  .md_y0ok
    mov  [gfx_dirty_y0], eax
.md_y0ok:
    inc  ebx
    cmp  ebx, [gfx_dirty_y1]
    jle  .md_y1ok
    mov  [gfx_dirty_y1], ebx
.md_y1ok:
    pop  ebx
    pop  eax
    ret

; -
; gfx_row_ptr - compute EDI = shadow address of pixel (EAX=x, EBX=y)
; Trashes EDI only.
; -
gfx_row_ptr:
    push eax
    push edx
    mov  edi, GFX_SHADOW
    mov  edx, GFX_W
    imul edx, ebx
    add  edi, edx
    add  edi, eax
    pop  edx
    pop  eax
    ret

; -
; fb_clear - fill entire shadow with colour AL then flush
; -
fb_clear:
    push eax
    push ecx
    push edi
    movzx eax, al
    mov  edi, GFX_SHADOW
    mov  ecx, GFX_PIX
    rep  stosb
    pop  edi
    pop  ecx
    pop  eax
    ret

; -
; fb_draw_pixel - EAX=x, EBX=y, CL=colour
; -
fb_draw_pixel:
    push edi
    call gfx_row_ptr
    mov  [edi], cl
    pop  edi
    ret

; -
; fb_hline - EAX=x, EBX=y, EDX=width, CL=colour
; -
fb_hline:
    push ecx
    push edi
    call gfx_row_ptr
    mov  ecx, edx
    movzx eax, cl
    rep  stosb
    pop  edi
    pop  ecx
    ret

; -
; fb_vline - EAX=x, EBX=y, EDX=height, CL=colour
; -
fb_vline:
    push eax
    push ebx
    push edx
    push edi
.vl:
    test edx, edx
    jz   .vd
    call gfx_row_ptr
    mov  [edi], cl
    inc  ebx
    dec  edx
    jmp  .vl
.vd:
    pop  edi
    pop  edx
    pop  ebx
    pop  eax
    ret

; -
; fb_set_pixel - EAX=x, EBX=y, CL=colour  (alias for fb_draw_pixel)
; -
fb_set_pixel:
    push edi
    push edx
    push eax
    mov  edi, GFX_SHADOW
    mov  edx, GFX_W
    imul edx, ebx
    add  edi, edx
    add  edi, eax
    mov  [edi], cl
    pop  eax
    pop  edx
    pop  edi
    ret

; -
; fb_fill_rect - EAX=x, EBX=y, ECX=width, EDX=height, ESI=colour
; -
fb_fill_rect:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov  [gfx_rect_x],   eax
    mov  [gfx_rect_w],   ecx
    mov  [gfx_rect_col], esi
.fr:
    test edx, edx
    jz   .fd
    mov  eax, [gfx_rect_x]
    call gfx_row_ptr
    mov  ecx, [gfx_rect_w]
    movzx eax, byte [gfx_rect_col]
    push ecx
.fi:
    mov  [edi], al
    inc  edi
    loop .fi
    pop  ecx
    inc  ebx
    dec  edx
    jmp  .fr
.fd:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; fb_draw_rect_outline - EAX=x, EBX=y, ECX=width, EDX=height, ESI=colour
; -
fb_draw_rect_outline:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    mov  [gfx_rect_x], eax
    mov  [gfx_rect_y], ebx
    mov  [gfx_rect_w], ecx
    mov  [gfx_rect_h], edx
    mov  [gfx_rect_col], esi
    mov  cl, byte [gfx_rect_col]
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    mov  edx, [gfx_rect_w]
    call fb_hline
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    add  ebx, [gfx_rect_h]
    dec  ebx
    mov  edx, [gfx_rect_w]
    call fb_hline
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    mov  edx, [gfx_rect_h]
    call fb_vline
    mov  eax, [gfx_rect_x]
    add  eax, [gfx_rect_w]
    dec  eax
    mov  ebx, [gfx_rect_y]
    mov  edx, [gfx_rect_h]
    call fb_vline
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; fb_xor_rect_outline - EAX=x, EBX=y, ECX=width, EDX=height
; -
fb_xor_rect_outline:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    mov  [gfx_rect_x], eax
    mov  [gfx_rect_y], ebx
    mov  [gfx_rect_w], ecx
    mov  [gfx_rect_h], edx
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    call gfx_row_ptr
    mov  ecx, [gfx_rect_w]
.xt: xor  byte [edi], 0xFF
    inc  edi
    loop .xt
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    add  ebx, [gfx_rect_h]
    dec  ebx
    call gfx_row_ptr
    mov  ecx, [gfx_rect_w]
.xb: xor  byte [edi], 0xFF
    inc  edi
    loop .xb
    mov  eax, [gfx_rect_x]
    mov  ebx, [gfx_rect_y]
    mov  ecx, [gfx_rect_h]
.xl: call gfx_row_ptr
    xor  byte [edi], 0xFF
    inc  ebx
    loop .xl
    mov  eax, [gfx_rect_x]
    add  eax, [gfx_rect_w]
    dec  eax
    mov  ebx, [gfx_rect_y]
    mov  ecx, [gfx_rect_h]
.xr: call gfx_row_ptr
    xor  byte [edi], 0xFF
    inc  ebx
    loop .xr
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; Data
; -
gfx_fb_base:   dd GFX_SHADOW
gfx_hw_base:   dd 0
gfx_fb_pitch:  dd GFX_W
gfx_rect_x:    dd 0
gfx_rect_y:    dd 0
gfx_rect_w:    dd 0
gfx_rect_h:    dd 0
gfx_dirty_y0:  dd 480      ; start at 480 = nothing dirty
gfx_dirty_y1:  dd 0
gfx_rect_col:  dd 0
