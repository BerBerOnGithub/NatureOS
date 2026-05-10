; ===========================================================================
; pm/wm_screenshot.asm - Screenshot counter and notifications
; ===========================================================================

[BITS 32]

; - Data -
scr_counter:    dd 0
scr_name:       db 'scr0000.bmp', 0
scr_msg_ok_save: db 'Screenshot saved!', 0
scr_msg_full:    db 'Disk full!', 0

notify_timer:   dd 0
notify_msg:     dd 0

; -
; scr_counter_init - Seed the screenshot counter from disk
; -
scr_counter_init:
    pusha
    mov  dword [scr_counter], 0
    popa
    ret

; -
; wm_screenshot_capture - Snapshot the shadow buffer to capture buffer
; -
wm_screenshot_capture:
    pusha
    ; Copy GFX_SHADOW (0x1400000) to SCR_CAPTURE (0x1500000)
    mov  esi, 0x1400000
    mov  edi, 0x1500000
    mov  ecx, 307200 / 4
    rep  movsd
    
    mov  byte [scr_pending], 1
    mov  esi, .msg
    call wm_notify
    popa
    ret
.msg db 'Screen captured!', 0

; -
; wm_notify - Show a temporary notification message
; ESI = message string
; -
wm_notify:
    push eax
    mov  [notify_msg], esi
    mov  dword [notify_timer], 200    ; 2 seconds at 100Hz
    pop  eax
    ret

; -
; wm_notify_tick - Update notification timer and redraw if needed
; -
wm_notify_tick:
    pusha
    cmp  dword [notify_timer], 0
    je   .done
    
    dec  dword [notify_timer]
    jz   .clear
    
    call wm_draw_notification
    jmp  .done
    
.clear:
    call wm_draw_all        ; Full redraw to erase notification
.done:
    popa
    ret

; -
; wm_draw_notification - Render the notification box
; -
wm_draw_notification:
    pusha
    mov  esi, [notify_msg]
    test esi, esi
    jz   .dn
    
    ; Draw a simple centered box at the top
    mov  eax, 200           ; x
    mov  ebx, 5             ; y
    mov  ecx, 240           ; w
    mov  edx, 20            ; h
    mov  esi, 0x0E          ; Yellow background
    call fb_fill_rect
    
    mov  esi, [notify_msg]
    mov  ebx, 210           ; x + padding
    mov  ecx, 10            ; y + padding
    mov  dl,  0x00          ; black text
    mov  dh,  0x0E          ; yellow bg
    call fb_draw_string
    
.dn:
    popa
    ret
