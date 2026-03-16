; ===========================================================================
; pm/wm_screenshot.asm  -  PrtSc screenshot to BMP on data disk
;
; Uses shadow framebuffer (GFX_SHADOW at 0x500000) - no MMIO reads needed.
;
; Phase 1 (PrtSc keypress):
;   wm_screenshot_capture - copies GFX_SHADOW -> 0x600000, sets scr_pending=1
;
; Phase 2 (user types "savescr"):
;   pm_cmd_savescr in pm_commands.asm - builds BMP from 0x600000, writes to disk
;
; BMP format (8bpp indexed):
;   14 bytes  BITMAPFILEHEADER
;   40 bytes  BITMAPINFOHEADER
; 1024 bytes  256-colour palette (from VGA DAC)
; 307200 bytes pixel data (BMP bottom-up = reverse row order)
; Total: 308278 bytes
; ===========================================================================

[BITS 32]
SCR_BUF     equ 0x300000
SCR_CAPTURE equ 0x600000
SCR_W       equ 640
SCR_H       equ 480
SCR_PIX     equ 307200
BMP_HDR_SZ  equ 1078
BMP_FILE_SZ equ 308278

; ---------------------------------------------------------------------------
; wm_screenshot_capture
; Called on PrtSc. Copies GFX_SHADOW (RAM) -> 0x600000.
; Fast RAM->RAM copy. No MMIO involved.
; ---------------------------------------------------------------------------
wm_screenshot_capture:
    pusha

    ; Print shadow bytes at rows 0,50,100,200,400 to serial
    ; Format: R<row>=<hex>
    push eax
    push edx
    push ecx
    ; print 'S:' prefix
    mov  dx, 0x3FD
.sp: in al, dx
    test al, 0x20
    jz   .sp
    mov  dx, 0x3F8
    mov  al, 'S'
    out  dx, al
    mov  dx, 0x3FD
.sq: in al, dx
    test al, 0x20
    jz   .sq
    mov  dx, 0x3F8
    mov  al, ':'
    out  dx, al
    ; print first byte of each row: 0, 50, 100, 200, 400
    mov  esi, scr_row_offsets
    mov  ecx, 5
.rowpr:
    lodsd
    movzx eax, byte [GFX_SHADOW + eax]
    ; print as hex
    push eax
    shr  al, 4
    add  al, '0'
    cmp  al, '9'
    jbe  .h1
    add  al, 7
.h1:
    mov  ah, al
    mov  dx, 0x3FD
.w1: in al, dx
    test al, 0x20
    jz   .w1
    mov  dx, 0x3F8
    mov  al, ah
    out  dx, al
    pop  eax
    and  al, 0x0F
    add  al, '0'
    cmp  al, '9'
    jbe  .h2
    add  al, 7
.h2:
    mov  ah, al
    mov  dx, 0x3FD
.w2: in al, dx
    test al, 0x20
    jz   .w2
    mov  dx, 0x3F8
    mov  al, ah
    out  dx, al
    ; space
    mov  dx, 0x3FD
.w3: in al, dx
    test al, 0x20
    jz   .w3
    mov  dx, 0x3F8
    mov  al, ' '
    out  dx, al
    loop .rowpr
    ; newline
    mov  dx, 0x3FD
.wn: in al, dx
    test al, 0x20
    jz   .wn
    mov  dx, 0x3F8
    mov  al, 10
    out  dx, al
    pop  ecx
    pop  edx
    pop  eax

    ; capture shadow -> 0x600000
    mov  esi, GFX_SHADOW
    mov  edi, 0x600000
    mov  ecx, 76800
    rep  movsd

    ; verify 0x600000[50*640] after copy
    push eax
    push edx
    movzx eax, byte [0x600000 + 50*640]
    ; print as hex
    push eax
    shr  al, 4
    and  al, 0xF
    add  al, '0'
    cmp  al, '9'
    jbe  .vh1
    add  al, 7
.vh1: mov ah,al
    mov dx,0x3FD
.vw1: in al,dx
    test al,0x20
    jz .vw1
    mov dx,0x3F8
    mov al,ah
    out dx,al
    pop eax
    and al,0xF
    add al,'0'
    cmp al,'9'
    jbe .vh2
    add al,7
.vh2: mov ah,al
    mov dx,0x3FD
.vw2: in al,dx
    test al,0x20
    jz .vw2
    mov dx,0x3F8
    mov al,ah
    out dx,al
    mov dx,0x3FD
.vn: in al,dx
    test al,0x20
    jz .vn
    mov dx,0x3F8
    mov al,10
    out dx,al
    pop edx
    pop eax

    mov  byte [scr_pending], 1

    cmp  byte [bd_ready], 1
    jne  .done
    mov  esi, scr_msg_ok_cap
    call wm_notify
.done:
    popa
    ret

scr_row_offsets:
    dd 0*640
    dd 50*640
    dd 100*640
    dd 200*640
    dd 400*640

wm_notify:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    pop  esi
    push esi
    mov  [notify_msg], esi
    mov  eax, [pit_ticks]
    add  eax, 300
    mov  [notify_expire], eax
    mov  eax, 4
    mov  ebx, WM_TASKBAR_Y - 20
    mov  ecx, 220
    mov  edx, 16
    mov  esi, 0x01
    call fb_fill_rect
    mov  esi, [notify_msg]
    mov  ebx, 8
    mov  ecx, WM_TASKBAR_Y - 16
    mov  dl,  0x0F
    mov  dh,  0x01
    call fb_draw_string
    call gfx_flush
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; wm_notify_tick - call from wm_update_contents each tick
; ---------------------------------------------------------------------------
wm_notify_tick:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    cmp  dword [notify_expire], 0
    je   .done
    mov  eax, [pit_ticks]
    cmp  eax, [notify_expire]
    jl   .done
    mov  dword [notify_expire], 0
    mov  dword [notify_msg], 0
    mov  eax, 4
    mov  ebx, WM_TASKBAR_Y - 20
    mov  ecx, 220
    mov  edx, 16
    mov  esi, WM_C_BODY
    call fb_fill_rect
    call wm_draw_all
.done:
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
notify_expire:   dd 0
notify_msg:      dd 0
scr_counter:     dd 0
scr_name:        db 'scr0001', 0
scr_msg_ok_cap:  db 'Screenshot captured! Type savescr to save.', 0
scr_msg_ok_save: db 'Screenshot saved!', 0
scr_msg_full:    db 'Data disk full!', 0
scr_msg_nodisk:  db 'No data disk attached', 0
