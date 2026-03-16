; ===========================================================================
; pm/ata.asm  -  ATA PIO driver with verbose probe logging
; ===========================================================================
[BITS 32]

ATA_SR_BSY       equ 0x80
ATA_SR_DRDY      equ 0x40
ATA_SR_DRQ       equ 0x08
ATA_SR_ERR       equ 0x01
ATA_CMD_READ     equ 0x20
ATA_CMD_WRITE    equ 0x30
ATA_CMD_IDENTIFY equ 0xEC

; ── ata_probe_one ─────────────────────────────────────────────────────────────
; In:  [ata_probe_base]=channel, BL=drive sel (0xA0/0xB0)
; Out: CF=0 found, CF=1 not found
; Also fills ata_probe_stat with final status for debug
ata_probe_one:
    push eax
    push ecx
    push edx

    ; select drive
    movzx edx, word [ata_probe_base]
    add   dx, 6
    mov   al, bl
    out   dx, al

    ; 400ns delay
    movzx edx, word [ata_probe_base]
    add   dx, 7
    in    al, dx
    in    al, dx
    in    al, dx
    in    al, dx

    ; wait BSY clear
    mov   ecx, 0x200000
.bsy1:
    in    al, dx
    test  al, ATA_SR_BSY
    jz    .bsy1done
    dec   ecx
    jnz   .bsy1
.bsy1done:

    ; zero LBA regs, send IDENTIFY
    movzx edx, word [ata_probe_base]
    add   dx, 2
    xor   al, al
    out   dx, al
    inc   dx
    out   dx, al
    inc   dx
    out   dx, al
    inc   dx
    out   dx, al

    movzx edx, word [ata_probe_base]
    add   dx, 7
    mov   al, ATA_CMD_IDENTIFY
    out   dx, al

    ; 400ns delay
    in    al, dx
    in    al, dx
    in    al, dx
    in    al, dx

    ; read status
    in    al, dx
    mov   [ata_probe_stat], al

    ; status=0 = no drive
    test  al, al
    jz    .nope

    ; wait BSY clear
    mov   ecx, 0x200000
.bsy2:
    in    al, dx
    test  al, ATA_SR_BSY
    jz    .bsy2done
    dec   ecx
    jnz   .bsy2
    jmp   .nope         ; timeout
.bsy2done:
    mov   [ata_probe_stat], al

    ; check ERR
    test  al, ATA_SR_ERR
    jnz   .nope

    ; check ATAPI (LBA_MID=0x14, LBA_HI=0xEB)
    movzx edx, word [ata_probe_base]
    add   dx, 4
    in    al, dx
    cmp   al, 0x14
    je    .nope
    inc   dx
    in    al, dx
    cmp   al, 0xEB
    je    .nope

    ; wait DRQ
    movzx edx, word [ata_probe_base]
    add   dx, 7
    mov   ecx, 0x200000
.drq:
    in    al, dx
    test  al, ATA_SR_ERR
    jnz   .nope
    test  al, ATA_SR_DRQ
    jnz   .drq_ok
    dec   ecx
    jnz   .drq
    jmp   .nope
.drq_ok:
    mov   [ata_probe_stat], al
    ; drain IDENTIFY
    movzx edx, word [ata_probe_base]
    mov   ecx, 256
    mov   edi, ata_ident_buf
    rep   insw
    clc
    jmp   .done
.nope:
    stc
.done:
    pop   edx
    pop   ecx
    pop   eax
    ret

; ── ata_init ──────────────────────────────────────────────────────────────────
ata_init:
    pusha
    mov   byte [ata_ready], 0

    mov   word [ata_probe_base], 0x170
    mov   bl, 0xA0
    call  ata_probe_one
    jnc   .found

    mov   word [ata_probe_base], 0x170
    mov   bl, 0xB0
    call  ata_probe_one
    jnc   .found

    mov   word [ata_probe_base], 0x1F0
    mov   bl, 0xB0
    call  ata_probe_one
    jnc   .found

    mov   word [ata_probe_base], 0x1F0
    mov   bl, 0xA0
    call  ata_probe_one
    jnc   .found

    jmp   .done

.found:
    mov   ax, [ata_probe_base]
    mov   [ata_base], ax
    mov   [ata_drive_sel], bl
    mov   byte [ata_ready], 1

.done:
    popa
    ret

; ── ata_wait_ready ────────────────────────────────────────────────────────────
ata_wait_ready:
    push  eax
    push  ecx
    push  edx
    movzx edx, word [ata_base]
    add   dx, 7
    mov   ecx, 0x200000
.spin:
    in    al, dx
    test  al, ATA_SR_BSY
    jnz   .next
    test  al, ATA_SR_DRDY
    jnz   .done
.next:
    dec   ecx
    jnz   .spin
.done:
    pop   edx
    pop   ecx
    pop   eax
    ret

; ── ata_wait_drq ──────────────────────────────────────────────────────────────
ata_wait_drq:
    push  eax
    push  ecx
    push  edx
    movzx edx, word [ata_base]
    add   dx, 7
    mov   ecx, 0x200000
.spin:
    in    al, dx
    test  al, ATA_SR_ERR
    jnz   .done
    test  al, ATA_SR_DRQ
    jnz   .done
    dec   ecx
    jnz   .spin
.done:
    pop   edx
    pop   ecx
    pop   eax
    ret

; ── ata_setup_lba ─────────────────────────────────────────────────────────────
ata_setup_lba:
    push  eax
    push  edx

    ; reselect drive
    movzx edx, word [ata_base]
    add   dx, 6
    mov   al, [ata_drive_sel]
    or    al, 0x40
    out   dx, al

    ; 400ns
    movzx edx, word [ata_base]
    add   dx, 7
    in    al, dx
    in    al, dx
    in    al, dx
    in    al, dx

    call  ata_wait_ready

    movzx edx, word [ata_base]
    add   dx, 2
    mov   al, cl
    out   dx, al            ; SECT_CNT

    pop   eax
    push  eax
    movzx edx, word [ata_base]
    add   dx, 3
    out   dx, al            ; LBA 7:0
    shr   eax, 8
    inc   dx
    out   dx, al            ; LBA 15:8
    shr   eax, 8
    inc   dx
    out   dx, al            ; LBA 23:16
    shr   eax, 8
    and   al, 0x0F
    or    al, [ata_drive_sel]
    or    al, 0x40
    inc   dx
    out   dx, al            ; drive/head

    pop   eax
    pop   edx
    ret

; ── ata_read ──────────────────────────────────────────────────────────────────
ata_read:
    push  eax
    push  ebx
    push  ecx
    push  edx
    cmp   byte [ata_ready], 1
    jne   .done
    mov   ebx, ecx
.loop:
    test  ebx, ebx
    jz    .done
    mov   cl, 1
    call  ata_setup_lba
    movzx edx, word [ata_base]
    add   dx, 7
    mov   al, ATA_CMD_READ
    out   dx, al
    call  ata_wait_drq
    movzx edx, word [ata_base]
    mov   ecx, 256
    rep   insw
    inc   eax
    dec   ebx
    jmp   .loop
.done:
    pop   edx
    pop   ecx
    pop   ebx
    pop   eax
    ret

; ── ata_write ─────────────────────────────────────────────────────────────────
ata_write:
    push  eax
    push  ebx
    push  ecx
    push  edx
    cmp   byte [ata_ready], 1
    jne   .done
    mov   ebx, ecx
.loop:
    test  ebx, ebx
    jz    .done
    mov   cl, 1
    call  ata_setup_lba
    movzx edx, word [ata_base]
    add   dx, 7
    mov   al, ATA_CMD_WRITE
    out   dx, al
    call  ata_wait_drq
    movzx edx, word [ata_base]
    mov   ecx, 256
    rep   outsw
    movzx edx, word [ata_base]
    add   dx, 7
    in    al, dx
    in    al, dx
    in    al, dx
    in    al, dx
    call  ata_wait_ready
    inc   eax
    dec   ebx
    jmp   .loop
.done:
    pop   edx
    pop   ecx
    pop   ebx
    pop   eax
    ret

; ── data ──────────────────────────────────────────────────────────────────────
ata_ready:      db 0
ata_base:       dw 0x170
ata_drive_sel:  db 0xA0
ata_probe_base: dw 0
ata_probe_stat: db 0
ata_ident_buf:  times 512 db 0