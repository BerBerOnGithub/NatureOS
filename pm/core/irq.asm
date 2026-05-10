; -
; irq.asm " IDT setup, PIC remap, PIT IRQ0 handler
;
; Exports:
;   irq_init        " remap PIC, install IDT, enable IRQ0
;   pit_ticks       " dd, incremented at 100Hz by IRQ0 handler
; -

; - irq_init -
; Remaps PIC so IRQ0-7 -> INT 0x20-0x27, IRQ8-15 -> INT 0x28-0x2F
; Builds a 256-entry IDT (all stubs, IRQ0 = real handler)
; Loads IDT and enables interrupts.
irq_init:
    pusha

    ; - remap PIC -
    mov  al, 0x11
    out  0x20, al
    out  0xA0, al
    mov  al, 0x20
    out  0x21, al
    mov  al, 0x28
    out  0xA1, al
    mov  al, 0x04
    out  0x21, al
    mov  al, 0x02
    out  0xA1, al
    mov  al, 0x01
    out  0x21, al
    out  0xA1, al
    mov  al, 0xFE
    out  0x21, al
    mov  al, 0xFF
    out  0xA1, al

    ; - build IDT " fill all 256 entries with irq_stub -
    mov  ecx, 256
    mov  edi, idt_table
.fill:
    mov  eax, irq_stub
    mov  word  [edi],   ax
    mov  word  [edi+2], 0x08
    mov  byte  [edi+4], 0x00
    mov  byte  [edi+5], 0x8E
    shr  eax, 16
    mov  word  [edi+6], ax
    add  edi, 8
    dec  ecx
    jnz  .fill

    ; - install IRQ0 (PIT) handler at vector 0x20 -
    mov  edi, idt_table + (0x20 * 8)
    mov  eax, irq0_handler
    mov  word  [edi],   ax
    mov  word  [edi+2], 0x08
    mov  byte  [edi+4], 0x00
    mov  byte  [edi+5], 0x8E
    shr  eax, 16
    mov  word  [edi+6], ax

    ; - install error-code stubs for exceptions that push an error code -
%macro set_err_gate 1
    mov  edi, idt_table + (%1 * 8)
    mov  eax, stub_err_%1
    mov  word  [edi],   ax
    mov  word  [edi+2], 0x08
    mov  byte  [edi+4], 0x00
    mov  byte  [edi+5], 0x8E
    shr  eax, 16
    mov  word  [edi+6], ax
%endmacro

%macro set_exc_gate 1
    mov  edi, idt_table + (%1 * 8)
    mov  eax, stub_exc_%1
    mov  word  [edi],   ax
    mov  word  [edi+2], 0x08
    mov  byte  [edi+4], 0x00
    mov  byte  [edi+5], 0x8E
    shr  eax, 16
    mov  word  [edi+6], ax
%endmacro

    set_err_gate 0x08   ; #DF double fault
    set_err_gate 0x0A   ; #TS invalid TSS
    set_err_gate 0x0B   ; #NP segment not present
    set_err_gate 0x0C   ; #SS stack fault
    set_err_gate 0x0D   ; #GP general protection
    set_err_gate 0x0E   ; #PF page fault
    set_err_gate 0x11   ; #AC alignment check

    set_exc_gate 0x00   ; #DE divide error
    set_exc_gate 0x06   ; #UD invalid opcode

    ; - load IDTR -
    mov  word  [idt_desc],   256*8 - 1
    mov  dword [idt_desc+2], idt_table
    lidt [idt_desc]

    sti
    popa
    ret

; - irq_restore -
; Restores PIC to Real Mode defaults:
; IRQ0-7  -> INT 0x08-0x0F
; IRQ8-15 -> INT 0x70-0x77
; Unmasks all IRQs.
irq_restore:
    pusha
    
    ; - remap PIC -
    mov  al, 0x11
    out  0x20, al
    out  0xA0, al
    mov  al, 0x08           ; Master PIC offset = 0x08 (BIOS default)
    out  0x21, al
    mov  al, 0x70           ; Slave PIC offset = 0x70 (BIOS default)
    out  0xA1, al
    mov  al, 0x04
    out  0x21, al
    mov  al, 0x02
    out  0xA1, al
    mov  al, 0x01
    out  0x21, al
    out  0xA1, al
    
    ; - unmask all IRQs -
    mov  al, 0x00
    out  0x21, al
    out  0xA1, al
    
    popa
    ret

; - IRQ0 handler (PIT, 100Hz) -
irq0_handler:
    push eax
    inc  dword [pit_ticks]
    mov  al, 0x20
    out  0x20, al
    pop  eax
    iret

; - generic stub (no error code) -
irq_stub:
    push eax
    mov  al, 0x20
    out  0x20, al
    out  0xA0, al
    pop  eax
    iret

; - stub for exceptions that push an error code -
irq_stub_err:
    add  esp, 4        ; discard error code
    hlt

; - crash reporter strings -
str_fatal_exc: db "FATAL EXCEPTION: ", 0
str_hex:       db "0123456789ABCDEF"

; EAX = vector, EBX = error code (if any)
irq_fatal_dump:
    push eax
    push ebx
    mov  esi, str_fatal_exc
    call irq_serial_puts
    pop  ebx
    pop  eax

    ; Print vector in hex (AL)
    push eax
    mov  al, [esp+0]
    shr  al, 4
    and  eax, 0xF
    mov  al, [str_hex + eax]
    call irq_serial_putc
    mov  al, [esp+0]
    and  eax, 0xF
    mov  al, [str_hex + eax]
    call irq_serial_putc
    pop  eax

    ; Print CR2 (Faulting Address) - critical for 0E
    mov  esi, str_cr2
    call irq_serial_puts
    mov  eax, cr2
    call irq_serial_print_hex32_local

    ; Print Error Code
    mov  esi, str_err_code
    call irq_serial_puts
    mov  eax, ebx
    call irq_serial_print_hex32_local

    mov  al, 13
    call irq_serial_putc
    mov  al, 10
    call irq_serial_putc
    
    cli
    hlt

; Local helper (can't rely on outside functions if GDT/IDT broken)
irq_serial_print_hex32_local:
    pusha
    mov  ecx, 8
.loop:
    rol  eax, 4
    mov  edx, eax
    and  edx, 0x0F
    mov  dl, [str_hex + edx]
    call irq_serial_putc
    loop .loop
    popa
    ret

str_cr2:      db " CR2:", 0
str_err_code: db " ERR:", 0

irq_serial_puts:
    push eax
.loop:
    mov  al, [esi]
    test al, al
    jz   .done
    call irq_serial_putc
    inc  esi
    jmp  .loop
.done:
    pop  eax
    ret

irq_serial_putc:
    push eax
    push edx
.wait:
    mov  dx, 0x3FD
    in   al, dx
    test al, 0x20
    jz   .wait
    mov  dx, 0x3F8
    pop  eax
    out  dx, al
    pop  edx
    ret

%macro make_stub_err 1
stub_err_%1:
    mov  eax, %1         ; vector
    mov  ebx, [esp]      ; error code
    jmp  irq_fatal_dump
%endmacro

%macro make_stub_exc 1
stub_exc_%1:
    mov  eax, %1         ; vector
    xor  ebx, ebx        ; no error code
    jmp  irq_fatal_dump
%endmacro

make_stub_err 0x08
make_stub_err 0x0A
make_stub_err 0x0B
make_stub_err 0x0C
make_stub_err 0x0D
make_stub_err 0x0E
make_stub_err 0x11

make_stub_exc 0x00
make_stub_exc 0x06

; - data -
pit_ticks:   dd 0

idt_desc:
    dw 0
    dd 0
align 8
idt_table:
    times (256 * 8) db 0
