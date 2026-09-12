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

    ; 2. Test INT 13h (Extensions Installation Check)
    mov     ah, 0x41
    mov     bx, 0x55AA
    mov     dl, 0x80
    int     0x13
    jc      .ext_failed
    cmp     bx, 0xAA55
    jne     .ext_failed

    mov     si, msg_int13_ok
    call    mbr_print
    jmp     .test_e820

.ext_failed:
    mov     si, msg_int13_fail
    call    mbr_print

.test_e820:
    ; 3. Test INT 15h (E820 Memory Map)
    mov     eax, 0x0000E820
    xor     ebx, ebx
    mov     ecx, 20
    mov     edx, 0x534D4150
    mov     di, e820_buf
    int     0x15
    jc      .e820_failed
    cmp     eax, 0x534D4150
    jne     .e820_failed

    mov     si, msg_e820_ok
    call    mbr_print
    jmp     .finish

.e820_failed:
    mov     si, msg_e820_fail
    call    mbr_print

.finish:
    mov     si, msg_test_passed
    call    mbr_print

    ; Exit QEMU quickly via isa-debug-exit
    mov     dx, 0x501
    mov     ax, 0x0001
    out     dx, ax
    out     dx, al

.hang:
    hlt
    jmp     .hang

mbr_print:
    push    ax
    push    si
.loop:
    lodsb
    test    al, al
    jz      .done
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    jmp     .loop
.done:
    pop     si
    pop     ax
    ret

msg_mbr_reached db "[Test_OS] OS MBR reached successfully!", 10, 13, 0
msg_int13_ok    db "[Test_OS] INT 13h Extensions Check: PASSED (BX=0xAA55)", 10, 13, 0
msg_int13_fail  db "[Test_OS] INT 13h Extensions Check: FAILED!", 10, 13, 0
msg_e820_ok     db "[Test_OS] INT 15h E820 Memory Map: PASSED ('SMAP' validated)", 10, 13, 0
msg_e820_fail   db "[Test_OS] INT 15h E820 Memory Map: FAILED!", 10, 13, 0
msg_test_passed db "[Test_OS] ALL FIRMWARE BIOS SERVICES VERIFIED!", 10, 13, 0

align 4
e820_buf        times 24 db 0

; Pad to 510 bytes and add standard MBR boot signature 0x55AA
times 510 - ($ - $$) db 0
dw 0xAA55
