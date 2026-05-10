; ===========================================================================
; pm/pm_string.asm - 32-bit string and number utilities
;
; Mirrors core/string.asm for the PM environment.
; All output via pm_putc (pm_screen.asm). No BIOS.
;
; Public interface:
;   pm_strcmp       ESI, EDI +' ZF=1 if equal
;   pm_startswith   ESI=input, EDI=prefix +' ZF=1 if match
;   pm_print_uint   EAX = unsigned 32-bit integer
;   pm_print_int    EAX = signed 32-bit integer
;   pm_parse_uint   ESI +' EAX, ESI advanced past digits
;   pm_parse_int    ESI +' EAX (signed), ESI advanced
; ===========================================================================

[BITS 32]

; -
; pm_strcmp - compare null-terminated strings at ESI and EDI
; ZF=1 if equal, ZF=0 if not
; -
pm_strcmp:
    push eax
    push esi
    push edi
.loop:
    mov  al, [esi]
    cmp  al, [edi]
    jne  .neq
    or   al, al
    jz   .eq
    inc  esi
    inc  edi
    jmp  .loop
.eq:
    pop  edi
    pop  esi
    pop  eax
    xor  eax, eax            ; ZF=1
    ret
.neq:
    pop  edi
    pop  esi
    pop  eax
    or   eax, 1              ; ZF=0
    ret

; -
; pm_startswith - ZF=1 if string at ESI starts with prefix at EDI
; Neither pointer is modified
; -
pm_startswith:
    push eax
    push esi
    push edi
.loop:
    mov  al, [edi]
    or   al, al
    jz   .yes                ; prefix exhausted = match
    cmp  al, [esi]
    jne  .no
    inc  esi
    inc  edi
    jmp  .loop
.yes:
    pop  edi
    pop  esi
    pop  eax
    xor  eax, eax
    ret
.no:
    pop  edi
    pop  esi
    pop  eax
    or   eax, 1
    ret

; -
; pm_print_uint - print EAX as unsigned decimal
; -
pm_print_uint:
    push eax
    push ebx
    push ecx
    push edx

    mov  ecx, 0
    mov  ebx, 10
    test eax, eax
    jnz  .div_loop
    mov  al, '0'
    mov  bl, 0x0F
    call pm_putc
    jmp  .done

.div_loop:
    xor  edx, edx
    div  ebx                 ; EAX = quot, EDX = remainder
    push edx
    inc  ecx
    test eax, eax
    jnz  .div_loop

.print_loop:
    pop  eax
    add  al, '0'
    mov  bl, 0x0F
    call pm_putc
    loop .print_loop

.done:
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; pm_print_int - print EAX as signed decimal
; -
pm_print_int:
    push eax
    push ebx
    test eax, eax
    jns  .positive
    push eax
    mov  al, '-'
    mov  bl, 0x0F
    call pm_putc
    pop  eax
    neg  eax
.positive:
    call pm_print_uint
    pop  ebx
    pop  eax
    ret

; -
; pm_parse_uint - parse decimal digits at [ESI] into EAX
; ESI is advanced past all digit characters
; -
pm_parse_uint:
    push ebx
    push ecx
    xor  eax, eax
    mov  ebx, 10
.loop:
    mov  cl, [esi]
    cmp  cl, '0'
    jb   .done
    cmp  cl, '9'
    ja   .done
    sub  cl, '0'
    push ecx
    mul  ebx
    pop  ecx
    add  eax, ecx
    inc  esi
    jmp  .loop
.done:
    pop  ecx
    pop  ebx
    ret

; -
; pm_parse_int - parse optional leading '-' then digits; result in EAX
; ESI is advanced past consumed characters
; -
pm_parse_int:
    push ebx
    xor  ebx, ebx            ; EBX=0 = positive
    cmp  byte [esi], '-'
    jne  .parse
    mov  ebx, 1
    inc  esi
.parse:
    call pm_parse_uint
    test ebx, ebx
    jz   .done
    neg  eax
.done:
    pop  ebx
    ret

; -
; pm_skip_spaces - advance ESI past space characters
; -
pm_skip_spaces:
    push eax
.loop:
    mov  al, [esi]
    cmp  al, ' '
    jne  .done
    inc  esi
    jmp  .loop
.done:
    pop  eax
    ret

; -
; pm_strlen - calculate length of null-terminated string at ESI
; Returns: EAX = length
; -
pm_strlen:
    push esi
    push ecx
    xor  ecx, ecx
.loop:
    cmp  byte [esi], 0
    je   .done
    inc  esi
    inc  ecx
    jmp  .loop
.done:
    mov  eax, ecx
    pop  ecx
    pop  esi
    ret

; -
; pm_cmdmatch - ZF=1 if string at ESI starts with command word at EDI
; and is immediately followed by a space or null.
; -
pm_cmdmatch:
    push eax
    push esi
    push edi
.loop:
    mov  al, [edi]
    or   al, al
    jz   .check_boundary     ; prefix exhausted
    cmp  al, [esi]
    jne  .no
    inc  esi
    inc  edi
    jmp  .loop
.check_boundary:
    mov  al, [esi]
    cmp  al, ' '
    je   .yes
    or   al, al
    jz   .yes
.no:
    pop  edi
    pop  esi
    pop  eax
    or   eax, 1              ; ZF=0
    ret
.yes:
    pop  edi
    pop  esi
    pop  eax
    xor  eax, eax            ; ZF=1
    ret
