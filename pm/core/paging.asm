; ===========================================================================
; pm/paging.asm - 32-bit Paging Implementation (Memory Mapper)
;
; Page tables are placed at FIXED physical addresses in conventional RAM,
; NOT embedded in the kernel binary. This avoids NASM multi-pass label
; shifting caused by align 4096 + large times blocks.
;
; Memory layout (0x120000 - 0x126FFF, 28KB total):
;   0x120000  page_directory   (4KB)
;   0x121000  page_table_0     (4KB)  maps 0x000000 - 0x3FFFFF
;   0x122000  page_table_1     (4KB)  maps 0x400000 - 0x7FFFFF
;   0x123000  page_table_2     (4KB)  maps 0x800000 - 0xBFFFFF
;   0x124000  page_table_3     (4KB)  maps 0xC00000 - 0xFFFFFFF
;   0x125000  page_table_vbe   (4KB)  maps VBE LFB (dynamic)
;   0x126000  page_table_e1000 (4KB)  maps e1000 BAR0 (dynamic)
;
; This region is above the e1000 buffers (0x11A000) and well below the
; wallpaper buffer (0x200000). This avoids overlapping with the FS blob
; which is loaded at 0x30000 and can be up to 800KB (ends at ~0xF8000).
; ===========================================================================
[BITS 32]

PAGE_DIR      equ 0x1000000    ; 16MB
PAGE_TBL_0    equ 0x1001000      ; Start of 64 contiguous tables
                                ; Tables 0-63 map 0x00000000 to 0x0FFFFFFF (256MB)
PAGE_TBL_VBE   equ 0x1041000
PAGE_TBL_E1000 equ 0x1042000
PAGE_TBL_USB   equ 0x1043000    ; USB controller MMIO (EHCI/OHCI/xHCI)

paging_init:
    pusha

    ; 0. Zero out all 67 pages (268KB) starting at 16MB
    mov  edi, PAGE_DIR
    mov  ecx, (67 * 4096) / 4
    xor  eax, eax
    rep  stosd

    ; 1. Link Page Directory entries 0..63 to Page Tables 0..63
    mov  ecx, 64
    mov  edi, PAGE_DIR
    mov  eax, PAGE_TBL_0 | 0x03
.dir_loop:
    mov  [edi], eax
    add  eax, 4096              ; next table address
    add  edi, 4
    loop .dir_loop

    ; 2. Fill Page Tables 0..63 with identity map (virtual == physical)
    ; 64 tables * 1024 entries = 65536 entries (maps 256MB)
    mov  ecx, 65536
    mov  edi, PAGE_TBL_0
    mov  eax, 0x03              ; phys 0x000000 | Present | R/W
.fill_loop:
    mov  [edi], eax
    add  eax, 4096
    add  edi, 4
    loop .fill_loop

    ; 3. Map VBE LFB dynamically (if present)
    mov  eax, [vbe_physbase]
    test eax, eax
    jz   .no_vbe

    ; PDE index = physbase >> 22
    mov  ebx, eax
    shr  ebx, 22

    ; Install VBE page table in the directory
    mov  dword [PAGE_DIR + ebx*4], PAGE_TBL_VBE | 0x03

    ; Fill VBE page table (1024 entries = 4MB)
    mov  ecx, 1024
    mov  edi, PAGE_TBL_VBE
    and  eax, 0xFFC00000        ; align to 4MB boundary
    or   eax, 0x03
.vbe_loop:
    mov  [edi], eax
    add  eax, 4096
    add  edi, 4
    loop .vbe_loop

.no_vbe:
    ; 3.5 Map e1000 BAR0 dynamically (if present)
    mov  eax, [pci_e1000_bar0]
    test eax, eax
    jz   .no_e1000

    ; PDE index = physbase >> 22
    mov  ebx, eax
    shr  ebx, 22

    ; Install e1000 page table in the directory
    mov  dword [PAGE_DIR + ebx*4], PAGE_TBL_E1000 | 0x03

    ; Fill e1000 page table (1024 entries = 4MB)
    mov  ecx, 1024
    mov  edi, PAGE_TBL_E1000
    and  eax, 0xFFC00000        ; align to 4MB boundary
    or   eax, 0x03
.e1000_loop:
    mov  [edi], eax
    add  eax, 4096
    add  edi, 4
    loop .e1000_loop

.no_e1000:
    ; 4. Enable Paging
    mov  eax, PAGE_DIR
    mov  cr3, eax

    mov  eax, cr0
    or   eax, 0x80000000        ; Set PG bit
    mov  cr0, eax
    jmp  $+2                    ; flush prefetch queue

    popa
    ret
