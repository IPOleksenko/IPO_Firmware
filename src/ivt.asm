; ivt.asm — Interrupt Vector Table (IVT) and BDA Setup
; Populates all 256 interrupt vectors at 0x0000:0x0000

BITS 16

ivt_setup:
    push    es
    push    di
    push    cx
    push    ax

    ; 1. Point all 256 vectors to default_int_handler
    xor     ax, ax
    mov     es, ax
    xor     di, di

    mov     cx, 256
.loop_default:
    mov     word [es:di], default_int_handler   ; Offset
    mov     word [es:di+2], FW_RAM_SEG          ; Segment 0x0800
    add     di, 4
    loop    .loop_default

    ; 2. Register implemented BIOS Interrupt handlers
    ; INT 10h (Video Services) — Vector 0x10 * 4 = 0x0040
    mov     word [es:0x0040], int10h_handler
    mov     word [es:0x0042], FW_RAM_SEG

    ; INT 13h (Disk Services) — Vector 0x13 * 4 = 0x004C
    mov     word [es:0x004C], int13h_handler
    mov     word [es:0x004E], FW_RAM_SEG

    ; INT 15h (System Services) — Vector 0x15 * 4 = 0x0054
    mov     word [es:0x0054], int15h_handler
    mov     word [es:0x0056], FW_RAM_SEG

    ; INT 16h (Keyboard Services) — Vector 0x16 * 4 = 0x0058
    mov     word [es:0x0058], int16h_handler
    mov     word [es:0x005A], FW_RAM_SEG

    ; 3. Setup standard BDA (BIOS Data Area) at 0x0040:0x0000 (0x0400)
    mov     word [es:0x0410], 0x0021            ; Equipment word (color 80x25, 1 floppy)
    mov     word [es:0x0413], 640               ; Base memory = 640 KB (0x0280)

    pop     ax
    pop     cx
    pop     di
    pop     es
    ret

; Default unhandled interrupt: clean return
default_int_handler:
    iret

; Minimal INT 16h stub
int16h_handler:
    ; AH=00h (read key): return space (0x20)
    ; AH=01h (check key): ZF=1 (no key available)
    cmp     ah, 0x01
    jne     .key_done
    ; Set ZF=1 to indicate no key
    push    bp
    mov     bp, sp
    or      byte [bp+6], 0x40                   ; Set ZF in caller FLAGS
    pop     bp
.key_done:
    iret

