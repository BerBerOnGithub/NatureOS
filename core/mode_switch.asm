; ===========================================================================
; core/mode_switch.asm - Bridge between PM (32-bit) and RM (16-bit)
;
; pm_bios_call: executes a BIOS interrupt from 32-bit protected mode.
;   Drop to real mode, fire INT, return to PM.  Used by bios_disk.asm.
;
; rm_idtr   - defined in pm/pm_commands.asm (shared)
; rm_sp_save - defined in commands/data.asm  (shared)
; Both are referenced here with [cs:label] since CS=0 in RM and the
; kernel is ORG 0x8000, so label values == physical addresses.
; ===========================================================================

RM_REGS_ADDR equ 0x1000

; Structure at RM_REGS_ADDR:
;   +0  EAX (dd)
;   +4  EBX (dd)
;   +8  ECX (dd)
;   +12 EDX (dd)
;   +16 ESI (dd)
;   +20 EDI (dd)
;   +24 DS  (dw)
;   +26 ES  (dw)
;   +28 FLG (dw)
;   +30 INT (db)

[BITS 32]

; -
; pm_bios_call
; Executes a BIOS interrupt from Protected Mode.
; In: AL = interrupt number
;     Registers in RM_REGS_ADDR structure
; -
pm_bios_call:
    pusha
    mov  [RM_REGS_ADDR + 30], al

    cli

    ; Save 32-bit stack pointer and IDTR
    mov  [pm_sp_save], esp
    sidt [pm_idtr_save]

    ; 1. Transition to 16-bit Protected Mode
    jmp  0x18:.pm16

[BITS 16]
.pm16:
    ; Load 16-bit data selectors
    mov  ax, 0x20
    mov  ds, ax
    mov  es, ax
    mov  ss, ax

    ; 2. Drop into Real Mode
    mov  eax, cr0
    and  eax, ~1
    mov  cr0, eax

    ; Far jump to flush prefetch and load RM CS.
    ; CS=0x0000, label values are physical addresses (ORG 0x8000).
    jmp  0x0000:.rm

.rm:
    ; 3. Setup RM environment
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  fs, ax
    mov  gs, ax

    ; Load BIOS IVT (base=0, limit=0x3FF) - rm_idtr defined in pm_commands.asm
    lidt [cs:rm_idtr]

    ; Restore RM stack pointer - rm_sp_save defined in commands/data.asm
    mov  sp, [cs:rm_sp_save]

    ; PIC Remap to BIOS defaults (Master IRQ0=0x08, Slave IRQ8=0x70)
    mov  al, 0x11
    out  0x20, al
    out  0xA0, al
    mov  al, 0x08
    out  0x21, al
    mov  al, 0x70
    out  0xA1, al
    mov  al, 0x04           ; cascade on IRQ2
    out  0x21, al
    mov  al, 0x02
    out  0xA1, al
    mov  al, 0x01
    out  0x21, al
    out  0xA1, al

    ; 4. Load RM registers from structure (DS=0, no seg prefix needed)
    mov  si, RM_REGS_ADDR
    mov  eax, [si + 0]
    mov  ebx, [si + 4]
    mov  ecx, [si + 8]
    mov  edx, [si + 12]
    mov  edi, [si + 20]
    push dword [si + 16]
    pop  esi

    ; Load segments (ES first so SI still points at structure)
    mov  ax, [si + 26]
    mov  es, ax
    mov  ax, [si + 24]
    mov  ds, ax

    ; 5. Self-modifying INT instruction - patch vector byte via CS:
    push ax
    push ds
    xor  ax, ax
    mov  ds, ax
    mov  al, [RM_REGS_ADDR + 30]
    mov  [cs:.int_instr + 1], al
    pop  ds
    pop  ax

.int_instr:
    int  0x00

    ; 6. Save results back to structure
    pushf
    push ds
    push bp
    xor  bp, bp
    mov  ds, bp
    mov  bp, RM_REGS_ADDR

    mov  [bp + 0],  eax
    mov  [bp + 4],  ebx
    mov  [bp + 8],  ecx
    mov  [bp + 12], edx
    mov  [bp + 16], esi
    mov  [bp + 20], edi

    pop  ax             ; original BP (discarded)
    pop  ax             ; original DS
    mov  [bp + 24], ax
    pop  ax             ; flags
    mov  [bp + 28], ax

    ; PIC Remap back to PM values (Master 0x20, Slave 0x28)
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

    ; 7. Re-enter Protected Mode
    cli
    lgdt [cs:gdt_descriptor]
    lidt [cs:pm_idtr_save]

    mov  eax, cr0
    or   eax, 1
    mov  cr0, eax

    jmp  0x08:.pm32

[BITS 32]
.pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, [pm_sp_save]

    popa
    sti
    ret

; ---- Variables (local to this file only) ----
pm_sp_save:   dd 0
pm_idtr_save:
    dw 0
    dd 0
