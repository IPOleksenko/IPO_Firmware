; INT 10h video services (Mode 03h 80x25 VGA text, with COM1 teletype mirroring)

BITS 16

int10h_handler:
    sti
    push    ds
    push    ax
    xor     ax, ax
    mov     ds, ax
    cmp     byte [ds:SCRATCH_VIDEO_ROM_ACTIVE], 1
    pop     ax
    pop     ds
    jne     .native_int10

    ; Option ROM active: mirror AH=0Eh teletype to COM1 before forwarding to INT 42h
    cmp     ah, 0x0E
    jne     .call_video_rom

    cmp     al, 10
    jne     .v_tx
    push    ax
    mov     al, 13
    call    serial_tx_char
    mov     ah, 0x0E
    int     0x42
    pop     ax
.v_tx:
    push    ax
    call    serial_tx_char
    pop     ax

.call_video_rom:
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

    jmp     .done

; AH=0Eh: teletype output (AL=char)
.fn_teletype:
    ; Mirror to COM1 (CR before LF)
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

    mov     cl, al

    xor     bx, bx
    mov     es, bx
    mov     dx, [es:0x0450]                 ; DH=row (0..24), DL=col (0..79)

    cmp     cl, 0x0D
    je      .tt_cr
    cmp     cl, 0x0A
    je      .tt_lf
    cmp     cl, 0x08
    je      .tt_bs

    push    es
    push    dx
    xor     bx, bx
    mov     es, bx
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_write

    mov     bx, VGA_TEXT_SEG
    mov     es, bx

    ; Byte offset = (row * 80 + col) * 2
    movzx   ax, dh
    shl     ax, 4
    mov     di, ax
    shl     ax, 2
    add     di, ax
    movzx   ax, dl
    add     di, ax
    shl     di, 1

    mov     al, cl
    mov     ah, 0x07                        ; light gray on black
    stosw

.skip_vga_write:
    pop     dx
    pop     es

    inc     dl
    cmp     dl, 80
    jb      .tt_save_cursor

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

    call    vga_scroll_up
    mov     dh, 24

.tt_save_cursor:
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0450], dx
    call    update_hw_cursor
    jmp     .done

; AH=00h: set video mode (Mode 03h 80x25 text)
.fn_set_mode:
    call    vga_hardware_init
    call    vga_clear_screen

    xor     bx, bx
    mov     es, bx
    mov     byte [es:0x0449], 0x03          ; mode 03h
    mov     word [es:0x044A], 80            ; columns
    mov     word [es:0x044C], 4096          ; page size
    mov     word [es:0x044E], 0             ; page offset
    mov     word [es:0x0450], 0             ; cursor (0, 0)
    mov     byte [es:0x0462], 0             ; active page
    mov     word [es:0x0463], CRT_ADDR_PORT ; CRTC base
    mov     byte [es:0x0484], 24            ; rows - 1
    mov     word [es:0x0485], 16            ; char height
    mov     byte [es:0x0487], 0x60          ; EGA/VGA active, 256 KiB VRAM
    mov     byte [es:0x0488], 0xF9          ; EGA feature switches
    mov     byte [es:0x0489], 0x51          ; video mode options

    xor     dx, dx
    call    update_hw_cursor
    jmp     .done

; AH=01h: set cursor shape (CH=start scan + bit 5 hide, CL=end scan)
.fn_set_cursor_shape:
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0460], cx

    mov     dx, CRT_ADDR_PORT
    mov     al, 0x0A                        ; cursor start / hide bit
    out     dx, al
    inc     dx
    mov     al, ch
    out     dx, al

    dec     dx
    mov     al, 0x0B                        ; cursor end
    out     dx, al
    inc     dx
    mov     al, cl
    out     dx, al
    jmp     .done

; AH=02h: set cursor position (DH=row, DL=col)
.fn_set_cursor_pos:
    xor     bx, bx
    mov     es, bx
    mov     [es:0x0450], dx
    call    update_hw_cursor
    jmp     .done

; AH=03h: get cursor position/shape -> DH=row, DL=col, CH=start, CL=end
.fn_get_cursor_pos:
    xor     bx, bx
    mov     es, bx
    mov     dx, [es:0x0450]
    mov     cx, [es:0x0460]

    ; Stack layout: [bp+0]=ax, [bp+2]=bx, [bp+4]=cx, [bp+6]=dx
    mov     bp, sp
    mov     [bp + 4], cx
    mov     [bp + 6], dx
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

; DX = (row << 8) | col
update_hw_cursor:
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
    add     bx, ax                          ; cell index (0..1999)
    mov     dx, CRT_ADDR_PORT

    mov     al, 0x0E                        ; cursor location high
    out     dx, al
    inc     dx
    mov     al, bh
    out     dx, al

    dec     dx
    mov     al, 0x0F                        ; cursor location low
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
    mov     ax, 0x0720
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

    ; Scroll rows 2..24 -> 1..23 to preserve row 0 header
    mov     di, 160
    mov     si, 320
    mov     cx, 80 * 23
    cld
    rep     movsw

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

; Draw startup header on row 0
fw_render_header:
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

    mov     ax, VGA_TEXT_SEG
    mov     es, ax

    ; Row 0 col 0, light green on black (0x0A)
    xor     di, di
    mov     si, fw_str_title
    mov     ah, 0x0A
.loop_title:
    lodsb
    test    al, al
    jz      .title_done
    stosw
    jmp     .loop_title
.title_done:

    ; Row 0 col 66 (byte offset 132)
    mov     di, 132
    mov     si, fw_str_author
    mov     ah, 0x0A
.loop_author:
    lodsb
    test    al, al
    jz      .author_done
    stosw
    jmp     .loop_author
.author_done:

    ; Place initial log cursor at row 2, col 0
    xor     ax, ax
    mov     es, ax
    mov     dx, 0x0200
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

fw_str_title  db "IPO_Firmware", 0
fw_str_author db "by IPOleksenko", 0

; Program VGA Mode 03h (80x25 text): Sequencer, CRTC, GC, AC, DAC, and 8x16 font
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

    ; Misc Output: 28 MHz clock, color CRTC (0x3D4), RAM decode enabled
    mov     dx, 0x03C2
    mov     al, 0x67
    out     dx, al

    ; Sequencer (0x3C4/0x3C5)
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

    ; Unlock CRTC regs 0..7 (clear reg 0x11 bit 7)
    mov     dx, CRT_ADDR_PORT
    mov     al, 0x11
    out     dx, al
    inc     dx
    in      al, dx
    and     al, 0x7F
    out     dx, al
    dec     dx

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

    ; Graphics Controller (0x3CE/0x3CF)
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

    ; Map Plane 2 at 0xA0000 to load 8x16 font
    mov     dx, 0x03C4
    mov     ax, 0x0100                      ; sync reset
    out     dx, ax
    mov     ax, 0x0402                      ; Plane 2 write enable
    out     dx, ax
    mov     ax, 0x0704                      ; sequential addressing
    out     dx, ax
    mov     ax, 0x0300                      ; clear reset
    out     dx, ax

    mov     dx, 0x03CE
    mov     ax, 0x0005                      ; write mode 0
    out     dx, ax
    mov     ax, 0x0406                      ; 64 KiB window at 0xA0000
    out     dx, ax

    ; Plane 2 uses a 32 B stride per glyph (16 B glyph + 16 B pad)
    mov     ax, 0xA000
    mov     es, ax
    xor     di, di
    mov     si, vga_font_data
    mov     cx, 256
.loop_font:
    push    cx
    mov     cx, 8
    rep     movsw
    add     di, 16
    pop     cx
    loop    .loop_font

    ; Restore Sequencer and GC for odd/even text mode at 0xB8000
    mov     dx, 0x03C4
    mov     ax, 0x0100
    out     dx, ax
    mov     ax, 0x0302                      ; Planes 0 & 1
    out     dx, ax
    mov     ax, 0x0304                      ; odd/even
    out     dx, ax
    mov     ax, 0x0300
    out     dx, ax

    mov     dx, 0x03CE
    mov     ax, 0x1005                      ; odd/even
    out     dx, ax
    mov     ax, 0x0E06                      ; map at 0xB8000
    out     dx, ax

    ; Reset Attribute Controller flip-flop before programming 0x3C0
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

    ; Load 256-entry DAC palette
    mov     dx, 0x03C8
    xor     al, al
    out     dx, al
    inc     dx
    mov     si, vga_dac_data
    mov     cx, 256 * 3
.loop_dac:
    lodsb
    out     dx, al
    loop    .loop_dac

    ; Enable video output (PAS bit 5)
    mov     dx, 0x03DA
    in      al, dx
    mov     dx, 0x03C0
    mov     al, 0x20
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

; Mode 03h register tables
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
