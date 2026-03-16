; ---------------------------------------------------------------------------
; irq.asm — IDT setup, PIC remap, PIT IRQ0 handler
;
; Exports:
;   irq_init        — remap PIC, install IDT, enable IRQ0
;   pit_ticks       — dd, incremented at 100Hz by IRQ0 handler
; ---------------------------------------------------------------------------

; ── irq_init ──────────────────────────────────────────────────────────────────
; Remaps PIC so IRQ0-7 -> INT 0x20-0x27, IRQ8-15 -> INT 0x28-0x2F
; Builds a 256-entry IDT (all stubs, IRQ0 = real handler)
; Loads IDT and enables interrupts.
irq_init:
    pusha

    ; ── remap PIC ─────────────────────────────────────────────────────────
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

    ; ── build IDT — fill all 256 entries with irq_stub ────────────────────
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

    ; ── install IRQ0 (PIT) handler at vector 0x20 ─────────────────────────
    mov  edi, idt_table + (0x20 * 8)
    mov  eax, irq0_handler
    mov  word  [edi],   ax
    mov  word  [edi+2], 0x08
    mov  byte  [edi+4], 0x00
    mov  byte  [edi+5], 0x8E
    shr  eax, 16
    mov  word  [edi+6], ax

    ; ── install error-code stubs for exceptions that push an error code ───
%macro set_err_gate 1
    mov  edi, idt_table + (%1 * 8)
    mov  eax, irq_stub_err
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

    ; ── load IDTR ─────────────────────────────────────────────────────────
    mov  word  [idt_desc],   256*8 - 1
    mov  dword [idt_desc+2], idt_table
    lidt [idt_desc]

    sti
    popa
    ret

; ── IRQ0 handler (PIT, 100Hz) ─────────────────────────────────────────────────
irq0_handler:
    push eax
    inc  dword [pit_ticks]
    mov  al, 0x20
    out  0x20, al
    pop  eax
    iret

; ── generic stub (no error code) ──────────────────────────────────────────────
irq_stub:
    push eax
    mov  al, 0x20
    out  0x20, al
    out  0xA0, al
    pop  eax
    iret

; ── stub for exceptions that push an error code ───────────────────────────────
irq_stub_err:
    add  esp, 4        ; discard error code
    hlt

; ── data ──────────────────────────────────────────────────────────────────────
pit_ticks:   dd 0

idt_desc:
    dw 0
    dd 0
align 8
idt_table:
    times (256 * 8) db 0