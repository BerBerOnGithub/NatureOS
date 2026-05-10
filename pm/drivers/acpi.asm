; ===========================================================================
; pm/drivers/acpi.asm - Basic ACPI support for PM
; ===========================================================================

[BITS 32]

; - Constants -
ACPI_RSDP_SIG  db "RSD PTR "   ; 8 bytes

; - Variables -
acpi_rsdp_ptr:  dd 0
acpi_rsdt_ptr:  dd 0
acpi_fadt_ptr:  dd 0
acpi_dsdt_ptr:  dd 0

acpi_pm1a_cnt:  dd 0        ; PM1a Control Block address
acpi_slp_typa:  dw 0x2000    ; Default sleep type (common for QEMU S5)
                            ; bit 13 (0x2000) is usually SLP_EN

; -
; acpi_init - find and parse ACPI tables
; Returns CF=0 if successful, CF=1 if not found/invalid
; -
acpi_init:
    pusha
    
    mov  esi, .msg_searching
    call dbg_serial_puts
    
    ; 1. Search for RSDP in 0xE0000 - 0xFFFFF
    mov  esi, 0xE0000
.rsdp_search:
    cmp  esi, 0x100000
    jae  .not_found
    
    ; check signature "RSD PTR "
    mov  edi, ACPI_RSDP_SIG
    mov  ecx, 8
    push esi
    repe cmpsb
    pop  esi
    je   .found_rsdp
    
    add  esi, 16            ; RSDP is 16-byte aligned
    jmp  .rsdp_search

.found_rsdp:
    mov  [acpi_rsdp_ptr], esi
    
    mov  esi, .msg_rsdp_found
    call dbg_serial_puts
    mov  eax, [acpi_rsdp_ptr]
    call dbg_serial_print_hex32
    mov  esi, .msg_nl
    call dbg_serial_puts
    
    ; check checksum (first 20 bytes sum to 0 mod 256)
    xor  al, al
    mov  ecx, 20
    mov  ebx, [acpi_rsdp_ptr]   ; reload original RSDP pointer
.rsdp_chk:
    add  al, [ebx]
    inc  ebx
    loop .rsdp_chk
    test al, al
    jnz  .invalid
    
    ; 2. Locate RSDT (address at offset 16 of RSDP)
    mov  esi, [acpi_rsdp_ptr]   ; reload original RSDP pointer
    mov  eax, [esi + 16]
    mov  [acpi_rsdt_ptr], eax
    
    mov  esi, .msg_rsdt_addr
    call dbg_serial_puts
    mov  eax, [acpi_rsdt_ptr]
    call dbg_serial_print_hex32
    mov  esi, .msg_nl
    call dbg_serial_puts
    
    ; - SAFETY: ensure RSDT is within mapped 256MB -
    cmp  eax, 0x10000000
    ja   .not_mapped
    
    mov  esi, eax
    
    ; validate RSDT signature "RSDT"
    cmp  dword [esi], "RSDT"
    jne  .invalid
    
    mov  esi, .msg_rsdt_ok
    call dbg_serial_puts
    
    mov  esi, [acpi_rsdt_ptr]
    ; 3. Parse RSDT for FADT
    ; RSDT entries start at offset 36
    mov  ecx, [esi + 4]     ; total length
    sub  ecx, 36
    shr  ecx, 2             ; number of 4-byte entries
    add  esi, 36            ; esi = pointer to first entry
    
.rsdt_loop:
    test ecx, ecx
    jz   .fadt_not_found
    
    mov  edi, [esi]         ; edi = address of table
    
    ; - SAFETY: ensure table is mapped -
    cmp  edi, 0x10000000
    ja   .next_rsdt
    
    cmp  dword [edi], "FACP" ; Fixed ACPI Description Table
    je   .found_fadt
    
.next_rsdt:
    add  esi, 4
    dec  ecx
    jmp  .rsdt_loop

.found_fadt:
    mov  [acpi_fadt_ptr], edi
    
    mov  esi, .msg_fadt_found
    call dbg_serial_puts
    mov  eax, [acpi_fadt_ptr]
    call dbg_serial_print_hex32
    mov  esi, .msg_nl
    call dbg_serial_puts
    
    ; 4. Extract PM1a_CNT_BLK from FADT
    ; PM1a_CNT_BLK is at offset 64 in FADT (32-bit address)
    mov  eax, [edi + 64]
    mov  [acpi_pm1a_cnt], eax
    
    mov  esi, .msg_pm1a_cnt
    call dbg_serial_puts
    mov  eax, [acpi_pm1a_cnt]
    call dbg_serial_print_hex32
    mov  esi, .msg_nl
    call dbg_serial_puts
    
    ; DSDT is at offset 40
    mov  eax, [edi + 40]
    mov  [acpi_dsdt_ptr], eax
    
    ; Success
    popa
    clc
    ret

.not_found:
.invalid:
.fadt_not_found:
.not_mapped:
    popa
    stc
    ret

.msg_searching: db 'ACPI: Searching for RSDP...', 13, 10, 0
.msg_rsdp_found: db 'ACPI: RSDP found at ', 0
.msg_rsdt_addr: db 'ACPI: RSDT address: ', 0
.msg_rsdt_ok:   db 'ACPI: RSDT signature OK', 13, 10, 0
.msg_fadt_found: db 'ACPI: FADT found at ', 0
.msg_pm1a_cnt: db 'ACPI: PM1a_CNT port: ', 0
.msg_nl: db 13, 10, 0

; -
; acpi_shutdown
; Attempts to power off the system via ACPI.
; -
acpi_shutdown:
    mov  edx, [acpi_pm1a_cnt]
    test edx, edx
    jz   .fail
    
    ; Write SLP_TYPa | SLP_EN to PM1a_CNT
    ; Common QEMU S5 SLP_TYP is 0. 
    ; SLP_EN is bit 13.
    ; So 0x2000 is common. 
    ; Future: parse DSDT/AML for _S5.
    mov  ax, [acpi_slp_typa]
    or   ax, 0x2000         ; ensure SLP_EN is set
    out  dx, ax
    
.fail:
    ret
