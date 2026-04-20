; ===========================================================================
; pm/browser.asm  -  NatureOS Simple Web Browser
; ===========================================================================

[BITS 32]

; DNS source port used when sending DNS queries from the browser
DNS_SRC_PORT    equ 4096    ; same ephemeral port as UDP_SRC_PORT in udp.asm

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
    sub  ecx, 32            ; content w (leave room for scrollbar)
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 35 ; content h
    
    mov  esi, browser_content
    call browser_draw_content
    
    ; Draw scrollbar
    mov  ebx, eax
    add  ebx, ecx
    add  ebx, 4
    mov  [wm_sb_x], ebx
    mov  eax, [br_y0]
    mov  [wm_sb_y], eax
    mov  dword [wm_sb_w], 10
    mov  eax, [br_h]
    mov  [wm_sb_h], eax
    mov  [wm_sb_visible], eax
    
    ; if total_h == 0, make it at least visible to draw full thumb
    mov  eax, [browser_total_h]
    test eax, eax
    jnz  .total_ok
    mov  eax, [wm_sb_visible]
.total_ok:
    mov  [wm_sb_total], eax
    mov  eax, [browser_scroll_y]
    mov  [wm_sb_pos], eax
    call wm_draw_scrollbar
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
    
    cmp  al, 9              ; Tab
    jne  .not_tab
    mov  al, 32             ; convert to space
.not_tab:
    cmp  al, 32
    jl   .loop              ; skip other control codes
    
    ; check wrap
    mov  edx, [br_cx]
    sub  edx, [br_x0]
    add  edx, 8
    cmp  edx, [br_w]
    ja   .wrap
    
    ; check vertical clip against scroll
    mov  ecx, [br_cy]
    sub  ecx, [browser_scroll_y]
    
    cmp  ecx, [br_y0]
    jl   .skip_draw
    
    mov  edx, ecx
    sub  edx, [br_y0]
    add  edx, 8
    cmp  edx, [br_h]
    jbe  .do_draw
    
    ; Below visible screen
    cmp  byte [browser_measuring], 1
    je   .skip_draw
    jmp  .exit

.do_draw:
    cmp  byte [browser_measuring], 1
    je   .skip_draw
    
    ; draw char
    mov  ebx, [br_cx]
    mov  dl, 0x00           ; black
    mov  dh, 0x0F           ; white
    call fb_draw_char
    
.skip_draw:
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
    jmp  .loop

.wrap:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    add  dword [br_cy], 8
    dec  esi                ; re-process current char
    jmp  .loop

.done:
    cmp  byte [browser_measuring], 1
    jne  .exit
    mov  eax, [br_cy]
    add  eax, 8
    sub  eax, [br_y0]
    mov  [browser_total_h], eax
.exit:
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
.key_loop:
    call pm_getkey
    or   al, al
    jz   .done
    
    ; Handle key
    cmp  al, 8 ; backspace
    je   .bs
    cmp  al, 13 ; enter
    je   .go
    cmp  al, 0x80 ; Up
    je   .scroll_up
    cmp  al, 0x81 ; Down
    je   .scroll_down
    cmp  al, 32
    jl   .key_loop
    cmp  al, 127
    jge  .key_loop
    
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
    call wm_invalidate
    jmp  .key_loop
    
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
    jz   .key_loop
    mov  byte [edi+ecx-1], 0
    call wm_invalidate
    jmp  .key_loop
    
.go:
    call browser_fetch
    call wm_invalidate
    jmp  .key_loop

.next:
    inc  dword [wm_i]
    jmp  .loop
.scroll_up:
    cmp  dword [browser_scroll_y], 8
    jl   .zero_scroll
    sub  dword [browser_scroll_y], 16
    call wm_invalidate
    jmp  .key_loop
.zero_scroll:
    mov  dword [browser_scroll_y], 0
    call wm_invalidate
    jmp  .key_loop
.scroll_down:
    mov  eax, [browser_total_h]
    sub  eax, [br_h]
    cmp  eax, 0
    jle  .key_loop
    mov  ebx, [browser_scroll_y]
    add  ebx, 16
    cmp  ebx, eax
    jge  .max_scroll
    mov  [browser_scroll_y], ebx
    call wm_invalidate
    jmp  .key_loop
.max_scroll:
    mov  [browser_scroll_y], eax
    call wm_invalidate
    jmp  .key_loop
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
    jl   .check_scroll
    mov  edx, [edi+8]
    sub  edx, 5
    cmp  eax, edx
    jg   .check_scroll
    
    cmp  ebx, WM_TITLE_H + 5
    jl   .check_scroll
    cmp  ebx, WM_TITLE_H + 21
    jg   .check_scroll
    
    ; Clicked Go!
    call browser_fetch
    call wm_invalidate
    jmp  .done

.check_scroll:
    mov  edx, [edi+8]
    sub  edx, 24
    cmp  eax, edx
    jl   .done
    
    cmp  ebx, WM_TITLE_H + 30
    jl   .done
    mov  edx, [edi+12]
    sub  edx, 5
    cmp  ebx, edx
    jg   .done

    sub  ebx, WM_TITLE_H + 30
    mov  ecx, [edi+12]
    sub  ecx, WM_TITLE_H + 35
    test ecx, ecx
    jle  .done
    mov  eax, [browser_total_h]
    sub  eax, ecx
    cmp  eax, 0
    jle  .done
    xchg eax, ebx
    imul ebx
    xor  edx, edx
    div  ecx
    mov  [browser_scroll_y], eax
    call wm_invalidate

.done:
    popa
    ret

; - browser_parse_url -
; Parse "http://hostname:port/path" into components
; In: ESI = URL string
; Out: EAX = IP (resolved) or 0 on error
;      AX = port, ESI = path pointer
;      browser_hostname populated
browser_parse_url:
    push ebx
    push ecx
    push edx
    push edi

    ; Skip "http://" prefix
    mov  edi, browser_hostname
    xor  ecx, ecx
.check_prefix:
    mov  al, [esi + ecx]
    mov  bl, [http_prefix + ecx]
    test bl, bl
    jz   .prefix_ok
    cmp  al, bl
    jne  .old_format
    inc  ecx
    jmp  .check_prefix

.prefix_ok:
    add  esi, ecx              ; skip "http://"
    jmp  .parse_hostname

.old_format:
    ; Not a URL, might be old "IP PORT PATH" format
    mov  esi, browser_url
    call pm_parse_ip
    test eax, eax
    jz   .error
    mov  [tcpg_dst_ip], eax

    ; skip to port
.skip1:
    lodsb
    test al, al
    jz   .error
    cmp  al, ' '
    jne  .skip1

    call pm_parse_uint
    test eax, eax
    jz   .error
    mov  [tcpg_dst_port], ax

    ; skip to path
.skip2:
    lodsb
    test al, al
    jz   .error
    cmp  al, ' '
    jne  .skip2
    mov  [tcpg_path_ptr], esi

    ; Return with EAX=IP already set
    jmp  .done

.parse_hostname:
    ; Extract hostname until ':' or '/'
    mov  edi, browser_hostname
    xor  ebx, ebx                ; hostname length

.host_loop:
    mov  al, [esi]
    test al, al
    jz   .host_done
    cmp  al, ':'
    je   .host_done
    cmp  al, '/'
    je   .host_done
    stosb
    inc  ebx
    inc  esi
    cmp  ebx, 253
    jl  .host_loop
.host_done:
    mov  byte [edi], 0           ; null-terminate hostname

    ; Check for port
    cmp  byte [esi], ':'
    jne  .default_port
    inc  esi                      ; skip ':'
    call pm_parse_uint
    test eax, eax
    jz   .error
    mov  [tcpg_dst_port], ax
    jmp  .check_path

.default_port:
    mov  word [tcpg_dst_port], 80

.check_path:
    ; Check for path
    cmp  byte [esi], '/'
    je   .has_path
    ; No path, use default
    mov  esi, browser_s_def_path
    jmp  .got_path

.has_path:
    ; Path already at ESI

.got_path:
    mov  [tcpg_path_ptr], esi

    ; Resolve hostname via DNS
    mov  esi, browser_hostname
    call dns_resolve_hostname
    jc   .error                  ; CF=1 means DNS failed

    ; EAX = resolved IP
    mov  [tcpg_dst_ip], eax
    clc
    jmp  .done

.error:
    xor  eax, eax
    stc

.done:
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - dns_resolve_hostname -
; Resolve hostname to IP using DNS
; In: ESI = hostname (null-terminated)
; Out: EAX = IP (host order), CF=0 success, CF=1 failed
dns_resolve_hostname:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov  [dns_tmp_hostname], esi

    ; Build DNS query
    mov  esi, [dns_tmp_hostname]
    call dns_build_query
    test ecx, ecx
    jz   .fail

    ; Send to DNS server (10.0.2.3:53)
    mov  eax, DNS_SERVER_IP
    mov  bx,  DNS_SRC_PORT
    mov  edx, ecx                ; save packet length
    mov  cx,  DNS_PORT
    mov  esi, dns_pkt_buf
    call udp_send
    jc   .fail

    ; Poll for DNS response
    mov  dword [dns_poll_ctr], 2000000
.dns_poll:
    inc  dword [net_poll_throttle]
    test dword [net_poll_throttle], 0x3FF
    jnz  .skip_hw
    call mouse_poll
    call pm_kb_poll
.skip_hw:
    call eth_recv
    jc   .dns_empty

    ; Skip ARP packets
    cmp  dx, ETHERTYPE_ARP
    jne  .dns_not_arp
    call arp_process
    jmp  .dns_poll
.dns_not_arp:

    ; Must be IPv4 UDP
    cmp  dx, ETHERTYPE_IPV4
    jne  .dns_poll
    cmp  ecx, 20 + UDP_HDR_LEN
    jl  .dns_poll
    cmp  byte [esi], 0x45
    jne  .dns_poll
    cmp  byte [esi + 9], IP_PROTO_UDP
    jne  .dns_poll

    ; Check UDP port matches our source port
    mov  ax, [esi + 20 + 2]      ; UDP dst port
    xchg al, ah
    cmp  ax, DNS_SRC_PORT
    jne  .dns_poll

    ; Get UDP payload length
    mov  ax, [esi + 20 + 4]
    xchg al, ah
    movzx ecx, ax
    sub  ecx, UDP_HDR_LEN
    cmp  ecx, 12
    jl  .dns_poll

    ; Copy DNS payload to dns_pkt_buf
    push esi
    push ecx
    push edi
    add  esi, 20 + UDP_HDR_LEN
    mov  edi, dns_pkt_buf
    rep  movsb
    pop  edi
    pop  ecx
    pop  esi

    call dns_parse_response
    jnc  .dns_success
    jmp  .dns_poll

.dns_empty:
    dec  dword [dns_poll_ctr]
    jnz  .dns_poll

.fail:
    stc
    jmp  .done

.dns_success:
    clc

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - browser_strip_headers -
; Strip HTTP headers from response, keeping only body
; In: ESI = response buffer, EDI = destination buffer
; Out: EDI updated to start of body
browser_strip_headers:
    push eax
    push ecx
    push esi

.strip_loop:
    movzx eax, byte [esi]
    test al, al
    jz   .not_found
    cmp  eax, 0x0D              ; CR
    jne  .check_lf1
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0D              ; CR
    jne  .not_found
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    ; Found \r\n\r\n - ESI now points to body
    jmp  .found
.check_lf1:
    cmp  eax, 0x0A              ; LF
    jne  .next_char
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    ; Found \n\n - ESI now points to body
    jmp  .found
.next_char:
    inc  esi
    jmp  .strip_loop

.not_found:
    ; No headers found, copy everything
    mov  esi, browser_content
    jmp  .copy_loop
.found:
    ; Copy body to destination
.copy_loop:
    movzx eax, byte [esi]
    test al, al
    jz   .done
    stosb
    inc  esi
    jmp  .copy_loop

.done:
    mov  byte [edi], 0          ; null-terminate
    pop  esi
    pop  ecx
    pop  eax
    ret

; - browser_fetch -
browser_fetch:
    pusha

    ; 1. Set "Fetching..." message
    mov  dword [browser_scroll_y], 0
    mov  dword [browser_total_h], 0
    mov  edi, browser_content
    mov  esi, browser_s_fetching
    call .copy_str
    call wm_invalidate

    ; 2. Parse URL
    mov  esi, browser_url
    call browser_parse_url
    test eax, eax
    jz   .err_url
    ; IP now in tcpg_dst_ip, port in tcpg_dst_port, path ptr set

    ; Connect
    mov  eax, [tcpg_dst_ip]
    movzx ecx, word [tcpg_dst_port]
    call tcp_connect
    jc   .err_conn

    ; Request - build HTTP GET with dynamic Host header
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

    ; Host header
    mov  esi, tcpg_str_host
    call .append_s
    mov  esi, browser_hostname
    call .append_s
    mov  byte [edi], 13
    inc  edi
    mov  byte [edi], 10
    inc  edi

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
    mov  ecx, 125000
    rep  stosd              ; clear 500KB
    
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
    
    ; Safety check: don't overflow browser_content (500KB)
    mov  eax, edi
    sub  eax, browser_content
    add  eax, ecx
    cmp  eax, 500000
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
    ; (Removed wm_draw_all here to prevent 50ms freezing per packet)
    
    jmp  .recv_loop

.recv_done:
    mov  byte [edi], 0      ; Final null terminator before stripping
    call tcp_close

    ; Strip HTTP headers to show only body content
    mov  esi, browser_content
    mov  edi, browser_content
    call browser_strip_headers

    ; Measure text height before drawing
    mov  byte [browser_measuring], 1
    mov  esi, browser_content
    mov  eax, [br_x0]
    mov  ebx, [br_y0]
    mov  ecx, [br_w]
    mov  edx, [br_h]
    call browser_draw_content
    mov  byte [browser_measuring], 0

    call wm_invalidate
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
browser_content  equ 0x140000
browser_s_go:    db 'Go', 0
browser_s_default_url: db '142.250.180.142 80 /', 0
browser_s_hdr_host:    db 'Host: google.com', 13, 10, 0
browser_s_welcome: db 'Welcome to NatureOS Browser!', 13, 10, 'Usage: http://hostname/path or IP PORT PATH', 0
browser_s_fetching: db 'Fetching...', 0
browser_s_err_url:  db 'Error: Invalid URL format.', 0
browser_s_err_conn: db 'Error: Connection failed.', 0
browser_s_err_send: db 'Error: Send failed.', 0

; Missing data symbols referenced by browser_parse_url / dns_resolve_hostname / browser_fetch
browser_hostname:   times 256 db 0     ; buffer for parsed hostname (null-terminated)
http_prefix:        db 'http://', 0    ; URL scheme prefix to detect and strip
browser_s_def_path: db '/', 0          ; default path when URL has no explicit path
dns_tmp_hostname:   dd 0               ; pointer to hostname being resolved
browser_scroll_y:   dd 0               ; virtual scroll offset
browser_total_h:    dd 0               ; total content height
browser_measuring:  db 0               ; 1 = measure height without drawing
