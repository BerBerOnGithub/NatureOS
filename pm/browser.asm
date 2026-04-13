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
    
    cmp  al, '<'            ; HTML tag start?
    je   .skip_tag
    
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

.skip_tag:
    mov  al, [esi]
    inc  esi
    test al, al
    jz   .done
    cmp  al, '>'
    jne  .skip_tag
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
br_hdr_state: db 0
br_header_done: db 0
browser_tmp_host: times 64 db 0

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
    
    ; 2. Parse URL (HOSTNAME PORT PATH)
    mov  esi, browser_url
    ; Extract hostname/IP part (until space or null)
    mov  edi, browser_tmp_host
    mov  ecx, 0
.copy_host:
    lodsb
    cmp  al, ' '
    je   .host_done
    cmp  al, 0
    je   .host_done
    stosb
    inc  ecx
    cmp  ecx, 63
    jl   .copy_host
.host_done:
    mov  byte [edi], 0
    
    ; Try parsing browser_tmp_host as IP
    push esi
    mov  esi, browser_tmp_host
    call pm_parse_ip
    test eax, eax
    jnz  .got_ip
    
    ; Try DNS
    mov  esi, browser_tmp_host
    call dns_resolve
    pop  esi
    jc   .err_url
    jmp  .got_ip2
    
.got_ip:
    pop  esi
.got_ip2:
    mov  [tcpg_dst_ip], eax
    
    ; Now ESI points to just after hostname in browser_url (at ' ' or 0)
    cmp  byte [esi-1], 0
    je   .err_url
    
    call pm_parse_uint
    test eax, eax
    jz   .err_url
    mov  [tcpg_dst_port], ax
    
    ; Check for space then path
    lodsb
    cmp  al, ' '
    jne  .err_url
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
    
    ; Host: <hostname>
    mov  esi, browser_s_hdr_host_pre
    call .append_s
    mov  esi, browser_tmp_host
    call .append_s
    mov  esi, browser_s_crlf
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
    
    mov  byte [br_header_done], 0
    mov  byte [br_hdr_state], 0
    mov  edi, browser_content
.recv_loop:
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
    jc   .recv_done
    test ecx, ecx
    jz   .recv_done
    
    mov  esi, tcpg_recv_buf
.process_packet:
    lodsb
    cmp  byte [br_header_done], 1
    je   .copy_to_content
    
    ; State machine for \r\n\r\n
    cmp  al, 13
    jne  .not_r
    cmp  byte [br_hdr_state], 0
    je   .st1
    cmp  byte [br_hdr_state], 2
    je   .st3
    mov  byte [br_hdr_state], 1
    jmp  .next_b
.st1: mov  byte [br_hdr_state], 1
    jmp  .next_b
.st3: mov  byte [br_hdr_state], 3
    jmp  .next_b

.not_r:
    cmp  al, 10
    jne  .not_n
    cmp  byte [br_hdr_state], 1
    je   .st2
    cmp  byte [br_hdr_state], 3
    je   .st4
    mov  byte [br_hdr_state], 0
    jmp  .next_b
.st2: mov  byte [br_hdr_state], 2
    jmp  .next_b
.st4: mov  byte [br_header_done], 1
    jmp  .next_b

.not_n:
    mov  byte [br_hdr_state], 0
    jmp  .next_b

.copy_to_content:
    push eax
    mov  eax, edi
    sub  eax, browser_content
    cmp  eax, 16000
    pop  eax
    jae  .recv_done
    
    mov  [edi], al
    inc  edi

.next_b:
    loop .process_packet
    
    mov  byte [edi], 0
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
browser_s_default_url: db 'google.com 80 /', 0
browser_s_hdr_host_pre: db 'Host: ', 0
browser_s_crlf:         db 13, 10, 0
browser_s_welcome: db 'Welcome to NatureOS Browser!', 13, 10, 'Usage: HOST PORT PATH (space-separated)', 0
browser_s_fetching: db 'Fetching...', 0
browser_s_err_url:  db 'Error: Invalid URL format.', 0
browser_s_err_conn: db 'Error: Connection failed.', 0
browser_s_err_send: db 'Error: Send failed.', 0
