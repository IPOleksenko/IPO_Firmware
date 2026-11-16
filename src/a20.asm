; A20 line enablement (Fast A20 port 0x92 with PS/2 controller fallback)

BITS 16

a20_enable:
    push    ds
    push    es
    push    ax
    push    cx

    call    a20_test
    test    ax, ax
    jnz     .a20_done

    ; Try Fast A20 gate (port 0x92)
    in      al, 0x92
    test    al, 0x02
    jnz     .check_after_set
    or      al, 0x02
    and     al, 0xFE                        ; Keep bit 0 clear (system reset)
    out     0x92, al

.check_after_set:
    mov     cx, 100
.wait_loop:
    call    a20_test
    test    ax, ax
    jnz     .a20_done
    loop    .wait_loop

    ; Fallback: enable A20 through PS/2 controller output port (0xD1 -> 0xDF)
    call    ps2_wait_write
    mov     al, 0xD1                        ; Write output port
    out     0x64, al
    call    ps2_wait_write
    mov     al, 0xDF                        ; Set A20 gate (bit 1)
    out     0x60, al
    call    ps2_wait_write
    mov     al, 0xFF                        ; Pulse/null command to latch output port
    out     0x64, al
    call    ps2_wait_write

.a20_done:
    pop     cx
    pop     ax
    pop     es
    pop     ds
    ret

; Test A20 by checking whether 0x0000:0x0500 and 0xFFFF:0x0510 (1 MiB alias) wrap.
; Returns AX = 1 if enabled, 0 if disabled.
a20_test:
    push    cx
    push    si
    push    di

    xor     ax, ax
    mov     ds, ax
    mov     si, 0x0500                      ; Phys 0x000500

    mov     ax, 0xFFFF
    mov     es, ax
    mov     di, 0x0510                      ; Phys 0x100500

    mov     al, [ds:si]
    mov     ah, [es:di]

    mov     byte [ds:si], 0x00
    mov     byte [es:di], 0xFF

    ; Wrapped memory aliases 0x100500 onto 0x000500
    cmp     byte [ds:si], 0xFF
    mov     cx, 0
    je      .restore

    mov     cx, 1

.restore:
    mov     [ds:si], al
    mov     [es:di], ah

    mov     ax, cx
    pop     di
    pop     si
    pop     cx
    ret

