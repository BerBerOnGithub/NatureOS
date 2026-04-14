; ===========================================================================
; pm/browser.asm  -  NatureOS Simple Web Browser (with HTML rendering)
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
    
    ; Draw current content (with HTML rendering)
    mov  eax, [edi+0]
    add  eax, 9             ; content x
    mov  ebx, [edi+4]
    add  ebx, WM_TITLE_H + 30 ; content y
    mov  ecx, [edi+8]
    sub  ecx, 18            ; content w
    mov  edx, [edi+12]
    sub  edx, WM_TITLE_H + 35 ; content h
    
    mov  esi, browser_content
    call browser_draw_content
    popa
    
    popa
    ret

; ===========================================================================
; HTML-aware content renderer
; ===========================================================================
; In: ESI=content (null-terminated), EAX=x0, EBX=y0, ECX=w, EDX=h
; Uses state variables: br_x0, br_y0, br_w, br_h, br_cx, br_cy,
;   br_scale, br_bold, br_skip, br_line_h, br_done_flag, br_closing,
;   br_tag_buf, br_char_buf, br_save_esi, br_match_len
browser_draw_content:
    pusha
    mov  [br_x0], eax
    mov  [br_y0], ebx
    mov  [br_w],  ecx
    mov  [br_h],  edx

    mov  [br_cx], eax
    mov  [br_cy], ebx
    mov  dword [br_scale], 1
    mov  dword [br_bold], 0
    mov  dword [br_skip], 0
    mov  dword [br_line_h], 8
    mov  dword [br_done_flag], 0

    ; save fcs_scale so we don't corrupt it for other callers
    mov  eax, [fcs_scale]
    mov  [br_save_scale], eax

.loop:
    cmp  dword [br_done_flag], 0
    jne  .done

    movzx eax, byte [esi]
    test al, al
    jz   .done

    cmp  al, '<'
    je   .tag
    cmp  al, '&'
    je   .entity

    ; CR - ignore
    cmp  al, 13
    je   .skip_inc

    ; LF - newline
    cmp  al, 10
    je   .newline_inc

    ; if skipping (inside script/style), skip char
    cmp  dword [br_skip], 0
    jg   .skip_inc

    ; render printable character
    mov  [br_char_buf], al
    call browser_render_char
    inc  esi
    jmp  .loop

.tag:
    ; ESI points to '<'. browser_parse_tag will parse from ESI+1 and update ESI.
    call browser_parse_tag
    ; ESI is now updated (saved/restored via br_save_esi since pusha/popa used)
    mov  esi, [br_save_esi]
    jmp  .loop

.entity:
    ; ESI points to '&'. browser_decode_entity will handle it.
    call browser_decode_entity
    ; ESI is updated via br_save_esi, decoded char in br_char_buf
    mov  esi, [br_save_esi]
    cmp  dword [br_skip], 0
    jg   .loop
    cmp  byte [br_char_buf], 0
    je   .loop
    call browser_render_char
    jmp  .loop

.newline_inc:
    inc  esi
    call browser_newline
    jmp  .loop

.skip_inc:
    inc  esi
    jmp  .loop

.done:
    ; restore fcs_scale for other callers
    mov  eax, [br_save_scale]
    mov  [fcs_scale], eax
    popa
    ret
; Render character from br_char_buf at current cursor position.
; Uses current br_scale and br_bold for rendering.
browser_render_char:
    pusha

    ; compute char width = 8 * scale
    mov  eax, [br_scale]
    shl  eax, 3
    mov  [br_cw], eax

    ; check wrap
    mov  edx, [br_cx]
    sub  edx, [br_x0]
    add  edx, eax            ; edx = (cx - x0) + char_width
    cmp  edx, [br_w]
    jbe  .no_wrap
    ; wrap to next line
    call browser_newline
.no_wrap:

    ; set fcs_scale for scaled rendering
    mov  eax, [br_scale]
    mov  [fcs_scale], eax

    ; compute foreground color
    mov  dl, 0x00            ; default: black
    cmp  dword [br_bold], 0
    je   .fg_set
    mov  dl, 0x08            ; bold: dark grey
.fg_set:
    mov  dh, 0x0F            ; white background

    ; draw char scaled - bounds check first (fb_draw_char_scaled has no bounds check)
    mov  al, [br_char_buf]
    mov  ebx, [br_cx]
    mov  ecx, [br_cy]
    ; check x: cx + 8*scale must be < 640
    mov  edx, ebx
    add  edx, [br_cw]
    cmp  edx, 640
    ja   .skip_draw
    ; check y: cy + 8*scale must be < 480
    mov  edx, ecx
    add  edx, [br_cw]
    cmp  edx, 480
    ja   .skip_draw
    call fb_draw_char_scaled
.skip_draw:

    ; advance cursor
    mov  eax, [br_cw]
    add  [br_cx], eax

    popa
    ret

; - browser_newline -
; Reset CX to x0, advance CY by current line height.
; Sets br_done_flag if past bottom clip or screen.
browser_newline:
    push eax
    mov  eax, [br_x0]
    mov  [br_cx], eax
    mov  eax, [br_line_h]
    add  [br_cy], eax
    ; check bottom clip (content area)
    mov  eax, [br_cy]
    sub  eax, [br_y0]
    add  eax, [br_line_h]
    cmp  eax, [br_h]
    ja   .nl_clip
    ; also check hard screen boundary
    mov  eax, [br_cy]
    add  eax, [br_line_h]
    cmp  eax, 480
    jbe  .nl_ok
.nl_clip:
    mov  dword [br_done_flag], 1
.nl_ok:
    pop  eax
    ret

; - browser_draw_hr -
; Draw horizontal rule at current position
browser_draw_hr:
    pusha
    ; reset to start of line
    mov  eax, [br_x0]
    mov  [br_cx], eax
    ; draw line: fb_fill_rect(x0, cy, w, 2, dark grey)
    mov  eax, [br_x0]
    mov  ebx, [br_cy]
    cmp  ebx, 478
    ja   .hr_skip
    mov  ecx, [br_w]
    mov  edx, 2
    mov  esi, 0x08           ; dark grey
    call fb_fill_rect
.hr_skip:
    ; advance cy past line + spacing
    add  dword [br_cy], 6
    mov  eax, [br_x0]
    mov  [br_cx], eax
    ; check bottom clip
    mov  eax, [br_cy]
    sub  eax, [br_y0]
    add  eax, 8
    cmp  eax, [br_h]
    ja   .hr_clip
.hr_clip:
    popa
    ret

; ===========================================================================
; browser_parse_tag
; ===========================================================================
; Called when '<' is encountered in main loop. ESI points to the '<'.
; Parses the tag, updates rendering state, and sets br_save_esi to
; point past the closing '>'.
; Uses pusha/popa so we must save ESI externally.
browser_parse_tag:
    pusha

    ; ESI points to '<', advance past it
    inc  esi

    ; check for closing tag '</'
    mov  dword [br_closing], 0
    cmp  byte [esi], '/'
    jne  .not_closing
    mov  dword [br_closing], 1
    inc  esi

.not_closing:
    ; read tag name into br_tag_buf (max 15 chars, lowercased)
    mov  edi, br_tag_buf
    xor  ecx, ecx
.read_tag:
    mov  al, [esi]
    ; stop at space, >, /, or null
    cmp  al, ' '
    je   .tag_name_done
    cmp  al, '>'
    je   .tag_name_done
    cmp  al, '/'
    je   .tag_name_done
    test al, al
    jz   .tag_name_done
    ; lowercase: if 'A'-'Z', OR with 0x20
    cmp  al, 'A'
    jb   .no_lower
    cmp  al, 'Z'
    ja   .no_lower
    or   al, 0x20
.no_lower:
    stosb
    inc  esi
    inc  ecx
    cmp  ecx, 15
    jb   .read_tag
.tag_name_done:
    ; null-terminate tag name
    xor  al, al
    stosb

    ; skip rest of tag until '>' or null
.skip_tag:
    mov  al, [esi]
    test al, al
    jz   .tag_end
    cmp  al, '>'
    je   .found_gt
    inc  esi
    jmp  .skip_tag
.found_gt:
    inc  esi                ; skip past '>'

.tag_end:
    ; save ESI so caller can pick it up
    mov  [br_save_esi], esi

    ; if inside script/style skip, only check for </script> or </style>
    cmp  dword [br_skip], 0
    jg   .check_skip_end

    ; apply tag effects
    call browser_apply_tag
    jmp  .parse_done

.check_skip_end:
    ; check if this closing tag ends the skip
    cmp  dword [br_closing], 1
    jne  .parse_done        ; not a closing tag, stay in skip
    ; check for </script>
    mov  esi, br_tag_buf
    mov  edi, browser_s_script
    call br_str_eq
    test al, al
    jnz  .end_skip
    ; check for </style>
    mov  esi, br_tag_buf
    mov  edi, browser_s_style
    call br_str_eq
    test al, al
    jnz  .end_skip
    jmp  .parse_done
.end_skip:
    dec  dword [br_skip]
    jmp  .parse_done

.parse_done:
    popa
    ret

; ===========================================================================
; browser_apply_tag
; ===========================================================================
; Apply rendering state changes based on tag in br_tag_buf.
; Uses br_closing to determine opening vs closing tag.
browser_apply_tag:
    pusha

    ; if closing tag
    cmp  dword [br_closing], 1
    je   .closing_tag

    ; --- Opening tags ---
    mov  esi, br_tag_buf
    mov  edi, browser_s_h1
    call br_str_eq
    test al, al
    jnz  .open_h1
    mov  esi, br_tag_buf
    mov  edi, browser_s_h2
    call br_str_eq
    test al, al
    jnz  .open_h2
    mov  esi, br_tag_buf
    mov  edi, browser_s_h3
    call br_str_eq
    test al, al
    jnz  .open_h3
    mov  esi, br_tag_buf
    mov  edi, browser_s_h4
    call br_str_eq
    test al, al
    jnz  .open_h4
    mov  esi, br_tag_buf
    mov  edi, browser_s_h5
    call br_str_eq
    test al, al
    jnz  .open_h5
    mov  esi, br_tag_buf
    mov  edi, browser_s_h6
    call br_str_eq
    test al, al
    jnz  .open_h6
    mov  esi, br_tag_buf
    mov  edi, browser_s_p
    call br_str_eq
    test al, al
    jnz  .open_p
    mov  esi, br_tag_buf
    mov  edi, browser_s_br
    call br_str_eq
    test al, al
    jnz  .open_br
    mov  esi, br_tag_buf
    mov  edi, browser_s_hr
    call br_str_eq
    test al, al
    jnz  .open_hr
    mov  esi, br_tag_buf
    mov  edi, browser_s_b
    call br_str_eq
    test al, al
    jnz  .open_b
    mov  esi, br_tag_buf
    mov  edi, browser_s_ul
    call br_str_eq
    test al, al
    jnz  .open_ul
    mov  esi, br_tag_buf
    mov  edi, browser_s_li
    call br_str_eq
    test al, al
    jnz  .open_li
    mov  esi, br_tag_buf
    mov  edi, browser_s_script
    call br_str_eq
    test al, al
    jnz  .open_script
    mov  esi, br_tag_buf
    mov  edi, browser_s_style
    call br_str_eq
    test al, al
    jnz  .open_style
    ; unknown tag - ignore
    jmp  .apply_done

.open_h1:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 3
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 24
    jmp  .apply_done

.open_h2:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 2
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 16
    jmp  .apply_done

.open_h3:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 1
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 8
    jmp  .apply_done

.open_h4:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 1
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 8
    jmp  .apply_done

.open_h5:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 1
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 8
    jmp  .apply_done

.open_h6:
    call browser_newline
    call browser_newline
    mov  dword [br_scale], 1
    mov  dword [br_bold], 1
    mov  dword [br_line_h], 8
    jmp  .apply_done

.open_p:
    call browser_newline
    call browser_newline
    jmp  .apply_done

.open_br:
    call browser_newline
    jmp  .apply_done

.open_hr:
    call browser_newline
    call browser_draw_hr
    jmp  .apply_done

.open_b:
    mov  dword [br_bold], 1
    jmp  .apply_done

.open_ul:
    call browser_newline
    jmp  .apply_done

.open_li:
    call browser_newline
    ; emit bullet prefix "* "
    cmp  dword [br_skip], 0
    jg   .apply_done
    mov  byte [br_char_buf], '*'
    call browser_render_char
    mov  byte [br_char_buf], ' '
    call browser_render_char
    jmp  .apply_done

.open_script:
    inc  dword [br_skip]
    jmp  .apply_done

.open_style:
    inc  dword [br_skip]
    jmp  .apply_done

    ; --- Closing tags ---
.closing_tag:
    mov  esi, br_tag_buf
    mov  edi, browser_s_h1
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_h2
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_h3
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_h4
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_h5
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_h6
    call br_str_eq
    test al, al
    jnz  .close_h
    mov  esi, br_tag_buf
    mov  edi, browser_s_p
    call br_str_eq
    test al, al
    jnz  .close_p
    mov  esi, br_tag_buf
    mov  edi, browser_s_b
    call br_str_eq
    test al, al
    jnz  .close_b
    mov  esi, br_tag_buf
    mov  edi, browser_s_ul
    call br_str_eq
    test al, al
    jnz  .close_ul
    ; /li - nothing special
    ; /script or /style handled in browser_parse_tag
    jmp  .apply_done

.close_h:
    call browser_newline
    mov  dword [br_scale], 1
    mov  dword [br_bold], 0
    mov  dword [br_line_h], 8
    jmp  .apply_done

.close_p:
    call browser_newline
    jmp  .apply_done

.close_b:
    mov  dword [br_bold], 0
    jmp  .apply_done

.close_ul:
    call browser_newline
    jmp  .apply_done

.apply_done:
    popa
    ret

; ===========================================================================
; browser_decode_entity
; ===========================================================================
; Called when '&' is encountered in main loop. ESI points to the '&'.
; Tries to match known HTML entities starting at ESI+1.
; On match: sets br_char_buf to decoded char, br_save_esi = ESI past entity.
; On no match: sets br_char_buf to '&', br_save_esi = ESI+1 (past the &).
browser_decode_entity:
    pusha

    ; ESI points to '&'. ESI+1 is start of entity name.
    ; Save base pointer for match length calculation
    mov  [br_save_esi], esi

    ; try &amp;
    lea  esi, [esi + 1]     ; ESI now points past '&'
    mov  edi, browser_s_amp
    call br_match_entity
    test al, al
    jz   .not_amp
    ; match_len bytes matched past the '&'. New ESI = base + 1 + match_len
    mov  eax, [br_save_esi]
    add  eax, [br_match_len]
    inc  eax                 ; +1 for the '&'
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], '&'
    jmp  .ent_done

.not_amp:
    mov  esi, [br_save_esi]
    lea  esi, [esi + 1]
    mov  edi, browser_s_lt
    call br_match_entity
    test al, al
    jz   .not_lt
    mov  eax, [br_save_esi]
    add  eax, [br_match_len]
    inc  eax
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], '<'
    jmp  .ent_done

.not_lt:
    mov  esi, [br_save_esi]
    lea  esi, [esi + 1]
    mov  edi, browser_s_gt
    call br_match_entity
    test al, al
    jz   .not_gt
    mov  eax, [br_save_esi]
    add  eax, [br_match_len]
    inc  eax
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], '>'
    jmp  .ent_done

.not_gt:
    mov  esi, [br_save_esi]
    lea  esi, [esi + 1]
    mov  edi, browser_s_nbsp
    call br_match_entity
    test al, al
    jz   .not_nbsp
    mov  eax, [br_save_esi]
    add  eax, [br_match_len]
    inc  eax
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], ' '
    jmp  .ent_done

.not_nbsp:
    mov  esi, [br_save_esi]
    lea  esi, [esi + 1]
    mov  edi, browser_s_quot
    call br_match_entity
    test al, al
    jz   .not_quot
    mov  eax, [br_save_esi]
    add  eax, [br_match_len]
    inc  eax
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], '"'
    jmp  .ent_done

.not_quot:
    ; no match - treat '&' as literal, advance past it
    mov  eax, [br_save_esi]
    inc  eax                ; skip the '&'
    mov  [br_save_esi], eax
    mov  byte [br_char_buf], '&'

.ent_done:
    popa
    ret

; ===========================================================================
; Utility: string equality comparison (non-local label, safe to call from
; both browser_parse_tag and browser_apply_tag)
; ===========================================================================
; ESI=str1, EDI=str2. Returns AL=1 if equal, AL=0 if not.
br_str_eq:
    push ebx
.se_loop:
    mov  al, [esi]
    mov  bl, [edi]
    cmp  al, bl
    jne  .se_ne
    test al, al
    jz   .se_eq
    inc  esi
    inc  edi
    jmp  .se_loop
.se_eq:
    mov  al, 1
    pop  ebx
    ret
.se_ne:
    xor  al, al
    pop  ebx
    ret

; ===========================================================================
; Utility: case-insensitive entity match
; ===========================================================================
; ESI points to content text (after '&'), EDI points to pattern string like "amp;"
; (the part after '&', including the trailing ';').
; Returns AL=1 if match, AL=0 if not. Sets br_match_len = number of matched bytes.
; Does NOT modify ESI or EDI.
br_match_entity:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    xor  ecx, ecx          ; match length counter
.me_loop:
    mov  bl, [edi]
    test bl, bl
    jz   .me_match         ; reached end of pattern - full match!
    mov  dl, [esi + ecx]
    ; case-insensitive: lowercase both
    mov  al, dl
    cmp  al, 'A'
    jb   .me_no_lower1
    cmp  al, 'Z'
    ja   .me_no_lower1
    or   al, 0x20
.me_no_lower1:
    mov  bh, bl
    cmp  bh, 'A'
    jb   .me_no_lower2
    cmp  bh, 'Z'
    ja   .me_no_lower2
    or   bh, 0x20
.me_no_lower2:
    cmp  al, bh
    jne  .me_nomatch
    inc  ecx
    inc  edi
    jmp  .me_loop
.me_match:
    mov  [br_match_len], ecx
    mov  al, 1
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret
.me_nomatch:
    xor  al, al
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret

; ===========================================================================
; Helper vars for browser content rendering
; ===========================================================================
br_x0: dd 0
br_y0: dd 0
br_w:  dd 0
br_h:  dd 0
br_cx: dd 0
br_cy: dd 0
br_scale: dd 1
br_bold:  dd 0
br_fg:    dd 0
br_skip:  dd 0
br_line_h: dd 8
br_cw:    dd 8
br_done_flag: dd 0
br_closing: dd 0
br_save_esi: dd 0
br_match_len: dd 0
br_save_scale: dd 0
br_tag_buf: times 16 db 0
br_char_buf: db 0

; tag name strings for comparison
browser_s_h1: db 'h1', 0
browser_s_h2: db 'h2', 0
browser_s_h3: db 'h3', 0
browser_s_h4: db 'h4', 0
browser_s_h5: db 'h5', 0
browser_s_h6: db 'h6', 0
browser_s_p: db 'p', 0
browser_s_br: db 'br', 0
browser_s_hr: db 'hr', 0
browser_s_b: db 'b', 0
browser_s_ul: db 'ul', 0
browser_s_li: db 'li', 0
browser_s_script: db 'script', 0
browser_s_style: db 'style', 0
; entity strings (the part after '&', including the ';')
browser_s_amp: db 'amp;', 0
browser_s_lt: db 'lt;', 0
browser_s_gt: db 'gt;', 0
browser_s_nbsp: db 'nbsp;', 0
browser_s_quot: db 'quot;', 0

; - browser_tick -
browser_tick:
    pusha
    
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
    in   al, 0x64
    test al, 0x01
    jz   .done
    test al, 0x20
    jnz  .done
    call pm_getkey
    or   al, al
    jz   .done
    
    ; Handle key
    cmp  al, 8 ; backspace
    je   .bs
    cmp  al, 13 ; enter
    je   .go
    cmp  al, 32
    jl   .done
    cmp  al, 127
    jge  .done
    
    ; Append to URL
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
    call wm_draw_all
    jmp  .done
    
.bs:
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
    jz   .done
    mov  byte [edi+ecx-1], 0
    call wm_draw_all
    jmp  .done
    
.go:
    call browser_fetch
    call wm_draw_all
    jmp  .done

.next:
    inc  dword [wm_i]
    jmp  .loop
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
    jl   .done
    mov  edx, [edi+8]
    sub  edx, 5
    cmp  eax, edx
    jg   .done
    
    cmp  ebx, WM_TITLE_H + 5
    jl   .done
    cmp  ebx, WM_TITLE_H + 21
    jg   .done
    
    ; Clicked Go!
    call browser_fetch
    call wm_draw_all
    
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

    ; Resolve hostname via DNS
    mov  esi, browser_hostname
    call dns_resolve_hostname
    jc   .error                  ; CF=1 means DNS failed

    ; EAX = resolved IP
    mov  [tcpg_dst_ip], eax
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

; - browser_fetch -
browser_fetch:
    pusha

    ; 1. Set "Fetching..." message
    mov  edi, browser_content
    mov  esi, browser_s_fetching
    call .copy_str
    call wm_draw_all

    ; 2. Parse URL
    mov  esi, browser_url
    call browser_parse_url
    test eax, eax
    jz   .err_url
    ; IP now in tcpg_dst_ip, port in tcpg_dst_port, path ptr set

    ; Connect
    mov  eax, [tcpg_dst_ip]
    movzx ecx, word [tcpg_dst_port]
    call tcp_connect
    jc   .err_conn

    ; Request - build HTTP GET with dynamic Host header
    mov  edi, tcpg_req_buf
    mov  byte [edi+0], 'G'
    mov  byte [edi+1], 'E'
    mov  byte [edi+2], 'T'
    mov  byte [edi+3], ' '
    add  edi, 4
    mov  esi, [tcpg_path_ptr]
.copy_p:
    lodsb
    stosb
    test al, al
    jnz  .copy_p
    dec  edi                ; overwrite null with space

    mov  esi, tcpg_str_http10
    call .append_s

    ; Host header
    mov  esi, tcpg_str_host
    call .append_s
    mov  esi, browser_hostname
    call .append_s
    mov  byte [edi], 13
    inc  edi
    mov  byte [edi], 10
    inc  edi

    mov  esi, tcpg_str_connclose
    call .append_s
    mov  byte [edi], 0
    
    mov  ecx, edi
    sub  ecx, tcpg_req_buf
    mov  esi, tcpg_req_buf
    call tcp_send
    jc   .err_send
    
    ; Receive into browser_content
    mov  dword [tcpg_total], 0
    mov  edi, browser_content
    xor  eax, eax
    mov  ecx, 4096
    rep  stosd              ; clear 16KB
    
    mov  edi, browser_content
.recv_loop:
    ; Progress feedback: draw simple dot or status bit
    ; (Could do more but let's keep it simple for now)
    
    cmp  byte [tcp_state], TCP_STATE_ESTABLISHED
    je   .do_recv
    cmp  byte [tcp_state], TCP_STATE_CLOSE_WAIT
    je   .do_recv
    jmp  .recv_done

.do_recv:
    mov  ecx, 1400
    push edi
    mov  edi, tcpg_recv_buf
    call tcp_recv
    pop  edi
    jc   .recv_done         ; error or timeout
    test ecx, ecx
    jz   .recv_done         ; EOF
    
    ; Safety check: don't overflow browser_content (16KB)
    mov  eax, edi
    sub  eax, browser_content
    add  eax, ecx
    cmp  eax, 16000
    jae  .recv_done         ; stop if near limit
    
    ; Copy from tcpg_recv_buf to browser_content
    push ecx
    mov  esi, tcpg_recv_buf
.copy_data:
    lodsb
    ; Optional: strip non-printable or handle line endings here
    mov  [edi], al
    inc  edi
    dec  ecx
    jnz  .copy_data
    pop  ecx
    
    ; [NEW] Brief progress update: redraw browser content while fetching
    ; This helps show it's not "dead" even if it's blocking
    mov  byte [edi], 0      ; null term for draw
    push edi
    call wm_draw_all
    pop  edi
    
    jmp  .recv_loop

.recv_done:
    mov  byte [edi], 0      ; Final null terminator before stripping
    call tcp_close

    ; Strip HTTP headers to show only body content
    mov  esi, browser_content
    mov  edi, browser_content
    call browser_strip_headers

    jmp  .done

.err_url:
    mov  esi, browser_s_err_url
    jmp  .set_msg
.err_conn:
    mov  esi, browser_s_err_conn
    jmp  .set_msg
.err_send:
    mov  esi, browser_s_err_send
.set_msg:
    mov  edi, browser_content
    call .copy_str
.done:
    popa
    ret

.copy_str:
    lodsb
    stosb
    test al, al
    jnz  .copy_str
    ret

.append_s:
    lodsb
    stosb
    test al, al
    jnz  .append_s
    dec  edi                ; keep edi at null
    ret

; - Data -
browser_url:     times 256 db 0
browser_content: times 16384 db 0
browser_s_go:    db 'Go', 0
browser_s_default_url: db '142.250.180.142 80 /', 0
browser_s_hdr_host:    db 'Host: google.com', 13, 10, 0
browser_s_welcome: db 'Welcome to NatureOS Browser!', 13, 10, 'Usage: http://hostname/path or IP PORT PATH', 0
browser_s_fetching: db 'Fetching...', 0
browser_s_err_url:  db 'Error: Invalid URL format.', 0
browser_s_err_conn: db 'Error: Connection failed.', 0
browser_s_err_send: db 'Error: Send failed.', 0

; Missing data symbols referenced by browser_parse_url / dns_resolve_hostname / browser_fetch
browser_hostname:   times 256 db 0     ; buffer for parsed hostname (null-terminated)
http_prefix:        db 'http://', 0    ; URL scheme prefix to detect and strip
browser_s_def_path: db '/', 0          ; default path when URL has no explicit path
dns_tmp_hostname:   dd 0               ; pointer to hostname being resolved