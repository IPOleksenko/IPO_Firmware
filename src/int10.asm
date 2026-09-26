; int10.asm — BIOS Video Services (INT 10h) implementation
; Supports 80x25 16-color VGA text mode (Mode 03h)

BITS 16

int10h_handler:
    sti
    push    ds
    push    ax
    xor     ax, ax
    mov     ds, ax
    cmp     byte [ds:SCRATCH_VBIOS_ACTIVE], 1
    pop     ax
    pop     ds
    jne     .native_int10

    ; VBIOS is active: mirror AH=0x0E (Teletype) to serial COM1
    cmp     ah, 0x0E
    jne     .call_vbios

    cmp     al, 10
    jne     .v_tx
    push    ax
    mov     al, 13
    call    serial_tx_char
    pop     ax
.v_tx:
    push    ax
    call    serial_tx_char
    pop     ax

.call_vbios:
    int     0x42
    iret

.native_int10:
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
    mov     bx, cs
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
    ; Mirror character to COM1 serial for debugging (send CR before LF)
    cmp     al, 10
    jne     .tt_tx
    push    ax
    mov     al, 13
    call    serial_tx_char
    pop     ax
.tt_tx:
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

    ; Normal printable character: write to VGA text buffer (0xB800) if VGA present
    push    es
    push    dx
    xor     bx, bx
    mov     es, bx
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_write

    mov     bx, VGA_TEXT_SEG
    mov     es, bx                          ; ES = 0xB800

    ; Offset = (row * 80 + col) * 2
    movzx   ax, dh                          ; AX = row (0..24)
    shl     ax, 4                           ; AX = row * 16
    mov     di, ax
    shl     ax, 2                           ; AX = row * 64
    add     di, ax                          ; DI = row * 80
    movzx   ax, dl                          ; AX = col (0..79)
    add     di, ax                          ; DI = row * 80 + col
    shl     di, 1                           ; DI = buffer byte offset

    ; Character attribute: default to light gray on black (0x07)
    mov     al, cl                          ; Character saved in CL
    mov     ah, 0x07
    stosw

.skip_vga_write:
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
    xor     dl, dl
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
    call    vga_hardware_init
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
    mov     byte [es:0x0487], 0x60          ; EGA/VGA active, 256KB video RAM
    mov     byte [es:0x0488], 0xF9          ; EGA feature switches
    mov     byte [es:0x0489], 0x51          ; Video mode options

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
    ; Stack layout: [esp+0]=ax, [esp+2]=bx, [esp+4]=cx, [esp+6]=dx
    mov     [esp + 4], cx                   ; Return CX (start/end scan line)
    mov     [esp + 6], dx                   ; Return DX (row/column)
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
    push    es

    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .cursor_done

    movzx   ax, dh
    shl     ax, 4
    mov     bx, ax
    shl     ax, 2
    add     bx, ax
    movzx   ax, dl
    add     bx, ax                          ; BX = linear character index (0..1999)
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

.cursor_done:
    pop     es
    pop     dx
    pop     bx
    pop     ax
    ret

vga_clear_screen:
    push    es
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    pop     es
    jne     .vga_clr_done

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
.vga_clr_done:
    ret

vga_scroll_up:
    push    es
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    pop     es
    jne     .vga_scroll_done

    push    ds
    push    es
    push    si
    push    di
    push    cx
    push    ax

    mov     ax, VGA_TEXT_SEG
    mov     ds, ax
    mov     es, ax

    ; Move lines 2..24 to lines 1..23 (80 * 23 words = 1840 words, preserving Row 0 header)
    mov     di, 160                         ; Destination: row 1
    mov     si, 320                         ; Source: row 2
    mov     cx, 80 * 23
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
.vga_scroll_done:
    ret

; =============================================================================
; Render BIOS Startup Header (Row 0: IPO_Firmware ... by IPOleksenko)
; =============================================================================
bios_render_header:
    push    es
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    pop     es
    jne     .header_skip

    push    es
    push    si
    push    di
    push    ax
    push    cx
    push    dx

    ; Point ES to VGA text segment (0xB800)
    mov     ax, VGA_TEXT_SEG
    mov     es, ax

    ; 1. Row 0 Left (col 0): "IPO_Firmware" (attribute 0x0A: Light Green on Black)
    xor     di, di
    mov     si, bios_str_title
    mov     ah, 0x0A
.loop_title:
    lodsb
    test    al, al
    jz      .title_done
    stosw
    jmp     .loop_title
.title_done:

    ; 2. Row 0 Right (col 66): "by IPOleksenko" (attribute 0x0A)
    ; Col 66 * 2 = 132 byte offset
    mov     di, 132
    mov     si, bios_str_author
    mov     ah, 0x0A
.loop_author:
    lodsb
    test    al, al
    jz      .author_done
    stosw
    jmp     .loop_author
.author_done:

    ; Set initial cursor position in BDA to Row 2, Col 0 (start of log output)
    xor     ax, ax
    mov     es, ax
    mov     dx, 0x0200                      ; DH = 2 (row), DL = 0 (col)
    mov     [es:0x0450], dx
    call    update_hw_cursor

    pop     dx
    pop     cx
    pop     ax
    pop     di
    pop     si
    pop     es
.header_skip:
    ret

bios_str_title  db "IPO_Firmware", 0
bios_str_author db "by IPOleksenko", 0

; =============================================================================
; VGA Hardware Initialization (Mode 03h: 80x25 text console)
; Programs Sequencer, CRTC, GC, AC, DAC, loads 8x16 font, and enables display.
; =============================================================================
vga_hardware_init:
    push    es
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    pop     es
    jne     .vga_hw_done

    push    es
    push    ds
    push    si
    push    di
    push    cx
    push    dx
    push    ax

    mov     ax, cs
    mov     ds, ax

    ; 1. Misc Output Register (Port 0x3C2)
    mov     dx, 0x03C2
    mov     al, 0x67                        ; 28MHz, color mode (0x3D4), enable RAM
    out     dx, al

    ; 2. Sequencer Registers (Port 0x3C4 / 0x3C5)
    mov     dx, 0x03C4
    mov     si, vga_seq_data
    mov     cx, 5
    xor     ah, ah
.loop_seq:
    mov     al, ah
    out     dx, al
    inc     dx
    lodsb
    out     dx, al
    dec     dx
    inc     ah
    loop    .loop_seq

    ; 3. CRTC: Unlock CRTC registers 0..7 (clear bit 7 of reg 0x11)
    mov     dx, CRT_ADDR_PORT               ; 0x3D4
    mov     al, 0x11
    out     dx, al
    inc     dx
    in      al, dx
    and     al, 0x7F
    out     dx, al
    dec     dx

    ; Write all 25 CRTC registers (Port 0x3D4 / 0x3D5)
    mov     si, vga_crtc_data
    mov     cx, 25
    xor     ah, ah
.loop_crtc:
    mov     al, ah
    out     dx, al
    inc     dx
    lodsb
    out     dx, al
    dec     dx
    inc     ah
    loop    .loop_crtc

    ; 4. Graphics Controller Registers (Port 0x3CE / 0x3CF)
    mov     dx, 0x03CE
    mov     si, vga_gc_data
    mov     cx, 9
    xor     ah, ah
.loop_gc:
    mov     al, ah
    out     dx, al
    inc     dx
    lodsb
    out     dx, al
    dec     dx
    inc     ah
    loop    .loop_gc

    ; 5. Load 8x16 Font into Plane 2 (0xA0000)
    ; Switch Sequencer to Plane 2 access
    mov     dx, 0x03C4
    mov     ax, 0x0100                      ; Synchronous reset
    out     dx, ax
    mov     ax, 0x0402                      ; Plane 2 write enable (bit 2)
    out     dx, ax
    mov     ax, 0x0704                      ; Sequential addressing (disable odd/even)
    out     dx, ax
    mov     ax, 0x0300                      ; Clear reset
    out     dx, ax

    ; Switch GC to map memory at 0xA0000
    mov     dx, 0x03CE
    mov     ax, 0x0005                      ; Write mode 0
    out     dx, ax
    mov     ax, 0x0406                      ; Map memory to 0xA0000 (64KB)
    out     dx, ax

    ; Copy 256 characters * 16 bytes into ES:DI (0xA000:0x0000)
    ; Each character in Plane 2 takes 32 bytes (16 bytes glyph + 16 bytes pad)
    mov     ax, 0xA000
    mov     es, ax
    xor     di, di
    mov     si, vga_font_data
    mov     cx, 256
.loop_font:
    push    cx
    mov     cx, 8                           ; 8 words = 16 bytes
    rep     movsw
    add     di, 16                          ; Next character slot in 32-byte stride
    pop     cx
    loop    .loop_font

    ; Restore Sequencer to normal text mode (Planes 0 & 1, odd/even enabled)
    mov     dx, 0x03C4
    mov     ax, 0x0100
    out     dx, ax
    mov     ax, 0x0302                      ; Planes 0 & 1 enable
    out     dx, ax
    mov     ax, 0x0304                      ; Odd/even mode enable
    out     dx, ax
    mov     ax, 0x0300
    out     dx, ax

    ; Restore GC to normal text mode (0xB8000)
    mov     dx, 0x03CE
    mov     ax, 0x1005                      ; Odd/even mode
    out     dx, ax
    mov     ax, 0x0E06                      ; Map memory to 0xB8000
    out     dx, ax

    ; 6. Attribute Controller Registers (Port 0x3C0)
    ; Reset flip-flop by reading 0x3DA
    mov     dx, 0x03DA
    in      al, dx

    mov     dx, 0x03C0
    mov     si, vga_ac_data
    mov     cx, 21
    xor     ah, ah
.loop_ac:
    mov     al, ah
    out     dx, al
    lodsb
    out     dx, al
    inc     ah
    loop    .loop_ac

    ; 7. Initialize DAC Palette (256 standard VGA colors)
    mov     dx, 0x03C8
    xor     al, al
    out     dx, al                          ; Start at color index 0
    inc     dx                              ; Port 0x03C9 (DAC Data)
    mov     si, vga_dac_data
    mov     cx, 256 * 3
.loop_dac:
    lodsb
    out     dx, al
    loop    .loop_dac

    ; 8. Enable Video Output (PAS bit in Attribute Controller)
    mov     dx, 0x03DA
    in      al, dx                          ; Reset flip-flop
    mov     dx, 0x03C0
    mov     al, 0x20                        ; Bit 5 = 1 (Enable Video / Palette Access Source)
    out     dx, al

    pop     ax
    pop     dx
    pop     cx
    pop     di
    pop     si
    pop     ds
    pop     es
.vga_hw_done:
    ret

; =============================================================================
; VGA Mode 03h Register Tables
; =============================================================================
vga_seq_data    db 0x03, 0x00, 0x03, 0x00, 0x02
vga_crtc_data   db 0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F
                db 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00
                db 0x9C, 0x8E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3
                db 0xFF
vga_gc_data     db 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x0F, 0xFF
vga_ac_data     db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
                db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
                db 0x0C, 0x00, 0x0F, 0x08, 0x00

align 4
vga_dac_data:
    incbin "src/vga_dac.bin"

align 4
vga_font_data:
    incbin "src/font8x16.bin"
