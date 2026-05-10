; ===========================================================================
; pm/bios_disk.asm  -  BIOS INT 13h disk I/O from protected mode
;
; Follows OSDev wiki procedure exactly:
; https://wiki.osdev.org/Real_Mode#x86_Assembly_Example
;
; Key insight from wiki: BIOS may clobber GDTR, so we must reload it
; before re-entering PM. We store the GDTR descriptor at a known low address.
;
; Stub copied to 0x7E00 (just after MBR area, always free, below 64KB):
;   0x7E00: 16-bit PM -> real mode -> INT 13h -> PM re-entry -> ret trampoline
;
; ESP saved to memory before mode switch, restored in ret trampoline.
; ALL interrupts masked before switch, IRQ0 unmasked after.
; ===========================================================================

[BITS 32]

BD_HDR_BASE  equ 0x80000
BD_MAGIC     equ 0x44464C43
BD_BOUNCE    equ 0x90000   ; 448KB - above stack, below 1MB, BIOS-visible
BD_DAP       equ 0x7D00    ; just below stub, definitely below 64KB
BD_STUB      equ 0x7E00    ; stub location - below 64KB, always free RAM

; Saved-state area at 0x500 - free conventional memory above BDA (0x400-0x4FF),
; never touched by SeaBIOS INT 13h handlers
BD_STUB_GDTR equ 0x0500    ; 6-byte GDTR saved here
BD_STUB_IDTR equ 0x0506    ; 6-byte IDTR saved here
BD_STUB_CR0  equ 0x050C    ; saved 32-bit CR0
BD_STUB_CR3  equ 0x0510    ; saved 32-bit CR3
BD_STUB_ESP  equ 0x0514    ; saved 32-bit ESP
BD_STUB_CMD  equ 0x7F14    ; INT 13h AH value (0x42=read, 0x43=write)
BD_STUB_DRV  equ 0x7F15    ; drive number
BD_STUB_IDTMP equ 0x051A   ; 6-byte temp for real-mode IDTR lidt

; - bios_disk_init -
bios_disk_init:
    pusha
    mov  byte [bd_ready], 0
    ; check if a valid filesystem was detected by stage2 (using safe ICA)
    cmp  byte [0x04F1], FSTYPE_NONE
    je   .done
    mov  al, [0x04F0]
    mov  [bd_drive], al
    call bd_install_stub
    mov  byte [bd_ready], 1
.done:
    popa
    ret

; - bd_install_stub -
bd_install_stub:
    push esi
    push edi
    push ecx
    mov  esi, bd_stub_code
    mov  edi, BD_STUB
    mov  ecx, bd_stub_code_end - bd_stub_code
    rep  movsb
    pop  ecx
    pop  edi
    pop  esi
    ret

; - bd_do_int13 -
bd_do_int13:
    pushad
    ; mask all IRQs
    mov  al, 0xFF
    out  0x21, al
    out  0xA1, al
    ; save current CPU state (CR0, CR3, GDTR, IDTR, ESP)
    mov  eax, cr0
    mov  [BD_STUB_CR0], eax
    mov  eax, cr3
    mov  [BD_STUB_CR3], eax
    sgdt [BD_STUB_GDTR]
    sidt [BD_STUB_IDTR]
    ; save ESP
    mov  [BD_STUB_ESP], esp
    ; write cmd and drive
    mov  al, [bd_cmd]
    mov  [BD_STUB_CMD], al
    mov  al, [bd_drive]
    mov  [BD_STUB_DRV], al
    ; far jump to 16-bit code selector 0x18, offset BD_STUB (< 64KB)
    ; This will jump to at 0x7E00 (BD_STUB)
    db   0xEA
    dd   BD_STUB
    dw   0x18

bd_do_int13_ret:
    ; stub now handles PIC reinit and ret directly
    ; this label kept for reference only - never jumped to
    ret

; - bd_stub_code -
; Copied to BD_STUB (0x7E00). All hardcoded addresses reference 0x7Exx/0x7Fxx.
[BITS 16]
bd_stub_code:
    ; === arrive in 16-bit PM, CS=0x18 (base=0, limit=64KB) ===
    ; load 16-bit data selector
    mov  ax, 0x20
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    ; disable Paging (bit 31) and Protected Mode (bit 0)
    ; we only clear bits, preserving other hardware flags
    mov  eax, cr0
    and  eax, 0x7FFFFFFE
    mov  cr0, eax
    ; far jump to flush pipeline and enter real mode
    ; target: 0x0000:0x7E40 (stub + 0x40)
    db   0xEA
    dw   0x7E40
    dw   0x0000
    ; pad to offset 0x40
    times (0x40 - ($ - bd_stub_code)) db 0x90

    ; === real mode entry (at 0x7E40) ===
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x6C00
    ; load BIOS IVT
    mov  word  [0x051A], 0x03FF
    mov  dword [0x051C], 0x00000000
    lidt [0x051A]
    sti
    ; call INT 13h
    mov  ah, [BD_STUB_CMD]
    xor  al, al
    mov  dl, [BD_STUB_DRV]
    mov  si, BD_DAP
    int  0x13
    cli
    ; reload GDT and IDT
    lgdt [BD_STUB_GDTR]
    lidt [BD_STUB_IDTR]
    ; restore CR3 and CR0
    mov  eax, [0x0510]      ; BD_STUB_CR3
    mov  cr3, eax
    mov  eax, [0x050C]      ; BD_STUB_CR0
    mov  cr0, eax
    ; far jump to 32-bit code selector - target must be < 0x10000
    db   0x66, 0xEA         ; 32-bit far jump (operand size prefix)
    dw   0x7EC0             ; offset - stub PM return code
    dw   0x00               ; pad (high word of 32-bit offset = 0)
    dw   0x08               ; CS selector
    ; pad to offset 0xC0
    times (0xC0 - ($ - bd_stub_code)) db 0x90

    ; === 32-bit PM return code (at 0x7EC0) ===
[BITS 32]
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, [0x0514]     ; BD_STUB_ESP
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
    popad
    sti
    ret
bd_stub_code_end:
[BITS 32]

; - bios_disk_read -
bios_disk_read:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    cmp  byte [bd_ready], 1
    jne  .done
    mov  ebx, ecx
    mov  [bd_cur_lba], eax
.loop:
    test ebx, ebx
    jz   .done
    mov  byte  [BD_DAP],    0x10
    mov  byte  [BD_DAP+1],  0
    mov  word  [BD_DAP+2],  1
    mov  word  [BD_DAP+4],  0
    mov  word  [BD_DAP+6],  BD_BOUNCE >> 4
    mov  dword [BD_DAP+8],  0
    mov  eax,  [bd_cur_lba]
    mov  dword [BD_DAP+8],  eax
    mov  dword [BD_DAP+12], 0
    mov  byte  [bd_cmd],    0x42
    push ebx
    call bd_do_int13
    pop  ebx
    test ah, ah             ; error check
    jnz  .err
    push esi
    push ecx
    mov  esi, BD_BOUNCE
    mov  ecx, 128
    rep  movsd
    pop  ecx
    pop  esi
    inc  dword [bd_cur_lba]
    dec  ebx
    jmp  .loop
.err:
    stc
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - bios_disk_write -
bios_disk_write:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    cmp  byte [bd_ready], 1
    jne  .done
    mov  ebx, ecx
    mov  [bd_cur_lba], eax
.loop:
    test ebx, ebx
    jz   .done
    push edi
    push ecx
    mov  edi, BD_BOUNCE
    mov  ecx, 128
    rep  movsd
    pop  ecx
    pop  edi
    add  esi, 512       ; advance source by one sector
    mov  byte  [BD_DAP],    0x10
    mov  byte  [BD_DAP+1],  0
    mov  word  [BD_DAP+2],  1
    mov  word  [BD_DAP+4],  0
    mov  word  [BD_DAP+6],  BD_BOUNCE >> 4
    mov  eax,  [bd_cur_lba]
    mov  dword [BD_DAP+8],  eax
    mov  dword [BD_DAP+12], 0
    mov  byte  [bd_cmd],    0x43
    push ebx
    call bd_do_int13
    pop  ebx
    inc  dword [bd_cur_lba]
    dec  ebx
    jmp  .loop
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - bios_disk_write_multi -
bios_disk_write_multi:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    cmp  byte [bd_ready], 1
    jne  .done
    mov  [bd_cur_lba], eax
    mov  ebx, ecx
.chunk:
    test ebx, ebx
    jz   .done
    mov  ecx, ebx
    cmp  ecx, 63
    jle  .ok
    mov  ecx, 63
.ok:
    push ecx
    push esi
    mov  edi, BD_BOUNCE
    mov  edx, ecx
    shl  edx, 7
    mov  ecx, edx
    rep  movsd
    pop  esi
    pop  ecx
    push ecx
    shl  ecx, 9
    add  esi, ecx
    pop  ecx
    mov  byte  [BD_DAP],    0x10
    mov  byte  [BD_DAP+1],  0
    mov  [BD_DAP+2],  cx
    mov  word  [BD_DAP+4],  0
    mov  word  [BD_DAP+6],  BD_BOUNCE >> 4
    mov  eax,  [bd_cur_lba]
    mov  dword [BD_DAP+8],  eax
    mov  dword [BD_DAP+12], 0
    mov  byte  [bd_cmd],    0x43
    push ecx
    push ebx
    call bd_do_int13
    pop  ebx
    pop  ecx
    add  [bd_cur_lba], ecx
    sub  ebx, ecx
    jmp  .chunk
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - data -
bd_ready:    db 0
bd_drive:    db 0x80
bd_cmd:      db 0x42
bd_cur_lba:  dd 0
bd_dbg_write:  db '[BD] write sector',13,10,0
bd_dbg_writem: db '[BD] write_multi chunk',13,10,0