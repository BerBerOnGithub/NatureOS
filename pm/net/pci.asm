; ===========================================================================
; pm/net/pci.asm - PCI bus enumerator
;
; PCI config space is accessed via two 32-bit I/O ports:
;   0xCF8  CONFIG_ADDRESS  (write the address you want to read)
;   0xCFC  CONFIG_DATA     (read/write the 32-bit value)
;
; Address format (32-bit):
;   bit 31    = enable bit (must be 1)
;   bits 23:16 = bus   (0-255)
;   bits 15:11 = device (0-31)
;   bits 10:8  = function (0-7)
;   bits 7:2   = register (0-63, each is 4 bytes)
;   bits 1:0   = 0 (always)
;
; Public interface:
;   pci_init          - scan bus, find e1000, store result
;   pci_read32        - EBX=addr -> EAX=data
;   pci_write32       - EBX=addr, EAX=data
;   pci_make_addr     - BL=bus, BH=dev, CL=func, CH=reg -> EBX=addr
;   cmd_pci           - shell command: list all PCI devices
;   cmd_lspci         - alias
;
; Results stored in:
;   pci_e1000_found   db  1 if found, 0 if not
;   pci_e1000_bus     db  bus number
;   pci_e1000_dev     db  device number
;   pci_e1000_func    db  function number
;   pci_e1000_bar0    dd  BAR0 value (memory base of e1000 registers)
; ===========================================================================

[BITS 32]

PCI_ADDR_PORT   equ 0xCF8
PCI_DATA_PORT   equ 0xCFC

; QEMU e1000 identifiers
E1000_VENDOR    equ 0x8086   ; Intel
E1000_DEVICE    equ 0x100E   ; 82540EM (QEMU default NIC)

; PCI config register offsets (each is a DWORD)
PCI_REG_VENDDEV equ 0x00     ; vendor (low 16) + device (high 16)
PCI_REG_CLASS   equ 0x08     ; class/subclass/prog-if/revision
PCI_REG_BAR0    equ 0x10     ; Base Address Register 0
PCI_REG_BAR1    equ 0x14
PCI_REG_SUBSYS  equ 0x2C
PCI_REG_INTLINE equ 0x3C     ; interrupt line + pin

; -
; pci_make_addr
; In:  BL=bus  BH=device  CL=function  CH=register (byte offset, 4-aligned)
; Out: EBX = 32-bit PCI config address (ready to write to 0xCF8)
; Preserves: EAX, ECX
; -
pci_make_addr:
    push eax

    ; Stash all four input bytes before anything gets clobbered
    movzx eax, bl           ; bus
    mov   [.s_bus],  al
    movzx eax, bh           ; device
    mov   [.s_dev],  al
    movzx eax, cl           ; function
    mov   [.s_func], al
    movzx eax, ch           ; register offset
    mov   [.s_reg],  al

    ; Build the 32-bit address in EBX
    xor  ebx, ebx
    or   ebx, 0x80000000        ; enable bit

    movzx eax, byte [.s_bus]
    shl  eax, 16
    or   ebx, eax

    movzx eax, byte [.s_dev]
    shl  eax, 11
    or   ebx, eax

    movzx eax, byte [.s_func]
    shl  eax, 8
    or   ebx, eax

    movzx eax, byte [.s_reg]
    or   ebx, eax

    pop  eax
    ret

; local scratch (safe - single-threaded, no re-entrancy concern)
.s_bus:  db 0
.s_dev:  db 0
.s_func: db 0
.s_reg:  db 0

; -
; pci_read32
; In:  EBX = PCI config address (from pci_make_addr)
; Out: EAX = 32-bit data
; -
pci_read32:
    push edx
    mov  dx, PCI_ADDR_PORT
    mov  eax, ebx
    out  dx, eax
    mov  dx, PCI_DATA_PORT
    in   eax, dx
    pop  edx
    ret

; -
; pci_write32
; In:  EBX = PCI config address, EAX = value to write
; -
pci_write32:
    push eax
    push edx
    mov  edx, PCI_ADDR_PORT
    ; write address
    push eax
    mov  eax, ebx
    out  dx, eax
    pop  eax
    ; write data
    mov  dx, PCI_DATA_PORT
    out  dx, eax
    pop  edx
    pop  eax
    ret

; -
; pci_read_venddev
; In:  BL=bus, BH=dev, CL=func
; Out: EAX = vendor(15:0) | device(31:16), or 0xFFFFFFFF if no device
; -
pci_read_venddev:
    push ebx
    push ecx
    mov  ch, PCI_REG_VENDDEV
    call pci_make_addr
    call pci_read32
    pop  ecx
    pop  ebx
    ret

; -
; pci_init - scan all buses/devices, find e1000, store result
; -
pci_init:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    mov  byte [pci_e1000_found], 0
    mov  dword [pci_scan_count], 0

    xor  edx, edx            ; EDX: bus(bits 23:16) | dev(bits 15:8) | func(bits 7:0)

    ; bus loop: BL = bus 0..255
    xor  bl, bl
.bus_loop:
    ; device loop: BH = dev 0..31
    xor  bh, bh
.dev_loop:
    ; function 0 only for now (single-function devices)
    xor  cl, cl

    call pci_read_venddev
    cmp  eax, 0xFFFFFFFF
    je   .next_dev           ; no device here

    inc  dword [pci_scan_count]

    ; store in scan table if room
    mov  esi, [pci_scan_count]
    dec  esi
    cmp  esi, PCI_SCAN_MAX
    jge  .check_usb

    ; entry: bus(1) dev(1) func(1) pad(1) venddev(4) = 8 bytes
    imul esi, 8
    add  esi, pci_scan_table
    mov  [esi],     bl       ; bus
    mov  [esi + 1], bh       ; dev
    mov  byte [esi + 2], 0   ; func
    mov  byte [esi + 3], 0   ; pad
    mov  [esi + 4], eax      ; vendor+device

.check_usb:
    ; Scan for USB controllers (any vendor, class-based)
    call uhci_pci_scan

.check_e1000:
    ; check vendor = Intel (0x8086)
    mov  ecx, eax
    and  ecx, 0x0000FFFF
    cmp  ecx, E1000_VENDOR
    jne  .next_dev

    ; check device = 0x100E
    mov  ecx, eax
    shr  ecx, 16
    cmp  ecx, E1000_DEVICE
    jne  .next_dev

    ; found e1000!
    mov  byte [pci_e1000_found], 1
    mov  [pci_e1000_bus],  bl
    mov  [pci_e1000_dev],  bh
    mov  byte [pci_e1000_func], 0

    ; read BAR0 - must set CL=0 (function 0) explicitly since ECX
    ; was last used for device ID checks and CL may be non-zero
    xor  cl, cl
    mov  ch, PCI_REG_BAR0
    call pci_make_addr
    call pci_read32
    and  eax, 0xFFFFFFF0     ; mask off flags (bits 3:0)
    mov  [pci_e1000_bar0], eax

    ; enable PCI Bus Master (bit 2) + Memory Space (bit 1)
    ; without Bus Master Enable the NIC cannot DMA TX/RX descriptors
    xor  cl, cl
    mov  ch, 0x04            ; PCI Command register
    call pci_make_addr
    call pci_read32
    or   eax, 0x06           ; bit2=BusMaster  bit1=MemorySpace
    call pci_write32

    ; read interrupt line
    xor  cl, cl
    mov  ch, PCI_REG_INTLINE
    call pci_make_addr
    call pci_read32
    mov  [pci_e1000_irq], al

.next_dev:
    inc  bh
    cmp  bh, 32
    jl   .dev_loop

    inc  bl
    jnz  .bus_loop           ; wraps 255->0, done

    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; cmd_pci  (also aliased as cmd_lspci)
; Lists all found PCI devices with vendor:device IDs and class
; -
cmd_pci:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    call pm_newline
    mov  esi, pm_str_pci_hdr
    mov  bl, 0x0B
    call pm_puts

    ; re-scan buses and print each device found
    xor  bl, bl              ; bus
.p_bus:
    xor  bh, bh              ; dev
.p_dev:
    xor  cl, cl              ; func 0

    call pci_read_venddev
    cmp  eax, 0xFFFFFFFF
    je   .p_next

    ; print "  BB:DD.F  VVVV:DDDD  "
    push eax
    mov  esi, pm_str_pci_indent
    mov  bl, 0x07
    call pm_puts
    pop  eax

    push eax
    ; print bus (save/restore BX around print)
    push ebx
    movzx eax, bl            ; bus - but BL is now clobbered by pm_puts attr
    pop  ebx
    push ebx
    movzx eax, bl
    call pm_print_hex8
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    movzx eax, bh
    call pm_print_hex8
    mov  al, '.'
    call pm_putc
    mov  al, '0'
    call pm_putc
    mov  al, ' '
    call pm_putc
    mov  al, ' '
    call pm_putc
    pop  ebx

    pop  eax
    push eax
    ; vendor
    mov  ecx, eax
    and  ecx, 0xFFFF
    mov  eax, ecx
    call pm_print_hex16
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    pop  eax
    shr  eax, 16
    call pm_print_hex16
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    mov  al, ' '
    call pm_putc

    ; print friendly name if known
    push ebx
    call .print_name
    pop  ebx

    call pm_newline

.p_next:
    inc  bh
    cmp  bh, 32
    jl   .p_dev
    inc  bl
    jnz  .p_bus

    ; e1000 summary
    cmp  byte [pci_e1000_found], 1
    jne  .no_e1000

    call pm_newline
    mov  esi, pm_str_pci_e1000_found
    mov  bl, 0x0A
    call pm_puts
    movzx eax, byte [pci_e1000_bus]
    call pm_print_hex8
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    movzx eax, byte [pci_e1000_dev]
    call pm_print_hex8
    call pm_newline
    mov  esi, pm_str_pci_bar0
    mov  bl, 0x0E
    call pm_puts
    mov  eax, [pci_e1000_bar0]
    call pm_print_hex32
    call pm_newline
    jmp  .pci_done

.no_e1000:
    call pm_newline
    mov  esi, pm_str_pci_no_e1000
    mov  bl, 0x0C
    call pm_puts

.pci_done:
    call pm_newline
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; print a friendly device name based on vendor:device in EAX at entry
; EAX = vendor(15:0) | device(31:16) - already consumed, passed on stack
; We just check a short table
.print_name:
    push eax
    push esi
    push ebx
    ; EAX was passed before the push - but we need original EAX
    ; it's on the stack: [esp+8] after push eax + push esi + push ebx
    mov  eax, [esp + 8 + 4]  ; 3 pushes = 12 bytes, but we pushed eax first
    ; simpler: just hardcode known IDs
    mov  ecx, eax
    and  ecx, 0xFFFF          ; vendor
    cmp  ecx, E1000_VENDOR
    jne  .pn_unknown
    shr  eax, 16              ; device
    cmp  eax, E1000_DEVICE
    jne  .pn_intel_other
    mov  esi, pm_str_dev_e1000
    jmp  .pn_print
.pn_intel_other:
    cmp  eax, 0x7010
    jne  .pn_intel2
    mov  esi, pm_str_dev_piix4
    jmp  .pn_print
.pn_intel2:
    cmp  eax, 0x7000
    jne  .pn_intel3
    mov  esi, pm_str_dev_piix3
    jmp  .pn_print
.pn_intel3:
    cmp  eax, 0x1237
    jne  .pn_unknown
    mov  esi, pm_str_dev_i440fx
    jmp  .pn_print
.pn_unknown:
    mov  esi, pm_str_dev_unknown
.pn_print:
    mov  bl, 0x0F
    call pm_puts
    pop  ebx
    pop  esi
    pop  eax
    ret

; -
; pm_print_hex8  - print AL as 2 hex digits
; pm_print_hex16 - print AX as 4 hex digits
; (pm_print_hex32 already exists in pm_commands.asm)
; -
pm_print_hex8:
    push eax
    push ebx
    push ecx
    mov  ecx, 2
.loop8:
    rol  al, 4
    push eax
    and  al, 0x0F
    cmp  al, 10
    jl   .d8
    add  al, 'A' - 10
    jmp  .o8
.d8:
    add  al, '0'
.o8:
    mov  bl, 0x0F
    call pm_putc
    pop  eax
    loop .loop8
    pop  ecx
    pop  ebx
    pop  eax
    ret

pm_print_hex16:
    push eax
    push ebx
    push ecx
    mov  ecx, 4
.loop16:
    rol  ax, 4
    push eax
    and  al, 0x0F
    cmp  al, 10
    jl   .d16
    add  al, 'A' - 10
    jmp  .o16
.d16:
    add  al, '0'
.o16:
    mov  bl, 0x0F
    call pm_putc
    pop  eax
    loop .loop16
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; Data
; -
pci_e1000_found:  db 0
pci_e1000_bus:    db 0
pci_e1000_dev:    db 0
pci_e1000_func:   db 0
pci_e1000_bar0:   dd 0
pci_e1000_irq:    db 0

pci_scan_count:   dd 0
PCI_SCAN_MAX      equ 32
pci_scan_table:   times (PCI_SCAN_MAX * 8) db 0

pm_str_pci_hdr:
    db ' Bus:Dev.F  Vendor:Dev  Description', 13, 10
    db ' -', 13, 10, 0
pm_str_pci_indent:    db '  ', 0
pm_str_pci_e1000_found:
    db ' [NET] Intel e1000 found at ', 0
pm_str_pci_bar0:
    db '       BAR0 (MMIO base): 0x', 0
pm_str_pci_no_e1000:
    db ' [NET] No e1000 NIC found. Check QEMU -nic flag.', 13, 10, 0
pm_str_dev_e1000:     db 'Intel 82540EM (e1000)', 0
pm_str_dev_piix4:     db 'Intel PIIX4 IDE', 0
pm_str_dev_piix3:     db 'Intel PIIX3 ISA Bridge', 0
pm_str_dev_i440fx:    db 'Intel 440FX Host Bridge', 0
pm_str_dev_unknown:   db 'Unknown', 0