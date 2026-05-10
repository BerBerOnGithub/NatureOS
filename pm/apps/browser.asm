; ===========================================================================
; pm/browser.asm  -  NatureOS Simple Web Browser
; ===========================================================================

[BITS 32]

; DNS source port used when sending DNS queries from the browser
DNS_SRC_PORT    equ 4096    ; same ephemeral port as UDP_SRC_PORT in udp.asm

browser_init:
    pusha
    ; clear buffers
    mov  edi, browser_url
    xor  eax, eax
    mov  ecx, 64
    rep  stosd
    mov  edi, browser_content
    mov  ecx, 4096
    rep  stosd
    
    ; initial URL
    mov  esi, browser_s_default_url
    mov  edi, browser_url
.copy_url:
    lodsb
    stosb
    test al, al
    jnz  .copy_url
    
    mov  esi, browser_s_welcome
    mov  edi, browser_content
.copy_welcome:
    lodsb
    stosb
    test al, al
    jnz  .copy_welcome
    
    popa
    ret

; - browser_draw -
; In: EDI = window record
browser_draw:
    pusha
    
    mov  eax, [edi+0]   ; wx
    mov  ebx, [edi+4]   ; wy
    mov  ecx, [edi+8]   ; ww
    mov  edx, [edi+12]  ; wh
    
    ; 1. Draw background
    pusha
    add  ebx, WM_TITLE_H
    sub  edx, WM_TITLE_H
    mov  esi, 0x07      ; light grey
    call fb_fill_rect
    popa
    
    ; 2. Draw address bar
    pusha
    add  eax, 5
    add  ebx, WM_TITLE_H + 5
    mov  ecx, [edi+8]   ; ww
    sub  ecx, 60        ; leave space for 'Go'
    mov  edx, 16        ; height
    mov  esi, 0x0F      ; white
    call fb_fill_rect
    
    ; Address bar label
    mov  ebx, eax
    add  ebx, 4
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 9
    mov  esi, browser_url
    mov  dl, 0x00       ; black text
    mov  dh, 0x0F       ; white bg
    call fb_draw_string
    popa
    
    ; 3. Draw 'Go' button
    pusha
    mov  eax, [edi+0]
    add  eax, [edi+8]
    sub  eax, 50
    add  ebx, WM_TITLE_H + 5
    mov  ecx, 45
    mov  edx, 16
    mov  esi, 0x09      ; blue
    call fb_fill_rect
    
    mov  ebx, eax
    add  ebx, 12
    mov  ecx, [edi+4]
    add  ecx, WM_TITLE_H + 9
    mov  esi, browser_s_go
    mov  dl, 0x0F       ; white text
    mov  dh, 0x09       ; blue bg
    call fb_draw_string
    popa
    
    ; 4. Draw content area
    pusha
    mov  eax, [edi+0]
    add  eax, 5
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 26
    mov  ecx, [edi+8]
    sub  ecx, 10
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 31
    mov  esi, 0x0F      ; white background for content
    call fb_fill_rect
    
    ; Draw current content (multi-line)
    mov  eax, [edi+0]
    add  eax, 9             ; content x
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 30 ; content y
    mov  ecx, [edi+8]
    sub  ecx, 32            ; content w (leave room for scrollbar)
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 35 ; content h
    
    mov  esi, browser_content
    call browser_draw_content
    
    ; Draw scrollbar
    mov  ebx, eax
    add  ebx, ecx
    add  ebx, 4
    mov  [wm_sb_x], ebx
    mov  eax, [br_y0]
    mov  [wm_sb_y], eax
    mov  dword [wm_sb_w], 10
    mov  eax, [br_h]
    mov  [wm_sb_h], eax
    mov  [wm_sb_visible], eax
    
    ; if total_h == 0, make it at least visible to draw full thumb
    mov  eax, [browser_total_h]
    test eax, eax
    jnz  .total_ok
    mov  eax, [wm_sb_visible]
.total_ok:
    mov  [wm_sb_total], eax
    mov  eax, [browser_scroll_y]
    mov  [wm_sb_pos], eax
    call wm_draw_scrollbar
    popa
    
    popa
    ret

; - browser_draw_content -
; In: ESI=content, EAX=x0, EBX=y0, ECX=w, EDX=h
browser_draw_content:
    pusha
    mov  [br_x0], eax
    mov  [br_y0], ebx
    mov  [br_w],  ecx
    mov  [br_h],  edx
    
    mov  [br_cx], eax
    mov  [br_cy], ebx
    
; reset scale and skip-flags at start of each render pass
    mov  dword [br_scale], 1
    mov  byte  [br_in_head], 0
    mov  byte  [br_in_style], 0
    mov  byte  [br_in_title], 0
    mov  dword [br_title_ptr], browser_title_buf

.loop:
    movzx eax, byte [esi]
    inc  esi
    test al, al
    jz   .done

    cmp  al, 13             ; CR - ignore
    je   .loop
    cmp  al, 60             ; < - always process tags even inside head/style
    je   .tag
    ; if inside <head> or <style>, skip non-tag chars
    cmp  byte [br_in_head], 1
    je   .loop
    cmp  byte [br_in_style], 1
    je   .loop
    ; if inside <title>, collect into title buffer
    cmp  byte [br_in_title], 1
    jne  .not_title_char
    mov  edi, [br_title_ptr]
    cmp  edi, browser_title_buf + 63  ; max 63 chars
    jge  .loop
    mov  [edi], al
    inc  dword [br_title_ptr]
    jmp  .loop
.not_title_char:
    cmp  al, 10             ; LF - treat as newline
    je   .lf

    cmp  al, 9              ; Tab -> space
    jne  .not_tab
    mov  al, 32
.not_tab:
    cmp  al, 32
    jl   .loop

    ; check wrap (char width = 8 * scale)
    mov  edx, [br_cx]
    sub  edx, [br_x0]
    mov  ecx, 8
    imul ecx, [br_scale]
    add  edx, ecx
    cmp  edx, [br_w]
    ja   .wrap

    ; check vertical clip against scroll
    mov  ecx, [br_cy]
    sub  ecx, [browser_scroll_y]
    cmp  ecx, [br_y0]
    jl   .skip_draw
    mov  edx, ecx
    sub  edx, [br_y0]
    mov  ecx, 8
    imul ecx, [br_scale]
    add  edx, ecx
    cmp  edx, [br_h]
    jbe  .do_draw
    cmp  byte [browser_measuring], 1
    je   .skip_draw
    jmp  .exit

.do_draw:
    cmp  byte [browser_measuring], 1
    je   .skip_draw
    mov  ebx, [br_cx]
    mov  ecx, [br_cy]
    sub  ecx, [browser_scroll_y]
    mov  dl, 0x00
    mov  dh, 0x0F
    cmp  dword [br_scale], 1
    je   .draw_normal
    ; scaled draw
    push eax
    mov  eax, [br_scale]
    mov  [fcs_scale], eax
    pop  eax
    call fb_draw_char_scaled
    jmp  .skip_draw
.draw_normal:
    call fb_draw_char

.skip_draw:
    mov  eax, 8
    imul eax, [br_scale]
    add  [br_cx], eax
    jmp  .loop

.lf:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    mov  eax, 8
    imul eax, [br_scale]
    add  [br_cy], eax
    jmp  .loop

.wrap:
    mov  eax, [br_x0]
    mov  [br_cx], eax
    mov  eax, 8
    imul eax, [br_scale]
    add  [br_cy], eax
    dec  esi
    jmp  .loop

; --- HTML tag handler ---
; Read tag name into br_tag_buf until > or space or end, then dispatch
.tag:
    push edi
    push ecx
    mov  edi, br_tag_buf
    xor  ecx, ecx
.tag_read:
    movzx eax, byte [esi]
    test al, al
    jz   .tag_eos
    cmp  al, 62             ; >
    je   .tag_end
    cmp  al, 32             ; space - stop reading name but keep consuming
    je   .tag_skip_rest
    inc  esi
    cmp  ecx, 15            ; max tag name length
    jge  .tag_read
    ; lowercase: if A-Z -> a-z
    cmp  al, 65
    jl   .tag_store
    cmp  al, 90
    jg   .tag_store
    add  al, 32
.tag_store:
    mov  [edi + ecx], al
    inc  ecx
    jmp  .tag_read
.tag_skip_rest:
    ; consume until >
    movzx eax, byte [esi]
    test al, al
    jz   .tag_eos
    inc  esi
    cmp  al, 62
    jne  .tag_skip_rest
    jmp  .tag_dispatch
.tag_end:
    inc  esi                ; skip the >
.tag_dispatch:
    mov  byte [edi + ecx], 0  ; null-terminate tag name
    ; compare tag names
    mov  edi, br_tag_buf
    ; use byte comparisons for h1..h6
    mov  al, [edi]
    mov  ah, [edi+1]
    cmp  ax, 0x3168         ; "h1" (h=0x68 1=0x31)
    jne  .chk_h2
    cmp  byte [edi+2], 0
    jne  .chk_h2
    call .do_block_newline
    mov  dword [br_scale], 4
    jmp  .tag_done
; --- <head> </head> <style> </style> <title> </title> ---
    ; check "head"
    cmp  ax, 0x6568         ; "he"
    jne  .chk_style
    cmp  word [edi+2], 0x6461  ; "ad"
    jne  .chk_style
    cmp  byte [edi+4], 0
    jne  .chk_style
    mov  byte [br_in_head], 1
    jmp  .tag_done
.chk_style:
    ; check "/head"
    cmp  al, 47             ; /
    jne  .chk_style2
    cmp  word [edi+1], 0x6568  ; "he"
    jne  .chk_style2
    cmp  word [edi+3], 0x6461  ; "ad"
    jne  .chk_style2
    mov  byte [br_in_head], 0
    jmp  .tag_done
.chk_style2:
    ; check "style"
    cmp  ax, 0x7473         ; "st"
    jne  .chk_style3
    cmp  word [edi+2], 0x6c79  ; "yl"
    jne  .chk_style3
    cmp  byte [edi+4], 101     ; "e"
    jne  .chk_style3
    mov  byte [br_in_style], 1
    jmp  .tag_done
.chk_style3:
    ; check "/style"
    cmp  al, 47
    jne  .chk_title
    cmp  word [edi+1], 0x7473  ; "st"
    jne  .chk_title
    cmp  word [edi+3], 0x6c79  ; "yl"
    jne  .chk_title
    cmp  byte [edi+5], 101     ; "e"
    jne  .chk_title
    mov  byte [br_in_style], 0
    jmp  .tag_done
.chk_title:
    ; check "title"
    cmp  ax, 0x6974         ; "ti"
    jne  .chk_title_end
    cmp  word [edi+2], 0x6c74  ; "tl"
    jne  .chk_title_end
    cmp  byte [edi+4], 101     ; "e"
    jne  .chk_title_end
    ; clear title buffer and start collecting
    push ecx
    mov  ecx, 64
    push edi
    mov  edi, browser_title_buf
    xor  eax, eax
    rep  stosb
    pop  edi
    pop  ecx
    mov  dword [br_title_ptr], browser_title_buf
    mov  byte [br_in_title], 1
    jmp  .tag_done
.chk_title_end:
    ; check "/title"
    cmp  al, 47
    jne  .chk_h1_cont
    cmp  word [edi+1], 0x6974  ; "ti"
    jne  .chk_h1_cont
    cmp  word [edi+3], 0x6c74  ; "tl"
    jne  .chk_h1_cont
    cmp  byte [edi+5], 101     ; "e"
    jne  .chk_h1_cont
    mov  byte [br_in_title], 0
    ; null-terminate collected title
    push edi
    mov  edi, [br_title_ptr]
    mov  byte [edi], 0
    pop  edi
    ; find open browser window and update its title pointer
    push eax
    push ebx
    push ecx
    xor  ebx, ebx
.title_scan:
    cmp  ebx, WM_MAX_WINS
    jge  .title_scan_done
    push edi
    imul edi, ebx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1
    jne  .title_scan_next
    cmp  byte [edi+16], WM_BROWSER
    jne  .title_scan_next
    mov  dword [edi+20], browser_title_buf
.title_scan_next:
    pop  edi
    inc  ebx
    jmp  .title_scan
.title_scan_done:
    pop  ecx
    pop  ebx
    pop  eax
    jmp  .tag_done
.chk_h1_cont:

.chk_h2:
    cmp  ax, 0x3268         ; "h2"
    jne  .chk_h3
    cmp  byte [edi+2], 0
    jne  .chk_h3
    call .do_block_newline
    mov  dword [br_scale], 3
    jmp  .tag_done
.chk_h3:
    cmp  ax, 0x3368         ; "h3"
    jne  .chk_h4
    cmp  byte [edi+2], 0
    jne  .chk_h4
    call .do_block_newline
    mov  dword [br_scale], 2
    jmp  .tag_done
.chk_h4:
    cmp  ax, 0x3468         ; "h4"
    jne  .chk_h5
    cmp  byte [edi+2], 0
    jne  .chk_h5
    call .do_block_newline
    mov  dword [br_scale], 2
    jmp  .tag_done
.chk_h5:
    cmp  ax, 0x3568         ; "h5"
    jne  .chk_h6
    cmp  byte [edi+2], 0
    jne  .chk_h6
    call .do_block_newline
    mov  dword [br_scale], 1
    jmp  .tag_done
.chk_h6:
    cmp  ax, 0x3668         ; "h6"
    jne  .chk_hend
    cmp  byte [edi+2], 0
    jne  .chk_hend
    call .do_block_newline
    mov  dword [br_scale], 1
    jmp  .tag_done
.chk_hend:
    ; /h1 .. /h6 : newline then reset scale to 1
    cmp  al, 47             ; first char = /
    jne  .chk_p
    cmp  ah, 0x68           ; second char = h
    jne  .chk_p
    call .do_block_newline
    call .do_block_newline  ; extra spacing after heading
    mov  dword [br_scale], 1
    jmp  .tag_done
.chk_p:
    ; <p> <br> <div> </p> </div> = newline
    cmp  ax, 0x7070         ; "pp" - no
    cmp  al, 112            ; p = 0x70
    jne  .chk_br
    cmp  byte [edi+1], 0
    jne  .chk_br
    call .do_block_newline
    jmp  .tag_done
.chk_br:
    cmp  ax, 0x7262         ; "br"
    jne  .chk_div
    call .do_block_newline
    jmp  .tag_done
.chk_div:
    ; div - just newline
    cmp  ax, 0x6964         ; "di"
    jne  .tag_done
    cmp  byte [edi+2], 118  ; v
    jne  .tag_done
    call .do_block_newline
.tag_done:
    pop  ecx
    pop  edi
    jmp  .loop
.tag_eos:
    pop  ecx
    pop  edi
    jmp  .done

; inline helper: newline by current scale
.do_block_newline:
    push eax
    mov  eax, [br_x0]
    mov  [br_cx], eax
    mov  eax, 8
    imul eax, [br_scale]
    add  [br_cy], eax
    pop  eax
    ret

.cr:
    jmp  .loop

.done:
    cmp  byte [browser_measuring], 1
    jne  .exit
    mov  eax, [br_cy]
    add  eax, 8
    sub  eax, [br_y0]
    mov  [browser_total_h], eax
.exit:
    popa
    ret

; helper vars
br_x0:      dd 0
br_y0:      dd 0
br_w:       dd 0
br_h:       dd 0
br_cx:      dd 0
br_cy:      dd 0
br_scale:        dd 1          ; current text scale (1=8px 2=16px 3=24px 4=32px)
br_tag_buf:      times 16 db 0 ; tag name buffer for HTML tag parsing
br_in_head:      db 0          ; 1 = inside <head> block, suppress output
br_in_style:     db 0          ; 1 = inside <style> block, suppress output
br_in_title:     db 0          ; 1 = collecting <title> content
br_title_ptr:    dd 0          ; write pointer into browser_title_buf
browser_title_buf: times 64 db 0 ; buffer for page title string

; - browser_tick -
browser_tick:
    pusha

    ; Always advance async fetch state machine, regardless of focus
    call browser_fetch_tick
    
    ; find focused browser
    mov  dword [wm_i], 0
.loop:
    mov  ecx, [wm_i]
    cmp  ecx, WM_MAX_WINS
    jge  .done
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    cmp  byte [edi+17], 1       ; open?
    jne  .next
    cmp  byte [edi+18], 1       ; focused?
    jne  .next
    cmp  byte [edi+16], WM_BROWSER
    jne  .next
    
    ; Focused browser found!
    ; Check keyboard
.key_loop:
    call pm_getkey
    or   al, al
    jz   .done
    
    ; Handle key
    cmp  al, 8 ; backspace
    je   .bs
    cmp  al, 13 ; enter
    je   .go
    cmp  al, 0x80 ; Up
    je   .scroll_up
    cmp  al, 0x81 ; Down
    je   .scroll_down
    cmp  al, 32
    jl   .key_loop
    cmp  al, 127
    jge  .key_loop
    
    ; Append to URL
    mov  [br_win_idx], ecx     ; save window index before ECX is clobbered
    mov  edi, browser_url
    xor  ecx, ecx
.find_end:
    cmp  byte [edi+ecx], 0
    je   .found
    inc  ecx
    cmp  ecx, 250
    jl   .find_end
    jmp  .done
.found:
    mov  [edi+ecx], al
    mov  byte [edi+ecx+1], 0
    mov  ecx, [br_win_idx]     ; restore window index for redraw
    call browser_redraw_urlbar
    jmp  .key_loop
    
.bs:
    mov  [br_win_idx], ecx     ; save window index before ECX is clobbered
    mov  edi, browser_url
    xor  ecx, ecx
.find_end2:
    cmp  byte [edi+ecx], 0
    je   .found2
    inc  ecx
    cmp  ecx, 250
    jl   .find_end2
    jmp  .done
.found2:
    test ecx, ecx
    jz   .key_loop
    mov  byte [edi+ecx-1], 0
    mov  ecx, [br_win_idx]     ; restore window index for redraw
    call browser_redraw_urlbar
    jmp  .key_loop
    
.go:
    call browser_fetch
    call wm_invalidate
    jmp  .key_loop

.next:
    inc  dword [wm_i]
    jmp  .loop
.scroll_up:
    cmp  dword [browser_scroll_y], 8
    jl   .zero_scroll
    sub  dword [browser_scroll_y], 16
    call wm_invalidate
    jmp  .key_loop
.zero_scroll:
    mov  dword [browser_scroll_y], 0
    call wm_invalidate
    jmp  .key_loop
.scroll_down:
    mov  eax, [browser_total_h]
    sub  eax, [br_h]
    cmp  eax, 0
    jle  .key_loop
    mov  ebx, [browser_scroll_y]
    add  ebx, 16
    cmp  ebx, eax
    jge  .max_scroll
    mov  [browser_scroll_y], ebx
    call wm_invalidate
    jmp  .key_loop
.max_scroll:
    mov  [browser_scroll_y], eax
    call wm_invalidate
    jmp  .key_loop
.done:
    popa
    ret

; - browser_click -
; In: EAX=mx, EBX=my, EDI=window record
browser_click:
    pusha
    
    ; coordinates relative to window
    sub  eax, [edi+0]
    sub  ebx, [edi+4]
    
    ; check Go button: x in [ww-50, ww-5], y in [TITLE+5, TITLE+21]
    mov  edx, [edi+8]
    sub  edx, 50
    cmp  eax, edx
    jl   .check_scroll
    mov  edx, [edi+8]
    sub  edx, 5
    cmp  eax, edx
    jg   .check_scroll
    
    cmp  ebx, WM_TITLE_H + 5
    jl   .check_scroll
    cmp  ebx, WM_TITLE_H + 21
    jg   .check_scroll
    
    ; Clicked Go!
    call browser_fetch
    call wm_invalidate
    jmp  .done

.check_scroll:
    mov  edx, [edi+8]
    sub  edx, 24
    cmp  eax, edx
    jl   .done
    
    cmp  ebx, WM_TITLE_H + 30
    jl   .done
    mov  edx, [edi+12]
    sub  edx, 5
    cmp  ebx, edx
    jg   .done

    sub  ebx, WM_TITLE_H + 30
    mov  ecx, [edi+12]
    sub  ecx, WM_TITLE_H + 35
    test ecx, ecx
    jle  .done
    mov  eax, [browser_total_h]
    sub  eax, ecx
    cmp  eax, 0
    jle  .done
    xchg eax, ebx
    imul ebx
    xor  edx, edx
    div  ecx
    mov  [browser_scroll_y], eax
    call wm_invalidate

.done:
    popa
    ret

; - browser_parse_url -
; Parse "http://hostname:port/path" into components
; In: ESI = URL string
; Out: EAX = IP (resolved) or 0 on error
;      AX = port, ESI = path pointer
;      browser_hostname populated
browser_parse_url:
    push ebx
    push ecx
    push edx
    push edi

    ; Skip "http://" prefix
    mov  edi, browser_hostname
    xor  ecx, ecx
.check_prefix:
    mov  al, [esi + ecx]
    mov  bl, [http_prefix + ecx]
    test bl, bl
    jz   .prefix_ok
    cmp  al, bl
    jne  .old_format
    inc  ecx
    jmp  .check_prefix

.prefix_ok:
    add  esi, ecx              ; skip "http://"
    jmp  .parse_hostname

.old_format:
    ; Not a URL - check if it looks like a hostname (contains dot before any space)
    ; e.g. "example.com" or "example.com/path" -> treat as http://hostname/path
    push esi
    xor  ecx, ecx
.scan_dot:
    mov  al, [esi + ecx]
    test al, al
    jz   .no_dot
    cmp  al, ' '
    je   .no_dot
    cmp  al, '.'
    je   .has_dot
    inc  ecx
    jmp  .scan_dot
.no_dot:
    pop  esi
    jmp  .try_ip
.has_dot:
    pop  esi
    ; Looks like a hostname - copy to browser_hostname and use DNS path
    mov  edi, browser_hostname
    xor  ebx, ebx
.hn_copy:
    mov  al, [esi]
    test al, al
    jz   .hn_done
    cmp  al, '/'
    je   .hn_done
    stosb
    inc  ebx
    inc  esi
    cmp  ebx, 253
    jl   .hn_copy
.hn_done:
    mov  byte [edi], 0
    cmp  byte [esi], '/'
    je   .hn_has_path
    mov  esi, browser_s_def_path
    jmp  .hn_got_path
.hn_has_path:
.hn_got_path:
    mov  [tcpg_path_ptr], esi
    mov  word [tcpg_dst_port], 80
    mov  dword [tcpg_dst_ip], 1
    mov  eax, 1
    clc
    jmp  .done

.try_ip:
    ; Not a URL, might be old "IP PORT PATH" format
    mov  esi, browser_url
    call pm_parse_ip
    test eax, eax
    jz   .error
    mov  [tcpg_dst_ip], eax

    ; skip to port
.skip1:
    lodsb
    test al, al
    jz   .error
    cmp  al, ' '
    jne  .skip1

    call pm_parse_uint
    test eax, eax
    jz   .error
    mov  [tcpg_dst_port], ax

    ; skip to path
.skip2:
    lodsb
    test al, al
    jz   .error
    cmp  al, ' '
    jne  .skip2
    mov  [tcpg_path_ptr], esi

    ; Return with EAX=IP already set
    jmp  .done

.parse_hostname:
    ; Extract hostname until ':' or '/'
    mov  edi, browser_hostname
    xor  ebx, ebx                ; hostname length

.host_loop:
    mov  al, [esi]
    test al, al
    jz   .host_done
    cmp  al, ':'
    je   .host_done
    cmp  al, '/'
    je   .host_done
    stosb
    inc  ebx
    inc  esi
    cmp  ebx, 253
    jl  .host_loop
.host_done:
    mov  byte [edi], 0           ; null-terminate hostname

    ; Check for port
    cmp  byte [esi], ':'
    jne  .default_port
    inc  esi                      ; skip ':'
    call pm_parse_uint
    test eax, eax
    jz   .error
    mov  [tcpg_dst_port], ax
    jmp  .check_path

.default_port:
    mov  word [tcpg_dst_port], 80

.check_path:
    ; Check for path
    cmp  byte [esi], '/'
    je   .has_path
    ; No path, use default
    mov  esi, browser_s_def_path
    jmp  .got_path

.has_path:
    ; Path already at ESI

.got_path:
    mov  [tcpg_path_ptr], esi

    ; For http:// URLs, DNS is handled asynchronously by browser_fetch_start.
    ; Set tcpg_dst_ip to a non-zero placeholder so browser_fetch_start
    ; knows parse succeeded, and return success. The real IP is filled in
    ; during BR_ST_DNS by dns_poll_nonblock.
    mov  dword [tcpg_dst_ip], 1     ; non-zero = parse OK, DNS pending
    mov  eax, 1
    clc
    jmp  .done

.error:
    xor  eax, eax
    stc

.done:
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - dns_resolve_hostname -
; Resolve hostname to IP using DNS
; In: ESI = hostname (null-terminated)
; Out: EAX = IP (host order), CF=0 success, CF=1 failed
dns_resolve_hostname:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov  [dns_tmp_hostname], esi

    ; Build DNS query
    mov  esi, [dns_tmp_hostname]
    call dns_build_query
    test ecx, ecx
    jz   .fail

    ; Send to DNS server (10.0.2.3:53)
    mov  eax, DNS_SERVER_IP
    mov  bx,  DNS_SRC_PORT
    mov  edx, ecx                ; save packet length
    mov  cx,  DNS_PORT
    mov  esi, dns_pkt_buf
    call udp_send
    jc   .fail

    ; Poll for DNS response
    mov  dword [dns_poll_ctr], 2000000
.dns_poll:
    inc  dword [net_poll_throttle]
    test dword [net_poll_throttle], 0x3FF
    jnz  .skip_hw
    call mouse_poll
    call pm_kb_poll
.skip_hw:
    call eth_recv
    jc   .dns_empty

    ; Skip ARP packets
    cmp  dx, ETHERTYPE_ARP
    jne  .dns_not_arp
    call arp_process
    jmp  .dns_poll
.dns_not_arp:

    ; Must be IPv4 UDP
    cmp  dx, ETHERTYPE_IPV4
    jne  .dns_poll
    cmp  ecx, 20 + UDP_HDR_LEN
    jl  .dns_poll
    cmp  byte [esi], 0x45
    jne  .dns_poll
    cmp  byte [esi + 9], IP_PROTO_UDP
    jne  .dns_poll

    ; Check UDP port matches our source port
    mov  ax, [esi + 20 + 2]      ; UDP dst port
    xchg al, ah
    cmp  ax, DNS_SRC_PORT
    jne  .dns_poll

    ; Get UDP payload length
    mov  ax, [esi + 20 + 4]
    xchg al, ah
    movzx ecx, ax
    sub  ecx, UDP_HDR_LEN
    cmp  ecx, 12
    jl  .dns_poll

    ; Copy DNS payload to dns_pkt_buf
    push esi
    push ecx
    push edi
    add  esi, 20 + UDP_HDR_LEN
    mov  edi, dns_pkt_buf
    rep  movsb
    pop  edi
    pop  ecx
    pop  esi

    call dns_parse_response
    jnc  .dns_success
    jmp  .dns_poll

.dns_empty:
    dec  dword [dns_poll_ctr]
    jnz  .dns_poll

.fail:
    stc
    jmp  .done

.dns_success:
    clc

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - browser_strip_headers -
; Strip HTTP headers from response, keeping only body
; In: ESI = response buffer, EDI = destination buffer
; Out: EDI updated to start of body
browser_strip_headers:
    push eax
    push ecx
    push esi

.strip_loop:
    movzx eax, byte [esi]
    test al, al
    jz   .not_found
    cmp  eax, 0x0D              ; CR
    jne  .check_lf1
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0D              ; CR
    jne  .not_found
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    ; Found \r\n\r\n - ESI now points to body
    jmp  .found
.check_lf1:
    cmp  eax, 0x0A              ; LF
    jne  .next_char
    inc  esi
    movzx eax, byte [esi]
    cmp  eax, 0x0A              ; LF
    jne  .not_found
    inc  esi
    ; Found \n\n - ESI now points to body
    jmp  .found
.next_char:
    inc  esi
    jmp  .strip_loop

.not_found:
    ; No headers found, copy everything
    mov  esi, browser_content
    jmp  .copy_loop
.found:
    ; Copy body to destination
.copy_loop:
    movzx eax, byte [esi]
    test al, al
    jz   .done
    stosb
    inc  esi
    jmp  .copy_loop

.done:
    mov  byte [edi], 0          ; null-terminate
    pop  esi
    pop  ecx
    pop  eax
    ret

; ===========================================================================
; ASYNC BROWSER FETCH - non-blocking state machine
;
; browser_fetch_start  - called once when user presses Go / Enter
;   Sets state to BR_ST_DNS (or BR_ST_CONNECT if URL was a raw IP),
;   clears content, builds DNS query and fires it off, then returns.
;
; browser_fetch_tick   - called every main-loop iteration from browser_tick
;   Advances the state machine by ONE step and returns immediately.
;   Never busy-polls; uses tcp_poll_nonblock / dns_poll_nonblock.
;
; States:
;   BR_ST_IDLE      0  nothing in progress
;   BR_ST_DNS       1  waiting for DNS UDP reply
;   BR_ST_CONNECT   2  waiting for TCP SYN-ACK
;   BR_ST_SEND      3  sending HTTP GET (completes in one tick)
;   BR_ST_RECV      4  draining TCP data
;   BR_ST_CLOSING   5  waiting for FIN handshake
;   BR_ST_STRIP     6  strip headers + measure (one tick, then -> IDLE)
; ===========================================================================

BR_ST_IDLE    equ 0
BR_ST_DNS     equ 1
BR_ST_CONNECT equ 2
BR_ST_SEND    equ 3
BR_ST_RECV    equ 4
BR_ST_CLOSING equ 5
BR_ST_STRIP   equ 6

; - tcp_poll_nonblock -
; Calls tcp_poll_one exactly once (no loop). Returns immediately.
; Used by the async state machine so the main loop stays responsive.
tcp_poll_nonblock:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call eth_recv
    jc   .empty

    mov  [tcp_rx_ip_base], esi

    cmp  dx, ETHERTYPE_ARP
    jne  .not_arp
    call arp_process
    jmp  .done
.not_arp:
    cmp  dx, ETHERTYPE_IPV4
    jne  .done
    cmp  ecx, 20 + TCP_HDR_LEN
    jl   .done

    mov  al, [esi]
    mov  bl, al
    shr  bl, 4
    cmp  bl, 4
    jne  .done
    and  al, 0x0F
    shl  al, 2
    movzx edx, al

    cmp  byte [esi + 9], IP_PROTO_TCP
    jne  .done

    mov  eax, [esi + 12]
    bswap eax
    mov  [tcp_rx_src_ip], eax
    cmp  eax, [tcp_dst_ip]
    jne  .done

    movzx ebx, word [esi + 2]
    xchg bl, bh
    movzx ecx, bx
    sub  ecx, edx

    add  esi, edx

    cmp  ecx, TCP_HDR_LEN
    jl   .done

    movzx eax, word [esi + 2]
    xchg al, ah
    cmp  ax, [tcp_src_port]
    jne  .done

    movzx eax, word [esi + 0]
    xchg al, ah
    cmp  ax, [tcp_dst_port]
    jne  .done

    mov  eax, [esi + 4]
    bswap eax
    mov  [tcp_rx_seq], eax

    mov  eax, [esi + 8]
    bswap eax
    mov  [tcp_rx_ack], eax

    mov  al, [esi + 13]
    mov  [tcp_rx_flags], al

    movzx eax, byte [esi + 12]
    shr  eax, 4
    shl  eax, 2
    mov  [tcp_rx_hdr_len], eax

    mov  ebx, ecx
    sub  ebx, [tcp_rx_hdr_len]
    mov  [tcp_rx_data_len], ebx

    test byte [tcp_rx_flags], TCP_FLAG_RST
    jz   .not_rst
    mov  byte [tcp_state], TCP_STATE_CLOSED
    jmp  .done
.not_rst:

    cmp  byte [tcp_state], TCP_STATE_SYN_SENT
    je   .syn_sent
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .established
    cmp  byte [tcp_state], TCP_STATE_FIN_WAIT1
    je   .fin_wait1
    cmp  byte [tcp_state], TCP_STATE_FIN_WAIT2
    je   .fin_wait2
    jmp  .done

.syn_sent:
    mov  al, [tcp_rx_flags]
    and  al, TCP_FLAG_SYN | TCP_FLAG_ACK
    cmp  al, TCP_FLAG_SYN | TCP_FLAG_ACK
    jne  .done
    mov  eax, [tcp_snd_isn]
    inc  eax
    cmp  eax, [tcp_rx_ack]
    jne  .done
    mov  eax, [tcp_rx_seq]
    inc  eax
    mov  [tcp_rcv_nxt], eax
    mov  eax, [tcp_rx_ack]
    mov  [tcp_snd_una], eax
    mov  byte [tcp_state], TCP_STATE_ESTABLISHED
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

.established:
    test byte [tcp_rx_flags], TCP_FLAG_ACK
    jz   .est_no_ack
    mov  eax, [tcp_rx_ack]
    cmp  eax, [tcp_snd_una]
    jle  .est_no_ack
    mov  [tcp_snd_una], eax
.est_no_ack:
    cmp  dword [tcp_rx_data_len], 0
    jle  .est_no_data
    mov  eax, [tcp_rx_seq]
    cmp  eax, [tcp_rcv_nxt]
    jne  .est_no_data
    mov  ecx, [tcp_rx_data_len]
    cmp  ecx, TCP_RX_BUF_SZ
    jle  .data_sz_ok
    mov  ecx, TCP_RX_BUF_SZ
.data_sz_ok:
    mov  edi, TCP_RX_BUF
    mov  esi, [tcp_rx_ip_base]
    add  esi, edx
    add  esi, [tcp_rx_hdr_len]
    push ecx
    rep  movsb
    pop  ecx
    mov  [tcp_rx_pending], ecx
    add  [tcp_rcv_nxt], ecx
    push esi
    push ecx
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    pop  ecx
    pop  esi
.est_no_data:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done
    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

.fin_wait1:
    test byte [tcp_rx_flags], TCP_FLAG_ACK
    jz   .fw1_fin
    mov  eax, [tcp_rx_ack]
    cmp  eax, [tcp_snd_nxt]
    jne  .fw1_fin
    mov  byte [tcp_state], TCP_STATE_FIN_WAIT2
.fw1_fin:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done
    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_TIME_WAIT
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment
    jmp  .done

.fin_wait2:
    test byte [tcp_rx_flags], TCP_FLAG_FIN
    jz   .done
    inc  dword [tcp_rcv_nxt]
    mov  byte [tcp_state], TCP_STATE_TIME_WAIT
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_ACK
    call tcp_send_segment

.empty:
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - dns_poll_nonblock -
; Calls eth_recv once and checks if a DNS reply arrived.
; Returns CF=0 and EAX=IP on success, CF=1 if no answer yet.
dns_poll_nonblock:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call eth_recv
    jc   .no_pkt

    cmp  dx, ETHERTYPE_ARP
    jne  .not_arp
    call arp_process
    stc
    jmp  .done
.not_arp:
    cmp  dx, ETHERTYPE_IPV4
    jne  .no_pkt
    cmp  ecx, 20 + UDP_HDR_LEN
    jl   .no_pkt
    cmp  byte [esi], 0x45
    jne  .no_pkt
    cmp  byte [esi + 9], IP_PROTO_UDP
    jne  .no_pkt
    mov  ax, [esi + 20 + 2]
    xchg al, ah
    cmp  ax, DNS_SRC_PORT
    jne  .no_pkt
    mov  ax, [esi + 20 + 4]
    xchg al, ah
    movzx ecx, ax
    sub  ecx, UDP_HDR_LEN
    cmp  ecx, 12
    jl   .no_pkt
    push esi
    push ecx
    push edi
    add  esi, 20 + UDP_HDR_LEN
    mov  edi, dns_pkt_buf
    rep  movsb
    pop  edi
    pop  ecx
    pop  esi
    call dns_parse_response
    jnc  .got_ip
    stc
    jmp  .done
.got_ip:
    clc
    jmp  .done
.no_pkt:
    stc
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; - browser_fetch_start -
; Called once when user presses Go. Fires DNS query (or skips to connect
; if URL is a raw IP) and sets fetch state. Returns immediately.
browser_fetch_start:
    pusha

    ; reset scroll, content
    mov  dword [browser_scroll_y], 0
    mov  dword [browser_total_h], 0
    mov  dword [br_recv_ptr], browser_content
    mov  dword [br_dns_ctr], 2000000
    mov  dword [br_conn_ctr], TCP_POLL_LIMIT
    mov  dword [br_close_ctr], TCP_POLL_LIMIT

    ; clear content buffer (500KB)
    mov  edi, browser_content
    xor  eax, eax
    mov  ecx, 125000
    rep  stosd

    ; show "Fetching..." while async work runs
    mov  edi, browser_content
    mov  esi, browser_s_fetching
.copy_f:
    lodsb
    stosb
    test al, al
    jnz  .copy_f
    call wm_invalidate

    ; parse URL to fill tcpg_dst_ip / tcpg_dst_port / tcpg_path_ptr
    ; browser_parse_url may resolve DNS synchronously for raw-IP format
    mov  esi, browser_url
    call browser_parse_url
    test eax, eax
    jz   .err_url

    ; check if we need DNS (ip was not raw)
    ; browser_parse_url puts IP in tcpg_dst_ip; if it went through
    ; dns_resolve_hostname it already resolved, but we re-do it async
    ; only when the URL starts with http://
    ; Simplest check: if http_prefix matched, hostname is in browser_hostname
    cmp  byte [browser_hostname], 0
    je   .skip_dns          ; no hostname = raw IP format, go straight to connect

    ; send DNS query and enter DNS-wait state
    mov  esi, browser_hostname
    call dns_build_query    ; ECX = pkt len, dns_pkt_buf populated
    mov  eax, DNS_SERVER_IP
    mov  bx,  DNS_SRC_PORT
    mov  edx, ecx
    mov  cx,  DNS_PORT
    mov  esi, dns_pkt_buf
    call udp_send
    jc   .err_url

    mov  byte [br_fetch_state], BR_ST_DNS
    jmp  .done

.skip_dns:
    ; raw IP already in tcpg_dst_ip, go straight to async connect
    call br_start_connect
    jmp  .done

.err_url:
    mov  esi, browser_s_err_url
    mov  edi, browser_content
.copy_err:
    lodsb
    stosb
    test al, al
    jnz  .copy_err
    mov  byte [br_fetch_state], BR_ST_IDLE
    call wm_invalidate

.done:
    popa
    ret

; - br_start_connect -
; Initiate async TCP connect (send SYN, enter BR_ST_CONNECT).
br_start_connect:
    push eax
    push ecx

    call tcp_reset_state

    mov  eax, [tcpg_dst_ip]
    mov  [tcp_dst_ip], eax
    movzx ecx, word [tcpg_dst_port]
    mov  [tcp_dst_port], cx
    mov  word [tcp_src_port], TCP_EPHEM_PORT

    mov  eax, [pit_ticks]
    shl  eax, 10
    mov  [tcp_snd_isn], eax
    mov  [tcp_snd_nxt], eax
    mov  dword [tcp_snd_una], 0
    mov  dword [tcp_rcv_nxt], 0
    mov  byte [tcp_state], TCP_STATE_SYN_SENT

    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_SYN
    call tcp_send_segment
    inc  dword [tcp_snd_nxt]

    mov  byte [br_fetch_state], BR_ST_CONNECT
    mov  dword [br_conn_ctr], TCP_POLL_LIMIT

    pop  ecx
    pop  eax
    ret

; - browser_fetch_tick -
; Called every main-loop iteration. Advances the async state machine
; by one small step and returns. Never loops or blocks.
browser_fetch_tick:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    movzx eax, byte [br_fetch_state]
    cmp  eax, BR_ST_IDLE
    je   .done
    cmp  eax, BR_ST_DNS
    je   .tick_dns
    cmp  eax, BR_ST_CONNECT
    je   .tick_connect
    cmp  eax, BR_ST_SEND
    je   .tick_send
    cmp  eax, BR_ST_RECV
    je   .tick_recv
    cmp  eax, BR_ST_CLOSING
    je   .tick_closing
    cmp  eax, BR_ST_STRIP
    je   .tick_strip
    jmp  .done

; ---- DNS wait: try one packet, count down timeout ----
.tick_dns:
    call dns_poll_nonblock
    jnc  .dns_got_ip        ; CF=0 means we got an answer

    dec  dword [br_dns_ctr]
    jnz  .done              ; still waiting

    ; timeout
    mov  esi, browser_s_err_conn
    jmp  .set_err

.dns_got_ip:
    mov  [tcpg_dst_ip], eax
    call br_start_connect
    jmp  .done

; ---- TCP connect: poll one packet, count down timeout ----
.tick_connect:
    call tcp_poll_nonblock

    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .connected

    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .conn_fail

    dec  dword [br_conn_ctr]
    jnz  .done

    ; timeout
.conn_fail:
    mov  esi, browser_s_err_conn
    jmp  .set_err

.connected:
    ; build HTTP GET request into tcpg_req_buf
    mov  edi, tcpg_req_buf
    mov  byte [edi+0], 'G'
    mov  byte [edi+1], 'E'
    mov  byte [edi+2], 'T'
    mov  byte [edi+3], ' '
    add  edi, 4
    mov  esi, [tcpg_path_ptr]
.copy_path:
    lodsb
    stosb
    test al, al
    jnz  .copy_path
    dec  edi

    mov  esi, tcpg_str_http10
.app1: lodsb
    stosb
    test al, al
    jnz  .app1
    dec  edi

    mov  esi, tcpg_str_host
.app2: lodsb
    stosb
    test al, al
    jnz  .app2
    dec  edi

    mov  esi, browser_hostname
.app3: lodsb
    stosb
    test al, al
    jnz  .app3
    dec  edi

    mov  byte [edi], 13
    inc  edi
    mov  byte [edi], 10
    inc  edi

    mov  esi, tcpg_str_connclose
.app4: lodsb
    stosb
    test al, al
    jnz  .app4
    dec  edi
    mov  byte [edi], 0

    mov  byte [br_fetch_state], BR_ST_SEND
    jmp  .done

; ---- Send: fire HTTP request in a single tick ----
.tick_send:
    mov  ecx, edi
    sub  ecx, tcpg_req_buf
    ; edi still points to end of request from BR_ST_CONNECT tick
    ; but this is a separate call - recalculate length
    mov  edi, tcpg_req_buf
.find_end:
    cmp  byte [edi], 0
    je   .end_found
    inc  edi
    jmp  .find_end
.end_found:
    ; last byte before null should be LF from connclose, back up 1 for null
    mov  ecx, edi
    sub  ecx, tcpg_req_buf
    mov  esi, tcpg_req_buf
    call tcp_send
    jc   .send_fail

    ; reset receive pointer to start of content buffer
    mov  dword [br_recv_ptr], browser_content
    mov  dword [tcpg_total], 0
    mov  byte [br_fetch_state], BR_ST_RECV
    jmp  .done

.send_fail:
    mov  esi, browser_s_err_send
    jmp  .set_err

; ---- Receive: drain one pending TCP segment per tick ----
.tick_recv:
    ; poll network once
    call tcp_poll_nonblock

    ; if data arrived, copy it out
    cmp  dword [tcp_rx_pending], 0
    jle  .recv_no_data

    mov  ecx, [tcp_rx_pending]
    ; safety: don't overflow 500KB
    mov  eax, [br_recv_ptr]
    sub  eax, browser_content
    add  eax, ecx
    cmp  eax, 500000
    jae  .recv_finish

    mov  esi, TCP_RX_BUF
    mov  edi, [br_recv_ptr]
    push ecx
    rep  movsb
    pop  ecx
    add  [br_recv_ptr], ecx
    add  [tcpg_total], ecx
    mov  dword [tcp_rx_pending], 0
    jmp  .done

.recv_no_data:
    ; check if connection closed by peer
    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .recv_finish
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .recv_finish
    jmp  .done

.recv_finish:
    ; null-terminate and start async close
    mov  edi, [br_recv_ptr]
    mov  byte [edi], 0

    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    jne  .skip_fin
    xor  esi, esi
    xor  ecx, ecx
    mov  bl, TCP_FLAG_FIN | TCP_FLAG_ACK
    call tcp_send_segment
    inc  dword [tcp_snd_nxt]
    mov  byte [tcp_state], TCP_STATE_FIN_WAIT1
    mov  byte [br_fetch_state], BR_ST_CLOSING
    mov  dword [br_close_ctr], TCP_POLL_LIMIT
    jmp  .done
.skip_fin:
    ; already closed/close_wait - go straight to strip
    mov  byte [tcp_state], TCP_STATE_CLOSED
    mov  byte [br_fetch_state], BR_ST_STRIP
    jmp  .done

; ---- Closing: wait for FIN-ACK, one poll per tick ----
.tick_closing:
    call tcp_poll_nonblock

    cmp  byte [tcp_state], TCP_STATE_TIME_WAIT
    je   .close_done
    cmp  byte [tcp_state], TCP_STATE_CLOSED
    je   .close_done

    dec  dword [br_close_ctr]
    jnz  .done

.close_done:
    mov  byte [tcp_state], TCP_STATE_CLOSED
    mov  byte [br_fetch_state], BR_ST_STRIP
    jmp  .done

; ---- Strip headers + measure in one tick, then go idle ----
.tick_strip:
    mov  esi, browser_content
    mov  edi, browser_content
    call browser_strip_headers

    mov  byte [browser_measuring], 1
    mov  esi, browser_content
    mov  eax, [br_x0]
    mov  ebx, [br_y0]
    mov  ecx, [br_w]
    mov  edx, [br_h]
    call browser_draw_content
    mov  byte [browser_measuring], 0

    mov  byte [br_fetch_state], BR_ST_IDLE
    call wm_invalidate
    jmp  .done

.set_err:
    mov  edi, browser_content
.copy_err2:
    lodsb
    stosb
    test al, al
    jnz  .copy_err2
    mov  byte [tcp_state], TCP_STATE_CLOSED
    mov  byte [br_fetch_state], BR_ST_IDLE
    call wm_invalidate

.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

; - browser_redraw_urlbar -
; Repaints only the address bar strip and flushes those rows.
; Much cheaper than wm_invalidate (no content repaint) - use on every keypress.
; Expects ECX = window index (same as when called from browser_tick key loop)
browser_redraw_urlbar:
    pusha
    imul edi, ecx, WM_STRIDE
    add  edi, wm_table
    ; stash wx, wy, ww before any call trashes EDI
    mov  eax, [edi+0]          ; wx
    mov  [br_tmp_wx], eax
    mov  eax, [edi+4]          ; wy
    mov  [br_tmp_wy], eax
    mov  eax, [edi+8]          ; ww
    mov  [br_tmp_ww], eax
    ; fill url bar background: x=wx+5, y=wy+TH+5, w=ww-60, h=16
    mov  eax, [br_tmp_wx]
    add  eax, 5
    mov  ebx, [br_tmp_wy]
    add  ebx, WM_TITLE_H + 5
    mov  ecx, [br_tmp_ww]
    sub  ecx, 60
    mov  edx, 16
    mov  esi, 0x0F
    call fb_fill_rect
    ; draw url text: EBX=x ECX=y (fb_draw_string convention)
    mov  ebx, [br_tmp_wx]
    add  ebx, 9                ; wx + 9
    mov  ecx, [br_tmp_wy]
    add  ecx, WM_TITLE_H + 9  ; wy + title + 9
    mov  esi, browser_url
    mov  dl, 0x00
    mov  dh, 0x0F
    call fb_draw_string
    ; flush only urlbar rows
    mov  eax, [br_tmp_wy]
    add  eax, WM_TITLE_H + 5  ; y_top
    mov  ebx, eax
    add  ebx, 16               ; y_bottom
    call gfx_mark_dirty
    call gfx_flush
    popa
    ret

; - browser_fetch - legacy shim: start async fetch (called from click/key)
browser_fetch:
    call browser_fetch_start
    ret

; - Data -
browser_url:     times 256 db 0
browser_content  equ 0x24C000
browser_s_go:    db 'Go', 0
browser_s_default_url: db '142.250.180.142 80 /', 0
browser_s_hdr_host:    db 'Host: google.com', 13, 10, 0
browser_s_welcome: db 'Welcome to ', OS_NAME, ' Browser!', 13, 10, 'Usage: http://hostname/path or IP PORT PATH', 0
browser_s_fetching: db 'Fetching...', 0
browser_s_err_url:  db 'Error: Invalid URL format.', 0
browser_s_err_conn: db 'Error: Connection failed.', 0
browser_s_err_send: db 'Error: Send failed.', 0

; Missing data symbols referenced by browser_parse_url / dns_resolve_hostname / browser_fetch
browser_hostname:   times 256 db 0     ; buffer for parsed hostname (null-terminated)
http_prefix:        db 'http://', 0    ; URL scheme prefix to detect and strip
browser_s_def_path: db '/', 0          ; default path when URL has no explicit path
dns_tmp_hostname:   dd 0               ; pointer to hostname being resolved
browser_scroll_y:   dd 0               ; virtual scroll offset
browser_total_h:    dd 0               ; total content height
browser_measuring:  db 0               ; 1 = measure height without drawing
br_fetch_state:     db BR_ST_IDLE      ; async fetch state machine
br_recv_ptr:        dd 0               ; write pointer into browser_content during recv
br_dns_ctr:         dd 0               ; DNS timeout countdown
br_conn_ctr:        dd 0               ; TCP connect timeout countdown
br_close_ctr:       dd 0               ; TCP close timeout countdown
br_win_idx:         dd 0               ; saved window index during key handling
br_tmp_wx:          dd 0               ; temp window x for urlbar redraw
br_tmp_wy:          dd 0               ; temp window y for urlbar redraw
br_tmp_ww:          dd 0               ; temp window w for urlbar redraw
