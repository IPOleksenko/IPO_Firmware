; kbd.asm — 8042 PS/2 Controller Initialization
; Configures Scan Code Set 2 -> Set 1 Translation (Bit 6 = 1)
; and enables keyboard and auxiliary ports.

BITS 16

ps2_controller_init:
    push    ax
    push    bx
    push    cx

    ; 1. Drain output buffer
    mov     cx, 1000
.drain1:
    in      al, 0x64
    test    al, 0x01                        ; Output buffer full?
    jz      .drained1
    in      al, 0x60                        ; Read and discard
    loop    .drain1
.drained1:

    ; 2. Read Controller Configuration Byte (Command 0x20)
    call    ps2_wait_write
    mov     al, 0x20
    out     0x64, al

    call    ps2_wait_read
    in      al, 0x60                        ; AL = config byte

    ; 3. Enable Translation (Bit 6 = 1) and Keyboard Clock (Bit 4 = 0)
    ; Standard BIOS setting: bit 6 (XLAT)=1, bit 0 (KBD IRQ)=1, bit 4 (KBD CLK)=0
    or      al, 0x41                        ; Bit 6 = 1 (XLAT), Bit 0 = 1 (KBD INT)
    and     al, ~0x10                       ; Bit 4 = 0 (Enable KBD Clock)
    mov     bl, al

    ; 4. Write Controller Configuration Byte (Command 0x60)
    call    ps2_wait_write
    mov     al, 0x60
    out     0x64, al

    call    ps2_wait_write
    mov     al, bl
    out     0x60, al

    ; 5. Enable Keyboard Interface (Command 0xAE)
    call    ps2_wait_write
    mov     al, 0xAE
    out     0x64, al

    ; 6. Drain any remaining bytes
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
    mov     cx, 10000
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
