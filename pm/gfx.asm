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

; ---------------------------------------------------------------------------
; gfx_init
; ---------------------------------------------------------------------------
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

    ; zero MMIO so display starts black
    mov  edi, [gfx_hw_base]
    mov  ecx, GFX_PIX / 4
    xor  eax, eax
    rep  stosd

    pop  edi
    pop  ecx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; gfx_flush - blit GFX_SHADOW -> MMIO hardware framebuffer
; Call at the end of every complete draw operation.
; ---------------------------------------------------------------------------
gfx_flush:
    push eax
    push ecx
    push esi
    push edi
    mov  esi, GFX_SHADOW
    mov  edi, [gfx_hw_base]
    mov  ecx, GFX_PIX / 4
    rep  movsd
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; gfx_row_ptr - compute EDI = shadow address of pixel (EAX=x, EBX=y)
; Trashes EDI only.
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_clear - fill entire shadow with colour AL then flush
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_draw_pixel - EAX=x, EBX=y, CL=colour
; ---------------------------------------------------------------------------
fb_draw_pixel:
    push edi
    call gfx_row_ptr
    mov  [edi], cl
    pop  edi
    ret

; ---------------------------------------------------------------------------
; fb_hline - EAX=x, EBX=y, EDX=width, CL=colour
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_vline - EAX=x, EBX=y, EDX=height, CL=colour
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_set_pixel - EAX=x, EBX=y, CL=colour  (alias for fb_draw_pixel)
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_fill_rect - EAX=x, EBX=y, ECX=width, EDX=height, ESI=colour
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_draw_rect_outline - EAX=x, EBX=y, ECX=width, EDX=height, ESI=colour
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; fb_xor_rect_outline - EAX=x, EBX=y, ECX=width, EDX=height
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
gfx_fb_base:   dd GFX_SHADOW
gfx_hw_base:   dd 0
gfx_fb_pitch:  dd GFX_W
gfx_rect_x:    dd 0
gfx_rect_y:    dd 0
gfx_rect_w:    dd 0
gfx_rect_h:    dd 0
gfx_rect_col:  dd 0
