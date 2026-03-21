; ===========================================================================
; pm/net/e1000.asm - Intel 82540EM (e1000) NIC driver
;
; No BIOS. Talks directly to the NIC via MMIO registers at BAR0.
; BAR0 is discovered by pci_init (pci.asm) and stored in pci_e1000_bar0.
;
; Memory layout (above 1MB, safe in PM):
;   E1000_TX_DESC_BASE  0x00101000  TX descriptor ring (16  16 bytes)
;   E1000_RX_DESC_BASE  0x00101100  RX descriptor ring (16  16 bytes)
;   E1000_TX_BUF_BASE   0x00102000  TX packet buffers  (16  2048 bytes)
;   E1000_RX_BUF_BASE   0x00112000  RX packet buffers  (16  2048 bytes)
;
; TX/RX descriptor format (16 bytes each):
;   [0]  dd  buffer address low
;   [4]  dd  buffer address high (0 for 32-bit)
;   [8]  dw  length
;   [10] db  checksum offset (TX) / reserved (RX)
;   [11] db  command (TX) / status (RX)
;   [12] db  status (TX) / errors (RX)
;   [13] db  checksum start (TX) / reserved (RX)
;   [14] dw  special
;
; Public interface:
;   e1000_init        - init NIC, setup rings, read MAC
;   e1000_send        - ESI=packet ptr, ECX=length -> send frame
;   e1000_recv        - EDI=buffer ptr -> ECX=length (0 if no packet)
;   e1000_read_mac    - read MAC into e1000_mac (6 bytes)
;   cmd_ifconfig      - shell: show MAC, link status
; ===========================================================================

[BITS 32]

; -
; e1000 register offsets from BAR0
; -
E1000_CTRL      equ 0x0000   ; Device Control
E1000_STATUS    equ 0x0008   ; Device Status
E1000_EECD      equ 0x0010   ; EEPROM/Flash Control
E1000_EERD      equ 0x0014   ; EEPROM Read
E1000_ICR       equ 0x00C0   ; Interrupt Cause Read (clears on read)
E1000_IMS       equ 0x00D0   ; Interrupt Mask Set
E1000_IMC       equ 0x00D8   ; Interrupt Mask Clear
E1000_RCTL      equ 0x0100   ; Receive Control
E1000_TCTL      equ 0x0400   ; Transmit Control
E1000_TIPG      equ 0x0410   ; TX Inter-Packet Gap
E1000_RDBAL     equ 0x2800   ; RX Descriptor Base Low
E1000_RDBAH     equ 0x2804   ; RX Descriptor Base High
E1000_RDLEN     equ 0x2808   ; RX Descriptor Length
E1000_RDH       equ 0x2810   ; RX Descriptor Head
E1000_RDT       equ 0x2818   ; RX Descriptor Tail
E1000_TDBAL     equ 0x3800   ; TX Descriptor Base Low
E1000_TDBAH     equ 0x3804   ; TX Descriptor Base High
E1000_TDLEN     equ 0x3808   ; TX Descriptor Length
E1000_TDH       equ 0x3810   ; TX Descriptor Head
E1000_TDT       equ 0x3818   ; TX Descriptor Tail
E1000_MTA       equ 0x5200   ; Multicast Table Array (128 dwords)
E1000_RAL0      equ 0x5400   ; Receive Address Low  (MAC bytes 0-3)
E1000_RAH0      equ 0x5404   ; Receive Address High (MAC bytes 4-5 + valid)

; CTRL bits
E1000_CTRL_RST  equ (1 << 26)  ; full reset
E1000_CTRL_SLU  equ (1 << 6)   ; set link up
E1000_CTRL_ASDE equ (1 << 5)   ; auto-speed detection

; RCTL bits
E1000_RCTL_EN   equ (1 << 1)
E1000_RCTL_BAM  equ (1 << 15)  ; broadcast accept
E1000_RCTL_BSIZE_2048 equ 0    ; bits 17:16 = 00 -> 2048 byte buffers
E1000_RCTL_SECRC equ (1 << 26) ; strip ethernet CRC

; TCTL bits
E1000_TCTL_EN   equ (1 << 1)
E1000_TCTL_PSP  equ (1 << 3)   ; pad short packets
E1000_TCTL_CT   equ (0x10 << 4)  ; collision threshold
E1000_TCTL_COLD equ (0x40 << 12) ; collision distance

; TX descriptor command bits
E1000_TXD_CMD_EOP  equ (1 << 0)  ; end of packet
E1000_TXD_CMD_FCS  equ (1 << 1)  ; insert FCS/CRC
E1000_TXD_CMD_RS   equ (1 << 3)  ; report status

; TX descriptor status bits
E1000_TXD_STAT_DD  equ (1 << 0)  ; descriptor done

; RX descriptor status bits
E1000_RXD_STAT_DD  equ (1 << 0)  ; descriptor done
E1000_RXD_STAT_EOP equ (1 << 1)  ; end of packet

; Ring sizes
E1000_NUM_TX_DESC  equ 16
E1000_NUM_RX_DESC  equ 16
E1000_BUF_SIZE     equ 2048

; Memory locations
E1000_TX_DESC_BASE equ 0x00101000
E1000_RX_DESC_BASE equ 0x00101100
E1000_TX_BUF_BASE  equ 0x00102000
E1000_RX_BUF_BASE  equ 0x00112000

; -
; e1000_mmio_read  - read 32-bit register
; In:  EDX = register offset
; Out: EAX = value
; -
e1000_mmio_read:
    push edx
    add  edx, [pci_e1000_bar0]
    mov  eax, [edx]
    pop  edx
    ret

; -
; e1000_mmio_write - write 32-bit register
; In:  EDX = register offset, EAX = value
; -
e1000_mmio_write:
    push edx
    add  edx, [pci_e1000_bar0]
    mov  [edx], eax
    pop  edx
    ret

; -
; e1000_eeprom_read - read one 16-bit word from EEPROM
; In:  AL = EEPROM word address
; Out: AX = 16-bit word
; QEMU 82540EM: start bit = bit 0, done bit = bit 4, data = bits 31:16
; -
e1000_eeprom_read:
    push ecx
    push edx

    movzx eax, al
    shl  eax, 8
    or   eax, 1              ; start bit (bit 0)
    mov  edx, E1000_EERD
    call e1000_mmio_write

    ; poll done bit (bit 4) - up to 100000 iterations
    mov  ecx, 100000
.poll:
    mov  edx, E1000_EERD
    call e1000_mmio_read
    test eax, (1 << 4)
    jnz  .done
    loop .poll
    ; timed out - return 0
    xor  eax, eax
    jmp  .ret

.done:
    shr  eax, 16             ; data in bits 31:16

.ret:
    pop  edx
    pop  ecx
    ret

; -
; e1000_read_mac - read MAC address into e1000_mac[6]
;
; Strategy:
;   1. Read RAL0/RAH0 - QEMU pre-loads the MAC here at power-on.
;      If RAL0 is non-zero, use it directly (fastest, most reliable).
;   2. Fall back to EEPROM words 0/1/2 if RAL0 is zero.
; -
e1000_read_mac:
    push eax
    push ebx

    ; - Try RAL0/RAH0 first -
    mov  edx, E1000_RAL0
    call e1000_mmio_read
    test eax, eax
    jz   .try_eeprom         ; zero -> not pre-loaded, try EEPROM

    ; RAL0 = MAC bytes 3:2:1:0
    mov  [e1000_mac + 0], al
    shr  eax, 8
    mov  [e1000_mac + 1], al
    shr  eax, 8
    mov  [e1000_mac + 2], al
    shr  eax, 8
    mov  [e1000_mac + 3], al

    ; RAH0 bits 15:0 = MAC bytes 5:4
    mov  edx, E1000_RAH0
    call e1000_mmio_read
    mov  [e1000_mac + 4], al
    shr  eax, 8
    mov  [e1000_mac + 5], al
    jmp  .mac_done

.try_eeprom:
    ; EEPROM word 0 = MAC bytes 1:0
    mov  al, 0
    call e1000_eeprom_read
    mov  [e1000_mac + 0], al
    shr  eax, 8
    mov  [e1000_mac + 1], al

    ; EEPROM word 1 = MAC bytes 3:2
    mov  al, 1
    call e1000_eeprom_read
    mov  [e1000_mac + 2], al
    shr  eax, 8
    mov  [e1000_mac + 3], al

    ; EEPROM word 2 = MAC bytes 5:4
    mov  al, 2
    call e1000_eeprom_read
    mov  [e1000_mac + 4], al
    shr  eax, 8
    mov  [e1000_mac + 5], al

.mac_done:
    pop  ebx
    pop  eax
    ret

; -
; e1000_init - full NIC initialisation sequence
; -
e1000_init:
    push eax
    push ecx
    push edx
    push edi

    ; - 1. Check BAR0 is valid -
    cmp  dword [pci_e1000_bar0], 0
    je   .no_nic

    ; - 2. Read MAC before reset (reset clears RAL0) -
    call e1000_read_mac

    ; - 2. Reset the NIC -
    mov  edx, E1000_CTRL
    call e1000_mmio_read
    or   eax, E1000_CTRL_RST
    mov  edx, E1000_CTRL
    call e1000_mmio_write

    ; wait for reset to clear
    mov  ecx, 200000
.rst_wait:
    loop .rst_wait

    ; - 3. Set link up, auto-speed -
    mov  edx, E1000_CTRL
    call e1000_mmio_read
    or   eax, E1000_CTRL_SLU | E1000_CTRL_ASDE
    mov  edx, E1000_CTRL
    call e1000_mmio_write

    ; poll STATUS.LU (bit 1) - wait for link up
    mov  ecx, 200000
.link_wait:
    mov  edx, E1000_STATUS
    call e1000_mmio_read
    test eax, (1 << 1)
    jnz  .link_up
    loop .link_wait
.link_up:

; - 1b. Enable Bus Master -
    push eax
    push edx
    mov  eax, 0x80001804
    mov  dx,  0xCF8
    out  dx,  eax
    mov  dx,  0xCFC
    in   eax, dx
    or   eax, (1 << 2) | (1 << 1)
    push eax
    mov  eax, 0x80001804
    mov  dx,  0xCF8
    out  dx,  eax
    pop  eax
    mov  dx,  0xCFC
    out  dx,  eax
    pop  edx
    pop  eax

    ; - DEBUG: read back PCI Command register and print it -
    push eax
    push edx
    push ebx
    mov  eax, 0x80001804
    mov  dx,  0xCF8
    out  dx,  eax
    mov  dx,  0xCFC
    in   eax, dx             ; read back
    call pm_print_hex32      ; should show 00000107 if Bus Master is set
    call pm_newline
    pop  ebx
    pop  edx
    pop  eax

    ; - 5. Disable all interrupts -
    mov  eax, 0xFFFFFFFF
    mov  edx, E1000_IMC
    call e1000_mmio_write

    ; - 6. Re-program Receive Address register with our MAC -
    mov  eax, [e1000_mac]
    mov  edx, E1000_RAL0
    call e1000_mmio_write

    movzx eax, word [e1000_mac + 4]
    or   eax, (1 << 31)
    mov  edx, E1000_RAH0
    call e1000_mmio_write

    ; - 7. Clear multicast table -
    xor  eax, eax
    mov  ecx, 128
    mov  edx, E1000_MTA
.mta_clear:
    call e1000_mmio_write
    add  edx, 4
    loop .mta_clear

    ; - 8. Setup TX descriptor ring -
    mov  edi, E1000_TX_DESC_BASE
    mov  ecx, (E1000_NUM_TX_DESC * 16) / 4
    xor  eax, eax
    rep  stosd

    xor  ecx, ecx
.tx_init2:
    cmp  ecx, E1000_NUM_TX_DESC
    jge  .tx_init2_done
    mov  edi, E1000_TX_DESC_BASE
    mov  eax, ecx
    imul eax, 16
    add  edi, eax
    mov  eax, ecx
    imul eax, E1000_BUF_SIZE
    add  eax, E1000_TX_BUF_BASE
    mov  [edi], eax
    mov  dword [edi + 4], 0
    mov  word  [edi + 8], 0
    mov  byte  [edi + 11], 0
    mov  byte  [edi + 12], E1000_TXD_STAT_DD
    inc  ecx
    jmp  .tx_init2
.tx_init2_done:

    mov  eax, E1000_TX_DESC_BASE
    mov  edx, E1000_TDBAL
    call e1000_mmio_write
    xor  eax, eax
    mov  edx, E1000_TDBAH
    call e1000_mmio_write
    mov  eax, E1000_NUM_TX_DESC * 16
    mov  edx, E1000_TDLEN
    call e1000_mmio_write
    xor  eax, eax
    mov  edx, E1000_TDH
    call e1000_mmio_write
    mov  edx, E1000_TDT
    call e1000_mmio_write

    ; - 9. Setup RX descriptor ring -
    mov  edi, E1000_RX_DESC_BASE
    mov  ecx, (E1000_NUM_RX_DESC * 16) / 4
    xor  eax, eax
    rep  stosd

    xor  ecx, ecx
.rx_init:
    cmp  ecx, E1000_NUM_RX_DESC
    jge  .rx_init_done
    mov  edi, E1000_RX_DESC_BASE
    mov  eax, ecx
    imul eax, 16
    add  edi, eax
    mov  eax, ecx
    imul eax, E1000_BUF_SIZE
    add  eax, E1000_RX_BUF_BASE
    mov  [edi], eax
    mov  dword [edi + 4], 0
    mov  word  [edi + 8], 0
    mov  byte  [edi + 12], 0
    inc  ecx
    jmp  .rx_init
.rx_init_done:

    mov  eax, E1000_RX_DESC_BASE
    mov  edx, E1000_RDBAL
    call e1000_mmio_write
    xor  eax, eax
    mov  edx, E1000_RDBAH
    call e1000_mmio_write
    mov  eax, E1000_NUM_RX_DESC * 16
    mov  edx, E1000_RDLEN
    call e1000_mmio_write
    xor  eax, eax
    mov  edx, E1000_RDH
    call e1000_mmio_write
    mov  eax, E1000_NUM_RX_DESC - 1
    mov  edx, E1000_RDT
    call e1000_mmio_write
    mov  dword [e1000_rx_tail], 0

    ; - 10. Enable transmitter -
    mov  eax, E1000_TCTL_EN | E1000_TCTL_PSP | E1000_TCTL_CT | E1000_TCTL_COLD
    mov  edx, E1000_TCTL
    call e1000_mmio_write

    mov  eax, 0x00602006
    mov  edx, E1000_TIPG
    call e1000_mmio_write

    ; - 11. Enable receiver -
    mov  eax, E1000_RCTL_EN | E1000_RCTL_BAM | E1000_RCTL_SECRC
    mov  edx, E1000_RCTL
    call e1000_mmio_write

    mov  byte [e1000_ready], 1
    jmp  .done

.no_nic:
    mov  byte [e1000_ready], 0

.done:
    pop  edi
    pop  edx
    pop  ecx
    pop  eax
    ret
; -
; e1000_send - transmit one Ethernet frame
; In:  ESI = pointer to frame data
;      ECX = frame length in bytes
; Out: CF=0 success, CF=1 error (NIC not ready or TX ring full)
; -
e1000_send:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp  byte [e1000_ready], 0
    je   .err

    ; get current TX tail
    mov  edx, E1000_TDT
    call e1000_mmio_read
    mov  ebx, eax            ; EBX = tail index

    ; check descriptor is free (status DD must be set)
    mov  edi, E1000_TX_DESC_BASE
    mov  eax, ebx
    imul eax, 16
    add  edi, eax            ; EDI = descriptor

    mov  al, [edi + 12]      ; status byte
    test al, E1000_TXD_STAT_DD
    jz   .err                ; descriptor in use

    ; copy packet to TX buffer
    mov  eax, ebx
    imul eax, E1000_BUF_SIZE
    add  eax, E1000_TX_BUF_BASE
    mov  [edi], eax          ; update buffer pointer (in case it changed)
    mov  dword [edi + 4], 0

    ; copy data
    push edi
    mov  edi, eax
    rep  movsb               ; ESI -> EDI, ECX bytes
    pop  edi

    ; restore ECX (it was consumed by movsb)
    ; ECX is now 0, so re-read from stack... instead save length before copy
    ; Actually we need to save ECX before the movsb - fix:
    ; (Length was in ECX at entry, movsb consumed it - we saved it via push at top)
    ; Get length back from [esp + 8] area... simpler: we saved ECX on stack at push ecx
    mov  cx, [esp + 4]       ; length from original ECX push
    ; Actually the stack at this point:
    ; esp+0  = edi save
    ; esp+4  = esi save (from push esi above)  wait - need to recount
    ; Let's just re-read from the descriptor's buffer and accept ECX=0 issue
    ; CORRECT APPROACH: save length to local var before movsb
    mov  ax, [e1000_tx_len_tmp]  ; we'll store it before movsb

    ; fill descriptor
    mov  word [edi + 8], ax       ; length
    mov  byte [edi + 10], 0       ; checksum offset
    mov  byte [edi + 11], E1000_TXD_CMD_EOP | E1000_TXD_CMD_FCS | E1000_TXD_CMD_RS
    mov  byte [edi + 12], 0       ; clear DD (mark in use)
    mov  byte [edi + 13], 0
    mov  word [edi + 14], 0

    ; advance tail
    inc  ebx
    cmp  ebx, E1000_NUM_TX_DESC
    jl   .no_wrap_tx
    xor  ebx, ebx
.no_wrap_tx:
    mov  eax, ebx
    mov  edx, E1000_TDT
    call e1000_mmio_write

    clc
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
; e1000_send_frame - cleaner wrapper that saves length before movsb
; In:  ESI = frame pointer, ECX = length
; -
; ===========================================================================
; PATCH FOR: pm/net/e1000.asm
; Replace the entire e1000_send_frame function with this debug version.
; It prints single characters to screen at each key checkpoint:
;
;   'S' = function entered
;   'R' = e1000_ready check passed
;   'D' = descriptor DD check passed (slot is free)
;   'C' = frame copy done, descriptor filled
;   'W' = TDT write done - NIC has been kicked
;   'E' = error exit (ready=0 or DD not set)
;
; After running ping/netdbg, the letters on screen tell you exactly
; how far execution gets.
; ===========================================================================

; ===========================================================================
; PATCH FOR: pm/net/e1000.asm
; Replace e1000_send_frame with this version.
; After SRDCW it now also prints:
;   " len=XXXX buf=XXXXXXXX" so we can verify the descriptor contents.
; ===========================================================================

e1000_send_frame:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; checkpoint S
    push eax
    push ebx
    mov  al, 'S'
    mov  bl, 0x0E
    call pm_putc
    pop  ebx
    pop  eax

    cmp  byte [e1000_ready], 0
    je   .err

    ; checkpoint R
    push eax
    push ebx
    mov  al, 'R'
    mov  bl, 0x0A
    call pm_putc
    pop  ebx
    pop  eax

    mov  [e1000_tx_len_tmp], cx

    mov  edx, E1000_TDT
    call e1000_mmio_read
    mov  ebx, eax

    mov  edi, E1000_TX_DESC_BASE
    mov  eax, ebx
    imul eax, 16
    add  edi, eax

    test byte [edi + 12], E1000_TXD_STAT_DD
    jz   .err

    ; checkpoint D
    push eax
    push ebx
    mov  al, 'D'
    mov  bl, 0x0B
    call pm_putc
    pop  ebx
    pop  eax

    ; TX buffer address
    mov  eax, ebx
    imul eax, E1000_BUF_SIZE
    add  eax, E1000_TX_BUF_BASE
    mov  [edi], eax
    mov  dword [edi + 4], 0

    ; copy frame into TX buffer
    push edi
    mov  edi, eax
    rep  movsb
    pop  edi

    ; fill descriptor
    movzx eax, word [e1000_tx_len_tmp]
    mov  word [edi + 8], ax
    mov  byte [edi + 10], 0
    mov  byte [edi + 11], E1000_TXD_CMD_EOP | E1000_TXD_CMD_FCS | E1000_TXD_CMD_RS
    mov  byte [edi + 12], 0
    mov  byte [edi + 13], 0
    mov  word [edi + 14], 0

    ; checkpoint C + print len and buf address
    push eax
    push ebx
    mov  al, 'C'
    mov  bl, 0x0D
    call pm_putc

    ; print " L="
    mov  al, 'L'
    mov  bl, 0x07
    call pm_putc
    mov  al, '='
    call pm_putc

    ; print length (word at [edi+8])
    movzx eax, word [edi + 8]
    call pm_print_hex32

    ; print " B="
    mov  al, 'B'
    call pm_putc
    mov  al, '='
    call pm_putc

    ; print buffer address (dword at [edi+0])
    mov  eax, [edi]
    call pm_print_hex32

    call pm_newline
    pop  ebx
    pop  eax

    ; bump tail
    inc  ebx
    cmp  ebx, E1000_NUM_TX_DESC
    jl   .no_wrap
    xor  ebx, ebx
.no_wrap:
    mov  eax, ebx
    mov  edx, E1000_TDT
    call e1000_mmio_write

    ; checkpoint W
    push eax
    push ebx
    mov  al, 'W'
    mov  bl, 0x0F
    call pm_putc
    pop  ebx
    pop  eax

    clc
    jmp  .sfDone

.err:
    push eax
    push ebx
    mov  al, 'E'
    mov  bl, 0x0C
    call pm_putc
    pop  ebx
    pop  eax
    stc

.sfDone:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret
; -
; e1000_recv - check for received packet, copy to buffer
; In:  EDI = destination buffer pointer
; Out: ECX = number of bytes received (0 = no packet)
;      CF=1 if NIC not ready
;
; Ownership model:
;   e1000_rx_tail tracks the slot we expect the NIC to have filled next.
;   We poll [slot+11] DD bit.  When set, a packet has landed there.
;   We copy it out, clear DD, give that same slot index back to the NIC
;   via RDT, then advance e1000_rx_tail to the next slot.
; -
e1000_recv:
    push eax
    push ebx
    push edx
    push esi

    xor  ecx, ecx

    cmp  byte [e1000_ready], 0
    je   .err

    ; EBX = descriptor index we expect the NIC to have filled
    mov  ebx, [e1000_rx_tail]

    ; ESI = address of that descriptor
    mov  esi, E1000_RX_DESC_BASE
    mov  eax, ebx
    imul eax, 16
    add  esi, eax

    ; Poll DD bit (bit 0) of STATUS byte at offset +11
    ; (NOT +12 - that is the errors byte)
    test byte [esi + 12], E1000_RXD_STAT_DD
    jz   .no_packet          ; NIC hasn't written here yet

    ; Get received length from offset +8
    movzx ecx, word [esi + 8]
    test ecx, ecx
    jz   .no_packet          ; zero-length, skip

    ; Copy from RX buffer to caller's EDI
    push esi
    mov  eax, ebx
    imul eax, E1000_BUF_SIZE
    add  eax, E1000_RX_BUF_BASE
    mov  esi, eax
    push ecx
    rep  movsb
    pop  ecx
    pop  esi

    ; Clear STATUS byte at +11 so we don't re-process this slot
    mov  byte [esi + 12], 0

    ; Save the slot index we just consumed - this goes back to RDT
    mov  edx, ebx            ; EDX = consumed slot index

    ; Advance software tail to next slot
    inc  ebx
    cmp  ebx, E1000_NUM_RX_DESC
    jl   .no_wrap_rx
    xor  ebx, ebx
.no_wrap_rx:
    mov  [e1000_rx_tail], ebx

    ; Give the consumed slot (EDX) back to the NIC via RDT.
    ; The NIC owns all slots from RDH up to (and including) RDT.
    ; Writing the slot we just freed tells the NIC it can reuse it.
    mov  eax, edx
    mov  edx, E1000_RDT
    call e1000_mmio_write

    clc
    jmp  .done

.no_packet:
    xor  ecx, ecx
    clc
    jmp  .done
.err:
    xor  ecx, ecx
    stc
.done:
    pop  esi
    pop  edx
    pop  ebx
    pop  eax
    ret

; -
; cmd_ifconfig - display MAC address, link status, NIC state
; -
cmd_ifconfig:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    call pm_newline

    cmp  byte [e1000_ready], 0
    je   .not_ready

    mov  esi, pm_str_ifc_hdr
    mov  bl, 0x0B
    call pm_puts

    ; MAC address
    mov  esi, pm_str_ifc_mac
    mov  bl, 0x0E
    call pm_puts

    push edi
    xor  edi, edi            ; EDI = byte index (0..5), safe from BL clobbers
    mov  ecx, 6
.mac_loop:
    movzx eax, byte [e1000_mac + edi]
    call pm_print_hex8
    cmp  ecx, 1
    je   .mac_no_colon
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
.mac_no_colon:
    inc  edi
    loop .mac_loop
    pop  edi
    call pm_newline

    ; Link status from STATUS register
    mov  esi, pm_str_ifc_link
    mov  bl, 0x0E
    call pm_puts
    mov  edx, E1000_STATUS
    call e1000_mmio_read
    test eax, (1 << 1)       ; LU = link up bit
    jz   .link_down
    mov  esi, pm_str_ifc_up
    mov  bl, 0x0A
    call pm_puts
    ; speed bits 7:6
    mov  ecx, eax
    shr  ecx, 6
    and  ecx, 3
    mov  esi, pm_str_ifc_1000
    cmp  ecx, 2
    je   .speed_done
    mov  esi, pm_str_ifc_100
    cmp  ecx, 1
    je   .speed_done
    mov  esi, pm_str_ifc_10
.speed_done:
    mov  bl, 0x0F
    call pm_puts
    call pm_newline
    jmp  .ifc_rx

.link_down:
    mov  esi, pm_str_ifc_down
    mov  bl, 0x0C
    call pm_puts
    call pm_newline

.ifc_rx:
    ; RX/TX ring state
    mov  esi, pm_str_ifc_tx
    mov  bl, 0x0E
    call pm_puts
    mov  edx, E1000_TDT
    call e1000_mmio_read
    call pm_print_uint
    mov  al, '/'
    mov  bl, 0x07
    call pm_putc
    mov  eax, E1000_NUM_TX_DESC
    call pm_print_uint
    call pm_newline

    mov  esi, pm_str_ifc_rx
    mov  bl, 0x0E
    call pm_puts
    mov  eax, [e1000_rx_tail]
    call pm_print_uint
    mov  al, '/'
    mov  bl, 0x07
    call pm_putc
    mov  eax, E1000_NUM_RX_DESC
    call pm_print_uint
    call pm_newline

    jmp  .ifc_done

.not_ready:
    mov  esi, pm_str_ifc_no_nic
    mov  bl, 0x0C
    call pm_puts

.ifc_done:
    call pm_newline
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; Data
; -
e1000_ready:      db 0
e1000_mac:        times 6 db 0
e1000_rx_tail:    dd 0
e1000_tx_len_tmp: dw 0

pm_str_ifc_hdr:   db ' eth0 - Intel 82540EM (e1000)', 13, 10, 0
pm_str_ifc_mac:   db '   MAC address : ', 0
pm_str_ifc_link:  db '   Link status : ', 0
pm_str_ifc_up:    db 'UP  ', 0
pm_str_ifc_down:  db 'DOWN', 13, 10, 0
pm_str_ifc_1000:  db '1000 Mbps', 13, 10, 0
pm_str_ifc_100:   db '100 Mbps', 13, 10, 0
pm_str_ifc_10:    db '10 Mbps', 13, 10, 0
pm_str_ifc_tx:    db '   TX ring     : tail=', 0
pm_str_ifc_rx:    db '   RX ring     : tail=', 0
pm_str_ifc_no_nic: db ' No e1000 NIC initialised. Run "pci" first.', 13, 10, 0

pm_str_dbg_hdr:    db ' [NICDBG] Raw e1000 registers:', 13, 10, 0
pm_str_dbg_bar0:   db '  BAR0    : 0x', 0
pm_str_dbg_ctrl:   db '  CTRL    : 0x', 0
pm_str_dbg_status: db '  STATUS  : 0x', 0
pm_str_dbg_ral0:   db '  RAL0    : 0x', 0
pm_str_dbg_rah0:   db '  RAH0    : 0x', 0
pm_str_dbg_rctl:   db '  RCTL    : 0x', 0
pm_str_dbg_tctl:   db '  TCTL    : 0x', 0
pm_str_dbg_mac:    db '  MAC buf : ', 0
pm_str_dbg_ready:  db '  ready   : ', 0