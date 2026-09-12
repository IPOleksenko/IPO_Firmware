; a20.asm — A20 Gate enablement via Fast A20 Gate (port 0x92)
; and 1MB wrap-around verification test

BITS 16

a20_enable:
    push    ds
    push    es
    push    ax

    ; 1. Check if A20 is already enabled
    call    a20_test
    test    ax, ax
    jnz     .a20_done

    ; 2. Attempt Fast A20 Gate via Port 0x92
    in      al, 0x92
    test    al, 0x02
    jnz     .check_after_set
    or      al, 0x02
    and     al, 0xFE                        ; Never set bit 0 (system reset!)
    out     0x92, al

.check_after_set:
    ; Small delay / loop waiting for A20 to settle
    mov     cx, 100
.wait_loop:
    call    a20_test
    test    ax, ax
    jnz     .a20_done
    loop    .wait_loop

.a20_done:
    pop     ax
    pop     es
    pop     ds
    ret

; -----------------------------------------------------------------------------
; a20_test — Checks if A20 line is enabled by testing memory wrap-around.
; Returns: AX = 1 if enabled, AX = 0 if disabled.
; -----------------------------------------------------------------------------
a20_test:
    push    cx
    push    si
    push    di

    xor     ax, ax
    mov     ds, ax                          ; DS = 0x0000 (phys 0x00000)
    mov     si, 0x0500                      ; DS:SI = 0x0000:0x0500 (phys 0x000500)

    mov     ax, 0xFFFF
    mov     es, ax                          ; ES = 0xFFFF
    mov     di, 0x0510                      ; ES:DI = 0xFFFF:0x0510 (phys 0x100500)

    ; Save original values
    mov     al, [ds:si]
    mov     ah, [es:di]

    ; Write test pattern
    mov     byte [ds:si], 0x00
    mov     byte [es:di], 0xFF

    ; If memory wrapped, byte [ds:si] will now be 0xFF
    cmp     byte [ds:si], 0xFF
    mov     cx, 0                           ; Assume disabled
    je      .restore

    mov     cx, 1                           ; Enabled!

.restore:
    ; Restore original values
    mov     [ds:si], al
    mov     [es:di], ah

    mov     ax, cx
    pop     di
    pop     si
    pop     cx
    ret
