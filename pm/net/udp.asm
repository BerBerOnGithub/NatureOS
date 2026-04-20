; ===========================================================================
; pm/net/udp.asm  -  UDP layer  (RFC 768)
;
; Provides a minimal UDP send/receive layer plus a DNS lookup command.
;
; UDP header (8 bytes):
;   [0]  src port   2  BE
;   [2]  dst port   2  BE
;   [4]  length     2  BE  (header + data)
;   [6]  checksum   2  BE  (0 = disabled, simplest valid option for IPv4)
;
; Public interface:
;   udp_send   EAX=dst_ip, BX=src_port, CX=dst_port, ESI=payload, EDX=len
;              -> CF=0 ok, CF=1 error
;   udp_recv   BX=expected_dst_port, EDI=buf -> ECX=payload_len, EAX=src_ip
;              -> CF=0 ok, CF=1 no matching packet
;   cmd_dns    shell: dns <hostname>  ->  resolve via QEMU SLIRP DNS (10.0.2.3)
; ===========================================================================

[BITS 32]

UDP_HDR_LEN     equ 8
UDP_SRC_PORT    equ 4096    ; ephemeral source port we use for outgoing queries

; QEMU SLIRP well-known addresses
DNS_SERVER_IP   equ 0x0A000203   ; 10.0.2.3
DNS_PORT        equ 53

; -
; udp_send - build UDP header and send via IP
;
; In:  EAX = destination IP (host order)
;      BX  = source port (host order)
;      CX  = destination port (host order)
;      ESI = payload pointer
;      EDX = payload length in bytes
; Out: CF=0 ok, CF=1 error
; -
udp_send:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp  edx, 1472           ; max UDP payload (1500 - 20 IP - 8 UDP)
    ja   .err

    mov  [udp_tx_dst_ip],   eax
    mov  [udp_tx_src_port], bx
    mov  [udp_tx_dst_port], cx
    mov  [udp_tx_pld_ptr],  esi
    mov  [udp_tx_pld_len],  edx

    ; build UDP header + payload in udp_tx_buf
    mov  edi, udp_tx_buf

    ; source port (big-endian)
    mov  ax, [udp_tx_src_port]
    xchg al, ah
    mov  [edi + 0], ax

    ; destination port (big-endian)
    mov  ax, [udp_tx_dst_port]
    xchg al, ah
    mov  [edi + 2], ax

    ; length = header + payload (big-endian)
    mov  eax, [udp_tx_pld_len]
    add  eax, UDP_HDR_LEN
    xchg al, ah
    mov  [edi + 4], ax

    ; checksum = 0 (disabled - legal for IPv4 UDP)
    mov  word [edi + 6], 0

    ; copy payload
    push esi
    push edi
    mov  esi, [udp_tx_pld_ptr]
    mov  edi, udp_tx_buf + UDP_HDR_LEN
    mov  ecx, [udp_tx_pld_len]
    rep  movsb
    pop  edi
    pop  esi

    ; total UDP segment length
    mov  ecx, [udp_tx_pld_len]
    add  ecx, UDP_HDR_LEN

    ; send via IP
    mov  esi, udp_tx_buf
    mov  eax, [udp_tx_dst_ip]
    mov  bl,  IP_PROTO_UDP
    call ip_send

    jmp  .done
.err:
    stc
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; udp_recv - check for a UDP packet on a given port
;
; In:  BX  = destination port to filter on (host order)
;      EDI = buffer for payload
; Out: CF=0 -> ECX=payload length, EAX=sender IP (host order)
;      CF=1 -> no matching packet
; -
udp_recv:
    push ebx
    push edx
    push esi

    mov  [udp_rx_want_port], bx

    ; poll IP layer
    call eth_recv
    jc   .no_pkt

    cmp  dx, ETHERTYPE_IPV4
    jne  .no_pkt

    cmp  ecx, 20 + UDP_HDR_LEN
    jl   .no_pkt

    ; validate IPv4: version=4, no options
    cmp  byte [esi], 0x45
    jne  .no_pkt
    cmp  byte [esi + 9], IP_PROTO_UDP
    jne  .no_pkt

    ; extract source IP
    mov  eax, [esi + 12]
    bswap eax
    mov  [udp_rx_src_ip], eax

    ; total length from IP header
    mov  bx, [esi + 2]
    xchg bl, bh
    movzx ecx, bx
    sub  ecx, 20             ; IP payload length

    ; advance to UDP header
    add  esi, 20

    ; check destination port (big-endian in packet)
    mov  ax, [esi + 2]
    xchg al, ah
    cmp  ax, [udp_rx_want_port]
    jne  .no_pkt

    ; UDP payload length from header
    mov  ax, [esi + 4]
    xchg al, ah
    movzx ecx, ax
    sub  ecx, UDP_HDR_LEN

    ; copy payload to caller buffer
    push esi
    add  esi, UDP_HDR_LEN
    push ecx
    rep  movsb
    pop  ecx
    pop  esi

    mov  eax, [udp_rx_src_ip]
    clc
    jmp  .done

.no_pkt:
    stc
.done:
    pop  esi
    pop  edx
    pop  ebx
    ret

; -
; dns_build_query - build a minimal DNS A-record query in dns_pkt_buf
;
; In:  ESI = null-terminated hostname
; Out: ECX = total packet length, dns_pkt_buf populated
;      dns_query_id set to a pseudo-random value
; -
dns_build_query:
    push eax
    push ebx
    push esi
    push edi

    ; pseudo-random query ID from PIT tick counter
    mov  eax, [pit_ticks]
    and  eax, 0xFFFF
    mov  [dns_query_id], ax
    mov  edi, dns_pkt_buf

    ; Transaction ID (big-endian)
    mov  ax, [dns_query_id]
    xchg al, ah
    mov  [edi + 0], ax

    ; Flags: standard query, recursion desired (0x0100 BE = 0x01 0x00)
    mov  word [edi + 2], 0x0001   ; 0x0100 BE

    ; QDCOUNT = 1
    mov  word [edi + 4], 0x0100   ; 0x0001 BE

    ; ANCOUNT, NSCOUNT, ARCOUNT = 0
    mov  dword [edi + 6], 0
    mov  word  [edi + 10], 0

    ; encode QNAME: split hostname on '.' into length-prefixed labels
    add  edi, 12             ; skip fixed header

.label_loop:
    ; find next '.' or end of string
    push esi
    xor  ecx, ecx
.count_label:
    mov  al, [esi + ecx]
    test al, al
    jz   .label_end
    cmp  al, '.'
    je   .label_end
    inc  ecx
    jmp  .count_label
.label_end:
    pop  esi

    test ecx, ecx
    jz   .qname_done         ; empty label = end

    ; write length byte then label characters
    mov  [edi], cl
    inc  edi
    push ecx
    push esi
    rep  movsb               ; copy ecx bytes from [esi] to [edi]
    pop  esi
    pop  ecx
    add  esi, ecx
    cmp  byte [esi], '.'
    jne  .qname_done
    inc  esi                 ; skip the dot
    jmp  .label_loop

.qname_done:
    ; terminating zero-length label
    mov  byte [edi], 0
    inc  edi

    ; QTYPE = A (1)
    mov  word [edi + 0], 0x0100   ; 0x0001 BE

    ; QCLASS = IN (1)
    mov  word [edi + 2], 0x0100   ; 0x0001 BE
    add  edi, 4

    ; total length = edi - dns_pkt_buf
    mov  ecx, edi
    sub  ecx, dns_pkt_buf

    pop  edi
    pop  esi
    pop  ebx
    pop  eax
    ret

; -
; dns_parse_response - extract first A record IP from dns_pkt_buf
;
; In:  ECX = response length (bytes in dns_pkt_buf)
; Out: CF=0 -> EAX = resolved IPv4 (host order)
;      CF=1 -> no A record found
; -
dns_parse_response:
    push ebx
    push ecx
    push esi

    mov  esi, dns_pkt_buf

    ; minimum DNS response size: 12 bytes header
    cmp  ecx, 12
    jl   .fail

    ; check transaction ID matches
    mov  ax, [esi + 0]
    xchg al, ah
    cmp  ax, [dns_query_id]
    jne  .fail

    ; check QR bit set (bit 15 of flags = response)
    test byte [esi + 2], 0x80
    jz   .fail

    ; ANCOUNT (big-endian)
    mov  ax, [esi + 6]
    xchg al, ah
    test ax, ax
    jz   .fail               ; no answers

    ; skip header (12) + question section
    ; question section: QNAME (variable) + QTYPE(2) + QCLASS(2)
    add  esi, 12
    mov  ecx, esi

    ; skip QNAME: read length bytes until zero label
.skip_qname:
    mov  al, [esi]
    inc  esi
    test al, al
    jz   .skip_qname_done
    test al, 0xC0            ; compression pointer?
    jnz  .ptr_skip
    movzx eax, al
    add  esi, eax
    jmp  .skip_qname
.ptr_skip:
    inc  esi                 ; skip second byte of pointer
    jmp  .skip_qname_done

.skip_qname_done:
    add  esi, 4              ; skip QTYPE + QCLASS

    ; now at first answer RR
    ; RR: NAME(variable) TYPE(2) CLASS(2) TTL(4) RDLENGTH(2) RDATA
.scan_answers:
    ; skip RR NAME (may be compression pointer)
    mov  al, [esi]
    test al, 0xC0
    jnz  .rr_name_ptr
    ; label encoding - skip
    test al, al
    jnz  .rr_name_label
    inc  esi                 ; skip root label
    jmp  .rr_type
.rr_name_label:
    movzx eax, al
    inc   esi
    add   esi, eax
    jmp  .scan_answers
.rr_name_ptr:
    add  esi, 2              ; skip 2-byte pointer
    jmp  .rr_type

.rr_type:
    ; TYPE (big-endian)
    mov  ax, [esi + 0]
    xchg al, ah
    ; CLASS
    mov  bx, [esi + 2]
    xchg bl, bh
    ; RDLENGTH
    mov  cx, [esi + 8]
    xchg cl, ch

    ; is this an A record (type=1, class=IN=1)?
    cmp  ax, 1
    jne  .skip_rr
    cmp  bx, 1
    jne  .skip_rr
    cmp  cx, 4
    jne  .skip_rr

    ; found! read RDATA (4-byte IPv4 in network order)
    mov  eax, [esi + 10]
    bswap eax               ; to host order
    add  esi, 10             ; no longer needed, just clean up
    clc
    jmp  .done

.skip_rr:
    add  esi, 10             ; skip to RDATA
    movzx eax, cx
    add  esi, eax            ; skip RDATA
    jmp  .scan_answers       ; try next RR (simplified - no bounds check)

.fail:
    stc
.done:
    pop  esi
    pop  ecx
    pop  ebx
    ret

; -
; cmd_dns - resolve a hostname via DNS (QEMU SLIRP DNS at 10.0.2.3)
; Usage: dns <hostname>
; -
cmd_dns:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; parse hostname from input (skip "dns ")
    mov  esi, pm_input_buf
    add  esi, 4

    ; check not empty
    cmp  byte [esi], 0
    je   .usage

    mov  [dns_hostname_ptr], esi

    call pm_newline
    mov  esi, pm_str_dns_query
    mov  bl,  0x0B
    call pm_puts
    mov  esi, [dns_hostname_ptr]
    mov  bl,  0x0F
    call pm_puts
    mov  esi, pm_str_dns_dots
    mov  bl,  0x07
    call pm_puts

    ; build DNS query packet
    mov  esi, [dns_hostname_ptr]
    call dns_build_query     ; ECX = packet length, dns_pkt_buf populated

    ; send UDP to 10.0.2.3:53 from port 4096
    mov  eax, DNS_SERVER_IP
    mov  bx,  UDP_SRC_PORT
    mov  edx, ecx            ; save packet length before CX is clobbered
    mov  cx,  DNS_PORT
    mov  esi, dns_pkt_buf
    call udp_send
    jc   .send_fail

    ; poll for reply - drain ARP, count only truly empty iterations
    mov  dword [dns_poll_ctr], 2000000
.poll:
    inc  dword [net_poll_throttle]
    test dword [net_poll_throttle], 0x3FF
    jnz  .skip_hw
    call mouse_poll
    call pm_kb_poll
.skip_hw:
    call eth_recv            ; CF=1 nothing; CF=0: ESI=payload ECX=len DX=etype
    jc   .empty              ; truly no packet - decrement counter

    ; drain ARP packets so they don't block us
    cmp  dx, ETHERTYPE_ARP
    jne  .not_arp
    call arp_process
    jmp  .poll               ; don't decrement - keep looking
.not_arp:

    ; must be IPv4
    cmp  dx, ETHERTYPE_IPV4
    jne  .poll
    cmp  ecx, 20 + UDP_HDR_LEN
    jl   .poll
    cmp  byte [esi], 0x45    ; IPv4 no options
    jne  .poll
    cmp  byte [esi + 9], IP_PROTO_UDP
    jne  .poll

    ; check destination port matches our src port (big-endian in packet)
    ; UDP header starts at esi+20
    mov  ax, [esi + 20 + 2]  ; UDP dst port
    xchg al, ah
    cmp  ax, UDP_SRC_PORT
    jne  .poll

    ; get UDP payload length
    mov  ax, [esi + 20 + 4]
    xchg al, ah
    movzx ecx, ax
    sub  ecx, UDP_HDR_LEN    ; payload length
    cmp  ecx, 12
    jl   .poll

    ; copy UDP payload into dns_pkt_buf directly
    push esi
    push ecx
    push edi
    add  esi, 20 + UDP_HDR_LEN
    mov  edi, dns_pkt_buf
    rep  movsb
    pop  edi
    pop  ecx
    pop  esi

    call dns_parse_response  ; ECX=len, parses dns_pkt_buf
    jc   .poll               ; not a valid response, keep waiting

    ; EAX = resolved IP (host order)
    mov  esi, pm_str_dns_result
    mov  bl,  0x0A
    call pm_puts
    mov  esi, [dns_hostname_ptr]
    mov  bl,  0x0F
    call pm_puts
    mov  esi, pm_str_dns_arrow
    mov  bl,  0x07
    call pm_puts
    call pm_print_ip
    call pm_newline
    jmp  .done

.empty:
    dec  dword [dns_poll_ctr]
    jnz  .poll

    mov  esi, pm_str_dns_timeout
    mov  bl,  0x0C
    call pm_puts
    jmp  .done

.send_fail:
    mov  esi, pm_str_dns_send_fail
    mov  bl,  0x0C
    call pm_puts
    jmp  .done

.usage:
    mov  esi, pm_str_dns_usage
    mov  bl,  0x0E
    call pm_puts

.done:
    call pm_newline
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; Data
; -
udp_tx_dst_ip:    dd 0
udp_tx_src_port:  dw 0
udp_tx_dst_port:  dw 0
udp_tx_pld_ptr:   dd 0
udp_tx_pld_len:   dd 0
udp_tx_buf:       times (UDP_HDR_LEN + 1472) db 0

udp_rx_want_port: dw 0
udp_rx_src_ip:    dd 0

dns_rx_buf:       times 512 db 0
dns_pkt_buf:      times 512 db 0
dns_query_id:     dw 0
dns_hostname_ptr: dd 0
dns_poll_ctr:     dd 0

pm_str_dns_query:     db ' Resolving ', 0
pm_str_dns_dots:      db '...', 13, 10, 0
pm_str_dns_result:    db ' ', 0
pm_str_dns_arrow:     db ' -> ', 0
pm_str_dns_timeout:   db ' Request timed out (no DNS reply).', 13, 10, 0
pm_str_dns_send_fail: db ' Send failed.', 13, 10, 0
pm_str_dns_usage:     db ' Usage: dns <hostname>  e.g. dns google.com', 13, 10, 0
