; ===========================================================================
; pm/gui/ctx_menu.asm - Right-click context menu for PM desktop
; ===========================================================================

[BITS 32]

; - Constants -
CTX_W      equ 120
CTX_ITEM_H equ 18
CTX_ITEMS  equ 6
CTX_H      equ (CTX_ITEM_H * CTX_ITEMS) + 4
CTX_C_BG   equ 0x01      ; dark blue (matches desktop/start menu)
CTX_C_HL   equ 0x03      ; blue-grey highlight
CTX_C_FG   equ 0x0F      ; white text
CTX_C_BRD  equ 0x0F      ; white border

; - Variables -
ctx_open:   db 0
ctx_x:      dd 0
ctx_y:      dd 0
ctx_hover:  dd -1

; - Menu labels and commands -
ctx_labels:
    dd ctx_s_term
    dd ctx_s_files
    dd ctx_s_sysinfo
    dd ctx_s_screenshot
    dd ctx_s_refresh
    dd ctx_s_exit

ctx_commands:
    dd pm_str_cmd_term
    dd pm_str_cmd_files
    dd pm_str_cmd_sysinfo
    dd pm_str_cmd_savescr
    dd ctx_s_cmd_ref
    dd pm_str_cmd_exit

ctx_s_term:       db 'Terminal', 0
ctx_s_files:      db 'Files', 0
ctx_s_sysinfo:    db 'System Info', 0
ctx_s_screenshot: db 'Screenshot', 0
ctx_s_refresh:    db 'Refresh', 0
ctx_s_exit:       db 'Exit to RM', 0
ctx_s_cmd_ref:    db 'refresh', 0    ; internal dummy command for refresh

; - ctx_show -
; EAX=x, EBX=y
ctx_show:
    pusha
    ; clip to screen: avoid menu going off right/bottom
    cmp  eax, 640 - CTX_W
    jle  .x_ok
    mov  eax, 640 - CTX_W
.x_ok:
    cmp  ebx, WM_TASKBAR_Y - CTX_H
    jle  .y_ok
    mov  ebx, WM_TASKBAR_Y - CTX_H
.y_ok:
    mov  [ctx_x], eax
    mov  [ctx_y], ebx
    mov  byte [ctx_open], 1
    mov  dword [ctx_hover], -1
    call wm_draw_all
    popa
    ret

; - ctx_hide -
ctx_hide:
    pusha
    cmp  byte [ctx_open], 0
    je   .done
    mov  byte [ctx_open], 0
    call wm_draw_all
.done:
    popa
    ret

; - ctx_draw -
ctx_draw:
    pusha
    cmp  byte [ctx_open], 1
    jne  .done

    ; shadow (bottom-right)
    mov  eax, [ctx_x]
    add  eax, 4
    mov  ebx, [ctx_y]
    add  ebx, 4
    mov  ecx, CTX_W
    mov  edx, CTX_H
    mov  esi, 0x08           ; shadow colour
    call fb_fill_rect

    ; background fill
    mov  eax, [ctx_x]
    mov  ebx, [ctx_y]
    mov  ecx, CTX_W
    mov  edx, CTX_H
    mov  esi, CTX_C_BG
    call fb_fill_rect

    ; border
    mov  esi, CTX_C_BRD
    call fb_draw_rect_outline

    ; draw items
    mov  dword [wm_i], 0
.item_loop:
    mov  ecx, [wm_i]
    cmp  ecx, CTX_ITEMS
    jge  .done

    ; item rect: x+2, y+2 + i*H, w-4, H
    mov  eax, [ctx_x]
    add  eax, 2
    mov  ebx, [ctx_y]
    add  ebx, 2
    mov  edx, CTX_ITEM_H
    imul edx, ecx
    add  ebx, edx

    ; hover highlight?
    cmp  ecx, [ctx_hover]
    jne  .no_hl
    push eax
    push ebx
    mov  ecx, CTX_W - 4
    mov  edx, CTX_ITEM_H
    mov  esi, CTX_C_HL
    call fb_fill_rect
    pop  ebx
    pop  eax
.no_hl:
    ; text
    mov  ecx, [wm_i]         ; reload index (ecx clobbered by highlight logic)
    mov  esi, [ctx_labels + ecx*4]
    push ebx                 ; preserve item_y
    mov  ebx, [ctx_x]        ; reload x
    add  ebx, 6              ; text x
    mov  ecx, [esp]          ; get item_y
    add  ecx, 4              ; text y
    mov  dl,  CTX_C_FG
    mov  dh,  CTX_C_BG

    ; use [wm_i] for comparison to check if this item is hovered
    mov  eax, [wm_i]
    cmp  eax, [ctx_hover]
    jne  .draw_txt
    mov  dh,  CTX_C_HL
.draw_txt:
    call fb_draw_string
    pop  ebx                 ; restore item_y

    inc  dword [wm_i]
    jmp  .item_loop

.done:
    ; mark context menu region dirty for gfx_flush
    push eax
    push ebx
    mov  eax, [ctx_y]
    mov  ebx, [ctx_y]
    add  ebx, CTX_H
    call gfx_mark_dirty
    pop  ebx
    pop  eax
    popa
    ret

; - ctx_on_click -
; EAX=mx, EBX=my
; Returns CF=1 if click handled (menu was open), 0 if not handled
ctx_on_click:
    cmp  byte [ctx_open], 0
    je   .miss

    ; hit test bounds
    cmp  eax, [ctx_x]
    jl   .hide
    mov  edx, [ctx_x]
    add  edx, CTX_W
    cmp  eax, edx
    jge  .hide
    cmp  ebx, [ctx_y]
    jl   .hide
    mov  edx, [ctx_y]
    add  edx, CTX_H
    cmp  ebx, edx
    jge  .hide

    ; which item?
    sub  ebx, [ctx_y]
    sub  ebx, 2
    js   .hit_border
    xor  edx, edx
    mov  eax, ebx
    mov  ecx, CTX_ITEM_H
    div  ecx            ; EAX = index
    cmp  eax, CTX_ITEMS
    jge  .hit_border

    ; special case: refresh
    cmp  eax, 4
    jne  .run_cmd
    call ctx_hide
    call wm_invalidate_all
    call wm_draw_all
    jmp  .handled

.run_cmd:
    mov  esi, [ctx_commands + eax*4]
    call ctx_hide
    call pm_run_command
    jmp  .handled

.hit_border:
    call ctx_hide
.handled:
    stc
    ret

.hide:
    call ctx_hide
.miss:
    clc
    ret

; - ctx_update_hover -
; EAX=mx, EBX=my
ctx_update_hover:
    pusha
    cmp  byte [ctx_open], 0
    je   .done
    
    mov  esi, [ctx_hover]    ; use ESI for old hover (saved by pusha)

    mov  dword [ctx_hover], -1

    ; bounds check
    mov  eax, [mouse_x]
    mov  ebx, [mouse_y]
    cmp  eax, [ctx_x]
    jl   .check_changed
    mov  edx, [ctx_x]
    add  edx, CTX_W
    cmp  eax, edx
    jge  .check_changed
    cmp  ebx, [ctx_y]
    jl   .check_changed
    mov  edx, [ctx_y]
    add  edx, CTX_H
    cmp  ebx, edx
    jge  .check_changed

    sub  ebx, [ctx_y]
    sub  ebx, 2
    js   .check_changed
    xor  edx, edx
    mov  eax, ebx
    mov  ecx, CTX_ITEM_H
    div  ecx
    cmp  eax, CTX_ITEMS
    jge  .check_changed
    mov  [ctx_hover], eax

.check_changed:
    mov  eax, [ctx_hover]
    cmp  eax, esi            ; compare with old hover in ESI
    je   .done
    ; hover changed! mark something dirty to trigger redraw
    mov  byte [gfx_dirty], 1 ; force wm_draw_dirty/flush
.done:
    popa
    ret
