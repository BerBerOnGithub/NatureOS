; ===========================================================================
; pm/net/ip.asm - IPv4 layer  (RFC 791)
;
; Builds and parses IPv4 headers. Calls eth_send/eth_recv.
; Checksum computed in software (no hardware offload in PM).
;
; IPv4 header (20 bytes, no options):
;   [0]  ver+IHL   1   0x45 (version 4, header len 5 dwords)
;   [1]  DSCP/ECN  1   0x00
;   [2]  total len 2   BE
;   [4]  ident     2   BE  (we increment per packet)
;   [6]  flags+frag 2  0x4000 BE (DF, no fragment)
;   [8]  TTL       1   64
;   [9]  protocol  1   (1=ICMP, 6=TCP, 17=UDP)
;   [10] checksum  2   BE  (ones-complement of header)
;   [12] src IP    4   BE
;   [16] dst IP    4   BE
;
; Public interface:
;   ip_send   ESI=payload, ECX=len, EAX=dst_ip, BL=protocol -> CF
;   ip_recv   -> ESI=payload, ECX=payload_len, AL=protocol,
;               ip_rx_src/dst populated; CF=1 no packet
; ===========================================================================

[BITS 32]

IP_HDR_LEN      equ 20
IP_TTL          equ 64
IP_PROTO_ICMP   equ 1
IP_PROTO_TCP    equ 6
IP_PROTO_UDP    equ 17

; -
; ip_checksum - compute ones-complement checksum over ECX bytes at ESI
; Returns checksum in AX (ready to store big-endian)
; Preserves all registers except EAX
; -
ip_checksum:
    push ebx
    push ecx
    push esi

    xor  eax, eax            ; accumulator
    xor  ebx, ebx

.loop:
    cmp  ecx, 2
    jl   .odd
    mov  bx, [esi]           ; read 16-bit word as-is (network order)
    add  eax, ebx
    add  esi, 2
    sub  ecx, 2
    jmp  .loop

.odd:
    test ecx, ecx
    jz   .fold
    movzx ebx, byte [esi]    ; odd trailing byte
    ; To match the 'mov bx, [esi]' (LE) loop, an even-indexed odd byte
    ; should be added in the low position.
    add  eax, ebx

.fold:
    ; fold 32-bit sum to 16 bits
    mov  ebx, eax
    shr  ebx, 16
    and  eax, 0xFFFF
    add  eax, ebx
    ; second fold in case of carry
    mov  ebx, eax
    shr  ebx, 16
    add  eax, ebx
    and  eax, 0xFFFF
    ; ones complement
    not  eax
    and  eax, 0xFFFF

    pop  esi
    pop  ecx
    pop  ebx
    ret

; -
; ip_send - build IPv4 header and transmit
;
; In:  ESI = payload pointer
;      ECX = payload length
;      EAX = destination IP (host order)
;      BL  = protocol (IP_PROTO_ICMP etc.)
; Out: CF=0 ok, CF=1 error
; -
ip_send:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp  ecx, 1480           ; max payload (1500 - 20 byte IP hdr)
    ja   .err

    ; save params
    mov  [ip_tx_dst],      eax
    mov  [ip_tx_proto],    bl
    mov  [ip_tx_pld_ptr],  esi
    mov  [ip_tx_pld_len],  ecx

    ; - Build IP header in ip_tx_buf -
    mov  edi, ip_tx_buf

    ; ver=4 IHL=5 -> 0x45; DSCP=0
    mov  word [edi + 0],  0x0045     ; stored LE: byte0=0x45 byte1=0x00 OK

    ; total length = 20 + payload (big-endian)
    mov  eax, [ip_tx_pld_len]
    add  eax, IP_HDR_LEN
    xchg al, ah
    mov  [edi + 2], ax

    ; identification (increment, big-endian)
    mov  ax, [ip_ident]
    inc  word [ip_ident]
    xchg al, ah
    mov  [edi + 4], ax

    ; flags=DF(0x4000), frag offset=0 -> 0x40 0x00 big-endian
    mov  word [edi + 6],  0x0040

    ; TTL, protocol
    mov  byte [edi + 8],  IP_TTL
    mov  al,  [ip_tx_proto]
    mov  byte [edi + 9],  al

    ; checksum = 0 for now
    mov  word [edi + 10], 0

    ; source IP (host -> big-endian)
    mov  eax, [net_our_ip]
    bswap eax
    mov  [edi + 12], eax

    ; dest IP (host -> big-endian)
    mov  eax, [ip_tx_dst]
    bswap eax
    mov  [edi + 16], eax

    ; compute header checksum
    push esi
    mov  esi, ip_tx_buf
    mov  ecx, IP_HDR_LEN
    call ip_checksum         ; AX = checksum (network order, ready to store)
    mov  [ip_tx_buf + 10], ax
    pop  esi

    ; copy payload after header
    push esi
    push edi
    mov  esi, [ip_tx_pld_ptr]
    mov  edi, ip_tx_buf + IP_HDR_LEN
    mov  ecx, [ip_tx_pld_len]
    rep  movsb
    pop  edi
    pop  esi

    ; total frame payload length
    mov  ecx, [ip_tx_pld_len]
    add  ecx, IP_HDR_LEN

    ; resolve destination MAC via ARP cache
    mov  eax, [ip_tx_dst]

    ; check if dst is on our subnet - if not, use gateway
    mov  edx, [net_our_mask]
    mov  ebx, [net_our_ip]
    and  ebx, edx
    push eax
    and  eax, edx
    cmp  eax, ebx
    pop  eax
    je   .local
    mov  eax, [net_our_gw]   ; off-subnet: route via gateway
.local:
    call arp_resolve         ; EAX=ip -> ESI=mac ptr, CF
    jc   .err                ; MAC not in cache

    ; send via ethernet
    mov  edi, esi            ; dst MAC ptr
    mov  esi, ip_tx_buf
    mov  dx,  ETHERTYPE_IPV4
    call eth_send
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
; ip_recv - receive one IPv4 packet if available
;
; Out: CF=1  no packet
;      CF=0:
;        ESI = pointer to payload (after IP header)
;        ECX = payload length
;        AL  = protocol
;        ip_rx_src, ip_rx_dst populated (host order)
; -
ip_recv:
    push ebx
    push edx
    push edi

    ; eth_recv returns: ESI=payload ptr (eth_rx_buf+14), ECX=payload len, DX=etype
    ; It does NOT use EDI - do not pass ip_rx_buf here.
    call eth_recv
    jc   .no_packet

    cmp  dx, ETHERTYPE_IPV4
    jne  .no_packet

    cmp  ecx, IP_HDR_LEN
    jl   .no_packet

    ; validate version/IHL = 0x45 (IPv4, no options)
    cmp  byte [esi], 0x45
    jne  .no_packet

    ; extract src/dst IPs (big-endian in packet -> host order)
    mov  eax, [esi + 12]
    bswap eax
    mov  [ip_rx_src], eax

    mov  eax, [esi + 16]
    bswap eax
    mov  [ip_rx_dst], eax

    ; verify packet is addressed to us or broadcast
    mov  eax, [ip_rx_dst]
    cmp  eax, [net_our_ip]
    je   .mine
    cmp  eax, 0xFFFFFFFF
    je   .mine
    jmp  .no_packet

.mine:
    ; protocol byte
    mov  al, [esi + 9]
    mov  [ip_rx_proto], al

    ; total length from header (big-endian)
    mov  bx, [esi + 2]
    xchg bl, bh
    movzx ecx, bx
    sub  ecx, IP_HDR_LEN     ; payload length

    ; advance ESI past IP header to payload
    add  esi, IP_HDR_LEN

    clc
    jmp  .done

.no_packet:
    stc
.done:
    pop  edi
    pop  edx
    pop  ebx
    ret
; -
; Data
; -
ip_tx_buf:       times (IP_HDR_LEN + 1480) db 0
ip_rx_buf:       times (IP_HDR_LEN + 1480) db 0

ip_ident:        dw 0x0100   ; packet ID counter
ip_tx_dst:       dd 0
ip_tx_proto:     db 0
ip_tx_pld_ptr:   dd 0
ip_tx_pld_len:   dd 0

ip_rx_src:       dd 0
ip_rx_dst:       dd 0
ip_rx_proto:     db 0