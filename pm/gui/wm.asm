; ===========================================================================
; pm/wm.asm  -  NatureOS Window Manager
;
; Up to WM_MAX_WINS windows.  Window types: TERM, CLOCK, FILES.
; Supports dragging by title bar, close button, focus.
;
; Window record  (WM_STRIDE bytes):
;   [+0]  dd  x
;   [+4]  dd  y
;   [+8]  dd  w
;  [+12]  dd  h
;  [+16]  db  type   (WM_TERM / WM_CLOCK / WM_FILES)
;  [+17]  db  open   (1 = visible)
;  [+18]  db  focus  (1 = active / topmost)
;  [+19]  db  dirty  (1 = needs redraw)
;  [+20]  dd  title  (pointer to null-terminated string)
;  [+24]  db  z_order
;  [+25] .. [+31]  reserved
;
; Calling conventions used in this file:
;   fb_fill_rect        EAX=x EBX=y ECX=w EDX=h ESI=colour
;   fb_draw_rect_outline EAX=x EBX=y ECX=w EDX=h ESI=colour
;   fb_hline            EAX=x EBX=y EDX=width CL=colour
;   fb_draw_string      ESI=str EBX=x ECX=y DL=fg DH=bg
;
; Public:
;   wm_init             once at startup
;   wm_draw_all         full redraw (desktop + windows + taskbar)
;   wm_open             AL=type EBX=x ECX=y EDX=w ESI=h  +' ECX=idx CF=1 full
;   wm_close            ECX=idx
;   wm_on_click         EAX=mx EBX=my  (call on left-button press)
;   wm_on_drag          (call each mouse-move while left held)
;   wm_on_release       (call on left-button release)
;   wm_update_contents  refresh live windows (clock, files)
; ===========================================================================

[BITS 32]

; - tunables -
WM_MAX_WINS   equ 8
WM_STRIDE     equ 32
WM_TITLE_H    equ 18        ; title bar pixel height
WM_TASKBAR_Y  equ 462       ; 480 - 18
WM_TASKBAR_H  equ 18

WM_TERM       equ 0
WM_CLOCK      equ 1
WM_FILES      equ 2
WM_HELP       equ 3
WM_BROWSER    equ 4
WM_TASKMAN    equ 5
WM_NOTEPAD    equ 6
WM_PAINT      equ 7

; colours
WM_C_DESK     equ 0x01      ; dark blue desktop
WM_C_TBAR     equ 0x08      ; dark grey taskbar
WM_C_TACT     equ 0x09      ; bright blue active title
WM_C_TINACT   equ 0x08      ; inactive title (same grey as taskbar)
WM_C_BODY     equ 0x00      ; black client area
WM_C_BORDER   equ 0x07      ; grey border
WM_C_CLOSE    equ 0x04      ; red close button
WM_SHADOW_OFS equ 4         ; drop shadow offset in pixels
WM_C_SHADOW   equ 0x08      ; dark grey shadow

; - wm_init -
wm_init:
    pusha

    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 0x200000
    push eax
    popfd
    pushfd
    pop  eax
    xor  eax, ecx
    jz   .no_cpu_brand
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .no_cpu_brand
    mov eax, 0x80000002
    cpuid
    mov [si_cpu_brand], eax
    mov [si_cpu_brand+4], ebx
    mov [si_cpu_brand+8], ecx
    mov [si_cpu_brand+12], edx
    mov eax, 0x80000003
    cpuid
    mov [si_cpu_brand+16], eax
    mov [si_cpu_brand+20], ebx
    mov [si_cpu_brand+24], ecx
    mov [si_cpu_brand+28], edx
    mov eax, 0x80000004
    cpuid
    mov [si_cpu_brand+32], eax
    mov [si_cpu_brand+36], ebx
    mov [si_cpu_brand+40], ecx
    mov [si_cpu_brand+44], edx
    mov byte [si_cpu_brand+48], 0

    ; trim leading spaces
    mov esi, si_cpu_brand
.trim_l:
    cmp byte [esi], ' '
    jne .trim_ok
    inc esi
    jmp .trim_l
.trim_ok:
    mov edi, si_cpu_brand
.copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    test al, al
    jnz .copy

.no_cpu_brand:

    mov  edi, wm_table
    mov  ecx, (WM_MAX_WINS * WM_STRIDE) / 4
    xor  eax, eax
    rep  stosd
    mov  dword [wm_drag_win], -1
    call wm_draw_all

    popa
    ret

; - wm_draw_desktop -
wm_draw_desktop:
    pusha
    ; draw wallpaper (or solid fill fallback) " bottom layer
    call wallpaper_draw
    call wm_draw_sysinfo

    ; - desktop watermark (bottom-right, right-aligned) -
    ; 'NatureOS' = 8 chars * 8px = 64px  -> x = 640 - 64 - 4 = 572
    mov  esi, wm_s_watermark_os
    mov  ebx, 572
    mov  ecx, WM_TASKBAR_Y - 20
    mov  dl,  0x0F              ; white
    mov  dh,  0xFF              ; transparent bg
    call fb_draw_string
    ; 'Build 2.0.0' = 11 chars * 8px = 88px -> x = 640 - 88 - 4 = 548
    mov  esi, wm_s_watermark_build
    mov  ebx, 548
    mov  ecx, WM_TASKBAR_Y - 10
    mov  dl,  0x0F
    mov  dh,  0xFF
    call fb_draw_string

    ; taskbar strip
    xor  eax, eax
    mov  ebx, WM_TASKBAR_Y
    mov  ecx, 640
    mov  edx, WM_TASKBAR_H
    mov  esi, WM_C_TBAR
    call fb_fill_rect
    ; taskbar top separator line
    xor  eax, eax
    mov  ebx, WM_TASKBAR_Y
    mov  edx, 640
    mov  cl,  0x0F
    call fb_hline
    ; "NatureOS" start button (x=2, y=taskbar+2, w=82, h=taskbar_h-4)
    mov  eax, 2
    mov  ebx, WM_TASKBAR_Y + 2
    mov  ecx, 82
    mov  edx, WM_TASKBAR_H - 4
    mov  esi, 0x01              ; dark blue fill
    call fb_fill_rect
    mov  eax, 2
    mov  ebx, WM_TASKBAR_Y + 2
    mov  ecx, 82
    mov  edx, WM_TASKBAR_H - 4
    mov  esi, 0x0F
    call fb_draw_rect_outline
    mov  esi, wm_s_brand
    mov  ebx, 6
    mov  ecx, WM_TASKBAR_Y + 6
    mov  dl,  0x0F
    mov  dh,  0x01
    call fb_draw_string
    popa
    ret

; - wm_draw_one -
; Draws one window chrome (title bar, border, close btn).
; For WM_TERM the client area is NOT cleared " terminal manages its own pixels.
; ECX = index.  Preserves all registers.
wm_draw_one:
    pusha
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .skip

    mov  eax, [edi+0]
    mov  ebx, [edi+4]
    mov  ecx, [edi+8]
    mov  edx, [edi+12]

    ; - drop shadow (drawn before window body so body covers overlap) -
    push eax
    push ebx
    push ecx
    push edx
    add  eax, WM_SHADOW_OFS
    add  ebx, WM_SHADOW_OFS
    ; clip shadow width to screen right edge
    mov  esi, eax
    add  esi, ecx
    cmp  esi, 640
    jle  .shadow_w_ok
    mov  ecx, 640
    sub  ecx, eax
.shadow_w_ok:
    ; clip shadow height to taskbar top
    mov  esi, ebx
    add  esi, edx
    cmp  esi, WM_TASKBAR_Y
    jle  .shadow_h_ok
    mov  edx, WM_TASKBAR_Y
    sub  edx, ebx
.shadow_h_ok:
    mov  esi, WM_C_SHADOW
    call fb_fill_rect
    ; mark shadow rows dirty
    push eax
    push ebx
    mov  eax, ebx
    lea  ebx, [ebx+edx]
    call gfx_mark_dirty
    pop  ebx
    pop  eax
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; - fill entire window rect first to erase anything underneath -
    push eax
    push ebx
    push ecx
    push edx
    mov  esi, WM_C_BODY
    call fb_fill_rect
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; - client area - already covered by full fill above, kept for clarity -

    ; - title bar -
    push eax
    push ebx
    push ecx
    push edx
    mov  edx, WM_TITLE_H
    mov  esi, WM_C_TINACT
    cmp  byte [edi+18], 1
    jne  .tb
    mov  esi, WM_C_TACT
.tb:
    call fb_fill_rect
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; - outer border -
    push eax
    push ebx
    push ecx
    push edx
    mov  esi, WM_C_BORDER
    call fb_draw_rect_outline
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; - close button (red rectangle, top-right of title bar) -
    push eax
    push ebx
    push ecx
    push edx
    add  eax, ecx               ; x + w
    sub  eax, 18                ; x of close box = winx+w-18
    add  ebx, 2
    push eax                    ; save box_x
    push ebx                    ; save box_y
    mov  ecx, 14
    mov  edx, 14
    mov  esi, WM_C_CLOSE
    call fb_fill_rect
    ; draw white X over the button (2px thick, 2px margin)
    pop  ebx                    ; box_y
    pop  eax                    ; box_x
    call wm_draw_close_x
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax

    ; - title text -
    push eax
    push ecx
    mov  esi, [edi+20]          ; title string pointer
    mov  ecx, [edi+4]
    add  ecx, 5                 ; y = win_y + 5
    mov  ebx, [edi+0]
    add  ebx, 6                 ; x = win_x + 6
    mov  dl,  0x0F
    mov  dh,  WM_C_TINACT
    cmp  byte [edi+18], 1
    jne  .tt
    mov  dh, WM_C_TACT
.tt:
    call fb_draw_string
    pop  ecx
    pop  eax

.skip:
    popa
    ret



; - wm_hide_startmenu -
; - wm_fmt_size -
; Convert byte count in EAX to short string at EDI.
; Shows bytes if < 1024, else KB.  e.g. "512b" or "4Kb"
; Trashes EAX, EBX, ECX, EDX. EDI advanced.
wm_fmt_size:
    push edi
    cmp  eax, 1024
    jl   .bytes
    ; KB: eax/1024
    xor  edx, edx
    mov  ecx, 1024
    div  ecx
    ; EAX = KB value
    call .write_dec
    mov  byte [edi], 'K'
    inc  edi
    jmp  .suffix
.bytes:
    call .write_dec
.suffix:
    mov  byte [edi], 'b'
    inc  edi
    mov  byte [edi], 0
    pop  edi
    ret
.write_dec:
    ; write decimal EAX to [EDI], advance EDI
    push eax
    push ebx
    push ecx
    push edx
    mov  ecx, 0
    mov  ebx, 10
.wd_push:
    xor  edx, edx
    div  ebx
    push edx
    inc  ecx
    test eax, eax
    jnz  .wd_push
.wd_pop:
    pop  edx
    add  dl, '0'
    mov  [edi], dl
    inc  edi
    loop .wd_pop
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret


; - wm_invalidate -
; Mark window ECX as dirty (needs redraw next frame)
wm_invalidate:
    push edi
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+19], 1
    pop  edi
    ret

; - wm_invalidate_all -
; Mark all open windows dirty
wm_invalidate_all:
    push eax
    push edi
    xor  eax, eax
.ia_loop:
    cmp  eax, WM_MAX_WINS
    jge  .ia_done
    imul edi, eax, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .ia_next
    mov  byte [edi+19], 1
.ia_next:
    inc  eax
    jmp  .ia_loop
.ia_done:
    pop  edi
    pop  eax
    ret

; - wm_draw_all -
; Full redraw - redraws desktop, marks all windows dirty, then flushes.
; Use for major events: window open/close, focus change, drag release.
; For incremental updates use wm_invalidate + let main loop handle it.
wm_draw_all:
    pusha
    call cursor_erase
    call wm_draw_desktop
    call icons_draw
    ; draw windows in z-order sweep (lowest z first)
    mov  dword [wm_z], 0
.zloop:
    mov  eax, [wm_z]
    cmp  eax, WM_MAX_WINS
    jge  .zdone
    mov  dword [wm_i], 0
.wloop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .wnext_z
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .wnext
    cmp  byte [edi+24], al
    jne  .wnext
    call wm_draw_one
    cmp  byte [edi+16], WM_TERM
    jne  .wcontent
    call term_redraw
    jmp  .wnext
.wcontent:
    cmp  byte [edi+16], WM_CLOCK
    je   .wclock
    cmp  byte [edi+16], WM_FILES
    je   .wfiles
    cmp  byte [edi+16], WM_HELP
    je   .whelp
    cmp  byte [edi+16], WM_BROWSER
    je   .wbrowser
    cmp  byte [edi+16], WM_TASKMAN
    je   .wtaskman
    cmp  byte [edi+16], WM_NOTEPAD
    je   .wnotepad
    cmp  byte [edi+16], WM_PAINT
    je   .wpaint
    jmp  .wnext
.wclock:
    call wm_draw_clock
    jmp  .wnext
.wfiles:
    call wm_draw_files
    jmp  .wnext
.whelp:
    call wm_draw_help
    jmp  .wnext
.wbrowser:
    call browser_draw
    jmp  .wnext
.wtaskman:
    call taskman_draw
    jmp  .wnext
.wnotepad:
    call notepad_draw
    jmp  .wnext
.wpaint:
    call paint_draw
.wnext:
    inc  dword [wm_i]
    jmp  .wloop
.wnext_z:
    inc  dword [wm_z]
    jmp  .zloop
.zdone:
    ; clear dirty flags on all windows after full redraw
    mov  dword [wm_i], 0
.clr_dirty:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .clr_done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+19], 0
    inc  dword [wm_i]
    jmp  .clr_dirty
.clr_done:
    call wm_draw_taskbar_btns
    cmp  byte [sm_open], 1
    jne  .no_sm_all
    call wm_draw_startmenu
.no_sm_all:
    call ctx_draw               ; draw context menu on top of everything
    call cursor_save_bg
    call cursor_draw
    call gfx_flush_full
    popa
    ret

; - wm_draw_dirty -
; Incremental redraw: only redraws windows marked dirty.
; Call from main loop each frame instead of wm_draw_all.
; - wm_draw_dirty -
; Incremental redraw: only redraws windows marked dirty.
; Call from main loop each frame instead of wm_draw_all.
wm_draw_dirty:
    pusha
    ; check if any window is dirty, or if global UI refresh is needed
    cmp  byte [gfx_dirty], 1
    je   .chk_hit
    cmp  byte [icn_hover_changed], 1
    je   .chk_hit

    xor  eax, eax
    mov  byte [wm_any_dirty], 0
.chk_loop:
    cmp  eax, WM_MAX_WINS
    jge  .chk_done
    imul edi, eax, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .chk_next
    cmp  byte [edi+19], 1
    jne  .chk_next
.chk_hit:
    mov  byte [wm_any_dirty], 1
    jmp  .chk_done
.chk_next:
    inc  eax
    jmp  .chk_loop
.chk_done:
    cmp  byte [wm_any_dirty], 0
    je   .dd_done               ; nothing dirty, skip
    
    call cursor_erase
    
    ; redraw dirty windows (and anything above them) in z-order sweep
    mov  byte [wm_dirty_hit], 0
    mov  dword [wm_z], 0
.dd_zloop:
    mov  eax, [wm_z]
    cmp  eax, WM_MAX_WINS
    jge  .dd_zdone
    mov  dword [wm_i], 0
.dd_wloop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .dd_wnext_z
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .dd_wnext
    cmp  byte [edi+24], al      ; current z?
    jne  .dd_wnext
    
    ; is this window dirty?
    cmp  byte [edi+19], 1
    je   .dd_mark_hit
    ; or was a window below it dirty?
    cmp  byte [wm_dirty_hit], 1
    jne  .dd_wnext

.dd_mark_hit:
    mov  byte [wm_dirty_hit], 1

    ; expand dirty flush region for this window (y to y+h)
    push eax
    push ebx
    mov  eax, [edi+4]
    mov  ebx, eax
    add  ebx, [edi+12]
    call gfx_mark_dirty
    pop  ebx
    pop  eax
    
    call wm_draw_one
    cmp  byte [edi+16], WM_TERM
    jne  .dd_wcontent
    call term_redraw
    jmp  .dd_wnext
.dd_wcontent:
    cmp  byte [edi+16], WM_CLOCK
    je   .dd_wclock
    cmp  byte [edi+16], WM_FILES
    je   .dd_wfiles
    cmp  byte [edi+16], WM_HELP
    je   .dd_whelp
    cmp  byte [edi+16], WM_BROWSER
    je   .dd_wbrowser
    cmp  byte [edi+16], WM_TASKMAN
    je   .dd_wtaskman
    cmp  byte [edi+16], WM_NOTEPAD
    je   .dd_wnotepad
    cmp  byte [edi+16], WM_PAINT
    je   .dd_wpaint
    jmp  .dd_wnext
.dd_wclock:
    call wm_draw_clock
    jmp  .dd_wnext
.dd_wfiles:
    call wm_draw_files
    jmp  .dd_wnext
.dd_whelp:
    call wm_draw_help
    jmp  .dd_wnext
.dd_wbrowser:
    call browser_draw
    jmp  .dd_wnext
.dd_wtaskman:
    call taskman_draw
    jmp  .dd_wnext
.dd_wnotepad:
    call notepad_draw
    jmp  .dd_wnext
.dd_wpaint:
    call paint_draw
    jmp  .dd_wnext
.dd_wnext:
    inc  dword [wm_i]
    jmp  .dd_wloop
.dd_wnext_z:
    inc  dword [wm_z]
    jmp  .dd_zloop
.dd_zdone:
    ; redraw taskbar and start menu last to keep them on top
    call wm_draw_taskbar_btns
    cmp  byte [sm_open], 1
    jne  .dd_no_sm
    call wm_draw_startmenu
.dd_no_sm:
    call ctx_draw               ; draw context menu on top

    ; clear all dirty flags
    mov  dword [wm_i], 0
.dd_clr:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .dd_clrdone
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+19], 0
    inc  dword [wm_i]
    jmp  .dd_clr
    
.dd_clrdone:
    mov  byte [gfx_dirty], 0
    mov  byte [icn_hover_changed], 0
    
    call cursor_save_bg
    call cursor_draw
    call gfx_flush
.dd_done:
    popa
    ret

wm_any_dirty: db 0
wm_dirty_hit: db 0

; - wm_open -
; In:  AL=type  EBX=x  ECX=y  EDX=w  ESI=h
; Out: ECX=new index (unchanged if error);  CF=1 table full
wm_open:
    push eax
    push esi
    push edi

    ; save params before we clobber registers
    movzx eax, al
    mov  [wm_op_type], eax
    mov  [wm_op_x],    ebx
    mov  [wm_op_y],    ecx
    mov  [wm_op_w],    edx
    mov  [wm_op_h],    esi

    ; find a free slot -> ECX
    xor  ecx, ecx
.find:
    cmp  ecx, WM_MAX_WINS
    jge  .full
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 0
    je   .fill
    inc  ecx
    jmp  .find

.fill:
    mov  eax, [wm_op_x]
    mov  [edi+0],  eax
    mov  eax, [wm_op_y]
    mov  [edi+4],  eax
    mov  eax, [wm_op_w]
    mov  [edi+8],  eax
    mov  eax, [wm_op_h]
    mov  [edi+12], eax
    mov  eax, [wm_op_type]
    mov  [edi+16], al
    mov  byte [edi+17], 1       ; open
    mov  byte [edi+18], 1       ; focused
    mov  byte [edi+19], 1       ; dirty - needs first draw

    ; pick title string
    cmp  eax, WM_TERM
    jne  .t1
    mov  dword [edi+20], wm_s_term
    jmp  .title_ok
.t1:
    cmp  eax, WM_CLOCK
    jne  .t2
    mov  dword [edi+20], wm_s_clock
    jmp  .title_ok
.t2:
    cmp  eax, WM_FILES
    jne  .t3
    mov  dword [edi+20], wm_s_files
    jmp  .title_ok
.t3:
    cmp  eax, WM_HELP
    jne  .t4
    mov  dword [edi+20], wm_s_help
    jmp  .title_ok
.t4:
    cmp  eax, WM_BROWSER
    jne  .t5
    mov  dword [edi+20], wm_s_browser
    jmp  .title_ok
.t5:
    cmp  eax, WM_TASKMAN
    jne  .t6
    mov  dword [edi+20], wm_s_taskman
    jmp  .title_ok
.t6:
    cmp  eax, WM_NOTEPAD
    jne  .t7
    mov  dword [edi+20], wm_s_notepad
    jmp  .title_ok
.t7:
    mov  dword [edi+20], wm_s_paint
.title_ok:

    ; count existing open windows to assign z_order
    push ecx
    push edi
    xor  eax, eax
    mov  byte [wm_tmp_zcnt], 0
.zcnt_loop:
    cmp  eax, WM_MAX_WINS
    jge  .zcnt_done
    cmp  eax, [esp+4]           ; skip the newly opened one (saved ecx)
    je   .zcnt_skip
    imul esi, eax, WM_STRIDE
    add  esi, wm_table
    cmp  byte [esi+17], 1
    jne  .zcnt_skip
    inc  byte [wm_tmp_zcnt]
.zcnt_skip:
    inc  eax
    jmp  .zcnt_loop
.zcnt_done:
    pop  edi
    pop  ecx
    movzx eax, byte [wm_tmp_zcnt]
    mov  byte [edi+24], al      ; z_order = number of existing open windows

    ; clear focus on all other windows
    push ecx
    push edi
    xor  eax, eax
.clrf:
    cmp  eax, WM_MAX_WINS
    jge  .clrf_done
    cmp  eax, [esp+4]           ; skip the newly opened one (saved ecx)
    je   .clrf_skip
    imul esi, eax, WM_STRIDE
    add  esi, wm_table
    mov  byte [esi+18], 0
.clrf_skip:
    inc  eax
    jmp  .clrf
.clrf_done:
    pop  edi
    pop  ecx

    clc
    jmp  .out

.full:
    stc

.out:
    pop  edi
    pop  esi
    pop  eax
    ret

; - wm_close -
; In: ECX = index
wm_close:
    pusha
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    movzx eax, byte [edi+24]    ; save closed window z_order
    mov  [wm_tmp_zclosed], eax
    mov  byte [edi+17], 0
    mov  byte [edi+18], 0
    mov  byte [edi+24], 0

    ; decrement z_order of all windows above the closed one
    xor  ecx, ecx
.zdec:
    cmp  ecx, WM_MAX_WINS
    jge  .zdec_done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .zdec_next
    movzx eax, byte [edi+24]
    cmp  eax, [wm_tmp_zclosed]
    jle  .zdec_next
    dec  byte [edi+24]
.zdec_next:
    inc  ecx
    jmp  .zdec
.zdec_done:

    ; focus the window with the highest z_order
    xor  ecx, ecx
    mov  byte [wm_tmp_ztop], 0
    mov  dword [wm_tmp_itop], 0
.rf:
    cmp  ecx, WM_MAX_WINS
    jge  .rf_done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .rf_next
    movzx eax, byte [edi+24]
    cmp  al, [wm_tmp_ztop]
    jle  .rf_next
    mov  [wm_tmp_ztop], al
    mov  [wm_tmp_itop], ecx
.rf_next:
    inc  ecx
    jmp  .rf
.rf_done:
    mov  ecx, [wm_tmp_itop]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+18], 1
    call wm_draw_all

    popa
    ret

; - wm_set_focus -
; In: ECX = index to focus
wm_set_focus:
    pusha
    xor  eax, eax
.clear:
    cmp  eax, WM_MAX_WINS
    jge  .set
    imul edi, eax, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+18], 0
    inc  eax
    jmp  .clear
.set:
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  byte [edi+18], 1
    call wm_raise_to_top
    popa
    ret

; - wm_raise_to_top -
; In: ECX = index to raise
wm_raise_to_top:
    pusha
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 0
    je   .done
    movzx eax, byte [edi+24]    ; current z_order
    mov  [wm_tmp_zcurr], eax

    ; count open windows to compute new top z
    xor  eax, eax
    mov  byte [wm_tmp_zcnt], 0
.cnt:
    cmp  eax, WM_MAX_WINS
    jge  .cnt_done
    imul esi, eax, WM_STRIDE
    add  esi, wm_table
    cmp  byte [esi+17], 1
    jne  .cnt_skip
    inc  byte [wm_tmp_zcnt]
.cnt_skip:
    inc  eax
    jmp  .cnt
.cnt_done:

    ; shift all windows with higher z down by 1
    xor  eax, eax
.shift:
    cmp  eax, WM_MAX_WINS
    jge  .shift_done
    cmp  eax, ecx
    je   .shift_skip
    imul esi, eax, WM_STRIDE
    add  esi, wm_table
    cmp  byte [esi+17], 1
    jne  .shift_skip
    movzx ebx, byte [esi+24]
    cmp  ebx, [wm_tmp_zcurr]
    jle  .shift_skip
    dec  byte [esi+24]
.shift_skip:
    inc  eax
    jmp  .shift
.shift_done:

    ; set target window to top z = num_open - 1
    movzx eax, byte [wm_tmp_zcnt]
    dec  eax
    mov  byte [edi+24], al
.done:
    popa
    ret

; - wm_draw_close_x -
; Draws a white X inside the 14x14 close button.
; In: EAX=box_x, EBX=box_y
wm_draw_close_x:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push eax                    ; push box_x onto stack (can't use ECX - CL needed for colour)
    push ebx                    ; push box_y onto stack
    xor  esi, esi               ; i = 0
.xloop:
    cmp  esi, 10
    jge  .xdone
    ; diagonal 1: top-left to bottom-right (2px thick)
    mov  eax, [esp+4]           ; box_x
    add  eax, 2
    add  eax, esi
    mov  ebx, [esp]             ; box_y
    add  ebx, 2
    add  ebx, esi
    mov  cl, 0x0F
    call fb_set_pixel
    inc  eax
    call fb_set_pixel
    ; diagonal 2: top-right to bottom-left (2px thick)
    mov  eax, [esp+4]           ; box_x
    add  eax, 11
    sub  eax, esi
    mov  ebx, [esp]             ; box_y
    add  ebx, 2
    add  ebx, esi
    mov  cl, 0x0F
    call fb_set_pixel
    dec  eax
    call fb_set_pixel
    inc  esi
    jmp  .xloop
.xdone:
    add  esp, 8                 ; pop box_x and box_y
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - wm_draw_scrollbar -
; Draws a vertical scrollbar. Needs variables wm_sb_x, wm_sb_y, wm_sb_w, wm_sb_h,
; wm_sb_total, wm_sb_visible, wm_sb_pos set before calling.
; Preserves all general registers.
wm_draw_scrollbar:
    pusha
    
    ; 1. Draw track background
    mov  eax, [wm_sb_x]
    mov  ebx, [wm_sb_y]
    mov  ecx, [wm_sb_w]
    mov  edx, [wm_sb_h]
    mov  esi, 0x08           ; dark grey track
    call fb_fill_rect
    
    ; 2. Calculate thumb size and position
    mov  esi, [wm_sb_total]
    mov  edi, [wm_sb_visible]
    
    ; if visible >= total, thumb fills track
    cmp  edi, esi
    jge  .full_thumb
    
    ; thumb height = (visible * track_height) / total
    mov  eax, edi
    mov  ecx, edx            ; ECX = track_height
    imul ecx                 ; EAX = visible * track_height
    xor  edx, edx
    div  esi                 ; EAX = thumb_height
    
    ; enforce minimum thumb height of 8 pixels
    cmp  eax, 8
    jge  .th_ok
    mov  eax, 8
.th_ok:
    mov  ebp, eax            ; EBP = thumb_height
    
    ; max thumb position = track_height - thumb_height
    mov  ecx, [wm_sb_h]
    sub  ecx, ebp            ; ECX = max_scroll_y
    
    ; thumb_y = (scroll_pos * max_scroll_y) / (total - visible)
    mov  eax, [wm_sb_pos]
    imul ecx                 ; EAX = pos * max_scroll_y
    mov  ecx, esi
    sub  ecx, edi            ; ECX = total - visible
    test ecx, ecx
    jz   .full_thumb         ; avoid div by zero if calculated total-visible=0
    xor  edx, edx
    div  ecx                 ; EAX = thumb_y (relative to track)
    
    ; Draw thumb
    mov  ebx, [wm_sb_y]
    add  ebx, eax            ; Y = track_y + thumb_y
    mov  eax, [wm_sb_x]
    mov  ecx, [wm_sb_w]
    mov  edx, ebp            ; Height = thumb_height
    mov  esi, 0x0F           ; white thumb
    call fb_fill_rect
    jmp  .done
    
.full_thumb:
    mov  eax, [wm_sb_x]
    mov  ebx, [wm_sb_y]
    mov  ecx, [wm_sb_w]
    mov  edx, [wm_sb_h]
    mov  esi, 0x0F           ; white thumb
    call fb_fill_rect
    
.done:
    popa
    ret

; - wm_hit_test -
; In:  EAX=mx  EBX=my
; Out: CF=0 -> ECX=window index (topmost hit)  EDX=region(1=title 2=close 3=client)
;      CF=1 -> desktop (no window hit)
; Tests windows in descending z-order so the visually topmost window wins.
wm_hit_test:
    push eax
    push ebx

    mov  dword [wm_z], WM_MAX_WINS - 1
.zscan:
    mov  eax, [wm_z]
    cmp  eax, 0
    jl   .miss
    mov  dword [wm_i], 0
.wscan:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .znext
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .wnext
    cmp  byte [edi+24], al
    jne  .wnext
    jmp  .test_bounds
.wnext:
    inc  dword [wm_i]
    jmp  .wscan
.znext:
    dec  dword [wm_z]
    jmp  .zscan

.test_bounds:
    pop  ebx
    pop  eax
    push eax
    push ebx
    ; x bounds check
    mov  edx, [edi+0]
    cmp  eax, edx
    jl   .bounds_miss
    add  edx, [edi+8]
    cmp  eax, edx
    jge  .bounds_miss
    ; y bounds check
    mov  edx, [edi+4]
    cmp  ebx, edx
    jl   .bounds_miss
    add  edx, [edi+12]
    cmp  ebx, edx
    jge  .bounds_miss
    jmp  .bounds_hit

.bounds_miss:
    jmp  .znext

.bounds_hit:
    ; - determine region -
    ; close button: x >= win_x+w-18  AND  y <= win_y+16
    mov  edx, [edi+0]
    add  edx, [edi+8]
    sub  edx, 18
    cmp  eax, edx
    jl   .not_close
    mov  edx, [edi+4]
    add  edx, 16
    cmp  ebx, edx
    jg   .not_close
    mov  edx, 2
    clc
    jmp  .hit

.not_close:
    ; title bar: y < win_y + WM_TITLE_H
    mov  edx, [edi+4]
    add  edx, WM_TITLE_H
    cmp  ebx, edx
    jge  .is_client
    mov  edx, 1
    clc
    jmp  .hit

.is_client:
    mov  edx, 3
    clc
    jmp  .hit

.miss:
    stc

.hit:
    pop  ebx
    pop  eax
    ret

; - wm_update_sm_hover -
; Updates sm_hover based on mouse coords if sm_open=1.
; Sets gfx_dirty=1 if hover changed.
wm_update_sm_hover:
    pusha
    cmp  byte [sm_open], 1
    jne  .no_sm
    
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    
    ; check bounds: x in [SM_X, SM_X+SM_W], y in [TASKBAR_Y-SM_H, TASKBAR_Y]
    cmp  eax, SM_X
    jl   .miss
    cmp  eax, SM_X + SM_W
    jge  .miss
    
    mov  ecx, WM_TASKBAR_Y - SM_H
    cmp  ebx, ecx
    jl   .miss
    cmp  ebx, WM_TASKBAR_Y
    jge  .miss
    
    ; which item? y - (menu_top+15) / SM_ITEM_H
    sub  ebx, ecx
    sub  ebx, 15                ; offset from first item
    js   .miss                  ; in header
    
    xor  edx, edx
    mov  eax, ebx
    mov  ecx, SM_ITEM_H
    div  ecx                    ; EAX = item index
    
    cmp  eax, SM_ITEMS
    jge  .miss
    
    mov  esi, eax               ; ESI = new hover
    jmp  .check_changed
    
.miss:
    mov  esi, -1
    
.check_changed:
    cmp  esi, [sm_hover]
    je   .no_sm
    mov  [sm_hover], esi
    mov  byte [gfx_dirty], 1
    
.no_sm:
    popa
    ret

; - wm_on_click -
; In: EAX=mx  EBX=my
wm_on_click:
    pusha

    ; - taskbar button click? -
    cmp  ebx, WM_TASKBAR_Y
    jl   .not_taskbar

    ; NatureOS start button: x < 84
    cmp  eax, 84
    jge  .tb_windows
    ; toggle start menu
    cmp  byte [sm_open], 1
    je   .close_sm
    mov  byte [sm_open], 1
    mov  dword [sm_hover], -1
    call cursor_erase
    call wm_draw_startmenu
    call cursor_save_bg
    call cursor_draw
    jmp  .done
.close_sm:
    call wm_hide_startmenu
    jmp  .done

.tb_windows:
    ; taskbar window buttons - dynamic widths
    mov  edx, 90
    xor  ecx, ecx
.tbscan:
    cmp  ecx, WM_MAX_WINS
    jge  .not_taskbar
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .tb_next
    push eax
    mov  esi, [edi+20]
    call wm_btn_width
    mov  [wm_cur_btn_w], eax
    pop  eax
    cmp  eax, edx
    jl   .tb_next
    mov  esi, edx
    add  esi, [wm_cur_btn_w]
    cmp  eax, esi
    jge  .tb_next
    call wm_set_focus
    call wm_draw_all
    jmp  .done
.tb_next:
    mov  esi, [wm_cur_btn_w]
    add  esi, 4
    add  edx, esi
    inc  ecx
    jmp  .tbscan

.not_taskbar:
    ; - start menu item click? -
    cmp  byte [sm_open], 1
    jne  .no_sm_click
    ; check bounds: x in [SM_X, SM_X+SM_W], y in [TASKBAR_Y-SM_H, TASKBAR_Y]
    cmp  eax, SM_X
    jl   .sm_dismiss
    cmp  eax, SM_X + SM_W
    jge  .sm_dismiss
    mov  ecx, WM_TASKBAR_Y - SM_H
    cmp  ebx, ecx
    jl   .sm_dismiss
    cmp  ebx, WM_TASKBAR_Y
    jge  .sm_dismiss
    ; which item? y - (menu_top+15) / SM_ITEM_H
    sub  ebx, ecx
    sub  ebx, 15                ; offset from first item
    js   .sm_dismiss            ; click in header
    xor  edx, edx
    mov  eax, ebx
    mov  ecx, SM_ITEM_H
    div  ecx                    ; EAX = item index
    cmp  eax, SM_ITEMS
    jge  .sm_dismiss
    ; execute item
    call wm_hide_startmenu
    mov  esi, [sm_commands + eax*4]
    call pm_run_command
    jmp  .done
.sm_dismiss:
    call wm_hide_startmenu
    jmp  .done
.no_sm_click:
    call ctx_hide               ; ensure context menu is hidden when interacting with windows
    ; - window hit test -
    call wm_hit_test
    jc   .desktop

    push ecx
    push edx
    call wm_set_focus
    pop  edx
    pop  ecx

    cmp  edx, 2             ; close?
    je   .do_close
    cmp  edx, 1             ; title bar " start drag
    je   .do_drag
    ; client click " check for button hit in WM_CLOCK window
    cmp  edx, 3
    jne  .done
    cmp  byte [edi+16], WM_CLOCK
    jne  .c1
    call wm_clock_click
    jmp  .done
.c1:
    cmp  byte [edi+16], WM_BROWSER
    jne  .done
    call browser_click
    jmp  .done

.do_close:
    call wm_close
    jmp  .done

.do_drag:
    mov  [wm_drag_win], ecx
    mov  [wm_drag_mx0], eax
    mov  [wm_drag_my0], ebx
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  eax, [edi+0]
    mov  [wm_drag_wx0], eax
    mov  eax, [edi+4]
    mov  [wm_drag_wy0], eax
    jmp  .done

.desktop:
    mov  dword [wm_drag_win], -1

.done:
    popa
    ret

; - wm_on_drag -
; XOR ghost drag " erase old outline, move, draw new outline. Zero flicker.
wm_on_drag:
    pusha
    cmp  dword [wm_drag_win], -1
    je   .done

    mov  ecx, [wm_drag_win]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .done

    ; compute new x
    mov  eax, [mouse_x]
    sub  eax, [wm_drag_mx0]
    add  eax, [wm_drag_wx0]
    test eax, eax
    jge  .xlo_ok
    xor  eax, eax
.xlo_ok:
    mov  edx, 640
    sub  edx, [edi+8]
    cmp  eax, edx
    jle  .xhi_ok
    mov  eax, edx
.xhi_ok:
    ; compute new y
    mov  ebx, [mouse_y]
    sub  ebx, [wm_drag_my0]
    add  ebx, [wm_drag_wy0]
    test ebx, ebx
    jge  .ylo_ok
    xor  ebx, ebx
.ylo_ok:
    mov  edx, WM_TASKBAR_Y
    sub  edx, [edi+12]
    cmp  ebx, edx
    jle  .yhi_ok
    mov  ebx, edx
.yhi_ok:

    ; skip if unchanged
    cmp  eax, [edi+0]
    jne  .moved
    cmp  ebx, [edi+4]
    je   .done

.moved:
    ; erase old XOR ghost at current (old) position
    call cursor_erase
    push eax
    push ebx
    mov  eax, [edi+0]
    mov  ebx, [edi+4]
    mov  ecx, [edi+8]
    mov  edx, [edi+12]
    call fb_xor_rect_outline
    pop  ebx
    pop  eax

    ; update position in table
    mov  [edi+0], eax
    mov  [edi+4], ebx

    ; draw new XOR ghost at new position
    mov  ecx, [edi+8]
    mov  edx, [edi+12]
    call fb_xor_rect_outline
    call cursor_save_bg
    call cursor_draw

.done:
    popa
    ret

; - wm_on_release -
; Full redraw now that drag is committed.
wm_on_release:
    pusha
    cmp  dword [wm_drag_win], -1
    je   .skip
    mov  dword [wm_drag_win], -1
    call wm_draw_all            ; already calls wm_redraw_contents internally
.skip:
    popa
    ret

; - wm_redraw_contents -
; Draw content for all open non-terminal windows (clock, files, help).
; Drawn in z-order sweep so higher windows overwrite lower ones.
wm_redraw_contents:
    pusha
    mov  dword [wm_z], 0
.zloop:
    mov  eax, [wm_z]
    cmp  eax, WM_MAX_WINS
    jge  .done
    mov  dword [wm_i], 0
.wloop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .wnext_z
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .wnext
    cmp  byte [edi+24], al
    jne  .wnext
    movzx eax, byte [edi+16]
    cmp  eax, WM_CLOCK
    je   .doclock
    cmp  eax, WM_FILES
    je   .dofiles
    cmp  eax, WM_HELP
    je   .dohelp
    jmp  .wnext
.doclock:
    call wm_draw_clock
    jmp  .wnext
.dofiles:
    call wm_draw_files
    jmp  .wnext
.dohelp:
    call wm_draw_help
.wnext:
    inc  dword [wm_i]
    jmp  .wloop
.wnext_z:
    inc  dword [wm_z]
    jmp  .zloop
.done:
    popa
    ret

; - wm_clock_click -
; Called when a client-area click hits a WM_CLOCK window.
; ECX=window index, EAX=mouse_x, EBX=mouse_y
wm_clock_click:
    push eax
    push ebx
    push ecx
    push edx
    push edi

    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    ; button row Y range: win_y + 74  to  win_y + 90
    mov  edx, [edi+4]
    add  edx, 74
    cmp  ebx, edx
    jl   .no_btn
    add  edx, 16
    cmp  ebx, edx
    jg   .no_btn

    ; Button 1 X range: win_x+8 to win_x+104
    mov  edx, [edi+0]
    add  edx, 8
    cmp  eax, edx
    jl   .chk_btn2
    add  edx, 96
    cmp  eax, edx
    jg   .chk_btn2
    ; Button 1: toggle start/stop
    cmp  byte [sw_running], 1
    je   .do_pause
    ; - START: restore cs_count from saved offset -
    mov  eax, [sw_start_offset]
    mov  [sw_cs_count], eax
    mov  byte [sw_running], 1
    jmp  .btn1_done
.do_pause:
    ; - STOP: save cs_count -
    mov  eax, [sw_cs_count]
    mov  [sw_start_offset], eax
    mov  byte [sw_running], 0
.btn1_done:
    call wm_draw_clock
    jmp  .no_btn

.chk_btn2:
    ; Button 2 X range: win_x+116 to win_x+212
    mov  edx, [edi+0]
    add  edx, 116
    cmp  eax, edx
    jl   .no_btn
    add  edx, 96
    cmp  eax, edx
    jg   .no_btn
    ; Button 2: Reset (stopwatch) or Cancel (timer)
    cmp  byte [sw_mode], SW_MODE_TIMER
    je   .cancel
    ; reset stopwatch
    mov  dword [sw_ticks], 0
    mov  dword [sw_cs_count], 0
    mov  dword [sw_start_offset], 0
    mov  byte  [sw_running], 0
    jmp  .redraw
.cancel:
    ; cancel timer " close the window
    call wm_close
    mov  dword [sw_ticks], 0
    mov  byte  [sw_running], 0
    call wm_draw_all
    jmp  .no_btn
.redraw:
    call wm_draw_clock

.no_btn:
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - wm_draw_clock -
; Draws stopwatch/timer window with GUI buttons.
; Layout (client area, win w=220 h=100):
;   y+8:  MM:SS.cs at 2x scale (centred)
;   y+34: status text
;   y+74: [  Start / Stop  ] [    Reset    ]   (buttons h=16)
; ECX = window index
wm_draw_clock:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov  [wm_tmp_idx], ecx
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .done

    ; clear client area
    mov  eax, [edi+0]
    add  eax, 1
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H
    mov  ecx, [edi+8]
    sub  ecx, 2
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 1
    mov  esi, WM_C_BODY
    call fb_fill_rect

    ; - compute display values -
    mov  ecx, [wm_tmp_idx]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    cmp  byte [sw_mode], SW_MODE_TIMER
    je   .timer_calc

    ; stopwatch: elapsed ticks -> MM:SS.cs
    mov  eax, [sw_ticks]
    xor  edx, edx
    mov  ecx, 100
    div  ecx
    mov  [sw_cs], edx
    xor  edx, edx
    mov  ecx, 60
    div  ecx
    mov  [wm_clk_mm], eax
    mov  [wm_clk_ss], edx
    jmp  .format

.timer_calc:
    ; sw_ticks already contains remaining centiseconds (set by wm_update_contents)
    mov  eax, [sw_ticks]
    xor  edx, edx
    mov  ecx, 100
    div  ecx
    mov  [sw_cs], edx
    xor  edx, edx
    mov  ecx, 60
    div  ecx
    mov  [wm_clk_mm], eax
    mov  [wm_clk_ss], edx

.format:
    push edi
    mov  edi, wm_clk_buf
    mov  eax, [wm_clk_mm]
    call wm_d2
    mov  byte [edi], ':'
    inc  edi
    mov  eax, [wm_clk_ss]
    call wm_d2
    mov  byte [edi], '.'
    inc  edi
    mov  eax, [sw_cs]
    call wm_d2
    mov  byte [edi], 0
    pop  edi                    ; restore window entry ptr

    ; - time display: 2x, centred (128px wide -> offset 46) -
    mov  dword [fcs_scale], 2
    mov  esi, wm_clk_buf
    mov  ebx, [edi+0]
    add  ebx, 46
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 8
    mov  dl,  0x0A
    mov  dh,  WM_C_BODY
    call fb_draw_string_scaled

    ; - status text -
    mov  esi, wm_s_sw_paused
    cmp  byte [sw_running], 1
    jne  .draw_status
    mov  esi, wm_s_sw_running
    cmp  byte [sw_mode], SW_MODE_TIMER
    jne  .draw_status
    ; timer is done when sw_running was cleared by countdown
    cmp  byte [sw_running], 1
    je   .draw_status
    mov  esi, wm_s_sw_done
.draw_status:
    mov  ebx, [edi+0]
    add  ebx, 8
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 34
    mov  dl,  0x07
    mov  dh,  WM_C_BODY
    call fb_draw_string

    ; - Button 1: [Start] / [Stop]  x=win_x+8  y=win_y+74  w=96  h=16 -
    mov  eax, [edi+0]
    add  eax, 8
    mov  ebx, [edi+4]
    add  ebx, 74
    mov  ecx, 96
    mov  edx, 16
    mov  esi, 0x08              ; dark = stopped
    cmp  byte [sw_running], 1
    jne  .b1fill
    mov  esi, 0x02              ; dark green = running
.b1fill:
    call fb_fill_rect
    mov  eax, [edi+0]
    add  eax, 8
    mov  ebx, [edi+4]
    add  ebx, 74
    mov  ecx, 96
    mov  edx, 16
    mov  esi, 0x0F
    call fb_draw_rect_outline
    ; label: "Start"(5) or "Stop"(4) " centre in 96px: Start->x+28, Stop->x+32
    mov  esi, wm_s_btn_start
    mov  ebx, [edi+0]
    add  ebx, 36                ; (96 - 5*8) / 2 + 8 = 36
    cmp  byte [sw_running], 1
    jne  .b1lbl
    mov  esi, wm_s_btn_stop
    mov  ebx, [edi+0]
    add  ebx, 40                ; (96 - 4*8) / 2 + 8 = 40
.b1lbl:
    mov  ecx, [edi+4]
    add  ecx, 78
    mov  dl,  0x0F
    mov  dh,  0x08
    cmp  byte [sw_running], 1
    jne  .b1lbl2
    mov  dh,  0x02
.b1lbl2:
    call fb_draw_string

    ; - Button 2: [Reset] / [Cancel]  x=win_x+116  y=win_y+74  w=96  h=16 -
    mov  eax, [edi+0]
    add  eax, 116
    mov  ebx, [edi+4]
    add  ebx, 74
    mov  ecx, 96
    mov  edx, 16
    mov  esi, 0x08
    call fb_fill_rect
    mov  eax, [edi+0]
    add  eax, 116
    mov  ebx, [edi+4]
    add  ebx, 74
    mov  ecx, 96
    mov  edx, 16
    mov  esi, 0x0F
    call fb_draw_rect_outline
    ; label: "Reset"(5)->offset 28+116=144, "Cancel"(6)->offset 24+116=140
    mov  esi, wm_s_btn_reset
    mov  ebx, [edi+0]
    add  ebx, 144               ; (96 - 5*8)/2 + 116 = 144
    cmp  byte [sw_mode], SW_MODE_TIMER
    jne  .b2lbl
    mov  esi, wm_s_btn_cancel
    mov  ebx, [edi+0]
    add  ebx, 140               ; (96 - 6*8)/2 + 116 = 140
.b2lbl:
    mov  ecx, [edi+4]
    add  ecx, 78
    mov  dl,  0x0F
    mov  dh,  0x08
    call fb_draw_string

    ; mark entire clock window dirty
    mov  eax, [edi+4]
    mov  ebx, eax
    add  ebx, [edi+12]
    call gfx_mark_dirty

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - wm_draw_help -
; In: ECX = window index  (must be WM_HELP)
wm_draw_help:
    pusha
    mov  [wm_tmp_idx], ecx
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .done

    ; clear client area
    mov  eax, [edi+0]
    add  eax, 2
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 2
    mov  ecx, [edi+8]
    sub  ecx, 4
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 4
    mov  esi, WM_C_BODY
    call fb_fill_rect

    mov  ecx, [wm_tmp_idx]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  ebx, [edi+0]           ; win_x
    mov  ecx, [edi+4]           ; win_y

    ; helper macro: draw line at offset
    ; draw each line: ESI=str, EBX=x+4, ECX=win_y+title+offset, DL=col
    push ebx
    push ecx

    %macro helpline 3           ; %1=y_offset %2=colour %3=string_label
        mov  esi, %3
        mov  ebx, [edi+0]
        add  ebx, 6
        mov  ecx, [edi+4]
        add  ecx, WM_TITLE_H + %1
        mov  dl,  %2
        mov  dh,  WM_C_BODY
        call fb_draw_string
    %endmacro

    helpline  8,  0x0B, wm_s_help_title
    helpline 20,  0x07, wm_s_help_sep
    helpline 30,  0x0F, wm_s_help_l1
    helpline 40,  0x07, wm_s_help_l2
    helpline 50,  0x07, wm_s_help_l3
    helpline 60,  0x07, wm_s_help_l4
    helpline 72,  0x0B, wm_s_help_sec2
    helpline 84,  0x07, wm_s_help_c1
    helpline 94,  0x07, wm_s_help_c2
    helpline 104, 0x07, wm_s_help_c3
    helpline 114, 0x07, wm_s_help_c4
    helpline 124, 0x07, wm_s_help_c5
    helpline 136, 0x0B, wm_s_help_sec3
    helpline 148, 0x07, wm_s_help_w1
    helpline 158, 0x07, wm_s_help_w2
    helpline 168, 0x07, wm_s_help_w3
    helpline 180, 0x08, wm_s_help_ver

    pop  ecx
    pop  ebx
.done:
    popa
    ret

; - wm_draw_files -
; In: ECX = window index  (must be WM_FILES)
wm_draw_files:
    pusha
    mov  [wm_tmp_idx], ecx

    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .fdone

    ; clear client area
    mov  eax, [edi+0]
    add  eax, 2
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 2
    mov  ecx, [edi+8]
    sub  ecx, 4
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 4
    mov  esi, WM_C_BODY
    call fb_fill_rect

    ; reload window entry
    mov  ecx, [wm_tmp_idx]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    ; compute base text x, starting y, max y
    ; reserve 12px at bottom for the summary footer
    mov  eax, [edi+0]
    add  eax, 6
    mov  [wm_fx], eax

    mov  eax, [edi+4]
    add  eax, WM_TITLE_H + 4
    mov  [wm_fy], eax

    mov  eax, [edi+4]
    add  eax, [edi+12]
    sub  eax, 18                ; reserve 18px for footer separator + text
    mov  [wm_fy_max], eax

    ; zero file counters
    mov  dword [wm_iso_count], 0
    mov  dword [wm_dat_count], 0

    ; - Section 1: ISO (read-only) -
    mov  esi, wm_s_sec_iso
    mov  ebx, [wm_fx]
    mov  ecx, [wm_fy]
    mov  dl,  0x0B              ; cyan header
    mov  dh,  WM_C_BODY
    call fb_draw_string
    add  dword [wm_fy], 10

    ; check FS magic
    cmp  dword [FS_PM_BASE], FS_MAGIC_VAL
    jne  .fno_iso


    movzx eax, word [FS_PM_BASE + 4]
    test eax, eax
    jz   .fiso_empty
    mov  [wm_fcount], eax

    mov  esi, FS_PM_BASE + 6    ; first ISO directory entry

.fiso_row:
    cmp  dword [wm_fcount], 0
    je   .fiso_done
    mov  eax, [wm_fy]
    cmp  eax, [wm_fy_max]
    jge  .fdone

    ; copy filename to wm_fbuf
    push esi
    mov  edi, wm_fbuf
    mov  ecx, 16
.fiso_copy:
    mov  al, [esi]
    mov  [edi], al
    inc  esi
    inc  edi
    test al, al
    jz   .fiso_copy_done
    loop .fiso_copy
    mov  byte [edi], 0
.fiso_copy_done:
    pop  esi

    push esi
    mov  esi, wm_fbuf
    mov  ebx, [wm_fx]
    mov  ecx, [wm_fy]
    mov  dl,  0x07              ; grey " read only
    mov  dh,  WM_C_BODY
    call fb_draw_string
    pop  esi

    add  dword [wm_fy], 9
    add  esi, FS_ENT_SZ
    inc  dword [wm_iso_count]
    dec  dword [wm_fcount]
    jmp  .fiso_row

.fiso_empty:
    mov  esi, wm_s_empty
    mov  ebx, [wm_fx]
    add  ebx, 4
    mov  ecx, [wm_fy]
    mov  dl,  0x08
    mov  dh,  WM_C_BODY
    call fb_draw_string
    add  dword [wm_fy], 9
    jmp  .fiso_done

.fno_iso:
    mov  esi, wm_s_nofs
    mov  ebx, [wm_fx]
    add  ebx, 4
    mov  ecx, [wm_fy]
    mov  dl,  0x0C
    mov  dh,  WM_C_BODY
    call fb_draw_string
    add  dword [wm_fy], 9

.fiso_done:

    ; - gap between sections -
    add  dword [wm_fy], 3

    ; - Section 2: DATA disk -
    mov  eax, [wm_fy]
    cmp  eax, [wm_fy_max]
    jge  .fdone

    mov  esi, wm_s_sec_data
    mov  ebx, [wm_fx]
    mov  ecx, [wm_fy]
    mov  dl,  0x0E              ; yellow header
    mov  dh,  WM_C_BODY
    call fb_draw_string
    add  dword [wm_fy], 10

    cmp  byte [fsd_ready], 1
    jne  .fno_data

    cmp  dword [fsd_used], 0
    je   .fdata_empty

    ; iterate data disk entries
    mov  esi, fsd_dir_buf
    mov  dword [wm_fcount], FSD_MAX_ENT

.fdata_row:
    cmp  dword [wm_fcount], 0
    je   .fdone
    mov  eax, [wm_fy]
    cmp  eax, [wm_fy_max]
    jge  .fdone

    ; Determine how to handle this entry based on FS type
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   .fdata_fat16

    ; --- CLFD logic ---
    cmp  dword [esi + 24], FSD_FLAG_USED
    jne  .fdata_next

    ; copy filename to wm_fbuf
    push esi
    mov  edi, wm_fbuf
    mov  ecx, FSD_NAME_LEN
.fdata_copy:
    mov  al, [esi]
    mov  [edi], al
    inc  esi
    inc  edi
    test al, al
    jz   .fdata_copy_done
    loop .fdata_copy
    mov  byte [edi], 0
.fdata_copy_done:
    pop  esi
    jmp  .fdata_draw

.fdata_fat16:
    ; --- FAT16 logic ---
    mov  al, [esi]
    test al, al
    jz   .fdone              ; End of directory
    cmp  al, 0xE5
    je   .fdata_next         ; Deleted entry
    
    mov  al, [esi + 11]      ; Attribute
    test al, 0x18            ; Directory or Vol Label?
    jnz  .fdata_next         ; Skip for now

    ; Translate 8.3 name to null-terminated for display
    push esi
    mov  edi, wm_fbuf
    call fsd_83_to_name
    pop  esi

.fdata_draw:
    ; draw filename in bright white (writable)
    push esi
    mov  esi, wm_fbuf
    mov  ebx, [wm_fx]
    mov  ecx, [wm_fy]
    mov  dl,  0x0F
    mov  dh,  WM_C_BODY
    call fb_draw_string
    pop  esi

    add  dword [wm_fy], 9
    inc  dword [wm_dat_count]

.fdata_next:
    add  esi, FSD_ENT_SZ
    dec  dword [wm_fcount]
    jmp  .fdata_row

.fdata_empty:
    mov  esi, wm_s_empty
    mov  ebx, [wm_fx]
    add  ebx, 4
    mov  ecx, [wm_fy]
    mov  dl,  0x08
    mov  dh,  WM_C_BODY
    call fb_draw_string
    jmp  .fdone

.fno_data:
    mov  esi, wm_s_no_data
    mov  ebx, [wm_fx]
    add  ebx, 4
    mov  ecx, [wm_fy]
    mov  dl,  0x08
    mov  dh,  WM_C_BODY
    call fb_draw_string

.fdone:
    ; draw footer: thin separator line then "N ISO  N disk"
    ; position at win_y + win_h - 16
    mov  ecx, [wm_tmp_idx]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table

    ; horizontal separator line
    mov  eax, [edi+0]
    add  eax, 2
    mov  ebx, [edi+4]
    add  ebx, [edi+12]
    sub  ebx, 15
    mov  edx, [edi+8]
    sub  edx, 4
    mov  cl,  0x08
    call fb_hline

    ; build summary string in wm_fbuf: "ISO: N  Disk: N"
    mov  edi, wm_fbuf
    ; "ISO: "
    mov  byte [edi+0], 'I'
    mov  byte [edi+1], 'S'
    mov  byte [edi+2], 'O'
    mov  byte [edi+3], ':'
    mov  byte [edi+4], ' '
    add  edi, 5
    ; iso count as decimal
    mov  eax, [wm_iso_count]
    call wm_write_dec_edi
    ; "  Disk: "
    mov  byte [edi+0], ' '
    mov  byte [edi+1], ' '
    mov  byte [edi+2], 'D'
    mov  byte [edi+3], 'i'
    mov  byte [edi+4], 's'
    mov  byte [edi+5], 'k'
    mov  byte [edi+6], ':'
    mov  byte [edi+7], ' '
    add  edi, 8
    ; disk count
    mov  eax, [wm_dat_count]
    call wm_write_dec_edi
    mov  byte [edi], 0

    ; draw summary
    mov  ecx, [wm_tmp_idx]
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    mov  ebx, [edi+0]
    add  ebx, 6
    mov  ecx, [edi+4]
    add  ecx, [edi+12]
    sub  ecx, 10
    mov  esi, wm_fbuf
    mov  dl,  0x08
    mov  dh,  WM_C_BODY
    call fb_draw_string

    popa
    ret

; - wm_write_dec_edi - write EAX as decimal to [EDI], advance EDI
wm_write_dec_edi:
    push eax
    push ebx
    push ecx
    push edx
    mov  ecx, 0
    mov  ebx, 10
    test eax, eax
    jnz  .push
    mov  byte [edi], '0'
    inc  edi
    jmp  .wde_done
.push:
    xor  edx, edx
    div  ebx
    push edx
    inc  ecx
    test eax, eax
    jnz  .push
.pop:
    pop  edx
    add  dl, '0'
    mov  [edi], dl
    inc  edi
    loop .pop
.wde_done:
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret



; - wm_update_contents -
; Called every main loop iteration.
; pit_ticks is incremented at 100Hz by the IRQ0 handler.
; We snapshot it and act only when it advances.
wm_update_contents:
    push eax
    push ecx
    push edi

    mov  eax, [pit_ticks]
    cmp  eax, [sw_last_pit]
    je   .done                  ; no new tick yet

    ; compute delta (handles wrap-around correctly for unsigned 32-bit)
    mov  ecx, eax
    sub  ecx, [sw_last_pit]     ; ECX = ticks elapsed since last call (may be >1 if main loop was slow)
    mov  [sw_last_pit], eax
    mov  [sw_tick_delta], ecx

    ; - notification auto-clear -
    call wm_notify_tick
.no_notify:

    ; - taskbar clock: update on RTC second change -
    push eax
    mov  al, 0x00
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    call wm_bcd2bin
    cmp  eax, [wm_last_sec]
    je   .no_clock
    mov  [wm_last_sec], eax
    inc  dword [si_uptime_secs]     ; tick uptime counter once per RTC second
    ; if timer is running, increment elapsed RTC seconds
    cmp  byte [sw_running], 1
    jne  .no_rtc_tick
    cmp  byte [sw_mode], SW_MODE_TIMER
    jne  .no_rtc_tick
    inc  dword [sw_rtc_secs]
.no_rtc_tick:
    call wm_draw_taskbar_clock
    call cursor_erase
    call wm_draw_sysinfo
    
    push eax
    push ebx
    mov eax, 0
    mov ebx, 100
    call gfx_mark_dirty
    pop ebx
    pop eax
    
    push eax
    push ebx
    push ecx
    push edi
    xor ecx, ecx
.ov_loop:
    cmp ecx, WM_MAX_WINS
    jge .ov_done
    imul edi, ecx, WM_STRIDE
    add edi, wm_table
    cmp byte [edi+17], 1
    jne .ov_next
    
    ; check SysInfo overlap (top-right)
    mov ebx, [edi+4]
    cmp ebx, 100
    jge .ov_tb
    mov eax, [edi+0]
    add eax, [edi+8]
    cmp eax, 470
    jg .ov_hit

.ov_tb:
    ; check Taskbar Clock overlap (bottom-right: [552..640, 462..480])
    mov ebx, [edi+4]
    add ebx, [edi+12]
    cmp ebx, 462
    jle .ov_next
    mov eax, [edi+0]
    add eax, [edi+8]
    cmp eax, 552
    jle .ov_next

.ov_hit:
    mov byte [edi+19], 1   ; dirty
.ov_next:
    inc ecx
    jmp .ov_loop
.ov_done:
    pop edi
    pop ecx
    pop ebx
    pop eax

    call cursor_save_bg
    call cursor_draw
.no_clock:
    pop  eax

    ; - stopwatch/timer: only if running -
    cmp  byte [sw_running], 1
    jne  .done

    ; stopwatch: accumulate exact PIT delta (fixes under-count when main loop is slow)
    mov  ecx, [sw_tick_delta]
    add  [sw_cs_count], ecx

    ; update sw_ticks: what wm_draw_clock will display
    cmp  byte [sw_mode], SW_MODE_TIMER
    je   .timer_update
    ; stopwatch: display = sw_cs_count
    mov  eax, [sw_cs_count]
    mov  [sw_ticks], eax
    jmp  .check_redraw

.timer_update:
    ; timer: display = remaining seconds from RTC (sw_rtc_secs counts real seconds)
    ; sw_ticks_end = total seconds entered by user
    mov  eax, [sw_ticks_end]
    sub  eax, [sw_rtc_secs]
    jns  .timer_pos
    xor  eax, eax
    mov  byte [sw_running], 0
.timer_pos:
    ; convert remaining seconds to centiseconds for display
    imul eax, 100
    mov  [sw_ticks], eax

.check_redraw:
    ; redraw every 4 ticks (25fps)
    mov  eax, [sw_cs_count]
    and  eax, 0x03
    jnz  .done
.do_redraw:
    mov  dword [wm_i], 0
.sw_loop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .sw_next
    cmp  byte [edi+16], WM_CLOCK
    jne  .sw_next
    call cursor_erase
    call wm_draw_clock
    call cursor_save_bg
    call cursor_draw
.sw_next:
    inc  dword [wm_i]
    jmp  .sw_loop

.done:
    call gfx_flush
    pop  edi
    pop  ecx
    pop  eax
    ret


; - data -

; -
; -

; -
; wm_restore_sysinfo_bg - patch background before sysinfo drawing
; -
wm_restore_sysinfo_bg:
    pusha
    cmp byte [wp_loaded], 1
    je .wp
    mov eax, 470
    mov ebx, 0
    mov ecx, 170
    mov edx, 110
    mov esi, 0x0A      ; Green Fallback
    call fb_fill_rect
    jmp .done

.wp:
    mov  ebx, 0       ; screen row counter (0..109, covers sysinfo region)
.yloop:
    cmp  ebx, 110
    jge  .done

    ; dst: shadow buffer row = y * 640 + 470
    mov  edi, GFX_SHADOW
    mov  eax, ebx
    imul eax, 640
    add  edi, eax
    add  edi, 470

    ; src: WP_BUF pixel at this screen row and x=470
    ; screen row -> WP_BUF row = screen_y - pad_top (if in range, else use desktop bg)
    mov  eax, ebx
    sub  eax, [wp_pad_top]
    js   .fill_bg           ; above wallpaper: fill with desktop colour
    cmp  eax, [wp_h]
    jge  .fill_bg           ; below wallpaper: fill with desktop colour

    ; WP_BUF row is valid: src = WP_BUF + row * 640 + pad_left
    ; but sysinfo x=470, so we want: WP_BUF + row*640 + max(470 - pad_left, 0)
    imul eax, 640
    add  eax, WP_BUF
    ; x in wallpaper = screen_x - pad_left; for x=470:
    mov  ecx, 470
    sub  ecx, [wp_pad_left]
    js   .fill_bg
    cmp  ecx, [wp_w]
    jge  .fill_bg
    add  eax, ecx
    mov  esi, eax
    mov  ecx, 170
    rep  movsb
    jmp  .next_si_row

.fill_bg:
    mov  ecx, 170
    mov  al, 0x01           ; dark blue (desktop background colour)
    rep  stosb

.next_si_row:
    inc  ebx
    jmp  .yloop

.pad_region:
    ; if wallpaper not loaded, just fill with fallback (Green for debug)
    mov  eax, 470
    mov  ebx, 0
    mov  ecx, 170
    mov  edx, 110
    mov  esi, 0x0A      ; Green
    call fb_fill_rect

.done:
    popa
    ret

; fb_draw_string_right
; ESI=str, EBX=right_x, ECX=y, DL=fg, DH=bg
fb_draw_string_right:
    pusha
    call pm_strlen
    imul eax, 8
    sub ebx, eax
    call fb_draw_string
    popa
    ret

; -
; wm_draw_sysinfo - transparent live stats panel, top-right of desktop
;
; No background box. Text drawn directly over restored wallpaper (dh=0xFF transparent).
; Lines (10px apart, x=474 label / right-aligned values limit=634):
;   System Info   (cyan header, right-aligned)
;   Uptime:  NNNs  (incremented each second, no division jitter)
;   RAM:     NNNMb  (from BIOS data at 0x413, conventional mem)
;   Files:   N      (fsd_used, no hardcoded max)
;   Disk:    NNNKb / NNNKb
;   CPU:     Intel ...
; -
wm_draw_sysinfo:
    pusha

    call wm_restore_sysinfo_bg

    mov  dword [si_y], 8

    ; Line 1: header
    mov  esi, si_str_hdr
    mov  ebx, 634
    mov  ecx, [si_y]
    mov  dl,  0x0B
    mov  dh,  0xFF
    call fb_draw_string_right
    add  dword [si_y], 11

    ; Line 2: Uptime
    mov  esi, si_str_uptime
    mov  ebx, 474
    mov  ecx, [si_y]
    mov  dl,  0x07
    mov  dh,  0xFF
    call fb_draw_string
    mov  eax, [si_uptime_secs]
    mov  edi, si_numbuf
    
    ; hours
    xor  edx, edx
    mov  ebx, 3600
    div  ebx
    push edx
    call si_write_dec
    mov  byte [edi], 'h'
    inc  edi
    mov  byte [edi], ' '
    inc  edi
    
    ; minutes
    pop  eax
    xor  edx, edx
    mov  ebx, 60
    div  ebx
    push edx
    call si_write_dec
    mov  byte [edi], 'm'
    inc  edi
    mov  byte [edi], ' '
    inc  edi
    
    ; seconds
    pop  eax
    call si_write_dec
    mov  byte [edi], 's'
    inc  edi
    mov  byte [edi], 0
    mov  esi, si_numbuf
    mov  ebx, 634
    mov  ecx, [si_y]
    mov  dl,  0x0F
    mov  dh,  0xFF
    call fb_draw_string_right
    add  dword [si_y], 11

    ; Line 3: RAM - read CMOS 0x17/0x18 (extended KB) + 640KB conventional
    mov  esi, si_str_ram
    mov  ebx, 474
    mov  ecx, [si_y]
    mov  dl,  0x07
    mov  dh,  0xFF
    call fb_draw_string
    ; Read CMOS 0x34/0x35: 64KB blocks above 16MB
    mov  al, 0x34
    out  0x70, al
    in   al, 0x71
    movzx ecx, al
    mov  al, 0x35
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    shl  eax, 8
    or   eax, ecx               ; EAX = blocks above 16MB
    
    test eax, eax
    jnz  .cmos_high
    
    ; Fallback: CMOS 0x30/0x31: KB above 1MB (max 64MB)
    mov  al, 0x30
    out  0x70, al
    in   al, 0x71
    movzx ecx, al
    mov  al, 0x31
    out  0x70, al
    in   al, 0x71
    movzx eax, al
    shl  eax, 8
    or   eax, ecx               ; EAX = KB
    shr  eax, 10                ; KB -> MB
    inc  eax                    ; add 1MB base
    jmp  .cmos_done

.cmos_high:
    shr  eax, 4                 ; blocks -> MB ( / 16 )
    add  eax, 16                ; add 16MB base
    
.cmos_done:
    mov  [si_total_mb], eax
    mov  eax, [si_total_mb]
    ; EAX = Total RAM in MB
    mov  edi, si_numbuf
    call si_write_dec
    mov  byte [edi], 'M'
    inc  edi
    mov  byte [edi], 'b'
    inc  edi
    mov  byte [edi], 0
    mov  esi, si_numbuf
    mov  ebx, 634
    mov  ecx, [si_y]
    mov  dl,  0x0F
    mov  dh,  0xFF
    call fb_draw_string_right
    add  dword [si_y], 11

    ; Line 4: Files
    mov  esi, si_str_files
    mov  ebx, 474
    mov  ecx, [si_y]
    mov  dl,  0x07
    mov  dh,  0xFF
    call fb_draw_string
    mov  eax, [fsd_used]
    mov  edi, si_numbuf
    call si_write_dec
    mov  byte [edi], 0
    mov  esi, si_numbuf
    mov  ebx, 634
    mov  ecx, [si_y]
    mov  dl,  0x0F
    mov  dh,  0xFF
    call fb_draw_string_right
    add  dword [si_y], 11

    ; compute used sectors
    xor  eax, eax
    mov  [si_tmp], eax
    cmp  byte [fsd_ready], 1
    jne  .si_disk_draw
    
    push esi
    push ecx
    push ebx
    
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   .si_used_fat16

    ; --- CLFD used space ---
    mov  esi, fsd_dir_buf
    mov  ecx, FSD_MAX_ENT
.si_used_loop:
    cmp  dword [esi + 24], FSD_FLAG_USED
    jne  .si_used_skip
    mov  eax, [esi + 20]
    add  eax, 511
    shr  eax, 9
    add  [si_tmp], eax
.si_used_skip:
    add  esi, FSD_ENT_SZ
    loop .si_used_loop
    jmp  .si_done

.si_used_fat16:
    ; --- FAT16 used space ---
    ; We can't easily walk the whole FAT here without performance hit, 
    ; but we can sum up the file sizes from root dir.
    ; Note: this doesn't account for cluster slack or fragmented overhead, 
    ; but gives a similar "used bytes" feel.
    mov  esi, fsd_dir_buf
    movzx ecx, word [fsd_hdr_buf + BPB_ROOT_ENTRIES]
.si_used_fat_lp:
    mov  al, [esi]
    test al, al
    jz   .si_done
    cmp  al, 0xE5
    je   .si_next_fat
    mov  al, [esi + 11]
    test al, 0x18
    jnz  .si_next_fat
    
    mov  eax, [esi + 28]      ; File size
    add  eax, 511
    shr  eax, 9               ; Sectors
    add  [si_tmp], eax
.si_next_fat:
    add  esi, 32
    loop .si_used_fat_lp

.si_done:
    pop  ebx
    pop  ecx
    pop  esi

    ; Line 5: Disk  NNNKb/NNNKb
.si_disk_draw:
    ; Used parts
    mov  esi, si_str_disk
    mov  ebx, 474
    mov  ecx, [si_y]
    mov  dl,  0x07
    call fb_draw_string
    mov  eax, [si_tmp]
    shr  eax, 1               ; sectors -> KB
    mov  edi, si_numbuf
    call si_write_dec
    mov  byte [edi], 'K'
    inc  edi
    mov  byte [edi], '/'
    inc  edi
    mov  byte [edi], 0
    mov  esi, si_numbuf
    mov  ebx, 560
    mov  dl,  0x0A
    call fb_draw_string
    
    ; Total size
    cmp  byte [fsd_type], FSTYPE_FAT16
    je   .si_total_fat
    mov  eax, [fsd_hdr_buf + 12]  ; CLFD total sectors
    jmp  .si_total_draw
.si_total_fat:
    movzx eax, word [fsd_hdr_buf + 19] ; BPB_TotSec16
    test eax, eax
    jnz  .si_total_draw
    mov  eax, [fsd_hdr_buf + 32]       ; BPB_TotSec32
.si_total_draw:
    shr  eax, 1               ; sectors -> KB
    mov  edi, si_numbuf
    call si_write_dec
    mov  byte [edi], 'K'
    inc  edi
    mov  byte [edi], 0
    mov  esi, si_numbuf
    mov  ebx, 634
    mov  dl,  0x0F
    call fb_draw_string_right
    add  dword [si_y], 11

    cmp byte [si_cpu_brand], 0
    je .skip_cpu

    ; dynamically right-align "CPU:" + brand string
    mov esi, si_cpu_brand
    call pm_strlen
    add eax, 4             ; length of "CPU:" is 4
    imul eax, 8
    mov ebx, 634
    sub ebx, eax           ; EBX = left starting position for combined string

    push ebx
    mov esi, si_str_cpu
    mov ecx, [si_y]
    mov dl, 0x07
    call fb_draw_string
    pop ebx
    
    add ebx, 32            ; offset by 4 chars for the brand text
    mov esi, si_cpu_brand
    mov dl, 0x0F
    call fb_draw_string
    add dword [si_y], 11
.skip_cpu:

    ; mark sysinfo region dirty so gfx_flush picks it up
    push eax
    push ebx
    xor  eax, eax
    mov  ebx, 110
    call gfx_mark_dirty
    pop  ebx
    pop  eax

    popa
    ret

; -
; si_write_dec - write EAX as decimal string to [EDI], advance EDI
; Trashes nothing (saves/restores all used regs)
; -
si_write_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov  ecx, 0
    mov  ebx, 10
    test eax, eax
    jnz  .push
    mov  byte [edi], '0'
    inc  edi
    jmp  .done
.push:
    xor  edx, edx
    div  ebx
    push edx
    inc  ecx
    test eax, eax
    jnz  .push
.pop:
    pop  edx
    add  dl, '0'
    mov  [edi], dl
    inc  edi
    loop .pop
.done:
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; sysinfo data
si_y:           dd 0
si_uptime_secs: dd 0
si_numbuf:      times 20 db 0
si_str_hdr:     db 'System Info', 0
si_str_uptime:  db 'Uptime: ', 0
si_str_ram:     db 'RAM:    ', 0
si_str_files:   db 'Files:  ', 0
si_str_disk:    db 'Disk:   ', 0
si_str_scrs:    db 'Scrs:   ', 0

wm_table:        times (WM_MAX_WINS * WM_STRIDE) db 0

wm_drag_win:     dd -1
wm_drag_mx0:     dd 0
wm_drag_my0:     dd 0
wm_drag_wx0:     dd 0
wm_drag_wy0:     dd 0

wm_tbx:          dd 0
wm_cur_btn_w:    dd 0
; stopwatch/timer constants
SW_MODE_SW    equ 0
SW_MODE_TIMER equ 1

wm_i:            dd 0
wm_z:            dd 0
wm_tmp_idx:      dd 0
wm_tmp_zcnt:     db 0
wm_tmp_zcurr:    db 0
wm_tmp_zclosed:  db 0
wm_tmp_ztop:     db 0
wm_tmp_itop:     dd 0

wm_op_type:      dd 0
wm_op_x:         dd 0
wm_op_y:         dd 0
wm_op_w:         dd 0
wm_op_h:         dd 0

wm_clk_hh:       dd 0
wm_clk_mm:       dd 0
wm_clk_ss:       dd 0
wm_clk_buf:      times 12 db 0
wm_clk_yy:       dd 0
wm_clk_mo:       dd 0
wm_clk_dd:       dd 0
wm_dat_buf:      times 12 db 0

; stopwatch/timer state
sw_mode:         db SW_MODE_SW
sw_running:      db 0
sw_ticks:        dd 0            ; centiseconds to display
sw_ticks_end:    dd 0            ; timer: total SECONDS entered by user
sw_cs:           dd 0            ; scratch for wm_draw_clock
sw_cs_count:     dd 0            ; total centiseconds elapsed since start
sw_start_offset: dd 0            ; centiseconds saved before pause
sw_last_pit:     dd 0            ; pit_ticks snapshot from last update
sw_tick_delta:   dd 0            ; ticks elapsed since last wm_update_contents call
sw_rtc_secs:     dd 0            ; RTC seconds elapsed since timer start

wm_fbuf:         times 20 db 0
wm_fbuf2:        times 12 db 0
wm_fx:           dd 0
wm_fy:           dd 0
wm_fy_max:       dd 0
wm_fcount:       dd 0
wm_iso_count:    dd 0
wm_dat_count:    dd 0

wm_s_brand:      db OS_NAME, 0
wm_s_logo:       db OS_NAME, 0
wm_s_logo_ver:   db 'v', OS_VERSION, 0
wm_s_watermark_os:    db OS_NAME, 0
wm_s_watermark_build: db 'Build ', OS_BUILD, 0
wm_s_term:       db 'Terminal', 0
wm_s_clock:      db 'Stopwatch', 0
wm_s_files:      db 'Files', 0
wm_s_help:       db 'About ', OS_NAME, 0
wm_s_browser:    db 'Simple Browser', 0
wm_s_taskman:    db 'Task Manager', 0
wm_s_notepad:    db 'Notepad', 0
wm_s_paint:      db 'Paint', 0

; Help window content
wm_s_help_title: db OS_NAME, '  Build ', OS_BUILD, 0
wm_s_help_sep:   db '------------------------------', 0
wm_s_help_l1:    db 'A hobby OS built in x86 assembly,', 0
wm_s_help_l2:    db 'running in 32-bit protected mode', 0
wm_s_help_l3:    db 'with a VBE graphical desktop,', 0
wm_s_help_l4:    db 'mouse, windows and ', FS_NAME, '.', 0
wm_s_help_sec2:  db 'Commands (type in terminal):', 0

wm_s_help_c1:    db '  term / files / stopwatch', 0
wm_s_help_c2:    db '  timer MM:SS  (countdown)', 0
wm_s_help_c3:    db '  calc <n> <op> <n>', 0
wm_s_help_c4:    db '  ping <ip>  arping <ip>', 0
wm_s_help_c5:    db '  pci  ifconfig  arp  dns', 0
wm_s_help_sec3:  db 'Desktop:', 0
wm_s_help_w1:    db '  Click icons or start menu', 0
wm_s_help_w2:    db '  Drag windows by title bar', 0
wm_s_help_w3:    db '  Close button (X) top-right', 0
wm_s_help_ver:   db 'github.com/BerBerOnGithub/TestOS', 0
wm_s_sw_running: db 'RUNNING', 0
wm_s_sw_paused:  db 'PAUSED', 0
wm_s_sw_done:    db 'DONE', 0
wm_s_sw_hint:    db 'start/stop/reset', 0
wm_s_btn_start:  db 'Start', 0
wm_s_btn_stop:   db 'Stop', 0
wm_s_btn_reset:  db 'Reset', 0
wm_s_btn_cancel: db 'Cancel', 0
wm_s_filehdr:    db 'Name', 0
wm_s_empty:      db '(empty)', 0
wm_s_nofs:       db 'No FS', 0
wm_s_sec_iso:    db '[ISO - read only]', 0
wm_s_sec_data:   db '[DATA - writable]', 0
wm_s_no_data:    db 'No data disk', 0

; start menu item labels
wm_s_sm_terminal:  db '  Terminal', 0
wm_s_sm_stopwatch: db '  Stopwatch', 0
wm_s_sm_files:     db '  Files', 0
wm_s_sm_help:      db '  Help', 0

; start menu command strings
wm_s_cmd_terminal:  db 'term', 0
wm_s_cmd_stopwatch: db 'stopwatch', 0
wm_s_cmd_files:     db 'files', 0
wm_s_cmd_helpwin:   db 'helpwin', 0

; start menu state
sm_open:         db 0
sm_hover:        dd -1

; start menu item label pointers
sm_labels:
    dd wm_s_sm_terminal
    dd wm_s_sm_stopwatch
    dd wm_s_sm_files
    dd wm_s_sm_help

; start menu command pointers
sm_commands:
    dd wm_s_cmd_terminal
    dd wm_s_cmd_stopwatch
    dd wm_s_cmd_files
    dd wm_s_cmd_helpwin

wm_sb_x:         dd 0
wm_sb_y:         dd 0
wm_sb_w:         dd 0
wm_sb_h:         dd 0
wm_sb_total:     dd 0
wm_sb_visible:   dd 0
wm_sb_pos:       dd 0

wm_last_sec:     dd 0xFF      ; force first update
gfx_needs_flush: db 0