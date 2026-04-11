; ===========================================================================
; pm/net/arp.asm - ARP (Address Resolution Protocol)  RFC 826
;
; Sends ARP requests and processes replies to resolve IPv4 -> MAC.
; Maintains a small cache of 8 entries.
;
; ARP packet layout (28 bytes for IPv4/Ethernet):
;   [0]  hw type     2  0x0001 (Ethernet)
;   [2]  proto type  2  0x0800 (IPv4)
;   [4]  hw size     1  6
;   [5]  proto size  1  4
;   [6]  opcode      2  1=request, 2=reply
;   [8]  sender MAC  6
;   [14] sender IP   4
;   [18] target MAC  6  (zeros for request)
;   [24] target IP   4
;
; Public interface:
;   arp_resolve   EDI=target_ip(dd) -> ESI=mac ptr, CF=0 found / CF=1 not found
;   arp_send_request  EDI=target_ip
;   arp_process   ESI=payload, ECX=len  (called by IP layer on EtherType 0x0806)
;   cmd_arp       shell: show ARP cache
;
; Fixes applied:
;   [FIX4] pm_parse_ip: EBX was not zeroed before the octet accumulation loop.
;          The first 'shl ebx, 8' would shift in whatever garbage was in EBX,
;          corrupting all parsed IPs. Added 'xor ebx, ebx' after 'xor eax, eax'.
; ===========================================================================

[BITS 32]

ARP_CACHE_SIZE  equ 8
ARP_OPCODE_REQ  equ 1
ARP_OPCODE_REP  equ 2
ARP_HW_ETH     equ 0x0001
ARP_PROTO_IP    equ 0x0800
ARP_PKT_LEN    equ 28

; ARP cache entry: 4 bytes IP + 6 bytes MAC + 1 byte valid = 11 bytes, pad to 12
ARP_ENTRY_SIZE  equ 12

; -
; arp_init - pre-seed ARP cache with QEMU SLIRP gateway
; Call once after e1000_init
; -
arp_init:
    push eax
    push esi
    ; clear cache
    push edi
    mov  edi, arp_cache
    mov  ecx, (ARP_CACHE_SIZE * ARP_ENTRY_SIZE) / 4
    xor  eax, eax
    rep  stosd
    pop  edi
    ; insert gateway: 10.0.2.2 -> 52:55:0a:00:02:02
    mov  eax, [net_our_gw]
    mov  esi, arp_slirp_gw_mac
    call arp_cache_insert
    ; insert DNS server: 10.0.2.3 -> 52:55:0a:00:02:03
    mov  eax, 0x0A000203    ; 10.0.2.3 QEMU SLIRP DNS
    mov  esi, arp_slirp_dns_mac
    call arp_cache_insert
    pop  esi
    pop  eax
    ret

; -
; arp_send_request - broadcast ARP request for target IP
; In: EDI = target IPv4 address (32-bit, host byte order)
; -
arp_send_request:
    push eax
    push ecx
    push edx
    push esi
    push edi

    mov  [arp_target_ip], edi

    ; build ARP packet in arp_pkt_buf
    mov  edi, arp_pkt_buf

    ; hw type = 0x0001 (big-endian)
    mov  word [edi + 0],  0x0100   ; 0x0001 BE
    ; proto type = 0x0800
    mov  word [edi + 2],  0x0008   ; 0x0800 BE
    ; hw size = 6, proto size = 4
    mov  byte [edi + 4],  6
    mov  byte [edi + 5],  4
    ; opcode = 1 (request, BE)
    mov  word [edi + 6],  0x0100   ; 0x0001 BE

    ; sender MAC = our MAC
    push esi
    push edi
    add  edi, 8
    mov  esi, e1000_mac
    mov  ecx, 6
    rep  movsb
    pop  edi
    pop  esi

    ; sender IP = our IP (host byte order -> big-endian in packet)
    mov  eax, [net_our_ip]
    bswap eax
    mov  [edi + 14], eax

    ; target MAC = zeros (unknown)
    mov  dword [edi + 18], 0
    mov  word  [edi + 22], 0

    ; target IP
    mov  eax, [arp_target_ip]
    bswap eax
    mov  [edi + 24], eax

    ; send via eth_send to broadcast FF:FF:FF:FF:FF:FF
    mov  esi, arp_pkt_buf
    mov  ecx, ARP_PKT_LEN
    mov  edi, arp_bcast_mac
    mov  dx,  ETHERTYPE_ARP
    call eth_send

    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  eax
    ret

; -
; arp_process - handle incoming ARP packet
; In: ESI = ARP payload pointer (28 bytes)
;     ECX = payload length
; -
arp_process:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp  ecx, ARP_PKT_LEN
    jl   .done               ; too short

    ; check it's Ethernet/IPv4 ARP
    mov  ax, [esi + 0]
    cmp  ax, 0x0100          ; hw type 0x0001 BE
    jne  .done
    mov  ax, [esi + 2]
    cmp  ax, 0x0008          ; proto 0x0800 BE
    jne  .done

    ; get opcode
    mov  ax, [esi + 6]
    xchg al, ah              ; to host order

    cmp  ax, ARP_OPCODE_REP
    je   .is_reply
    cmp  ax, ARP_OPCODE_REQ
    je   .is_request
    jmp  .done

.is_reply:
    ; cache sender MAC + IP from reply
    ; sender IP at [esi+14] (BE), sender MAC at [esi+8]
    mov  eax, [esi + 14]
    bswap eax                ; to host order
    push esi
    lea  esi, [esi + 8]      ; sender MAC
    call arp_cache_insert    ; EAX=ip, ESI=mac ptr
    pop  esi
    jmp  .done

.is_request:
    ; if they're asking for our IP, send a reply
    mov  eax, [esi + 24]
    bswap eax
    cmp  eax, [net_our_ip]
    jne  .done

    ; also cache the requester while we're here
    push esi
    mov  eax, [esi + 14]
    bswap eax
    lea  esi, [esi + 8]
    call arp_cache_insert
    pop  esi

    ; build reply: swap sender/target, fill our MAC
    mov  edi, arp_pkt_buf
    ; copy incoming packet as base
    push esi
    push edi
    mov  ecx, ARP_PKT_LEN
    rep  movsb
    pop  edi
    pop  esi

    ; opcode = 2 (reply)
    mov  word [edi + 6], 0x0200

    ; new sender = us
    push esi
    push edi
    add  edi, 8
    mov  esi, e1000_mac
    mov  ecx, 6
    rep  movsb
    pop  edi
    pop  esi
    mov  eax, [net_our_ip]
    bswap eax
    mov  [edi + 14], eax

    ; new target = original sender
    push esi
    push edi
    add  edi, 18
    add  esi, 8
    mov  ecx, 6
    rep  movsb               ; target MAC = original sender MAC
    pop  edi
    pop  esi
    mov  eax, [esi + 14]     ; target IP = original sender IP
    mov  [edi + 24], eax

    ; send reply unicast back to requester
    mov  esi, arp_pkt_buf
    mov  ecx, ARP_PKT_LEN
    push esi
    add  esi, 18             ; original sender MAC is now target MAC in reply
    ; actually we want to send to original sender's MAC
    ; original sender MAC is at [esi_orig + 8]
    pop  esi
    lea  edi, [esi + 8]      ; sender MAC of incoming packet
    mov  dx, ETHERTYPE_ARP
    push esi
    mov  esi, arp_pkt_buf
    mov  ecx, ARP_PKT_LEN
    call eth_send
    pop  esi

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; arp_cache_insert - add or update cache entry
; In: EAX = IPv4 (host order), ESI = pointer to 6-byte MAC
; -
arp_cache_insert:
    push eax
    push ebx
    push ecx
    push esi
    push edi

    ; search for existing entry with this IP
    mov  ecx, ARP_CACHE_SIZE
    mov  edi, arp_cache
.search:
    cmp  byte [edi + 10], 0  ; valid?
    je   .found_slot
    cmp  [edi], eax          ; IP match?
    je   .found_slot
    add  edi, ARP_ENTRY_SIZE
    loop .search

    ; cache full - evict slot 0 (simple round-robin would be better)
    mov  edi, arp_cache

.found_slot:
    mov  [edi], eax          ; store IP
    mov  ecx, 6
    push esi
    push edi
    add  edi, 4
    rep  movsb               ; store MAC
    pop  edi
    pop  esi
    mov  byte [edi + 10], 1  ; valid

    pop  edi
    pop  esi
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; arp_resolve - look up MAC for given IP
; In:  EAX = target IPv4 (host order)
; Out: CF=0 -> ESI = pointer to 6-byte MAC in cache
;      CF=1 -> not found
; -
arp_resolve:
    push ecx
    push edi

    mov  ecx, ARP_CACHE_SIZE
    mov  edi, arp_cache
.loop:
    cmp  byte [edi + 10], 0
    je   .next
    cmp  [edi], eax
    je   .found
.next:
    add  edi, ARP_ENTRY_SIZE
    loop .loop
    stc
    jmp  .done
.found:
    lea  esi, [edi + 4]      ; pointer to MAC bytes
    clc
.done:
    pop  edi
    pop  ecx
    ret

; -
; cmd_arp - display ARP cache
; -
cmd_arp:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call pm_newline
    mov  esi, pm_str_arp_hdr
    mov  bl, 0x0B
    call pm_puts

    mov  ecx, ARP_CACHE_SIZE
    mov  edi, arp_cache
    xor  edx, edx            ; entry counter

.row:
    cmp  byte [edi + 10], 0
    je   .skip

    ; print IP
    mov  eax, [edi]
    call pm_print_ip
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    mov  al, ' '
    call pm_putc

    ; print MAC - walk EDI through 6 bytes, ECX counts down
    push ecx
    push edi
    add  edi, 4              ; point at MAC byte 0
    mov  ecx, 6
.mac:
    movzx eax, byte [edi]
    call pm_print_hex8
    inc  edi
    cmp  ecx, 1
    je   .no_col
    push eax
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    pop  eax
.no_col:
    loop .mac
    pop  edi
    pop  ecx

    call pm_newline
    inc  edx

.skip:
    add  edi, ARP_ENTRY_SIZE
    loop .row

    test edx, edx
    jnz  .done
    mov  esi, pm_str_arp_empty
    mov  bl, 0x07
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
; pm_print_ip - print EAX as dotted-quad IPv4 (host byte order)
; 0x0A000202 -> "10.0.2.2"
; -
pm_print_ip:
    push eax
    push ebx
    push ecx

    mov  ecx, eax            ; work copy

    ; octet 0: bits 31:24
    mov  eax, ecx
    shr  eax, 24
    and  eax, 0xFF
    mov  bl, 0x0F
    call pm_print_uint
    mov  al, '.'
    mov  bl, 0x07
    call pm_putc

    ; octet 1: bits 23:16
    mov  eax, ecx
    shr  eax, 16
    and  eax, 0xFF
    mov  bl, 0x0F
    call pm_print_uint
    mov  al, '.'
    mov  bl, 0x07
    call pm_putc

    ; octet 2: bits 15:8
    mov  eax, ecx
    shr  eax, 8
    and  eax, 0xFF
    mov  bl, 0x0F
    call pm_print_uint
    mov  al, '.'
    mov  bl, 0x07
    call pm_putc

    ; octet 3: bits 7:0
    mov  eax, ecx
    and  eax, 0xFF
    mov  bl, 0x0F
    call pm_print_uint

    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; pm_parse_ip - parse dotted-quad at ESI into EAX (host byte order)
; "10.0.2.2" -> EAX = 0x0A000202
; ESI advanced past the IP string
;
; [FIX4] EBX was never zeroed before the loop, so the first 'shl ebx, 8'
; shifted in garbage from the caller's EBX, corrupting every parsed IP.
; -
pm_parse_ip:
    push ebx
    push ecx
    push edx

    xor  eax, eax
    xor  ebx, ebx            ; [FIX4] must zero accumulator before first shl
    mov  ecx, 4              ; 4 octets

.octet:
    call pm_parse_uint       ; EAX = octet (0-255), ESI advanced
    and  eax, 0xFF
    ; shift accumulator left 8 and OR in new octet
    shl  ebx, 8
    or   bl, al
    ; skip '.' separator (except after last octet)
    cmp  ecx, 1
    je   .last
    cmp  byte [esi], '.'
    jne  .last
    inc  esi
.last:
    dec  ecx
    jnz  .octet

    mov  eax, ebx

    pop  edx
    pop  ecx
    pop  ebx
    ret

; -
; cmd_arping - send ARP request for IP given on command line
; Usage: arping <dotted-quad>
; Sends request, polls for reply up to ~1 second, shows result
; -
cmd_arping:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; parse IP from command line (skip "arping ")
    mov  esi, pm_input_buf
    add  esi, 7              ; skip "arping "

    call pm_parse_ip         ; EAX = target IP host order
    test eax, eax
    jz   .bad_ip

    mov  [arping_target], eax

    call pm_newline
    mov  esi, pm_str_arping_send
    mov  bl, 0x0E
    call pm_puts
    mov  eax, [arping_target]
    call pm_print_ip
    call pm_newline

    ; send ARP request
    mov  edi, [arping_target]
    call arp_send_request

    ; poll for reply: call eth_recv in a loop, pass ARP packets to arp_process
    ; timeout ~500000 iterations
    mov  ecx, 500000
.poll:
    push ecx
    call eth_recv            ; CF=1 no packet; CF=0: ESI=payload,ECX=len,DX=etype
    jc   .no_pkt

    cmp  dx, ETHERTYPE_ARP
    jne  .no_pkt

    ; process the ARP packet (may cache the reply)
    call arp_process

    ; check if our target is now in cache
    mov  eax, [arping_target]
    call arp_resolve         ; CF=0 -> ESI=mac
    jnc  .got_reply

.no_pkt:
    pop  ecx
    loop .poll

    ; timeout
    mov  esi, pm_str_arping_timeout
    mov  bl, 0x0C
    call pm_puts
    jmp  .done

.got_reply:
    pop  ecx
    mov  esi, pm_str_arping_reply
    mov  bl, 0x0A
    call pm_puts
    mov  eax, [arping_target]
    call pm_print_ip
    mov  esi, pm_str_arping_is
    mov  bl, 0x07
    call pm_puts

    ; print MAC - ESI points to 6-byte MAC in cache, walk EDI through it
    mov  edi, esi
    mov  ecx, 6
.mac:
    movzx eax, byte [edi]
    call pm_print_hex8
    inc  edi
    cmp  ecx, 1
    je   .no_col
    push eax
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    pop  eax
.no_col:
    loop .mac
    call pm_newline
    jmp  .done

.bad_ip:
    mov  esi, pm_str_arping_usage
    mov  bl, 0x0E
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

arping_target:  dd 0

pm_str_arping_send:    db ' Sending ARP request for ', 0
pm_str_arping_reply:   db ' Reply: ', 0
pm_str_arping_is:      db ' is at ', 0
pm_str_arping_timeout: db ' Request timed out (no reply).', 13, 10, 0
pm_str_arping_usage:   db ' Usage: arping <ip>  e.g. arping 10.0.2.2', 13, 10, 0

; -
; Data
; -
arp_cache:       times (ARP_CACHE_SIZE * ARP_ENTRY_SIZE) db 0
arp_pkt_buf:     times ARP_PKT_LEN db 0
arp_target_ip:   dd 0
arp_bcast_mac:   db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

; Network configuration (set via 'ipconfig' command or defaults)
net_our_ip:      dd 0x0A00020F    ; 10.0.2.15 - QEMU user-net guest IP
net_our_mask:    dd 0xFFFFFF00    ; /24
net_our_gw:      dd 0x0A000202    ; 10.0.2.2  - QEMU user-net gateway

; QEMU SLIRP does not respond to ARP - pre-seed the cache with the
; well-known SLIRP gateway MAC (52:55:0a:00:02:02).
; This runs once at init time via arp_init.
arp_slirp_gw_mac: db 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02
arp_slirp_dns_mac: db 0x52, 0x55, 0x0A, 0x00, 0x02, 0x03

pm_str_arp_hdr:
    db ' ARP Cache:', 13, 10
    db ' IP Address       MAC Address', 13, 10
    db ' -', 13, 10, 0
pm_str_arp_empty:
    db ' (empty)', 13, 10, 0
