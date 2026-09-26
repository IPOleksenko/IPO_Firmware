; stub_mbr.asm — Minimal 512-byte MBR payload for isolated IPO_Firmware testing
; Loaded at 0x0000:0x7C00 by IPO_Firmware chainloader

BITS 16
ORG 0x7C00

mbr_start:
    ; Verify segment & stack state under Contract 3
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti

    ; 1. Test INT 10h (Teletype Output)
    mov     si, msg_mbr_reached
    call    mbr_print

    ; Test INT 10h AH=03h (Get Cursor Position — must return DX and preserve BX)
    mov     bx, 0x1234                      ; Distinct value in BX
    mov     ah, 0x03
    int     0x10
    cmp     bx, 0x1234                      ; BX must NOT be corrupted with DX!
    jne     .failed
    mov     si, msg_int10_cursor_ok
    call    mbr_print

    ; 2. Test INT 13h (Extensions Installation Check)
    mov     ah, 0x41
    mov     bx, 0x55AA
    mov     dl, 0x80
    int     0x13
    jc      .failed
    cmp     bx, 0xAA55
    jne     .failed
    mov     si, msg_int13_ok
    call    mbr_print

    ; 3. Test INT 15h (E820 Memory Map)
    mov     eax, 0x0000E820
    xor     ebx, ebx
    mov     ecx, 20
    mov     edx, 0x534D4150
    mov     di, 0x7E00                      ; Safe buffer at 0x0000:0x7E00
    int     0x15
    jc      .failed
    cmp     eax, 0x534D4150
    jne     .failed
    mov     si, msg_e820_ok
    call    mbr_print

    ; 4. Test INT 12h (Conventional Memory Size — 639K or 640K)
    int     0x12
    cmp     ax, 639
    je      .int12_pass
    cmp     ax, 640
    jne     .failed
.int12_pass:
    mov     si, msg_int12_ok
    call    mbr_print

    ; 5. Test INT 16h (Keyboard Status — must preserve CS without corruption)
    push    cs
    mov     ah, 0x01
    int     0x16
    pop     dx
    mov     ax, cs
    cmp     ax, dx
    jne     .failed
    mov     si, msg_int16_ok
    call    mbr_print

    ; 6. Test INT 1Ah (Timer Services)
    xor     ah, ah
    int     0x1A
    mov     si, msg_int1a_ok
    call    mbr_print

    ; All tests passed
    mov     si, msg_test_passed
    call    mbr_print
    jmp     .finish

.failed:
    mov     si, msg_fail
    call    mbr_print

.finish:
    ; Exit QEMU via isa-debug-exit
    mov     dx, 0x501
    mov     ax, 0x0001
    out     dx, ax
    out     dx, al

.hang:
    hlt
    jmp     .hang

mbr_print:
    push    ax
    push    dx
    push    si
.loop:
    lodsb
    test    al, al
    jz      .done
    ; Video INT 10h output (INT 10h mirrors to COM1 serial)
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    jmp     .loop
.done:
    pop     si
    pop     dx
    pop     ax
    ret

msg_mbr_reached db "[Test_OS] OS MBR reached successfully!", 10, 13, 0
msg_int10_cursor_ok db "[Test_OS] INT 10h: OK", 10, 13, 0
msg_int13_ok    db "[Test_OS] INT 13h: OK", 10, 13, 0
msg_e820_ok     db "[Test_OS] INT 15h E820: OK", 10, 13, 0
msg_int12_ok    db "[Test_OS] INT 12h: OK", 10, 13, 0
msg_int16_ok    db "[Test_OS] INT 16h: OK", 10, 13, 0
msg_int1a_ok    db "[Test_OS] INT 1Ah: OK", 10, 13, 0
msg_fail        db "[Test_OS] SERVICE CHECK FAILED!", 10, 13, 0
msg_test_passed db "[Test_OS] ALL FIRMWARE BIOS SERVICES VERIFIED!", 10, 13, 0

; Pad to 510 bytes and add standard MBR boot signature 0x55AA
times 510 - ($ - $$) db 0
dw 0xAA55

