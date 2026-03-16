; ===========================================================================
; pm/wallpaper.asm  —  Desktop wallpaper loader + blitter
;
; Loads any 8-bit indexed BMP from ClaudeFS without modifying it.
; Palette split at runtime:
;   DAC slots  0-15  : system colours — NEVER touched
;   DAC slots 16-255 : wallpaper colours — BMP palette entries remapped here
;
; A 256-byte remap table (WP_REMAP) is built at load time:
;   remap[bmp_index] = 16 + bmp_index  (clamped to 255)
; Pixels are translated through this table during the blit.
; The BMP file on disk is never modified.
;
; Supports any size up to 640x480 (centred if smaller).
; Decoded+remapped pixels stored top-to-bottom at WP_BUF (0x100000).
;
; NOTE: WP_BUF is in extended memory (above 1MB). A20 must be enabled
;       before wallpaper_load is called. 0xF0000-0xFFFFF is BIOS ROM
;       (read-only), so we must use 0x100000+.
;
; Public:
;   wallpaper_load  — call once at startup after FS is ready
;   wallpaper_draw  — blit to framebuffer as bottom layer
; ===========================================================================

[BITS 32]

WP_BUF   equ 0x100000      ; 640x480 = 300KB pixel buffer (extended memory)
WP_REMAP equ 0x14B000      ; 256-byte remap table (immediately after WP_BUF)

; ---------------------------------------------------------------------------
wallpaper_load:
    pusha

    ; always build remap table first — icons/cursor depend on it
    ; even if wallpaper load fails, remap must be valid
    mov  edi, WP_REMAP
    xor  ecx, ecx
.remap_build:
    mov  eax, ecx
    add  eax, 16
    cmp  eax, 255
    jbe  .remap_store
    mov  eax, 255
.remap_store:
    mov  [edi + ecx], al
    inc  ecx
    cmp  ecx, 256
    jl   .remap_build

    mov  esi, wp_filename
    call fs_pm_find
    jc   .fail

    mov  [wp_file], eax
    mov  edi, eax

    ; validate BMP
    cmp  word [edi], 0x4D42     ; 'BM'
    jne  .fail
    cmp  word [edi+28], 8       ; 8bpp
    jne  .fail
    cmp  dword [edi+30], 0      ; no compression
    jne  .fail

    ; dimensions
    mov  eax, [edi+18]
    mov  [wp_w], eax
    mov  eax, [edi+22]
    mov  [wp_h], eax
    cmp  dword [wp_w], 640
    ja   .fail
    cmp  dword [wp_h], 480
    ja   .fail

    ; row stride (DWORD-aligned) and pixel data offset
    mov  eax, [wp_w]
    add  eax, 3
    and  eax, ~3
    mov  [wp_stride], eax
    mov  eax, [edi+10]
    mov  [wp_pixoff], eax

    ; --- load DAC slots 16-255 from BMP palette entries 0-239 ---
    ; BMP palette at file+54, each entry B G R 0 (4 bytes)
    ; Entry N goes to DAC slot 16+N
    mov  esi, [wp_file]
    add  esi, 54                ; point to BMP palette entry 0
    mov  ecx, 240               ; load 240 entries -> fills DAC slots 16-255
    mov  ebx, 16                ; starting DAC index

.pal_loop:
    mov  al, bl
    mov  dx, 0x3C8
    out  dx, al                 ; set DAC write index

    mov  dx, 0x3C9
    movzx eax, byte [esi+2]     ; R
    shr  eax, 2                 ; 8-bit -> 6-bit
    out  dx, al
    movzx eax, byte [esi+1]     ; G
    shr  eax, 2
    out  dx, al
    movzx eax, byte [esi+0]     ; B
    shr  eax, 2
    out  dx, al

    add  esi, 4
    inc  ebx
    dec  ecx
    jnz  .pal_loop

    ; --- decode BMP (bottom-up) into WP_BUF (top-down), remapping pixels ---
    mov  edi, WP_BUF
    mov  edx, [wp_h]
    dec  edx                    ; start at last BMP row (= top of screen)

.row_loop:
    mov  esi, [wp_file]
    add  esi, [wp_pixoff]
    mov  eax, edx
    imul eax, [wp_stride]
    add  esi, eax               ; ESI = source row in BMP

    mov  ecx, [wp_w]
.px_loop:
    movzx eax, byte [esi]       ; read original BMP pixel index
    movzx eax, byte [WP_REMAP + eax]  ; remap to DAC slot 16+
    mov  [edi], al
    inc  esi
    inc  edi
    dec  ecx
    jnz  .px_loop

    ; pad row to 640 with index 16 (first wallpaper slot) if image is narrower
    mov  ecx, 640
    sub  ecx, [wp_w]
    jz   .no_pad
    mov  al, 16
    rep  stosb
.no_pad:
    dec  edx
    jns  .row_loop

    mov  byte [wp_loaded], 1
    popa
    ret

.fail:
    mov  byte [wp_loaded], 0
    popa
    ret

; ---------------------------------------------------------------------------
wallpaper_draw:
    pusha

    cmp  byte [wp_loaded], 1
    jne  .solid_fill

    ; top padding rows if image shorter than 480
    mov  eax, 480
    sub  eax, [wp_h]
    jz   .blit
    shr  eax, 1                 ; centre vertically
    mov  edi, [gfx_fb_base]
    imul eax, [gfx_fb_pitch]
    mov  ecx, eax
    xor  al, al
    rep  stosb

.blit:
    ; blit row by row using explicit framebuffer row pointer
    xor  ebx, ebx               ; screen row counter (top to bottom)
.blit_loop:
    cmp  ebx, [wp_h]
    jge  .blit_done

    ; framebuffer row pointer: base + row * pitch
    mov  edi, [gfx_fb_base]
    mov  eax, [gfx_fb_pitch]
    imul eax, ebx
    add  edi, eax

    ; source pointer: WP_BUF + row * 640
    mov  esi, WP_BUF
    mov  eax, ebx
    imul eax, 640
    add  esi, eax

    mov  ecx, [wp_w]
    rep  movsb

    ; pad right side with black if image narrower than 640
    mov  ecx, 640
    sub  ecx, [wp_w]
    jz   .next_row
    xor  al, al
    rep  stosb

.next_row:
    inc  ebx
    jmp  .blit_loop

.blit_done:
    ; bottom padding rows if image shorter than 480
    mov  eax, 480
    sub  eax, [wp_h]
    jz   .done
    mov  ebx, 480
    sub  ebx, [wp_h]
    shr  ebx, 1
    add  ebx, [wp_h]            ; first bottom padding row
    mov  edi, [gfx_fb_base]
    mov  eax, [gfx_fb_pitch]
    imul eax, ebx
    add  edi, eax
    mov  eax, 480
    sub  eax, ebx
    imul eax, [gfx_fb_pitch]
    mov  ecx, eax
    xor  al, al
    rep  stosb
    jmp  .done

.solid_fill:
    xor  eax, eax
    xor  ebx, ebx
    mov  ecx, 640
    mov  edx, WM_TASKBAR_Y
    mov  esi, 0x01              ; dark blue
    call fb_fill_rect

.done:
    popa
    ret

; ---------------------------------------------------------------------------
wp_loaded:   db 0
wp_file:     dd 0
wp_w:        dd 0
wp_h:        dd 0
wp_stride:   dd 0
wp_pixoff:   dd 0
wp_filename: db 'wallpaper', 0