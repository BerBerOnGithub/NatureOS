; ===========================================================================
; pm/pm_drivers.asm - Protected-mode driver registry
;
; Provides:
;   pm_drv_init      - called on PM entry, initialises all PM drivers
;   pm_drv_shutdown  - called before returning to RM, shuts down PM drivers
;   pm_cmd_drivers   - shell command: list loaded drivers and status
;
; PM drivers:
;   [0] Screen   - direct VGA RAM (0xB8000), CRT controller ports 0x3D4/0x3D5
;   [1] Keyboard - direct PS/2 ports 0x60/0x64, scan code translation
;   [2] PIT      - 8253/8254 timer ports 0x40-0x43, channel 0 for delay
;   [3] Speaker  - PIT channel 2 + port 0x61 (no BIOS)
; ===========================================================================

[BITS 32]

; -
; Driver status table
; -
pm_drv_status:
    db 0    ; 0 Screen
    db 0    ; 1 Keyboard
    db 0    ; 2 PIT timer
    db 0    ; 3 Speaker
    db 0    ; 4 PCI bus
    db 0    ; 5 e1000 NIC

PM_DRV_COUNT equ 6

; -
; pm_drv_init - initialise all PM drivers on entry to protected mode
; -
pm_drv_init:
    push eax
    push ecx
    push edx
    push edi

    ; - Driver 0: Screen -
    ; Clear VGA text buffer directly (no BIOS)
    mov  edi, 0x000B8000
    mov  ecx, 80 * 25
    mov  eax, 0x0F200F20     ; two spaces, attr 0x0F (bright white on black)
    rep  stosd
    ; reset cursor vars
    mov  dword [pm_cursor_x], 0
    mov  dword [pm_cursor_y], 0
    ; home hardware cursor via CRT controller
    mov  dx, 0x3D4
    mov  al, 0x0F
    out  dx, al
    mov  dx, 0x3D5
    mov  al, 0
    out  dx, al
    mov  dx, 0x3D4
    mov  al, 0x0E
    out  dx, al
    mov  dx, 0x3D5
    mov  al, 0
    out  dx, al
    mov  byte [pm_drv_status + 0], 1

    ; - Driver 1: Keyboard -
    ; Flush PS/2 output buffer " drain any pending bytes from port 0x60
.kbd_flush:
    in   al, 0x64
    test al, 1
    jz   .kbd_done
    in   al, 0x60
    jmp  .kbd_flush
.kbd_done:
    ; reset shift state
    mov  byte [pm_shift], 0
    mov  byte [pm_drv_status + 1], 1

    ; - Driver 2: PIT timer -
    ; Program channel 0: mode 3 (square wave), divisor 11932 0/00 100 Hz
    ; (default BIOS rate is 18.2 Hz; 100 Hz is more useful for delays)
    mov  al, 0x36            ; channel 0, lobyte/hibyte, mode 3, binary
    out  0x43, al
    mov  ax, 11932           ; 1193182 / 100 = 11931.82 0/00 11932
    out  0x40, al            ; low byte
    mov  al, ah
    out  0x40, al            ; high byte
    mov  byte [pm_drv_status + 2], 1

    ; - Driver 3: Speaker " ensure off -
    in   al, 0x61
    and  al, 0xFC
    out  0x61, al
    mov  byte [pm_drv_status + 3], 1

    ; - Driver 4: PCI bus -
    call pci_init
    mov  byte [pm_drv_status + 4], 1

    ; - Driver 5: e1000 NIC -
    call e1000_init
    mov  al, [e1000_ready]
    mov  [pm_drv_status + 5], al

    ; pre-seed ARP cache (QEMU SLIRP gateway doesn't respond to ARP)
    call arp_init

    pop  edi
    pop  edx
    pop  ecx
    pop  eax
    ret

; -
; pm_drv_shutdown - cleanly shut down all PM drivers before returning to RM
; -
pm_drv_shutdown:
    push eax
    push edx

    ; - Driver 3: Speaker " off -
    in   al, 0x61
    and  al, 0xFC
    out  0x61, al
    mov  byte [pm_drv_status + 3], 0

    ; - Driver 2: PIT " restore BIOS default rate (divisor 0 = 65536 0/00 18.2 Hz)
    mov  al, 0x36
    out  0x43, al
    xor  al, al
    out  0x40, al
    out  0x40, al
    mov  byte [pm_drv_status + 2], 0

    ; - Driver 1: Keyboard " flush PS/2 buffer -
.flush:
    in   al, 0x64
    test al, 1
    jz   .flush_done
    in   al, 0x60
    jmp  .flush
.flush_done:
    mov  byte [pm_drv_status + 1], 0

    ; - Driver 0: Screen " mark unloaded (RM will reinit via BIOS) -
    mov  byte [pm_drv_status + 0], 0

    ; - Driver 5: e1000 " disable RX/TX -
    cmp  byte [e1000_ready], 1
    jne  .e1000_skip
    xor  eax, eax
    mov  edx, E1000_RCTL
    call e1000_mmio_write
    xor  eax, eax
    mov  edx, E1000_TCTL
    call e1000_mmio_write
.e1000_skip:
    mov  byte [pm_drv_status + 5], 0

    ; - Driver 4: PCI " nothing to teardown -
    mov  byte [pm_drv_status + 4], 0

    pop  edx
    pop  eax
    ret

; -
; pm_cmd_drivers - display PM driver status table
; -
pm_cmd_drivers:
    push esi
    push ebx

    call pm_newline
    mov  esi, pm_str_drv_hdr
    mov  bl, 0x0B
    call pm_puts

    mov  esi, pm_str_drv_screen
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 0]
    call .status

    mov  esi, pm_str_drv_kbd
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 1]
    call .status

    mov  esi, pm_str_drv_pit
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 2]
    call .status

    mov  esi, pm_str_drv_spk
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 3]
    call .status

    mov  esi, pm_str_drv_pci
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 4]
    call .status

    mov  esi, pm_str_drv_e1000
    mov  bl, 0x0E
    call pm_puts
    mov  al, [pm_drv_status + 5]
    call .status

    mov  esi, pm_str_drv_footer
    mov  bl, 0x0B
    call pm_puts
    call pm_newline

    pop  ebx
    pop  esi
    ret

.status:
    cmp  al, 1
    je   .yes
    mov  esi, pm_str_drv_unloaded
    mov  bl, 0x0C
    call pm_puts
    ret
.yes:
    mov  esi, pm_str_drv_loaded
    mov  bl, 0x0A
    call pm_puts
    ret

; -
; pm_delay_ms - busy-wait approximately EAX milliseconds using PIT channel 0
; Reads port 0x40 latch; each tick at 100 Hz = 10ms.
; For simplicity: spins reading PIT status, counts ticks.
; -
pm_delay_ms:
    push eax
    push ecx
    push edx
    ; convert ms to ticks at 100Hz (divide by 10)
    mov  ecx, eax
    xor  edx, edx
    mov  eax, ecx
    mov  ecx, 10
    div  ecx             ; EAX = ticks needed
    mov  ecx, eax
    test ecx, ecx
    jz   .done
.tick:
    ; latch channel 0 count
    mov  al, 0x00
    out  0x43, al
    in   al, 0x40        ; low byte
    in   al, 0x40        ; high byte (discard " just burning a tick)
    loop .tick
.done:
    pop  edx
    pop  ecx
    pop  eax
    ret

; -
; Strings
; -
pm_str_drv_hdr:
    db 13, 10
    db ' -', 13, 10
    db ' | PM Driver            | Status   |', 13, 10
    db ' -', 13, 10, 0
pm_str_drv_footer:
    db ' -', 13, 10, 0
pm_str_drv_screen:  db ' | Screen  (0xB8000)    | ', 0
pm_str_drv_kbd:     db ' | Keyboard (port 0x60) | ', 0
pm_str_drv_pit:     db ' | PIT Timer (0x40-43)  | ', 0
pm_str_drv_spk:     db ' | Speaker (PIT ch.2)   | ', 0
pm_str_drv_pci:     db ' | PCI Bus  (0xCF8)     | ', 0
pm_str_drv_e1000:   db ' | e1000 NIC (MMIO)     | ', 0
pm_str_drv_loaded:   db 'LOADED   |', 13, 10, 0
pm_str_drv_unloaded: db 'UNLOADED |', 13, 10, 0

%include "pm/net/pci.asm"
%include "pm/net/e1000.asm"
%include "pm/net/eth.asm"
%include "pm/net/arp.asm"
%include "pm/net/ip.asm"
%include "pm/net/icmp.asm"
%include "pm/net/udp.asm"
%include "pm/net/tcp.asm"