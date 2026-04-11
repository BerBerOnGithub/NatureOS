; ===========================================================================
; pm/browser.asm  -  NatureOS Simple Web Browser
; ===========================================================================

[BITS 32]

browser_init:
    pusha
    ; clear buffers
    mov  edi, browser_url
    xor  eax, eax
    mov  ecx, 64
    rep  stosd
    mov  edi, browser_content
    mov  ecx, 4096
    rep  stosd
    
    ; initial URL
    mov  esi, browser_s_default_url
    mov  edi, browser_url
.copy_url:
    lodsb
    stosb
    test al, al
    jnz  .copy_url
    
    mov  esi, browser_s_welcome
    mov  edi, browser_content
.copy_welcome:
    lodsb
    stosb
    test al, al
    jnz  .copy_welcome
    
    popa
    ret

; - browser_draw -
; In: EDI = window record
browser_draw:
    pusha
    
    mov  eax, [edi+0]   ; wx
    mov  ebx, [edi+4]   ; wy
    mov  ecx, [edi+8]   ; ww
    mov  edx, [edi+12]  ; wh
    
    ; 1. Draw background
    pusha
    add  ebx, WM_TITLE_H
    sub  edx, WM_TITLE_H
    mov  esi, 0x07      ; light grey
    call fb_fill_rect
    popa
    
    ; 2. Draw address bar
    pusha
    add  eax, 5
    add  ebx, WM_TITLE_H + 5
    mov  ecx, [edi+8]   ; ww
    sub  ecx, 60        ; leave space for 'Go'
    mov  edx, 16        ; height
    mov  esi, 0x0F      ; white
    call fb_fill_rect
    
    ; Address bar label
    mov  ebx, eax
    add  ebx, 4
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 9
    mov  esi, browser_url
    mov  dl, 0x00       ; black text
    mov  dh, 0x0F       ; white bg
    call fb_draw_string
    popa
    
    ; 3. Draw 'Go' button
    pusha
    mov  eax, [edi+0]
    add  eax, [edi+8]
    sub  eax, 50
    add  ebx, WM_TITLE_H + 5
    mov  ecx, 45
    mov  edx, 16
    mov  esi, 0x09      ; blue
    call fb_fill_rect
    
    mov  ebx, eax
    add  ebx, 12
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 9
    mov  esi, browser_s_go
    mov  dl, 0x0F       ; white text
    mov  dh, 0x09       ; blue bg
    call fb_draw_string
    popa
    
    ; 4. Draw content area
    pusha
    mov  eax, [edi+0]
    add  eax, 5
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 26
    mov  ecx, [edi+8]
    sub  ecx, 10
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 31
    mov  esi, 0x0F      ; white background for content
    call fb_fill_rect
    
    ; Draw current content (multi-line)
    mov  eax, [edi+0]
    add  eax, 9             ; content x
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 30 ; content y
    mov  ecx, [edi+8]
    sub  ecx, 18            ; content w
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 35 ; content h
    
    mov  esi, browser_content
    call browser_draw_content
    popa
    
    popa
    ret

; - browser_draw_content -
; In: ESI=content, EAX=x0, EBX=y0, ECX=w, EDX=h
browser_draw_content:
    pusha
    mov  [br_x0], eax
    mov  [br_y0], ebx
    mov  [br_w],  ecx
    mov  [br_h],  edx
    
    mov  [br_cx], eax
    mov  [br_cy], ebx
    
.loop:
    movzx eax, byte [esi]
    inc  esi
    test al, al
    jz   .done
    
    cmp  al, 13             ; CR
    je   .cr
    cmp  al, 10             ; LF
    je   .lf
    
    ; check wrap
    mov  edx, [br_cx]
    sub  edx, [br_x0]
    add  edx, 8
    cmp  edx, [br_w]
    ja   .wrap
    
    ; draw char
    mov  ebx, [br_cx]
    mov  ecx, [br_cy]
    mov  dl, 0x00           ; black
    mov  dh, 0x0F           ; white
    call fb_draw_char
    
    add  dword [br_cx], 8
    jmp  .loop

.cr:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    jmp  .loop
    
.lf:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    add  dword [br_cy], 8
    ; check bottom clip
    mov  eax, [br_cy]
    sub  eax, [br_y0]
    add  eax, 8
    cmp  eax, [br_h]
    ja   .done
    jmp  .loop

.wrap:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    add  dword [br_cy], 8
    ; check bottom clip
    mov  eax, [br_cy]
    sub  eax, [br_y0]
    add  eax, 8
    cmp  eax, [br_h]
    ja   .done
    dec  esi                ; re-process current char
    jmp  .loop

.done:
    popa
    ret

; helper vars
br_x0: dd 0
br_y0: dd 0
br_w:  dd 0
br_h:  dd 0
br_cx: dd 0
br_cy: dd 0

; - browser_tick -
browser_tick:
    pusha
    
    ; find focused browser
    mov  dword [wm_i], 0
.loop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1       ; open?
    jne  .next
    cmp  byte [edi+18], 1       ; focused?
    jne  .next
    cmp  byte [edi+16], WM_BROWSER
    jne  .next
    
    ; Focused browser found!
    ; Check keyboard
    in   al, 0x64
    test al, 0x01
    jz   .done
    test al, 0x20
    jnz  .done
    call pm_getkey
    or   al, al
    jz   .done
    
    ; Handle key
    cmp  al, 8 ; backspace
    je   .bs
    cmp  al, 13 ; enter
    je   .go
    cmp  al, 32
    jl   .done
    cmp  al, 127
    jge  .done
    
    ; Append to URL
    mov  edi, browser_url
    xor  ecx, ecx
.find_end:
    cmp  byte [edi+ecx], 0
    je   .found
    inc  ecx
    cmp  ecx, 250
    jl   .find_end
    jmp  .done
.found:
    mov  [edi+ecx], al
    mov  byte [edi+ecx+1], 0
    call wm_draw_all
    jmp  .done
    
.bs:
    mov  edi, browser_url
    xor  ecx, ecx
.find_end2:
    cmp  byte [edi+ecx], 0
    je   .found2
    inc  ecx
    cmp  ecx, 250
    jl   .find_end2
    jmp  .done
.found2:
    test ecx, ecx
    jz   .done
    mov  byte [edi+ecx-1], 0
    call wm_draw_all
    jmp  .done
    
.go:
    call browser_fetch
    call wm_draw_all
    jmp  .done

.next:
    inc  dword [wm_i]
    jmp  .loop
.done:
    popa
    ret

; - browser_click -
; In: EAX=mx, EBX=my, EDI=window record
browser_click:
    pusha
    
    ; coordinates relative to window
    sub  eax, [edi+0]
    sub  ebx, [edi+4]
    
    ; check Go button: x in [ww-50, ww-5], y in [TITLE+5, TITLE+21]
    mov  edx, [edi+8]
    sub  edx, 50
    cmp  eax, edx
    jl   .done
    mov  edx, [edi+8]
    sub  edx, 5
    cmp  eax, edx
    jg   .done
    
    cmp  ebx, WM_TITLE_H + 5
    jl   .done
    cmp  ebx, WM_TITLE_H + 21
    jg   .done
    
    ; Clicked Go!
    call browser_fetch
    call wm_draw_all
    
.done:
    popa
    ret

; - browser_fetch -
browser_fetch:
    pusha
    
    ; 1. Set "Fetching..." message
    mov  edi, browser_content
    mov  esi, browser_s_fetching
    call .copy_str
    call wm_draw_all
    
    ; 2. Parse URL (simple IP support for now)
    ; We'll reuse the tcpget logic. 
    ; For now, let's hardcode a test fetch if URL is "test"
    
    ; Actual fetch logic (simplified version of cmd_tcpget)
    ; In a real browser we'd parse "http://ip:port/path"
    ; For "simple", we'll just assume browser_url contains "ip port path"
    
    mov  esi, browser_url
    call pm_parse_ip
    test eax, eax
    jz   .err_url
    mov  [tcpg_dst_ip], eax
    
    ; skip to port
.skip1:
    lodsb
    test al, al
    jz   .err_url
    cmp  al, ' '
    jne  .skip1
    
    call pm_parse_uint
    test eax, eax
    jz   .err_url
    mov  [tcpg_dst_port], ax
    
    ; skip to path
.skip2:
    lodsb
    test al, al
    jz   .err_url
    cmp  al, ' '
    jne  .skip2
    mov  [tcpg_path_ptr], esi
    
    ; Connect
    mov  eax, [tcpg_dst_ip]
    movzx ecx, word [tcpg_dst_port]
    call tcp_connect
    jc   .err_conn
    
    ; Request
    mov  edi, tcpg_req_buf
    mov  byte [edi+0], 'G'
    mov  byte [edi+1], 'E'
    mov  byte [edi+2], 'T'
    mov  byte [edi+3], ' '
    add  edi, 4
    mov  esi, [tcpg_path_ptr]
.copy_p:
    lodsb
    stosb
    test al, al
    jnz  .copy_p
    dec  edi                ; overwrite null with space
    
    mov  esi, tcpg_str_http10
    call .append_s
    mov  esi, browser_s_hdr_host
    call .append_s
    mov  esi, tcpg_str_connclose
    call .append_s
    mov  byte [edi], 0
    
    mov  ecx, edi
    sub  ecx, tcpg_req_buf
    mov  esi, tcpg_req_buf
    call tcp_send
    jc   .err_send
    
    ; Receive into browser_content
    mov  dword [tcpg_total], 0
    mov  edi, browser_content
    xor  eax, eax
    mov  ecx, 4096
    rep  stosd              ; clear 16KB
    
    mov  edi, browser_content
.recv_loop:
    ; Progress feedback: draw simple dot or status bit
    ; (Could do more but let's keep it simple for now)
    
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .do_recv
    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .do_recv
    jmp  .recv_done

.do_recv:
    mov  ecx, 1400
    push edi
    mov  edi, tcpg_recv_buf
    call tcp_recv
    pop  edi
    jc   .recv_done         ; error or timeout
    test ecx, ecx
    jz   .recv_done         ; EOF
    
    ; Safety check: don't overflow browser_content (16KB)
    mov  eax, edi
    sub  eax, browser_content
    add  eax, ecx
    cmp  eax, 16000
    jae  .recv_done         ; stop if near limit
    
    ; Copy from tcpg_recv_buf to browser_content
    push ecx
    mov  esi, tcpg_recv_buf
.copy_data:
    lodsb
    ; Optional: strip non-printable or handle line endings here
    mov  [edi], al
    inc  edi
    dec  ecx
    jnz  .copy_data
    pop  ecx
    
    ; [NEW] Brief progress update: redraw browser content while fetching
    ; This helps show it's not "dead" even if it's blocking
    mov  byte [edi], 0      ; null term for draw
    push edi
    call wm_draw_all
    pop  edi
    
    jmp  .recv_loop

.recv_done:
    mov  byte [edi], 0      ; Final null terminator
    call tcp_close
    jmp  .done

.err_url:
    mov  esi, browser_s_err_url
    jmp  .set_msg
.err_conn:
    mov  esi, browser_s_err_conn
    jmp  .set_msg
.err_send:
    mov  esi, browser_s_err_send
.set_msg:
    mov  edi, browser_content
    call .copy_str
.done:
    popa
    ret

.copy_str:
    lodsb
    stosb
    test al, al
    jnz  .copy_str
    ret

.append_s:
    lodsb
    stosb
    test al, al
    jnz  .append_s
    dec  edi                ; keep edi at null
    ret

; - Data -
browser_url:     times 256 db 0
browser_content: times 16384 db 0
browser_s_go:    db 'Go', 0
browser_s_default_url: db '142.250.180.142 80 /', 0
browser_s_hdr_host:    db 'Host: google.com', 13, 10, 0
browser_s_welcome: db 'Welcome to NatureOS Browser!', 13, 10, 'Usage: IP PORT PATH (space-separated)', 0
browser_s_fetching: db 'Fetching...', 0
browser_s_err_url:  db 'Error: Invalid URL format.', 0
browser_s_err_conn: db 'Error: Connection failed.', 0
browser_s_err_send: db 'Error: Send failed.', 0
