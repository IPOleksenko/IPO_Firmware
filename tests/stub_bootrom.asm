; stub_bootrom.asm — Self-contained minimal Boot ROM for standalone Firmware testing
; Does not depend on external Boot ROM project sources


BITS 16
ORG 0xF800

stub_rom_start:
    cli
    cld

    ; Setup stack
    xor     ax, ax
    mov     ss, ax
    mov     sp, 0x7000

    ; Copy 32KB from ROM 0xF000:0000 to RAM 0x0800:0000
    mov     ax, 0xF000
    mov     ds, ax
    xor     si, si

    mov     ax, 0x0800
    mov     es, ax
    xor     di, di

    mov     cx, 16384
    rep     movsw

    ; Contract 2 handover
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7000
    cli

    jmp     0x0800:0x0004

; Reset vector at F000:FFF0 (offset 0x7F0 from 0xF800)
times 0x7F0 - ($ - $$) db 0xFF

reset_vector:
    jmp     0xF000:0xF800
    times 16 - ($ - reset_vector) db 0x90

