; ===========================================================================
; pm/icons.asm " Desktop icon system
; ===========================================================================
[BITS 32]

%define ICON_STRIDE   24
%define ICON_COUNT    2
%define ICON_SZ       32
%define ICON_TRANSP   1     ; BMP index 1 = dark blue = transparent background

; -
; icons_init
; -
icons_init:
    pusha
    mov  dword [icn_init_idx], 0
.loop:
    mov  ecx, [icn_init_idx]
    cmp  ecx, ICON_COUNT
    jge  .done
    imul edi, ecx, ICON_STRIDE
    add  edi, icon_table
    mov  esi, [edi+20]
    push edi
    call fs_pm_find
    pop  edi
    jc   .next
    cmp  word  [eax],    0x4D42
    jne  .next
    cmp  word  [eax+28], 8
    jne  .next
    cmp  dword [eax+18], ICON_SZ
    jne  .next
    cmp  dword [eax+22], ICON_SZ
    jne  .next
    mov  ebx, [eax+10]
    add  ebx, eax
    mov  esi, [edi+8]
    mov  dword [icn_crow], 0
.crow:
    mov  ecx, [icn_crow]
    cmp  ecx, ICON_SZ
    jge  .crowdone
    mov  eax, ICON_SZ
    dec  eax
    sub  eax, ecx
    imul eax, ICON_SZ
    add  eax, ebx
    push esi
    push edi
    mov  edi, esi
    imul ecx, ICON_SZ
    add  edi, ecx
    mov  esi, eax
    mov  ecx, ICON_SZ
    rep  movsb
    pop  edi
    pop  esi
    inc  dword [icn_crow]
    jmp  .crow
.crowdone:
    mov  byte [edi+13], 1
.next:
    inc  dword [icn_init_idx]
    jmp  .loop
.done:
    popa
    ret

; -
; icons_draw
; -
icons_draw:
    pusha
    mov  dword [icn_draw_idx], 0
.loop:
    mov  ecx, [icn_draw_idx]
    cmp  ecx, ICON_COUNT
    jge  .done
    imul edi, ecx, ICON_STRIDE
    add  edi, icon_table
    cmp  byte [edi+13], 1
    jne  .next
.no_hover:
    ; cache draw params
    mov  eax, [edi+0]
    mov  [icn_bx],  eax
    mov  eax, [edi+4]
    mov  [icn_by],  eax
    mov  eax, [edi+8]
    mov  [icn_buf], eax
    ; blit pixels " compute row ptr once per row, write across
    mov  dword [icn_row], 0
.prow:
    mov  eax, [icn_row]
    cmp  eax, ICON_SZ
    jge  .prowdone
    ; compute framebuffer row ptr: base + (icon_y + row) * pitch + icon_x
    mov  ebx, [icn_by]
    add  ebx, eax              ; y + row
    mov  edi, [gfx_fb_base]
    mov  ecx, [gfx_fb_pitch]
    imul ecx, ebx
    add  edi, ecx
    add  edi, [icn_bx]         ; edi = &fb[y+row][x]
    ; src ptr into pixel buffer for this row
    mov  eax, [icn_row]
    imul eax, ICON_SZ
    mov  esi, [icn_buf]
    add  esi, eax              ; esi = &pixels[row*32]
    ; write 32 pixels, skip transparent
    mov  dword [icn_col], 0
.pcol:
    mov  ecx, [icn_col]
    cmp  ecx, ICON_SZ
    jge  .pnextrow
    movzx eax, byte [esi+ecx]
    cmp  al, ICON_TRANSP
    je   .pskip
    mov  [edi+ecx], al
.pskip:
    inc  dword [icn_col]
    jmp  .pcol
.pnextrow:
    inc  dword [icn_row]
    jmp  .prow
.prowdone:
    ; draw label centred below icon " reload edi first
    mov  ecx, [icn_draw_idx]
    imul edi, ecx, ICON_STRIDE
    add  edi, icon_table
    mov  esi, [edi+16]
    push esi
    xor  ecx, ecx
.slen:
    cmp  byte [esi+ecx], 0
    je   .slen_done
    inc  ecx
    jmp  .slen
.slen_done:
    shl  ecx, 3
    mov  eax, ICON_SZ
    sub  eax, ecx
    sar  eax, 1
    add  eax, [edi+0]
    mov  ebx, eax
    pop  esi
    mov  ecx, [edi+4]
    add  ecx, ICON_SZ + 3
    mov  dl,  0x0F
    mov  dh,  0xFF
    call fb_draw_string
.next:
    inc  dword [icn_draw_idx]
    jmp  .loop
.done:
    popa
    ret

; -
; icons_hover " update hover flags, set icn_hover_changed if any flipped
; -
icons_hover:
    pusha
    mov  dword [icn_hover_idx], 0
    mov  byte  [icn_hover_changed], 0
.loop:
    mov  ecx, [icn_hover_idx]
    cmp  ecx, ICON_COUNT
    jge  .done
    imul edi, ecx, ICON_STRIDE
    add  edi, icon_table
    cmp  byte [edi+13], 1
    jne  .next
    mov  bl, 0
    mov  eax, [mouse_x]
    mov  ecx, [edi+0]
    cmp  eax, ecx
    jl   .set
    add  ecx, ICON_SZ
    cmp  eax, ecx
    jg   .set
    mov  eax, [mouse_y]
    mov  ecx, [edi+4]
    cmp  eax, ecx
    jl   .set
    add  ecx, ICON_SZ
    cmp  eax, ecx
    jg   .set
    mov  bl, 1
.set:
    cmp  bl, [edi+14]
    je   .next
    mov  [edi+14], bl
    mov  byte [icn_hover_changed], 1
.next:
    inc  dword [icn_hover_idx]
    jmp  .loop
.done:
    popa
    ret

; -
; icons_click " EAX=x EBX=y; CF=1 hit, CF=0 miss
; -
icons_click:
    push ecx
    push edi
    mov  [icn_cx], eax
    mov  [icn_cy], ebx
    mov  dword [icn_click_idx], 0
.loop:
    mov  ecx, [icn_click_idx]
    cmp  ecx, ICON_COUNT
    jge  .miss
    imul edi, ecx, ICON_STRIDE
    add  edi, icon_table
    cmp  byte [edi+13], 1
    jne  .next
    mov  eax, [icn_cx]
    mov  ebx, [edi+0]
    cmp  eax, ebx
    jl   .next
    add  ebx, ICON_SZ
    cmp  eax, ebx
    jg   .next
    mov  eax, [icn_cy]
    mov  ebx, [edi+4]
    cmp  eax, ebx
    jl   .next
    add  ebx, ICON_SZ + 10
    cmp  eax, ebx
    jg   .next
    ; hit " open by type
    movzx eax, byte [edi+12]
    cmp  eax, 0
    jne  .chk_clock
    call pm_cmd_term
    jmp  .hit
.chk_clock:
    cmp  eax, 1
    jne  .do_files
    mov  al,  WM_CLOCK
    mov  ebx, 420
    mov  ecx, 50
    mov  edx, 160
    mov  esi, 80
    call wm_open
    call wm_draw_all
    jmp  .hit
.do_files:
    mov  al,  WM_FILES
    mov  ebx, 420
    mov  ecx, 50
    mov  edx, 210
    mov  esi, 200
    call wm_open
    jc   .hit
    call wm_draw_files
    call wm_draw_all
    jmp  .hit
.hit:
    stc
    pop  edi
    pop  ecx
    ret
.next:
    inc  dword [icn_click_idx]
    jmp  .loop
.miss:
    clc
    pop  edi
    pop  ecx
    ret

; -
; icons_redraw_column " repaint just the left icon column (no full redraw)
; -
icons_redraw_column:
    pusha
    ; fill icon column with desktop colour
    xor  eax, eax              ; x=0
    xor  ebx, ebx              ; y=0
    mov  ecx, 110              ; width of icon column
    mov  edx, WM_TASKBAR_Y     ; height up to taskbar
    mov  esi, WM_C_DESK
    call fb_fill_rect
    ; redraw icons on top
    call icons_draw
    popa
    ret
icn_init_idx:      dd 0
icn_draw_idx:      dd 0
icn_hover_idx:     dd 0
icn_click_idx:     dd 0
icn_hover_changed: db 0
icn_crow:          dd 0
icn_row:           dd 0
icn_col:           dd 0
icn_bx:            dd 0
icn_by:            dd 0
icn_buf:           dd 0
icn_cx:            dd 0
icn_cy:            dd 0

icon_pixels_term:  times (ICON_SZ*ICON_SZ) db ICON_TRANSP
icon_pixels_clock: times (ICON_SZ*ICON_SZ) db ICON_TRANSP
icon_pixels_files: times (ICON_SZ*ICON_SZ) db ICON_TRANSP

icon_lbl_term:  db 'Terminal', 0
icon_lbl_clock: db 'Clock', 0
icon_lbl_files: db 'Files', 0

icon_fn_term:   db 'icon_term', 0
icon_fn_clock:  db 'icon_clock', 0
icon_fn_files:  db 'icon_files', 0

icon_table:
    dd 39,  20,  icon_pixels_term
    db 0, 0, 0, 0
    dd icon_lbl_term,  icon_fn_term

    dd 39,  78, icon_pixels_files
    db 2, 0, 0, 0
    dd icon_lbl_files, icon_fn_files