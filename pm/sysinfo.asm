; ===========================================================================
; pm/sysinfo.asm - System Information Detection
; ===========================================================================

[BITS 32]

pm_cmd_sysinfo:
    pusha

    call pm_newline
    mov  esi, sysinfo_hdr
    mov  bl, 0x0B
    call pm_puts
    call pm_newline

    ; --- CPU Info ---
    mov  esi, sysinfo_cpu_hdr
    mov  bl, 0x0E
    call pm_puts

    ; Check if CPUID is supported
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 0x200000
    push eax
    popfd
    pushfd
    pop  eax
    xor  eax, ecx
    jz   .no_cpuid

    ; Get Vendor ID
    xor  eax, eax
    cpuid
    mov  [sysinfo_vendor], ebx
    mov  [sysinfo_vendor+4], edx
    mov  [sysinfo_vendor+8], ecx
    mov  byte [sysinfo_vendor+12], 0

    mov  esi, sysinfo_vendor_lbl
    mov  bl, 0x07
    call pm_puts
    mov  esi, sysinfo_vendor
    mov  bl, 0x0F
    call pm_puts
    call pm_newline

    ; Get Processor Brand String
    mov  eax, 0x80000000
    cpuid
    cmp  eax, 0x80000004
    jb   .no_brand

    mov  eax, 0x80000002
    cpuid
    mov  [sysinfo_brand], eax
    mov  [sysinfo_brand+4], ebx
    mov  [sysinfo_brand+8], ecx
    mov  [sysinfo_brand+12], edx

    mov  eax, 0x80000003
    cpuid
    mov  [sysinfo_brand+16], eax
    mov  [sysinfo_brand+20], ebx
    mov  [sysinfo_brand+24], ecx
    mov  [sysinfo_brand+28], edx

    mov  eax, 0x80000004
    cpuid
    mov  [sysinfo_brand+32], eax
    mov  [sysinfo_brand+36], ebx
    mov  [sysinfo_brand+40], ecx
    mov  [sysinfo_brand+44], edx
    mov  byte [sysinfo_brand+48], 0

    mov  esi, sysinfo_brand_lbl
    mov  bl, 0x07
    call pm_puts
    mov  esi, sysinfo_brand
    mov  bl, 0x0F
    call pm_puts
    call pm_newline
    jmp  .features

.no_brand:
    mov  esi, sysinfo_brand_lbl
    mov  bl, 0x07
    call pm_puts
    mov  esi, sysinfo_not_avail
    mov  bl, 0x07
    call pm_puts
    call pm_newline

.features:
    ; Features (EAX=1)
    mov  eax, 1
    cpuid
    mov  [sysinfo_feat_edx], edx
    mov  [sysinfo_feat_ecx], ecx

    mov  esi, sysinfo_feat_lbl
    mov  bl, 0x07
    call pm_puts
    
    ; Decode some features
    mov  edx, [sysinfo_feat_edx]
    
    test edx, 1 << 0 ; FPU
    jz   .no_fpu
    mov  esi, sysinfo_feat_fpu
    call .print_feat
.no_fpu:
    test edx, 1 << 4 ; TSC
    jz   .no_tsc_feat
    mov  esi, sysinfo_feat_tsc
    call .print_feat
.no_tsc_feat:
    test edx, 1 << 23 ; MMX
    jz   .no_mmx
    mov  esi, sysinfo_feat_mmx
    call .print_feat
.no_mmx:
    test edx, 1 << 25 ; SSE
    jz   .no_sse
    mov  esi, sysinfo_feat_sse
    call .print_feat
.no_sse:
    test edx, 1 << 26 ; SSE2
    jz   .no_sse2
    mov  esi, sysinfo_feat_sse2
    call .print_feat
.no_sse2:
    
    call pm_newline
    jmp  .gpu

.no_cpuid:
    mov  esi, sysinfo_no_cpuid_msg
    mov  bl, 0x0C
    call pm_puts
    call pm_newline

.gpu:
    ; --- GPU Info ---
    mov  esi, sysinfo_gpu_hdr
    mov  bl, 0x0E
    call pm_puts

    ; Scan PCI for Class 03 (Display Controller)
    xor  bl, bl ; bus
.pci_bus:
    xor  bh, bh ; dev
.pci_dev:
    xor  cl, cl ; func 0
    call pci_read_venddev
    cmp  eax, 0xFFFFFFFF
    je   .pci_next
    
    ; Read Class Code (Offset 0x08)
    push eax
    push ebx ; save loop bus/dev
    mov  ch, 0x08
    call pci_make_addr
    call pci_read32
    pop  ebx ; restore loop bus/dev
    shr  eax, 24
    cmp  al, 0x03 ; Display Controller
    pop  eax
    jne  .pci_next

    ; Found GPU
    push eax
    mov  esi, sysinfo_gpu_found
    mov  bl, 0x07
    call pm_puts
    pop  eax
    
    push eax
    push ebx ; save current loop bus/dev
    and  eax, 0xFFFF ; vendor
    call pm_print_hex16
    mov  al, ':'
    mov  bl, 0x07
    call pm_putc
    pop  ebx ; restore loop bus/dev
    pop  eax ; restore venddev
    shr  eax, 16 ; device
    call pm_print_hex16
    call pm_newline
    jmp  .mem

.pci_next:
    inc  bh
    cmp  bh, 32
    jl   .pci_dev
    inc  bl
    jnz  .pci_bus
    
    mov  esi, sysinfo_not_found
    mov  bl, 0x07
    call pm_puts
    call pm_newline

.mem:
    ; --- Memory Info ---
    mov  esi, sysinfo_mem_hdr
    mov  bl, 0x0E
    call pm_puts

    ; Get Conventional Memory (INT 12h)
    xor  eax, eax
    mov  edi, RM_REGS_ADDR
    mov  ecx, 8
    rep  stosd
    
    mov  al, 0x12
    call pm_bios_call
    movzx eax, word [RM_REGS_ADDR]
    
    mov  esi, sysinfo_mem_conv
    mov  bl, 0x07
    call pm_puts
    call pm_print_uint
    mov  esi, sysinfo_kb
    call pm_puts
    call pm_newline

    ; Get Extended Memory (INT 15h, AX=E801h)
    xor  eax, eax
    mov  edi, RM_REGS_ADDR
    mov  ecx, 8
    rep  stosd
    mov  dword [RM_REGS_ADDR], 0xE801 ; EAX = 0xE801
    
    mov  al, 0x15
    call pm_bios_call
    
    ; AX contains KB between 1MB and 16MB
    ; BX contains 64KB blocks above 16MB
    movzx eax, word [RM_REGS_ADDR]     ; AX
    movzx ebx, word [RM_REGS_ADDR + 4] ; BX
    
    ; Total extended memory = AX + BX * 64
    shl  ebx, 6
    add  eax, ebx
    
    mov  esi, sysinfo_mem_ext
    mov  bl, 0x07
    call pm_puts
    call pm_print_uint
    mov  esi, sysinfo_kb
    call pm_puts
    call pm_newline

.tsc:
    ; --- TSC ---
    mov  esi, sysinfo_tsc_hdr
    mov  bl, 0x0E
    call pm_puts
    
    mov  edx, [sysinfo_feat_edx]
    test edx, 1 << 4
    jz   .no_tsc
    
    mov  esi, sysinfo_tsc_avail
    mov  bl, 0x0A
    call pm_puts
    
    ; Print current TSC (low 32 bits)
    rdtsc
    push eax
    mov  esi, sysinfo_tsc_val
    mov  bl, 0x07
    call pm_puts
    pop  eax
    call pm_print_hex32
    call pm_newline
    jmp  .done

.no_tsc:
    mov  esi, sysinfo_not_avail
    mov  bl, 0x0C
    call pm_puts
    call pm_newline

.done:
    call pm_newline
    popa
    ret

.print_feat:
    push ebx
    mov  bl, 0x0F
    call pm_puts
    mov  al, ' '
    mov  bl, 0x07
    call pm_putc
    pop  ebx
    ret

; --- Data ---
sysinfo_hdr:        db ' --- System Information ---', 13, 10, 0
sysinfo_cpu_hdr:    db ' [CPU]', 13, 10, 0
sysinfo_vendor_lbl: db '  Vendor:  ', 0
sysinfo_brand_lbl:  db '  Brand:   ', 0
sysinfo_feat_lbl:   db '  Features: ', 0
sysinfo_no_cpuid_msg: db '  CPUID not supported.', 0
sysinfo_not_avail:  db 'Not available', 0
sysinfo_feat_fpu:   db 'FPU', 0
sysinfo_feat_tsc:   db 'TSC', 0
sysinfo_feat_mmx:   db 'MMX', 0
sysinfo_feat_sse:   db 'SSE', 0
sysinfo_feat_sse2:  db 'SSE2', 0

sysinfo_gpu_hdr:    db ' [GPU]', 13, 10, 0
sysinfo_gpu_found:  db '  Found:   ', 0
sysinfo_not_found:  db '  None found', 0

sysinfo_mem_hdr:    db ' [Memory]', 13, 10, 0
sysinfo_mem_conv:   db '  Conventional: ', 0
sysinfo_mem_ext:    db '  Extended: ', 0
sysinfo_kb:         db ' KB', 0

sysinfo_tsc_hdr:    db ' [TSC]', 13, 10, 0
sysinfo_tsc_avail:  db '  Available', 13, 10, 0
sysinfo_tsc_val:    db '  Current: 0x', 0

sysinfo_vendor:     times 13 db 0
sysinfo_brand:      times 49 db 0
sysinfo_feat_edx:   dd 0
sysinfo_feat_ecx:   dd 0
