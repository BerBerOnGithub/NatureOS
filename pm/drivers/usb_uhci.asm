; ===========================================================================
; pm/drivers/usb_uhci.asm - Intel UHCI Host Controller Driver (Basic)
;
; Targets QEMU's default Intel PIIX3/PIIX4 UHCI controller.
; Provides: controller reset, frame list init, port status polling.
;
; Public interface:
;   uhci_init        - detect UHCI via PCI, reset, init frame list
;   uhci_poll        - poll port status changes (call from main loop)
;   uhci_port_status - read and report port connection status
;   uhci_stop        - stop controller (shutdown)
;
; Memory:
;   UHCI_FL_BASE     - 4KB frame list at fixed phys addr
; ===========================================================================

[BITS 32]

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

; PCI USB class codes
PCI_CLASS_SERIAL    equ 0x0C
PCI_SUBCLASS_USB    equ 0x03
USB_PROG_UHCI       equ 0x00
USB_PROG_OHCI       equ 0x10
USB_PROG_EHCI       equ 0x20
USB_PROG_XHCI       equ 0x30

; QEMU PIIX3/PIIX4 UHCI identifiers
UHCI_VENDOR_PIIX3   equ 0x8086
UHCI_DEVICE_PIIX3   equ 0x7020   ; 82371SB PIIX3 USB
UHCI_VENDOR_PIIX4   equ 0x8086
UHCI_DEVICE_PIIX4   equ 0x7112   ; 82371AB PIIX4 USB

; UHCI I/O register offsets from base
UHCI_USBCMD         equ 0x00     ; Command (16-bit)
UHCI_USBSTS         equ 0x02     ; Status (16-bit)
UHCI_USBINTR        equ 0x04     ; Interrupt Enable (16-bit)
UHCI_FRNUM          equ 0x06     ; Frame Number (16-bit)
UHCI_FLBASEADD      equ 0x08     ; Frame List Base Address (32-bit)
UHCI_SOFMOD         equ 0x0C     ; SOF Modify (8-bit)
UHCI_PORTSC1        equ 0x10     ; Port 1 Status/Control (16-bit)
UHCI_PORTSC2        equ 0x12     ; Port 2 Status/Control (16-bit)

; USBCMD bits
UHCI_CMD_RUN        equ 0x0001   ; Run/Stop
UHCI_CMD_HCRESET    equ 0x0002   ; Host Controller Reset
UHCI_CMD_GRESET     equ 0x0004   ; Global Reset
UHCI_CMD_EGSM       equ 0x0008   ; Enter Global Suspend
UHCI_CMD_FGR        equ 0x0010   ; Force Global Resume
UHCI_CMD_SWDBG      equ 0x0020   ; SW Debug
UHCI_CMD_CF         equ 0x0040   ; Configure Flag
UHCI_CMD_MAXP       equ 0x0080   ; Max Packet (0=32, 1=64)

; USBSTS bits
UHCI_STS_INT        equ 0x0001   ; USB Interrupt
UHCI_STS_ERR        equ 0x0002   ; USB Error
UHCI_STS_RD         equ 0x0004   ; Resume Detect
UHCI_STS_HSE        equ 0x0008   ; Host System Error
UHCI_STS_HCPE       equ 0x0010   ; HC Process Error
UHCI_STS_HCH        equ 0x0020   ; HC Halted

; PORTSC bits
UHCI_PORT_CONN      equ 0x0001   ; Connection Status
UHCI_PORT_CONNC     equ 0x0002   ; Connect Status Change
UHCI_PORT_EN        equ 0x0004   ; Port Enabled
UHCI_PORT_ENC       equ 0x0008   ; Enable Status Change
UHCI_PORT_LS        equ 0x0010   ; Line Status (bits 4-5)
UHCI_PORT_RD        equ 0x0040   ; Resume Detect
UHCI_PORT_LSDA      equ 0x0100   ; Low Speed Device Attached
UHCI_PORT_PR        equ 0x0200   ; Port Reset
UHCI_PORT_SUSP      equ 0x1000   ; Suspend

; Frame list
UHCI_FL_ENTRIES     equ 1024     ; 1024 entries
UHCI_FL_SIZE        equ (UHCI_FL_ENTRIES * 4)   ; 4096 bytes
UHCI_FL_ALIGN       equ 0x1000   ; 4KB alignment
UHCI_FL_BASE        equ 0x700000 ; Fixed physical address (safe: clear of Paint)

; Terminate bit in frame list entry
UHCI_FL_TERM        equ 0x0001   ; T-bit = terminate

; Maximum controllers to detect
UHCI_MAX_CTRL       equ 4

; ---------------------------------------------------------------------------
; PCI Integration - USB controller scan data
; ---------------------------------------------------------------------------

; USB controller table: 16 bytes per entry
;   +0  db  bus
;   +1  db  dev
;   +2  db  func
;   +3  db  type (0=UHCI, 1=OHCI, 2=EHCI, 3=xHCI)
;   +4  dd  BAR0 (I/O base or MMIO base)
;   +8  dd  BAR1 (optional)
;   +12 dd  reserved
usb_ctrl_count:     dd 0
usb_ctrl_table:     times (UHCI_MAX_CTRL * 16) db 0

; UHCI-specific data (first found controller)
uhci_found:         db 0
uhci_bus:           db 0
uhci_dev:           db 0
uhci_func:          db 0
uhci_io_base:       dd 0       ; I/O port base (from BAR0)
uhci_port_count:    db 2       ; UHCI has 2 ports typically

; Port tracking
uhci_port1_last:    dw 0
uhci_port2_last:    dw 0

; ---------------------------------------------------------------------------
; uhci_pci_scan - called from pci_init to detect USB controllers
; In:  BL=bus, BH=dev, CL=func, EAX=venddev
; Uses existing PCI read infrastructure
; Clobbers: EAX, EDX, ESI
; ---------------------------------------------------------------------------
uhci_pci_scan:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    ; Read class code at offset 0x08
    mov  ch, PCI_REG_CLASS
    call pci_make_addr
    call pci_read32

    ; Extract class (bits 24:31), subclass (bits 16:23), prog-if (bits 8:15)
    mov  edx, eax
    shr  edx, 24
    cmp  dl, PCI_CLASS_SERIAL
    jne  .not_usb

    mov  edx, eax
    shr  edx, 16
    and  dl, 0xFF
    cmp  dl, PCI_SUBCLASS_USB
    jne  .not_usb

    ; It's a USB controller! Determine type from prog-if
    mov  edx, eax
    shr  edx, 8
    and  dl, 0xFF

    cmp  dl, USB_PROG_UHCI
    je   .is_uhci
    cmp  dl, USB_PROG_OHCI
    je   .is_ohci
    cmp  dl, USB_PROG_EHCI
    je   .is_ehci
    cmp  dl, USB_PROG_XHCI
    je   .is_xhci
    jmp  .not_usb

.is_uhci:
    mov  dl, 0     ; type = UHCI
    jmp  .store
.is_ohci:
    mov  dl, 1     ; type = OHCI
    jmp  .store
.is_ehci:
    mov  dl, 2     ; type = EHCI
    jmp  .store
.is_xhci:
    mov  dl, 3     ; type = xHCI
    jmp  .store

.store:
    ; Check if table is full
    mov  esi, [usb_ctrl_count]
    cmp  esi, UHCI_MAX_CTRL
    jge  .not_usb

    ; Store entry: bus, dev, func, type
    imul esi, 16
    add  esi, usb_ctrl_table
    mov  [esi],     bl       ; bus
    mov  [esi + 1], bh       ; dev
    mov  [esi + 2], cl       ; func
    mov  [esi + 3], dl       ; type

    ; Read BAR0
    mov  ch, PCI_REG_BAR0
    call pci_make_addr
    call pci_read32
    mov  [esi + 4], eax      ; BAR0

    ; Read BAR1
    mov  ch, PCI_REG_BAR1
    call pci_make_addr
    call pci_read32
    mov  [esi + 8], eax      ; BAR1

    ; Enable Bus Master + Memory Space + I/O Space in PCI Command
    mov  ch, 0x04            ; PCI Command register
    call pci_make_addr
    call pci_read32
    or   eax, 0x07           ; bit2=BusMaster, bit1=MemorySpace, bit0=IOSpace
    call pci_write32

    inc  dword [usb_ctrl_count]

.not_usb:
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; ---------------------------------------------------------------------------
; uhci_init - initialize the first UHCI controller found
; ---------------------------------------------------------------------------
uhci_init:
    pusha

    mov  byte [uhci_found], 0

    ; Check if any USB controllers were found
    cmp  dword [usb_ctrl_count], 0
    je   .no_uhci

    ; Find first UHCI controller in table
    xor  ecx, ecx
.find_loop:
    cmp  ecx, [usb_ctrl_count]
    jge  .no_uhci

    imul esi, ecx, 16
    add  esi, usb_ctrl_table
    cmp  byte [esi + 3], 0    ; type == UHCI?
    je   .found_uhci
    inc  ecx
    jmp  .find_loop

.found_uhci:
    ; Store UHCI location
    mov  al, [esi]
    mov  [uhci_bus], al
    mov  al, [esi + 1]
    mov  [uhci_dev], al
    mov  al, [esi + 2]
    mov  [uhci_func], al

    ; Get I/O base from BAR0
    mov  eax, [esi + 4]
    and  eax, 0xFFFFFFFC     ; mask off bottom 2 bits (I/O space indicator)
    mov  [uhci_io_base], eax

    ; Stop controller if running
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    xor  ax, ax              ; Write 0 = stop
    out  dx, ax

    ; Short delay for stop to take effect
    mov  eax, 10
    call pm_delay_ms

    ; Issue Host Controller Reset
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    mov  ax, UHCI_CMD_HCRESET
    out  dx, ax

    ; Wait for reset to complete (bit 1 clears when done)
    mov  ecx, 1000           ; timeout count
.hc_reset_wait:
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    in   ax, dx
    test ax, UHCI_CMD_HCRESET
    jz   .reset_done
    ; small delay
    push ecx
    mov  eax, 1
    call pm_delay_ms
    pop  ecx
    loop .hc_reset_wait
    jmp  .no_uhci            ; reset timed out

.reset_done:
    ; Issue Global Reset (legacy devices)
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    mov  ax, UHCI_CMD_GRESET
    out  dx, ax

    mov  eax, 100            ; 100ms global reset
    call pm_delay_ms

    ; Clear global reset
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    xor  ax, ax
    out  dx, ax

    ; Clear status register (write 1s to clear)
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBSTS
    mov  ax, 0xFFFF
    out  dx, ax

    ; Disable all interrupts (polling mode)
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBINTR
    xor  ax, ax
    out  dx, ax

    ; Initialize frame list
    call uhci_init_frame_list

    ; Set frame list base address
    mov  edx, [uhci_io_base]
    add  dx, UHCI_FLBASEADD
    mov  eax, UHCI_FL_BASE
    out  dx, eax

    ; Set frame number to 0
    mov  edx, [uhci_io_base]
    add  dx, UHCI_FRNUM
    xor  ax, ax
    out  dx, ax

    ; Set SOF modify to 64 (default)
    mov  edx, [uhci_io_base]
    add  dx, UHCI_SOFMOD
    mov  al, 64
    out  dx, al

    ; Clear port status registers
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    mov  [uhci_port1_last], ax
    mov  ax, 0x0A0A          ; write 1s to clear change bits (CONNC | ENC)
    out  dx, ax

    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    mov  [uhci_port2_last], ax
    mov  ax, 0x0A0A
    out  dx, ax

    ; Set Configure Flag and RUN
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    mov  ax, UHCI_CMD_RUN | UHCI_CMD_CF | UHCI_CMD_MAXP
    out  dx, ax

    ; Verify controller is running (not halted)
    mov  ecx, 100
.verify_run:
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBSTS
    in   ax, dx
    test ax, UHCI_STS_HCH
    jz   .running
    push ecx
    mov  eax, 1
    call pm_delay_ms
    pop  ecx
    loop .verify_run
    jmp  .no_uhci            ; controller stayed halted

.running:
    mov  byte [uhci_found], 1
    jmp  .done

.no_uhci:
    mov  byte [uhci_found], 0

.done:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_init_frame_list - zero and initialize the frame list
; ---------------------------------------------------------------------------
uhci_init_frame_list:
    pusha

    ; Clear entire frame list area
    mov  edi, UHCI_FL_BASE
    mov  ecx, UHCI_FL_SIZE / 4
    xor  eax, eax
    rep  stosd

    ; Fill each entry with a terminated null link
    ; All entries point to a single shared null queue head at FL_BASE + 4096
    mov  eax, (UHCI_FL_BASE + 4096) | UHCI_FL_TERM
    mov  edi, UHCI_FL_BASE
    mov  ecx, UHCI_FL_ENTRIES
.fill_loop:
    mov  [edi], eax
    add  edi, 4
    loop .fill_loop

    ; Set up the null queue head (terminates all transactions)
    mov  dword [UHCI_FL_BASE + 4096], 0x00000001  ; QH with T-bit set
    mov  dword [UHCI_FL_BASE + 4096 + 4], 0x00000001

    popa
    ret

; ---------------------------------------------------------------------------
; uhci_poll - poll port status for changes (call from main loop)
; ---------------------------------------------------------------------------
uhci_poll:
    pusha

    cmp  byte [uhci_found], 0
    je   .done

    ; Poll port 1
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    mov  bx, [uhci_port1_last]
    cmp  ax, bx
    je   .check_port2
    mov  [uhci_port1_last], ax

    ; Check for new connection
    test ax, UHCI_PORT_CONN
    jz   .check_port2
    test ax, UHCI_PORT_CONNC
    jz   .check_port2

    ; New device connected on port 1
    call uhci_handle_connect_port1

.check_port2:
    ; Poll port 2
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    mov  bx, [uhci_port2_last]
    cmp  ax, bx
    je   .done
    mov  [uhci_port2_last], ax

    ; Check for new connection
    test ax, UHCI_PORT_CONN
    jz   .done
    test ax, UHCI_PORT_CONNC
    jz   .done

    ; New device connected on port 2
    call uhci_handle_connect_port2

.done:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_handle_connect_port1 - reset and enable port 1
; ---------------------------------------------------------------------------
uhci_handle_connect_port1:
    pusha

    ; Clear connect change bit
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    mov  ax, UHCI_PORT_CONNC
    out  dx, ax

    ; Issue port reset
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    or   ax, UHCI_PORT_PR
    out  dx, ax

    ; Wait 50ms for reset
    mov  eax, 50
    call pm_delay_ms

    ; Clear port reset bit
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    and  ax, ~UHCI_PORT_PR
    out  dx, ax

    ; Wait 10ms after reset
    mov  eax, 10
    call pm_delay_ms

    ; Enable the port
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    or   ax, UHCI_PORT_EN
    out  dx, ax

    ; Wait for enable to take effect
    mov  ecx, 100
.wait_enable:
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    test ax, UHCI_PORT_EN
    jnz  .enabled
    push ecx
    mov  eax, 1
    call pm_delay_ms
    pop  ecx
    loop .wait_enable

.enabled:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_handle_connect_port2 - reset and enable port 2
; ---------------------------------------------------------------------------
uhci_handle_connect_port2:
    pusha

    ; Clear connect change bit
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    mov  ax, UHCI_PORT_CONNC
    out  dx, ax

    ; Issue port reset
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    or   ax, UHCI_PORT_PR
    out  dx, ax

    ; Wait 50ms for reset
    mov  eax, 50
    call pm_delay_ms

    ; Clear port reset bit
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    and  ax, ~UHCI_PORT_PR
    out  dx, ax

    ; Wait 10ms after reset
    mov  eax, 10
    call pm_delay_ms

    ; Enable the port
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    or   ax, UHCI_PORT_EN
    out  dx, ax

    ; Wait for enable to take effect
    mov  ecx, 100
.wait_enable:
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    test ax, UHCI_PORT_EN
    jnz  .enabled
    push ecx
    mov  eax, 1
    call pm_delay_ms
    pop  ecx
    loop .wait_enable

.enabled:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_stop - stop the UHCI controller (shutdown)
; ---------------------------------------------------------------------------
uhci_stop:
    pusha

    cmp  byte [uhci_found], 0
    je   .done

    ; Stop controller
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBCMD
    xor  ax, ax
    out  dx, ax

    ; Wait for halt
    mov  ecx, 100
.wait_halt:
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBSTS
    in   ax, dx
    test ax, UHCI_STS_HCH
    jnz  .halted
    push ecx
    mov  eax, 1
    call pm_delay_ms
    pop  ecx
    loop .wait_halt

.halted:
    ; Disable interrupts
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBINTR
    xor  ax, ax
    out  dx, ax

    ; Disable ports
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    xor  ax, ax
    out  dx, ax

    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    xor  ax, ax
    out  dx, ax

.done:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_port_status - print port status to terminal
; Called by shell command or for diagnostics
; ---------------------------------------------------------------------------
uhci_port_status:
    pusha

    cmp  byte [uhci_found], 0
    je   .not_found

    call pm_newline
    mov  esi, uhci_str_header
    mov  bl, 0x0B
    call pm_puts

    ; Print I/O base
    mov  esi, uhci_str_iobase
    mov  bl, 0x0E
    call pm_puts
    mov  eax, [uhci_io_base]
    call pm_print_hex32
    call pm_newline

    ; Port 1 status
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC1
    in   ax, dx
    push ax
    mov  esi, uhci_str_port1
    mov  bl, 0x0E
    call pm_puts
    pop  ax
    call uhci_print_port_status

    ; Port 2 status
    mov  edx, [uhci_io_base]
    add  dx, UHCI_PORTSC2
    in   ax, dx
    push ax
    mov  esi, uhci_str_port2
    mov  bl, 0x0E
    call pm_puts
    pop  ax
    call uhci_print_port_status

    ; Controller status
    mov  edx, [uhci_io_base]
    add  dx, UHCI_USBSTS
    in   ax, dx
    push ax
    mov  esi, uhci_str_ctrlsts
    mov  bl, 0x0E
    call pm_puts
    pop  ax
    call pm_print_hex16
    call pm_newline

    jmp  .done

.not_found:
    call pm_newline
    mov  esi, uhci_str_not_found
    mov  bl, 0x0C
    call pm_puts
    call pm_newline

.done:
    popa
    ret

; ---------------------------------------------------------------------------
; uhci_print_port_status - helper to decode port status word
; In: AX = port status word
; ---------------------------------------------------------------------------
uhci_print_port_status:
    pusha

    ; Print raw hex value
    call pm_print_hex16
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc

    ; Decode flags
    test ax, UHCI_PORT_CONN
    jz   .no_conn
    mov  esi, uhci_str_connected
    mov  bl, 0x0A
    call pm_puts
.no_conn:

    test ax, UHCI_PORT_EN
    jz   .no_en
    mov  esi, uhci_str_enabled
    mov  bl, 0x0A
    call pm_puts
.no_en:

    test ax, UHCI_PORT_LSDA
    jz   .no_ls
    mov  esi, uhci_str_lowspeed
    mov  bl, 0x0E
    call pm_puts
.no_ls:

    test ax, UHCI_PORT_SUSP
    jz   .no_susp
    mov  esi, uhci_str_suspended
    mov  bl, 0x0C
    call pm_puts
.no_susp:

    call pm_newline
    popa
    ret

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------
; NOTE: pm_print_hex16 is provided by pm/net/pci.asm (already included)
; Do NOT redefine it here.

; ---------------------------------------------------------------------------
; Strings
; ---------------------------------------------------------------------------
uhci_str_header:
    db ' --- UHCI Controller Status ---', 13, 10, 0
uhci_str_iobase:
    db ' I/O Base: 0x', 0
uhci_str_port1:
    db ' Port 1: 0x', 0
uhci_str_port2:
    db ' Port 2: 0x', 0
uhci_str_ctrlsts:
    db ' Ctrl STS: 0x', 0
uhci_str_not_found:
    db ' [USB] No UHCI controller found.', 13, 10, 0
uhci_str_connected:
    db ' [CONN]', 0
uhci_str_enabled:
    db ' [EN]', 0
uhci_str_lowspeed:
    db ' [LOW]', 0
uhci_str_suspended:
    db ' [SUSP]', 0
