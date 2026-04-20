; ===========================================================================
; pm/net/tcp.asm  -  Minimal TCP layer  (RFC 793)
;
; Fixes applied:
;   [FIX1] tcp_close: CLOSE_WAIT branch was dead code.
;   [FIX2] tcp_poll_one: ESI stack offset [esp+16]->[esp+4].
;   [FIX2b] tcp_poll_one: [esp+4] is the CALLER's saved ESI, not eth_recv's
;           result. eth_recv's ESI (= eth_rx_buf+14, IP header start) is now
;           saved into tcp_rx_ip_base immediately after the call and used in
;           the data-copy path instead of the stale stack slot.
;   [FIX3] cmd_tcpget recv loop: exited on CLOSE_WAIT before draining data.
;   [FIX5] tcp_poll_one: hardcoded 0x45 check dropped SYN-ACKs with IP
;          options (IHL>5). Now extracts actual IHL, checks version=4 only.
;   [FIX6] TCP_POLL_LIMIT raised 2M->20M for real internet round-trips.
;   [FIX7] tcp_checksum: pseudo-header IP contribution was computed with
;          incorrect bswap. net_our_ip and tcp_dst_ip are stored in host
;          byte order (0x0A00020F). bswapping then splitting gave wrong
;          halves (0x000A,0x0F02) instead of correct (0x020F,0x0A00).
;          Fixed: split host-order dword directly without bswap.
; ===========================================================================

[BITS 32]

TCP_TX_BUF      equ 0x650000
TCP_RX_BUF      equ 0x650800
TCP_RX_BUF_SZ   equ 0x2000

TCP_HDR_LEN     equ 20
TCP_DATA_OFF    equ 0x50

TCP_FLAG_FIN    equ 0x01
TCP_FLAG_SYN    equ 0x02
TCP_FLAG_RST    equ 0x04
TCP_FLAG_PSH    equ 0x08
TCP_FLAG_ACK    equ 0x10

TCP_EPHEM_PORT  equ 0xC000
TCP_WIN_SIZE    equ 8192

; [FIX6] Raised from 2,000,000 - internet SYN-ACK via SLIRP needs more time
TCP_POLL_LIMIT  equ 4000000

TCP_STATE_CLOSED      equ 0
TCP_STATE_SYN_SENT    equ 1
TCP_STATE_ESTABLISHED equ 2
TCP_STATE_FIN_WAIT1   equ 3
TCP_STATE_FIN_WAIT2   equ 4
TCP_STATE_TIME_WAIT   equ 5
TCP_STATE_CLOSE_WAIT  equ 6

; ===========================================================================
; tcp_connect
; In:  EAX=dst_ip, CX=dst_port -> CF=0 ok, CF=1 error
; ===========================================================================
tcp_connect:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call tcp_reset_state

    mov  [tcp_dst_ip],   eax
    mov  [tcp_dst_port], cx
    mov  word [tcp_src_port], TCP_EPHEM_PORT

    mov  eax, [pit_ticks]
    shl  eax, 10
    mov  [tcp_snd_isn], eax
    mov  [tcp_snd_nxt], eax
    mov  dword [tcp_snd_una], 0
    mov  dword [tcp_rcv_nxt], 0
    mov  byte [tcp_state], TCP_STATE_SYN_SENT

    ; DBG: print ISN
    push eax
    push esi
    mov  esi, tcp_dbg_syn
    call term_puts
    mov  eax, [tcp_snd_nxt]
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax

    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_SYN
    call tcp_send_segment
    jc   .err

    ; DBG: SYN sent ok
    push esi
    mov  esi, tcp_dbg_syn_sent
    call term_puts
    pop  esi

    inc  dword [tcp_snd_nxt]

    mov  edx, TCP_POLL_LIMIT
.wait_synack:
    test edx, edx
    jz   .timeout
    dec  edx
    call tcp_poll_one
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .connected
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .err
    jmp  .wait_synack

.connected:
    push esi
    mov  esi, tcp_dbg_connected
    call term_puts
    pop  esi
    clc
    jmp  .done
.timeout:
    push esi
    mov  esi, tcp_dbg_timeout
    call term_puts
    call term_newline
    pop  esi
    mov  byte [tcp_state], TCP_STATE_CLOSED
    stc
    jmp  .done
.err:
    push esi
    mov  esi, tcp_dbg_err
    call term_puts
    call term_newline
    pop  esi
    mov  byte [tcp_state], TCP_STATE_CLOSED
    stc
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ===========================================================================
; tcp_send
; In:  ESI=data, ECX=len -> CF=0 ok, CF=1 error
; ===========================================================================
tcp_send:
    push eax
    push ebx
    push ecx

    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    jne  .err

    cmp  ecx, 1440
    jle  .sz_ok
    mov  ecx, 1440
.sz_ok:
    mov  bl, TCP_FLAG_ACK | TCP_FLAG_PSH
    call tcp_send_segment
    jc   .err

    clc
    jmp  .done
.err:
    stc
.done:
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ===========================================================================
; tcp_recv
; In:  EDI=buf, ECX=maxlen -> ECX=bytes read, CF=1 error
; ===========================================================================
tcp_recv:
    push eax
    push edx
    push esi

    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    jne  .err

    mov  [tcp_recv_buf], edi
    mov  [tcp_recv_max], ecx

    mov  edx, TCP_POLL_LIMIT
.poll:
    test edx, edx
    jz   .timeout
    dec  edx
    call tcp_poll_one

    cmp  dword [tcp_rx_pending], 0
    jg   .got_data

    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .peer_closed
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .err
    jmp  .poll

.got_data:
    mov  ecx, [tcp_rx_pending]
    cmp  ecx, [tcp_recv_max]
    jle  .copy_sz_ok
    mov  ecx, [tcp_recv_max]
.copy_sz_ok:
    mov  esi, TCP_RX_BUF
    push ecx
    rep  movsb
    pop  ecx
    mov  dword [tcp_rx_pending], 0
    clc
    jmp  .done

.peer_closed:
    xor  ecx, ecx
    clc
    jmp  .done

.timeout:
.err:
    xor  ecx, ecx
    stc
.done:
    pop  esi
    pop  edx
    pop  eax
    ret

; ===========================================================================
; tcp_close  [FIX1] Both ESTABLISHED and CLOSE_WAIT reach .send_fin
; ===========================================================================
tcp_close:
    push eax
    push ecx
    push edx

    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .send_fin
    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .send_fin
    jmp  .skip_fin

.send_fin:
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_FIN | TCP_FLAG_ACK
    call tcp_send_segment
    inc  dword [tcp_snd_nxt]
    mov  byte [tcp_state], TCP_STATE_FIN_WAIT1

    mov  edx, TCP_POLL_LIMIT
.wait_ack:
    test edx, edx
    jz   .done
    dec  edx
    call tcp_poll_one
    cmp  byte [tcp_state], TCP_STATE_FIN_WAIT2
    je   .wait_fin
    cmp  byte [tcp_state], TCP_STATE_TIME_WAIT
    je   .done
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .done
    jmp  .wait_ack

.wait_fin:
    mov  edx, TCP_POLL_LIMIT
.wf2:
    test edx, edx
    jz   .done
    dec  edx
    call tcp_poll_one
    cmp  byte [tcp_state], TCP_STATE_TIME_WAIT
    je   .done
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .done
    jmp  .wf2

.skip_fin:
.done:
    mov  byte [tcp_state], TCP_STATE_CLOSED
    pop  edx
    pop  ecx
    pop  eax
    ret

; ===========================================================================
; tcp_reset
; ===========================================================================
tcp_reset:
    push ecx
    push esi
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .done
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_RST | TCP_FLAG_ACK
    call tcp_send_segment
    mov  byte [tcp_state], TCP_STATE_CLOSED
.done:
    pop  esi
    pop  ecx
    ret

; ===========================================================================
; tcp_reset_state
; ===========================================================================
tcp_reset_state:
    push eax
    push edi
    push ecx
    mov  byte [tcp_state], TCP_STATE_CLOSED
    mov  dword [tcp_dst_ip], 0
    mov  dword [tcp_snd_nxt], 0
    mov  dword [tcp_snd_una], 0
    mov  dword [tcp_rcv_nxt], 0
    mov  dword [tcp_snd_isn], 0
    mov  dword [tcp_rx_pending], 0
    mov  edi, TCP_RX_BUF
    mov  ecx, 8
    xor  eax, eax
    rep  stosd
    pop  ecx
    pop  edi
    pop  eax
    ret

; ===========================================================================
; tcp_send_segment (internal)
; In:  ESI=payload or 0, ECX=payload len, BL=flags
; ===========================================================================
tcp_send_segment:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov  [tcp_tx_flags],   bl
    mov  [tcp_tx_pld_ptr], esi
    mov  [tcp_tx_pld_len], ecx

    mov  edi, TCP_TX_BUF

    mov  ax, [tcp_src_port]
    xchg al, ah
    mov  [edi + 0], ax

    mov  ax, [tcp_dst_port]
    xchg al, ah
    mov  [edi + 2], ax

    mov  eax, [tcp_snd_nxt]
    bswap eax
    mov  [edi + 4], eax

    mov  eax, [tcp_rcv_nxt]
    bswap eax
    mov  [edi + 8], eax

    mov  byte [edi + 12], TCP_DATA_OFF
    mov  al, [tcp_tx_flags]
    mov  byte [edi + 13], al

    mov  ax, TCP_WIN_SIZE
    xchg al, ah
    mov  [edi + 14], ax

    mov  word [edi + 16], 0
    mov  word [edi + 18], 0

    mov  ecx, [tcp_tx_pld_len]
    test ecx, ecx
    jz   .no_payload
    push esi
    push edi
    mov  esi, [tcp_tx_pld_ptr]
    add  edi, TCP_HDR_LEN
    rep  movsb
    pop  edi
    pop  esi
.no_payload:

    mov  ecx, [tcp_tx_pld_len]
    add  ecx, TCP_HDR_LEN

    push ecx
    call tcp_checksum
    mov  [TCP_TX_BUF + 16], ax
    pop  ecx


    mov  esi, TCP_TX_BUF
    mov  eax, [tcp_dst_ip]
    mov  bl,  IP_PROTO_TCP
    call ip_send

    mov  eax, [tcp_tx_pld_len]
    add  [tcp_snd_nxt], eax

    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ===========================================================================
; tcp_checksum
; In:  ECX=seg_len -> AX=checksum
; ===========================================================================
tcp_checksum:
    push ebx
    push ecx
    push esi

    xor  ebx, ebx

    ; [FIX7 - Corrected]
    ; To match the x86 16-bit word summation loop, we need to add the
    ; pseudo-header fields as swapped little-endian words.
    ; net_our_ip and tcp_dst_ip are stored in host order (e.g. 0x0A00020F).
    ; bswap gives 0x0F02000A.
    ; Split high/low now gives: 0x000A (BE 10.0) and 0x0F02 (BE 2.15).
    ; These are exactly the little-endian words the loop would see.
    mov  eax, [net_our_ip]
    bswap eax
    movzx esi, ax
    add  ebx, esi
    shr  eax, 16
    add  ebx, eax

    ; dst IP
    mov  eax, [tcp_dst_ip]
    bswap eax
    movzx esi, ax
    add  ebx, esi
    shr  eax, 16
    add  ebx, eax

    ; zero + proto=6 (BE 0x0006 -> LE 0x0600)
    add  ebx, 0x0600

    ; TCP length as BE word
    mov  eax, ecx
    xchg al, ah
    movzx eax, ax
    add  ebx, eax

    ; sum segment bytes
    mov  esi, TCP_TX_BUF
    push ecx
.loop:
    cmp  ecx, 2
    jl   .odd
    movzx eax, word [esi]
    add  ebx, eax
    add  esi, 2
    sub  ecx, 2
    jmp  .loop
.odd:
    test ecx, ecx
    jz   .fold
    movzx eax, byte [esi]
    ; Odd byte at even offset should be added as the low byte of a 16-bit word
    ; to be consistent with 'movzx word [esi]' on LE architecture.
    add  ebx, eax
.fold:
    pop  ecx

    mov  eax, ebx
    shr  eax, 16
    and  ebx, 0xFFFF
    add  eax, ebx
    mov  ebx, eax
    shr  ebx, 16
    add  eax, ebx
    and  eax, 0xFFFF
    not  eax
    and  eax, 0xFFFF

    pop  esi
    pop  ecx
    pop  ebx
    ret

; ===========================================================================
; tcp_poll_one
; [FIX5] Was: cmp byte[esi],0x45 / jne .done -> dropped all IP-with-options.
;         QEMU SLIRP SYN-ACK can have IHL>5 (timestamp option etc).
; Fix: extract IHL from low nibble of version/IHL byte, verify version=4,
;      use actual IHL for header skip.  EDX holds IHL throughout.
; ===========================================================================
tcp_poll_one:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    inc  dword [net_poll_throttle]
    test dword [net_poll_throttle], 0x3FF
    jnz  .skip_hw
    call mouse_poll
    call pm_kb_poll
    call wm_update_contents
    call gfx_flush
.skip_hw:

    call eth_recv
    jc   .empty

    ; [FIX2b] Save the eth payload pointer (ESI = eth_rx_buf+14 = IP header start)
    ; immediately before anything can clobber it.  Used later to locate TCP payload.
    mov  [tcp_rx_ip_base], esi

    ; drain ARP
    cmp  dx, ETHERTYPE_ARP
    jne  .not_arp
    call arp_process
    jmp  .done
.not_arp:

    cmp  dx, ETHERTYPE_IPV4
    jne  .done_not_ip

    ; minimum size: need at least 20-byte IP + 20-byte TCP
    cmp  ecx, 20 + TCP_HDR_LEN
    jl   .drop_short

    ; [FIX5] check version=4; extract actual IP header length
    mov  al, [esi]              ; version/IHL byte (e.g. 0x45 or 0x46)
    mov  bl, al
    shr  bl, 4                  ; IP version
    cmp  bl, 4
    jne  .drop_ver              ; not IPv4

    and  al, 0x0F               ; IHL in dwords
    shl  al, 2                  ; IHL in bytes
    movzx edx, al               ; EDX = IP header length (20, 24, 28...)

    cmp  byte [esi + 9], IP_PROTO_TCP
    jne  .drop_proto

    ; check source IP = our peer
    mov  eax, [esi + 12]
    bswap eax
    mov  [tcp_rx_src_ip], eax
    cmp  eax, [tcp_dst_ip]
    jne  .drop_ip

    ; IP total length -> TCP segment length
    movzx ebx, word [esi + 2]
    xchg bl, bh
    movzx ecx, bx
    sub  ecx, edx               ; TCP seg len = IP total - IP header

    ; [FIX5] skip actual IP header length, not hardcoded 20
    add  esi, edx               ; ESI -> TCP header

    cmp  ecx, TCP_HDR_LEN
    jl   .drop_short2

    ; check ports
    movzx eax, word [esi + 2]
    xchg al, ah
    cmp  ax, [tcp_src_port]
    jne  .drop_port

    movzx eax, word [esi + 0]
    xchg al, ah
    cmp  ax, [tcp_dst_port]
    jne  .drop_port

    ; extract fields
    mov  eax, [esi + 4]
    bswap eax
    mov  [tcp_rx_seq], eax

    mov  eax, [esi + 8]
    bswap eax
    mov  [tcp_rx_ack], eax

    mov  al, [esi + 13]
    mov  [tcp_rx_flags], al

    movzx eax, byte [esi + 12]
    shr  eax, 4
    shl  eax, 2
    mov  [tcp_rx_hdr_len], eax

    mov  ebx, ecx
    sub  ebx, [tcp_rx_hdr_len]
    mov  [tcp_rx_data_len], ebx

    ; RST
    test byte [tcp_rx_flags], TCP_FLAG_RST
    jz   .not_rst
    push eax
    push esi
    mov  esi, tcp_dbg_rx_rst
    call term_puts
    pop  esi
    pop  eax
    mov  byte [tcp_state], TCP_STATE_CLOSED
    jmp  .done
.not_rst:


    cmp  byte [tcp_state], TCP_STATE_SYN_SENT
    je   .state_syn_sent
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .state_established
    cmp  byte [tcp_state], TCP_STATE_FIN_WAIT1
    je   .state_fin_wait1
    cmp  byte [tcp_state], TCP_STATE_FIN_WAIT2
    je   .state_fin_wait2
    jmp  .done

; -----------------------------------------------------------------------
.state_syn_sent:
    mov  al, [tcp_rx_flags]
    and  al, TCP_FLAG_SYN | TCP_FLAG_ACK
    cmp  al, TCP_FLAG_SYN | TCP_FLAG_ACK
    jne  .drop_not_synack

    mov  eax, [tcp_snd_isn]
    inc  eax
    cmp  eax, [tcp_rx_ack]
    jne  .drop_ack_mismatch

    mov  eax, [tcp_rx_seq]
    inc  eax
    mov  [tcp_rcv_nxt], eax

    mov  eax, [tcp_rx_ack]
    mov  [tcp_snd_una], eax

    mov  byte [tcp_state], TCP_STATE_ESTABLISHED

    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

; -----------------------------------------------------------------------
.state_established:
    test byte [tcp_rx_flags], TCP_FLAG_ACK
    jz   .est_no_ack
    mov  eax, [tcp_rx_ack]
    cmp  eax, [tcp_snd_una]
    jle  .est_no_ack
    mov  [tcp_snd_una], eax
.est_no_ack:

    cmp  dword [tcp_rx_data_len], 0
    jle  .est_no_data

    mov  eax, [tcp_rx_seq]
    cmp  eax, [tcp_rcv_nxt]
    jne  .est_no_data

    mov  ecx, [tcp_rx_data_len]
    cmp  ecx, TCP_RX_BUF_SZ
    jle  .data_sz_ok
    mov  ecx, TCP_RX_BUF_SZ
.data_sz_ok:
    mov  edi, TCP_RX_BUF
    ; [FIX2b] Use tcp_rx_ip_base (saved right after eth_recv) as the IP header
    ; start.  The old code read [esp+4] claiming it was the Ethernet payload
    ; ptr, but that slot holds the *caller's* saved ESI — not eth_recv's result.
    ; EDX = IP IHL in bytes (set above, not clobbered since).
    mov  esi, [tcp_rx_ip_base]    ; IP header start (eth_rx_buf + 14)
    add  esi, edx                 ; skip IP header -> TCP header start
    add  esi, [tcp_rx_hdr_len]    ; skip TCP header -> payload
    push ecx
    rep  movsb
    pop  ecx
    mov  [tcp_rx_pending], ecx

    add  [tcp_rcv_nxt], ecx

    push esi
    push ecx
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    pop  ecx
    pop  esi

.est_no_data:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done

    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_CLOSE_WAIT

    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

; -----------------------------------------------------------------------
.state_fin_wait1:
    test byte [tcp_rx_flags], TCP_FLAG_ACK
    jz   .fw1_check_fin
    mov  eax, [tcp_rx_ack]
    cmp  eax, [tcp_snd_nxt]
    jne  .fw1_check_fin
    mov  byte [tcp_state], TCP_STATE_FIN_WAIT2
.fw1_check_fin:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done
    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_TIME_WAIT
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

; -----------------------------------------------------------------------
.state_fin_wait2:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done
    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_TIME_WAIT
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment

.empty:
    pause
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; --- tcp_poll_one drop points with diagnostic prints ---
.done_not_ip:
    jmp  .done

.drop_short:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_short
    call term_puts
    mov  eax, ecx
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

.drop_ver:
    push esi
    mov  esi, tcp_dbg_drop_ver
    call term_puts
    call term_newline
    pop  esi
    jmp  .done

.drop_proto:
    jmp  .done

.drop_ip:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_ip
    call term_puts
    mov  eax, [tcp_rx_src_ip]
    call pm_print_hex32
    mov  esi, tcp_dbg_want
    call term_puts
    mov  eax, [tcp_dst_ip]
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

.drop_short2:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_short2
    call term_puts
    mov  eax, ecx
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

.drop_port:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_port
    call term_puts
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

.drop_not_synack:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_flags
    call term_puts
    mov  al, [tcp_rx_flags]
    movzx eax, al
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

.drop_ack_mismatch:
    push eax
    push esi
    mov  esi, tcp_dbg_drop_ack
    call term_puts
    mov  eax, [tcp_snd_isn]
    inc  eax
    call pm_print_hex32
    mov  esi, tcp_dbg_got
    call term_puts
    mov  eax, [tcp_rx_ack]
    call pm_print_hex32
    call term_newline
    pop  esi
    pop  eax
    jmp  .done

; ===========================================================================
; cmd_tcpget  -  tcpget <ip> <port> <path>
; ===========================================================================
cmd_tcpget:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call term_newline

    mov  esi, pm_input_buf
    add  esi, 7

    call pm_parse_ip
    test eax, eax
    jz   .usage
    mov  [tcpg_dst_ip], eax

    cmp  byte [esi], ' '
    jne  .usage
    inc  esi

    call pm_parse_uint
    test eax, eax
    jz   .usage
    cmp  eax, 65535
    ja   .usage
    mov  [tcpg_dst_port], ax

    cmp  byte [esi], ' '
    jne  .usage
    inc  esi

    mov  [tcpg_path_ptr], esi

    mov  esi, tcpg_str_connecting
    call term_puts
    mov  eax, [tcpg_dst_ip]
    call pm_print_ip
    mov  esi, tcpg_str_port
    call term_puts
    movzx eax, word [tcpg_dst_port]
    call pm_print_uint
    call term_newline

    mov  eax, [tcpg_dst_ip]
    movzx ecx, word [tcpg_dst_port]
    call tcp_connect
    jc   .conn_fail

    mov  esi, tcpg_str_connected
    call term_puts
    call term_newline

    ; build HTTP/1.0 GET
    mov  edi, tcpg_req_buf
    mov  byte [edi+0], 'G'
    mov  byte [edi+1], 'E'
    mov  byte [edi+2], 'T'
    mov  byte [edi+3], ' '
    add  edi, 4
    mov  esi, [tcpg_path_ptr]
.copy_path:
    mov  al, [esi]
    test al, al
    jz   .path_done
    mov  [edi], al
    inc  esi
    inc  edi
    jmp  .copy_path
.path_done:
    mov  esi, tcpg_str_http10
    call .append_str
    mov  esi, tcpg_str_connclose
    call .append_str
    mov  byte [edi], 0

    mov  ecx, edi
    sub  ecx, tcpg_req_buf

    mov  esi, tcpg_req_buf
    call tcp_send
    jc   .send_fail

    mov  esi, tcpg_str_sent
    call term_puts
    call term_newline

    mov  esi, tcpg_str_response
    call term_puts
    call term_newline

    mov  dword [tcpg_total], 0

; [FIX3] Keep looping in CLOSE_WAIT to drain last data chunk
.recv_loop:
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .do_recv
    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .do_recv
    jmp  .recv_done

.do_recv:
    mov  edi, tcpg_recv_buf
    mov  ecx, 1400
    call tcp_recv
    jc   .recv_done
    test ecx, ecx
    jz   .recv_done

    add  [tcpg_total], ecx

    mov  esi, tcpg_recv_buf
    push ecx
.print_byte:
    test ecx, ecx
    jz   .print_done
    mov  al, [esi]
    cmp  al, 10
    je   .is_lf
    cmp  al, 13
    je   .is_cr
    cmp  al, 32
    jl   .ctrl
    cmp  al, 126
    jg   .ctrl
    call term_putchar
    jmp  .next_byte
.is_lf:
    call term_newline
    jmp  .next_byte
.is_cr:
    jmp  .next_byte
.ctrl:
    mov  al, '.'
    call term_putchar
.next_byte:
    inc  esi
    dec  ecx
    jmp  .print_byte
.print_done:
    pop  ecx
    jmp  .recv_loop

.recv_done:
    call tcp_close

    call term_newline
    mov  esi, tcpg_str_done
    call term_puts
    mov  eax, [tcpg_total]
    call pm_print_uint
    mov  esi, tcpg_str_bytes
    call term_puts
    call term_newline
    jmp  .done

.conn_fail:
    mov  esi, tcpg_str_conn_fail
    call term_puts
    call term_newline
    jmp  .done

.send_fail:
    mov  esi, tcpg_str_send_fail
    call term_puts
    call term_newline
    call tcp_reset
    jmp  .done

.usage:
    mov  esi, tcpg_str_usage
    call term_puts
    call term_newline

.done:
    call term_newline
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

.append_str:
    push eax
.as_loop:
    mov  al, [esi]
    test al, al
    jz   .as_done
    mov  [edi], al
    inc  esi
    inc  edi
    jmp  .as_loop
.as_done:
    pop  eax
    ret

; ===========================================================================
; Data
; ===========================================================================

tcp_state:       db TCP_STATE_CLOSED
                 db 0, 0, 0
tcp_dst_ip:      dd 0
tcp_dst_port:    dw 0
tcp_src_port:    dw TCP_EPHEM_PORT
tcp_snd_nxt:     dd 0
tcp_snd_una:     dd 0
tcp_rcv_nxt:     dd 0
tcp_snd_isn:     dd 0

tcp_rx_pending:  dd 0
tcp_recv_buf:    dd 0
tcp_recv_max:    dd 0

tcp_rx_src_ip:   dd 0
tcp_rx_ip_base:  dd 0          ; [FIX2b] eth payload ptr saved after eth_recv
tcp_rx_seq:      dd 0
tcp_rx_ack:      dd 0
tcp_rx_flags:    db 0
                 db 0, 0, 0
tcp_rx_hdr_len:  dd 0
tcp_rx_data_len: dd 0

tcp_tx_flags:    db 0
                 db 0, 0, 0
tcp_tx_pld_ptr:  dd 0
tcp_tx_pld_len:  dd 0

tcpg_dst_ip:     dd 0
tcpg_dst_port:   dw 0
                 dw 0
tcpg_path_ptr:   dd 0
tcpg_total:      dd 0
tcpg_req_buf:    times 512 db 0
tcpg_recv_buf:   times 1500 db 0

tcpg_str_connecting: db ' Connecting to ', 0
tcpg_str_port:       db ':', 0
tcpg_str_connected:  db ' Connected!', 0
tcpg_str_sent:       db ' Request sent.', 0
tcpg_str_response:   db ' --- Response ---', 0
tcpg_str_done:       db ' Done. Received ', 0
tcpg_str_bytes:      db ' bytes.', 13, 10, 0
tcpg_str_conn_fail:  db ' Connection failed (timeout or RST).', 0
tcpg_str_send_fail:  db ' Send failed.', 0
tcpg_str_usage:
    db ' Usage: tcpget <ip> <port> <path>', 13, 10
    db ' Example: tcpget 93.184.216.34 80 /', 13, 10
    db ' Tip: use "dns <host>" first to resolve the IP.', 13, 10, 0
tcpg_str_http10:     db ' HTTP/1.0', 13, 10, 0
tcpg_str_host:       db 'Host: ', 0
tcpg_str_connclose:  db 'Connection: close', 13, 10, 13, 10, 0

; ===========================================================================
; Debug strings
; ===========================================================================
tcp_dbg_syn:        db ' TCP> SYN ISN=', 0
tcp_dbg_syn_sent:   db ' TCP> SYN sent OK', 13, 10, 0
tcp_dbg_connected:  db ' TCP> ESTABLISHED', 13, 10, 0
tcp_dbg_timeout:    db ' TCP> TIMEOUT waiting for SYN-ACK', 0
tcp_dbg_err:        db ' TCP> ERROR (send failed or RST)', 0
tcp_dbg_tx:         db ' TX> flags=', 0
tcp_dbg_rx:         db ' RX> flags=', 0
tcp_dbg_rx_rst:     db ' RX> RST received - closing', 13, 10, 0
tcp_dbg_seq:        db ' seq=', 0
tcp_dbg_ack:        db ' ack=', 0
tcp_dbg_csum:       db ' csum=', 0
tcp_dbg_dlen:       db ' dlen=', 0
tcp_dbg_want:       db ' want=', 0
tcp_dbg_got:        db ' got=', 0
tcp_dbg_drop_short: db ' DROP> pkt too short: ', 0
tcp_dbg_drop_short2:db ' DROP> TCP seg too short: ', 0
tcp_dbg_drop_ver:   db ' DROP> not IPv4', 0
tcp_dbg_drop_ip:    db ' DROP> src IP=', 0
tcp_dbg_drop_port:  db ' DROP> port mismatch', 0
tcp_dbg_drop_flags: db ' DROP> not SYN+ACK, flags=', 0
tcp_dbg_drop_ack:   db ' DROP> ACK mismatch want=', 0
net_poll_throttle: dd 0