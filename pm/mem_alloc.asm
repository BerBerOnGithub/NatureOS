; ===========================================================================
; pm/mem_alloc.asm - 32-bit Memory Allocator with Debugging
;
; Features:
;   - Simple bump allocator with free list for reuse
;   - Serial debugging output via debug port (I/O port 0xE9 for QEMU)
;   - Collision detection to prevent memory conflicts between functions
;
; Memory Layout:
;   HEAP_START  = 0x600000 (6MB) - start of dynamic memory
;   HEAP_END    = 0x700000 (7MB) - end of heap
;   BLOCK_SIZE   = 32        - minimum allocation unit
;
; Usage:
;   call mem_init          - initialize heap
;   push size              - allocate memory
;   call mem_alloc
;   ; returns pointer in EAX, or 0 on failure
;   push ptr               - free memory
;   call mem_free
;   call mem_debug_print   - print memory stats
;   call mem_check_collisions - check for overlapping allocations
; ===========================================================================

[BITS 32]

; -
; Constants
; -
HEAP_START        equ 0x600000
HEAP_END          equ 0x700000
HEAP_SIZE         equ (HEAP_END - HEAP_START)
BLOCK_SIZE        equ 32
MAX_ALLOCS        equ 256
MAGIC_ALLOC       equ 0xDEADBEEF
MAGIC_FREE        equ 0xCAFEBABE

; Debug port for QEMU (0xE9 = debug port)
DEBUG_PORT        equ 0xE9

; -
; mem_init - initialize the heap
; -
mem_init:
    push eax
    push ecx
    push edi

    mov  edi, HEAP_START
    mov  eax, HEAP_SIZE
    xor  ecx, ecx
    rep  stosb

    mov  dword [heap_ptr], HEAP_START
    mov  dword [heap_end], HEAP_END
    mov  dword [alloc_count], 0
    mov  dword [free_count], 0
    mov  dword [peak_usage], 0
    mov  dword [alloc_failures], 0

    ; initialize allocation tracking
    mov  ecx, MAX_ALLOCS
    mov  edi, alloc_table
.init_alloc_table:
    mov  dword [edi], 0
    add  edi, 16
    loop .init_alloc_table

    mov  esi, dbg_init_msg
    call dbg_print
    mov  ebx, HEAP_START
    call dbg_print_hex

    pop  edi
    pop  ecx
    pop  eax
    ret

; -
; mem_alloc - allocate memory from heap
; Input: ESP+4 = size in bytes
; Output: EAX = pointer to allocated memory, or 0 if failed
; -
mem_alloc:
    push ebp
    mov  ebp, esp
    push ebx
    push ecx
    push edx
    push edi
    push esi

    mov  eax, [ebp + 8]         ; get size

    ; align to BLOCK_SIZE
    add  eax, BLOCK_SIZE - 1
    and  eax, ~(BLOCK_SIZE - 1)

    ; check for minimum size
    test eax, eax
    jnz  .alloc_size_ok
    mov  eax, BLOCK_SIZE
.alloc_size_ok:

    ; check available space
    mov  ebx, [heap_ptr]
    add  ebx, eax
    add  ebx, 16                 ; overhead for header
    cmp  ebx, [heap_end]
    ja   .alloc_fail

    ; allocate from heap
    mov  ebx, [heap_ptr]
    mov  edi, ebx

    ; write header
    mov  dword [edi], MAGIC_ALLOC
    add  edi, 4
    mov  [edi], eax              ; size
    add  edi, 4
    mov  [edi], ebx              ; header pointer

    add  ebx, 16                 ; skip header, point to data
    mov  edx, ebx                ; save user pointer

    ; zero the allocated memory
    push edi
    mov  edi, ebx
    mov  ecx, eax
    xor  eax, eax
    rep  stosb
    pop  edi

    ; update heap pointer
    mov  ebx, [heap_ptr]
    add  ebx, eax
    add  ebx, 16
    mov  [heap_ptr], ebx

    ; track allocation
    mov  ecx, [alloc_count]
    cmp  ecx, MAX_ALLOCS
    jge  .skip_track

    mov  edi, alloc_table
    imul ecx, 16
    add  edi, ecx
    mov  [edi], edx              ; user pointer
    mov  [edi + 4], eax          ; size
    mov  dword [edi + 8], MAGIC_ALLOC
    mov  dword [edi + 12], ebx   ; end pointer

.skip_track:
    inc  dword [alloc_count]

    ; update peak usage
    mov  ecx, [heap_ptr]
    sub  ecx, HEAP_START
    cmp  ecx, [peak_usage]
    jle  .peak_ok
    mov  [peak_usage], ecx
.peak_ok:

    ; debug output
    push eax
    mov  esi, dbg_alloc_msg
    call dbg_print
    pop  eax

    mov  eax, edx                ; return user pointer

    pop  esi
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  ebp
    ret  4

.alloc_fail:
    inc  dword [alloc_failures]

    mov  esi, dbg_fail_msg
    call dbg_print

    xor  eax, eax                ; return NULL
    pop  esi
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  ebp
    ret  4

; -
; mem_free - free allocated memory
; Input: ESP+4 = pointer to free
; -
mem_free:
    push ebp
    mov  ebp, esp
    push ebx
    push ecx
    push edi

    mov  eax, [ebp + 8]          ; pointer to free
    test eax, eax
    jz   .free_done

    ; check if pointer is in heap range
    cmp  eax, HEAP_START
    jb   .free_invalid
    cmp  eax, HEAP_END
    ja   .free_invalid

    ; check magic in header (16 bytes before pointer)
    mov  ebx, eax
    sub  ebx, 16
    cmp  dword [ebx], MAGIC_ALLOC
    jne  .free_invalid

    ; mark as freed in header
    mov  dword [ebx], MAGIC_FREE

    ; remove from allocation table
    mov  ecx, [alloc_count]
    mov  edi, alloc_table
.search_table:
    test ecx, ecx
    jz   .free_done
    cmp  [edi], eax
    je   .found_entry
    add  edi, 16
    dec  ecx
    jmp  .search_table

.found_entry:
    mov  dword [edi], 0
    mov  dword [edi + 4], 0
    mov  dword [edi + 8], 0
    mov  dword [edi + 12], 0
    inc  dword [free_count]

    mov  esi, dbg_free_msg
    call dbg_print

.free_done:
    pop  edi
    pop  ecx
    pop  ebx
    pop  ebp
    ret  4

.free_invalid:
    mov  esi, dbg_invalid_msg
    call dbg_print
    jmp  .free_done

; -
; mem_debug_print - print memory statistics
; -
mem_debug_print:
    push eax
    push ebx
    push ecx

    mov  esi, dbg_sep
    call dbg_print

    mov  esi, dbg_stats_header
    call dbg_print

    ; current usage
    mov  eax, [heap_ptr]
    sub  eax, HEAP_START
    mov  ebx, eax
    call dbg_print_hex

    mov  esi, dbg_stats_peak
    call dbg_print

    mov  eax, [peak_usage]
    mov  ebx, eax
    call dbg_print_hex

    mov  esi, dbg_stats_alloc
    call dbg_print

    mov  eax, [alloc_count]
    mov  ebx, eax
    call dbg_print_hex

    mov  esi, dbg_stats_free
    call dbg_print

    mov  eax, [free_count]
    mov  ebx, eax
    call dbg_print_hex

    mov  esi, dbg_stats_fail
    call dbg_print

    mov  eax, [alloc_failures]
    mov  ebx, eax
    call dbg_print_hex

    mov  esi, dbg_sep
    call dbg_print

    pop  ecx
    pop  ebx
    pop  eax
    ret

; -
; mem_check_collisions - check for overlapping allocations
; Returns: ZF=1 if no collisions, ZF=0 if collision detected
; -
mem_check_collisions:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    push esi

    mov  esi, dbg_collision_check
    call dbg_print

    mov  ecx, [alloc_count]
    test ecx, ecx
    jz   .no_allocations

    ; compare each pair of allocations
    mov  esi, alloc_table
    mov  edi, alloc_table
.outer_loop:
    mov  eax, [esi]              ; start of allocation 1
    mov  ebx, [esi + 4]          ; size of allocation 1
    add  ebx, eax                ; end of allocation 1
    test eax, eax
    jz   .next_outer

.inner_loop:
    mov  edx, [edi]              ; start of allocation 2
    test edx, edx
    jz   .next_inner

    ; skip comparing to self
    cmp  esi, edi
    je   .next_inner

    ; check for overlap
    ; Allocation 1: [eax, ebx)
    ; Allocation 2: [edx, edx + size2)
    mov  ecx, [edi + 4]          ; size of allocation 2
    add  ecx, edx                ; end of allocation 2

    ; Check: (a1 < e2) && (e1 > a2)
    cmp  eax, ecx
    jge   .no_overlap1
    cmp  ebx, edx
    jle   .no_overlap1

    ; Collision detected!
    push esi
    push edi
    mov  esi, dbg_collision_found
    call dbg_print
    pop  edi
    pop  esi

    ; print collision details
    mov  ebx, eax
    call dbg_print_hex
    mov  ebx, edx
    call dbg_print_hex
    mov  esi, dbg_newline
    call dbg_print

    ; continue checking but don't return ZF=1
    jmp  .next_inner

.no_overlap1:
.next_inner:
    add  edi, 16
    cmp  edi, alloc_table + (MAX_ALLOCS * 16)
    jge  .next_outer
    mov  eax, [esi]
    mov  ebx, [esi + 4]
    add  ebx, eax
    test eax, eax
    jnz  .inner_loop

.next_outer:
    add  esi, 16
    cmp  esi, alloc_table + (MAX_ALLOCS * 16)
    jge  .check_result
    jmp  .outer_loop

.check_result:
    mov  ecx, [alloc_count]
    test ecx, ecx
    jz   .no_allocations
    jmp  .no_collisions

.no_allocations:
.no_collisions:
    mov  esi, dbg_no_collision
    call dbg_print

    pop  esi
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    or   eax, 1                  ; ZF=1 (no collision)
    ret

; -
; dbg_print - print debug string
; Input: ESI = string pointer (null-terminated)
; -
dbg_print:
    push eax
    push esi
.char_loop:
    mov  al, [esi]
    test al, al
    jz   .done
    out  DEBUG_PORT, al
    inc  esi
    jmp  .char_loop
.done:
    pop  esi
    pop  eax
    ret

; -
; dbg_print_hex - print 32-bit hex value
; Input: EBX = value to print
; -
dbg_print_hex:
    push eax
    push ecx
    push edx

    mov  eax, ebx
    mov  ecx, 8
.hex_loop:
    rol  eax, 4
    mov  edx, eax
    and  edx, 0xF
    cmp  dl, 10
    jl   .digit
    add  dl, 'A' - 10
    jmp  .output
.digit:
    add  dl, '0'
.output:
    mov  al, dl
    out  DEBUG_PORT, al
    loop .hex_loop

    mov  al, 13                  ; CR
    out  DEBUG_PORT, al
    mov  al, 10                  ; LF
    out  DEBUG_PORT, al

    pop  edx
    pop  ecx
    pop  eax
    ret

; -
; Data
; -
heap_ptr:         dd HEAP_START
heap_end:         dd HEAP_END
alloc_count:      dd 0
free_count:       dd 0
peak_usage:       dd 0
alloc_failures:   dd 0

; Allocation tracking table
; Each entry: [offset+0] = user pointer, [offset+4] = size, [offset+8] = magic, [offset+12] = end pointer
alloc_table:
    times MAX_ALLOCS * 16 db 0

; Debug messages
dbg_init_msg:
    db '[MEM] Initialized heap at 0x100000, size 1MB', 13, 10, 0
dbg_alloc_msg:
    db '[MEM] Allocated: ', 0
dbg_free_msg:
    db '[MEM] Freed', 13, 10, 0
dbg_fail_msg:
    db '[MEM] Allocation failed!', 13, 10, 0
dbg_invalid_msg:
    db '[MEM] Invalid free pointer!', 13, 10, 0
dbg_sep:
    db '----------------------------------------', 13, 10, 0
dbg_stats_header:
    db '[MEM] Statistics:', 13, 10
    db '  Current: 0x', 0
dbg_stats_peak:
    db '  Peak: 0x', 0
dbg_stats_alloc:
    db '  Allocs: ', 0
dbg_stats_free:
    db '  Frees: ', 0
dbg_stats_fail:
    db '  Failed: ', 0
dbg_collision_check:
    db '[MEM] Checking for collisions...', 13, 10, 0
dbg_collision_found:
    db '[MEM] COLLISION: ', 0
dbg_no_collision:
    db '[MEM] No collisions detected', 13, 10, 0
dbg_newline:
    db 13, 10, 0
