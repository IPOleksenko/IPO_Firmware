; int10.asm — BIOS Video Services (INT 10h) implementation
; Supports 80x25 16-color VGA text mode (Mode 03h)

BITS 16

int10h_handler:
    sti
    push    ds
    push    es
    push    bp
    push    si
    push    di
    push    dx
    push    cx
    push    bx
    push    ax

    ; Use Firmware data segment for local operations
    mov     bx, FW_RAM_SEG
    mov     ds, bx

    cmp     ah, 0x0E
    je      .fn_teletype
    cmp     ah, 0x00
    je      .fn_set_mode
    cmp     ah, 0x01
    je      .fn_set_cursor_shape
    cmp     ah, 0x02
    je      .fn_set_cursor_pos
    cmp     ah, 0x03
    je      .fn_get_cursor_pos

    ; Unsupported function — just return
    jmp     .done

; -----------------------------------------------------------------------------
; AH = 0x0E — Teletype Character Output
; Input: AL = ASCII char, BH = Page (ignored for page 0), BL = Color (attribute)
; -----------------------------------------------------------------------------
.fn_teletype:
    ; Mirror character to COM1 serial for debugging
    push    ax
    call    serial_tx_char
    pop     ax

    mov     cl, al                          ; Save character in CL

    ; Access BDA for cursor coordinates
    xor     bx, bx
    mov     es, bx                          ; ES = 0x0000 (BDA at 0x0400)
    mov     dx, [es:0x0450]                 ; DH = row (0..24), DL = col (0..79)

    cmp     cl, 0x0D                        ; Carriage return (\r)
    je      .tt_cr
    cmp     cl, 0x0A                        ; Line feed (\n)
    je      .tt_lf
    cmp     cl, 0x08                        ; Backspace (\b)
    je      .tt_bs

    ; Normal printable character: write to VGA text buffer (0xB800)
    push    es
    push    dx
    mov     bx, VGA_TEXT_SEG
    mov     es, bx                          ; ES = 0xB800

    ; Offset = (row * 80 + col) * 2
    movzx   ax, dh
    mov     bx, 80
    mul     bx
    movzx   bx, dl
    add     ax, bx
    shl     ax, 1
    mov     di, ax                          ; DI = buffer byte offset

    ; Character attribute: default to light gray on black (0x07)
    mov     al, cl                          ; Character saved in CL
    mov     ah, 0x07
    stosw
    pop     dx
    pop     es

    ; Advance column
    inc     dl
    cmp     dl, 80
    jb      .tt_save_cursor

    ; Wrap to next line
    xor     dl, dl
    inc     dh
    jmp     .tt_check_scroll

.tt_bs:
    test    dl, dl
    jz      .tt_save_cursor
    dec     dl
    jmp     .tt_save_cursor

.tt_cr:
    xor     dl, dl
    jmp     .tt_save_cursor

.tt_lf:
    inc     dh
.tt_check_scroll:
    cmp     dh, 25
    jb      .tt_save_cursor

    ; Screen scroll up by 1 line
    call    vga_scroll_up
    mov     dh, 24                          ; Keep cursor on last row

.tt_save_cursor:
    ; Save updated row/col back to BDA (0x0450)
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0450], dx

    ; Update hardware cursor position via CRT controller
    call    update_hw_cursor
    jmp     .done

; -----------------------------------------------------------------------------
; AH = 0x00 — Set Video Mode
; Input: AL = Video Mode (supports Mode 03h)
; -----------------------------------------------------------------------------
.fn_set_mode:
    call    vga_clear_screen

    ; Initialize BDA video fields
    xor     bx, bx
    mov     es, bx
    mov     byte [es:0x0449], 0x03          ; Video mode = 3 (80x25 text)
    mov     word [es:0x044A], 80            ; Columns = 80
    mov     word [es:0x044C], 4096          ; Video page size
    mov     word [es:0x044E], 0             ; Page offset = 0
    mov     word [es:0x0450], 0             ; Cursor pos = (0, 0)
    mov     byte [es:0x0462], 0             ; Active page = 0
    mov     word [es:0x0463], CRT_ADDR_PORT ; CRT base = 0x3D4
    mov     byte [es:0x0484], 24            ; Rows - 1 = 24
    mov     word [es:0x0485], 16            ; Char height = 16

    xor     dx, dx
    call    update_hw_cursor
    jmp     .done

; -----------------------------------------------------------------------------
; AH = 0x01 — Set Cursor Shape
; Input: CH = start scan line (bit 5 = 1 hides cursor), CL = end scan line
; -----------------------------------------------------------------------------
.fn_set_cursor_shape:
    ; Save to BDA 0x0460
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0460], cx

    ; Program CRT controller registers 0x0A and 0x0B
    mov     dx, CRT_ADDR_PORT
    mov     al, 0x0A
    out     dx, al
    inc     dx
    mov     al, ch
    out     dx, al                          ; Reg 0x0A: Cursor Start / Hide bit

    dec     dx
    mov     al, 0x0B
    out     dx, al
    inc     dx
    mov     al, cl
    out     dx, al                          ; Reg 0x0B: Cursor End
    jmp     .done

; -----------------------------------------------------------------------------
; AH = 0x02 — Set Cursor Position
; Input: BH = Page, DH = Row, DL = Column
; -----------------------------------------------------------------------------
.fn_set_cursor_pos:
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0450], dx
    call    update_hw_cursor
    jmp     .done

; -----------------------------------------------------------------------------
; AH = 0x03 — Get Cursor Position and Shape
; Input: BH = Page
; Output: DH = Row, DL = Column, CH = Start scan, CL = End scan
; -----------------------------------------------------------------------------
.fn_get_cursor_pos:
    xor     bx, bx
    mov     es, bx
    mov     dx, [es:0x0450]
    mov     cx, [es:0x0460]

    ; Store results in caller's saved registers on stack
    ; Stack layout: [bp+2]=bx, [bp+4]=cx, [bp+6]=dx, ...
    mov     [esp + 4], cx                   ; Return CX
    mov     [esp + 2], dx                   ; Return DX
    jmp     .done

.done:
    pop     ax
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    iret

; =============================================================================
; Helper Functions for Video Operations
; =============================================================================
update_hw_cursor:
    ; DX = (row << 8) | col
    push    ax
    push    bx
    push    dx

    movzx   ax, dh
    mov     bx, 80
    mul     bx
    movzx   bx, dl
    add     ax, bx                          ; AX = linear character index (0..1999)

    mov     bx, ax                          ; BX = index
    mov     dx, CRT_ADDR_PORT

    ; Cursor Location High Register (0x0E)
    mov     al, 0x0E
    out     dx, al
    inc     dx
    mov     al, bh
    out     dx, al

    ; Cursor Location Low Register (0x0F)
    dec     dx
    mov     al, 0x0F
    out     dx, al
    inc     dx
    mov     al, bl
    out     dx, al

    pop     dx
    pop     bx
    pop     ax
    ret

vga_clear_screen:
    push    es
    push    di
    push    cx
    push    ax

    mov     ax, VGA_TEXT_SEG
    mov     es, ax
    xor     di, di
    mov     cx, 80 * 25
    mov     ax, 0x0720                      ; Space (0x20) with attribute 0x07
    rep     stosw

    pop     ax
    pop     cx
    pop     di
    pop     es
    ret

vga_scroll_up:
    push    ds
    push    es
    push    si
    push    di
    push    cx
    push    ax

    mov     ax, VGA_TEXT_SEG
    mov     ds, ax
    mov     es, ax

    ; Move lines 1..24 to lines 0..23 (80 * 24 words = 1920 words)
    xor     di, di                          ; Destination: row 0
    mov     si, 160                         ; Source: row 1
    mov     cx, 80 * 24
    cld
    rep     movsw

    ; Clear row 24 with spaces
    mov     di, 80 * 24 * 2
    mov     cx, 80
    mov     ax, 0x0720
    rep     stosw

    pop     ax
    pop     cx
    pop     di
    pop     si
    pop     es
    pop     ds
    ret
