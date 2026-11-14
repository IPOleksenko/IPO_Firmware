; kbd.asm — 8042 PS/2 Controller Initialization
; Configures Scan Code Set 2 -> Set 1 Translation (Bit 6 = 1)
; and enables keyboard and auxiliary ports.

BITS 16

ps2_controller_init:
    push    ax
    push    bx
    push    cx

    ; Drain output buffer
    mov     cx, 1000
.drain1:
    in      al, 0x64
    test    al, 0x01                        ; Output buffer full?
    jz      .drained1
    in      al, 0x60                        ; Read and discard
    loop    .drain1
.drained1:

    ; Read Controller Configuration Byte (Command 0x20)
    call    ps2_wait_write
    mov     al, 0x20
    out     0x64, al

    call    ps2_wait_read
    in      al, 0x60                        ; AL = config byte

    ; Enable Translation (Bit 6 = 1) and Keyboard Clock (Bit 4 = 0)
    ; Controller setting: bit 6 (XLAT)=1, bit 0 (KBD IRQ)=1, bit 4 (KBD CLK)=0
    or      al, 0x41                        ; Bit 6 = 1 (XLAT), Bit 0 = 1 (KBD INT)
    and     al, ~0x10                       ; Bit 4 = 0 (Enable KBD Clock)
    mov     bl, al

    ; Write Controller Configuration Byte (Command 0x60)
    call    ps2_wait_write
    mov     al, 0x60
    out     0x64, al

    call    ps2_wait_write
    mov     al, bl
    out     0x60, al

    ; Enable Keyboard Interface (Command 0xAE)
    call    ps2_wait_write
    mov     al, 0xAE
    out     0x64, al

    ; Drain any remaining bytes
    mov     cx, 1000
.drain2:
    in      al, 0x64
    test    al, 0x01
    jz      .done
    in      al, 0x60
    loop    .drain2

.done:
    pop     cx
    pop     bx
    pop     ax
    ret

; Wait until input buffer is empty (bit 1 of port 0x64 == 0)
ps2_wait_write:
    push    cx
    mov     cx, 0xFFFF
.wait_w:
    in      al, 0x64
    test    al, 0x02
    jz      .w_done
    loop    .wait_w
.w_done:
    pop     cx
    ret

; Wait until output buffer is full (bit 0 of port 0x64 == 1)
ps2_wait_read:
    push    cx
    mov     cx, 10000
.wait_r:
    in      al, 0x64
    test    al, 0x01
    jnz     .r_done
    loop    .wait_r
.r_done:
    pop     cx
    ret

; IRQ 1 (INT 09h): read scancode from port 0x60, buffer keystroke, and send EOI
int09h_keyboard_handler:
    push    ds
    push    ax
    push    bx
    push    si

    xor     ax, ax
    mov     ds, ax

    in      al, 0x60

    cmp     al, 0xE0
    je      .kbd_eoi

    cmp     al, 0x2A
    jne     .chk_rshift_make
    or      byte [ds:0x0417], 0x02
    jmp     .kbd_eoi
.chk_rshift_make:
    cmp     al, 0x36
    jne     .chk_lshift_brk
    or      byte [ds:0x0417], 0x01
    jmp     .kbd_eoi
.chk_lshift_brk:
    cmp     al, 0xAA
    jne     .chk_rshift_brk
    and     byte [ds:0x0417], ~0x02
    jmp     .kbd_eoi
.chk_rshift_brk:
    cmp     al, 0xB6
    jne     .chk_break
    and     byte [ds:0x0417], ~0x01
    jmp     .kbd_eoi

.chk_break:
    test    al, 0x80
    jnz     .kbd_eoi

    mov     ah, al
    cmp     al, 0x39
    ja      .non_ascii
    movzx   bx, al
    test    byte [ds:0x0417], 0x03
    jnz     .use_shifted
    mov     al, [cs:kbd_scancode_unshifted + bx]
    jmp     .store_key
.use_shifted:
    mov     al, [cs:kbd_scancode_shifted + bx]
    jmp     .store_key
.non_ascii:
    xor     al, al

.store_key:
    mov     si, [ds:0x041C]
    mov     bx, si
    add     bx, 2
    cmp     bx, [ds:0x0482]
    jb      .wrap_ok
    mov     bx, [ds:0x0480]
.wrap_ok:
    cmp     bx, [ds:0x041A]
    je      .kbd_eoi

    mov     [ds:0x0400 + si], ax
    mov     [ds:0x041C], bx

.kbd_eoi:
    mov     al, 0x20
    out     0x20, al

    pop     si
    pop     bx
    pop     ax
    pop     ds
    iret

kbd_scancode_unshifted:
    db 0, 27, '1','2','3','4','5','6','7','8','9','0','-','=', 8, 9
    db 'q','w','e','r','t','y','u','i','o','p','[',']', 13, 0, 'a','s'
    db 'd','f','g','h','j','k','l',';',"'",'`', 0, '\','z','x','c','v'
    db 'b','n','m',',','.','/', 0, '*', 0, ' '

kbd_scancode_shifted:
    db 0, 27, '!','@','#','$','%','^','&','*','(',')','_','+', 8, 9
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}', 13, 0, 'A','S'
    db 'D','F','G','H','J','K','L',':','"','~', 0, '|','Z','X','C','V'
    db 'B','N','M','<','>','?', 0, '*', 0, ' '

; INT 16h: BIOS Keyboard Services
int16h_handler:
    sti
    cmp     ah, 0x00
    je      .fn_read_key
    cmp     ah, 0x10
    je      .fn_read_key
    cmp     ah, 0x01
    je      .fn_check_key
    cmp     ah, 0x11
    je      .fn_check_key
    cmp     ah, 0x02
    je      .fn_get_shift
    iret

.fn_read_key:
    push    ds
    push    si
    push    bx
    xor     bx, bx
    mov     ds, bx
.wait_key:
    mov     si, [ds:0x041A]
    cmp     si, [ds:0x041C]
    jne     .consume_key
    hlt
    jmp     .wait_key

.consume_key:
    mov     ax, [ds:0x0400 + si]
    add     si, 2
    cmp     si, [ds:0x0482]
    jb      .head_ok
    mov     si, [ds:0x0480]
.head_ok:
    mov     [ds:0x041A], si
    pop     bx
    pop     si
    pop     ds
    iret

.fn_check_key:
    push    ds
    push    si
    push    bp
    mov     bp, sp
    xor     si, si
    mov     ds, si
    mov     si, [ds:0x041A]
    cmp     si, [ds:0x041C]
    jne     .key_ready

    or      byte [bp + 10], 0x40
    xor     ax, ax
    pop     bp
    pop     si
    pop     ds
    iret

.key_ready:
    and     byte [bp + 10], ~0x40
    mov     ax, [ds:0x0400 + si]
    pop     bp
    pop     si
    pop     ds
    iret

.fn_get_shift:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     al, [ds:0x0417]
    pop     ds
    iret
