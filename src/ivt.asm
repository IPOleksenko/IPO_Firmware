; IVT/BDA setup, PIC/PIT programming, and INT 11h/12h/14h/17h/1Ah handlers

BITS 16

%include "boot_constants.inc"

ivt_setup:
    push    es
    push    di
    push    cx
    push    ax
    push    bx

    mov     bx, cs                          ; 0xF000 in shadow RAM

    ; Point all 256 vectors to default IRET stub
    xor     ax, ax
    mov     es, ax
    xor     di, di

    mov     cx, 256
.loop_default:
    mov     word [es:di], default_int_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_default

    ; Master PIC IRQs (INT 08h..0Fh -> IVT 0x0020..0x003C)
    mov     cx, 8
    mov     di, 0x0020
.loop_pic1:
    mov     word [es:di], pic1_default_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_pic1

    ; Slave PIC IRQs (INT 70h..77h -> IVT 0x01C0..0x01DC)
    mov     cx, 8
    mov     di, 0x01C0
.loop_pic2:
    mov     word [es:di], pic2_default_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_pic2

    ; IRQ 0 (timer) and IRQ 1 (PS/2 keyboard)
    mov     word [es:0x0020], int08h_timer_handler
    mov     word [es:0x0022], bx

    mov     word [es:0x0024], int09h_keyboard_handler
    mov     word [es:0x0026], bx

    ; Software service vectors
    mov     word [es:0x0040], int10h_handler    ; INT 10h video
    mov     word [es:0x0042], bx

    mov     word [es:0x0044], int11h_handler    ; INT 11h equipment
    mov     word [es:0x0046], bx

    mov     word [es:0x0048], int12h_handler    ; INT 12h base RAM
    mov     word [es:0x004A], bx

    mov     word [es:0x004C], int13h_handler    ; INT 13h disk
    mov     word [es:0x004E], bx

    mov     word [es:0x0050], int14h_handler    ; INT 14h serial
    mov     word [es:0x0052], bx

    mov     word [es:0x0054], int15h_handler    ; INT 15h system / E820
    mov     word [es:0x0056], bx

    mov     word [es:0x0058], int16h_handler    ; INT 16h keyboard
    mov     word [es:0x005A], bx

    mov     word [es:0x005C], int17h_handler    ; INT 17h printer
    mov     word [es:0x005E], bx

    mov     word [es:0x0068], int1Ah_handler    ; INT 1Ah RTC / ticks
    mov     word [es:0x006A], bx

    mov     word [es:0x0070], default_int_handler ; INT 1Ch timer hook
    mov     word [es:0x0072], bx

    ; Populate BDA at 0x0040:0x0000
    mov     word [es:0x0400], 0x03F8            ; COM1 base port
    mov     word [es:0x040E], 0x9FC0            ; EBDA segment
    mov     word [es:0x0410], 0x4223            ; Equipment word: 80x25 color, mouse, FPU, floppy
    mov     word [es:0x0413], 640               ; Base RAM = 640 KiB
    mov     byte [es:0x0417], 0                 ; Keyboard shift flags
    mov     word [es:0x041A], 0x001E            ; Kbd ring head
    mov     word [es:0x041C], 0x001E            ; Kbd ring tail
    mov     dword [es:0x046C], 0                ; Timer ticks
    mov     byte [es:0x0470], 0                 ; Midnight wrap flag
    mov     byte [es:0x0475], 1                 ; Hard disk count
    mov     word [es:0x0480], 0x001E            ; Kbd buffer start
    mov     word [es:0x0482], 0x003E            ; Kbd buffer end

    ; PIT channel 0: mode 3 square wave, 18.2 Hz (divisor 0 = 65536)
    mov     al, 0x36
    out     0x43, al
    xor     al, al
    out     0x40, al
    out     0x40, al

    ; Master/slave PIC cascade setup: master -> INT 08h-0Fh, slave -> INT 70h-77h
    mov     al, 0x11                            ; ICW1: edge, cascade, ICW4
    out     0x20, al
    out     0xA0, al
    mov     al, 0x08                            ; ICW2 master
    out     0x21, al
    mov     al, 0x70                            ; ICW2 slave
    out     0xA1, al
    mov     al, 0x04                            ; ICW3: slave on IRQ 2
    out     0x21, al
    mov     al, 0x02                            ; ICW3: cascade ID 2
    out     0xA1, al
    mov     al, 0x01                            ; ICW4: standard PC mode
    out     0x21, al
    out     0xA1, al

    ; Unmask IRQ 0 (timer), IRQ 1 (keyboard), IRQ 2 (cascade)
    mov     al, 0xF8
    out     0x21, al
    mov     al, 0xFF
    out     0xA1, al

    pop     bx
    pop     ax
    pop     cx
    pop     di
    pop     es
    ret

pic1_default_handler:
    push    ax
    mov     al, 0x20
    out     0x20, al
    pop     ax
    iret

pic2_default_handler:
    push    ax
    mov     al, 0x20
    out     0xA0, al                            ; Slave EOI first, then master
    out     0x20, al
    pop     ax
    iret

default_int_handler:
    iret

; IRQ 0 (INT 08h): increment 32-bit BDA tick count, handle 24 h wrap, call INT 1Ch
int08h_timer_handler:
    push    ds
    push    eax

    xor     ax, ax
    mov     ds, ax

    mov     eax, [ds:0x046C]
    inc     eax
    cmp     eax, 0x001800B0                     ; 1,573,040 ticks (~24 h at 18.2065 Hz)
    jb      .tick_stored
    xor     eax, eax
    mov     byte [ds:0x0470], 1                 ; Midnight wrap flag

.tick_stored:
    mov     [ds:0x046C], eax

    int     0x1C

    mov     al, 0x20
    out     0x20, al

    pop     eax
    pop     ds
    iret

; INT 11h: returns equipment word (BDA 0x0410) in AX
int11h_handler:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [ds:0x0410]
    pop     ds
    iret

; INT 12h: returns base RAM size in KiB (BDA 0x0413) in AX
int12h_handler:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [ds:0x0413]
    pop     ds
    iret

; INT 14h: serial status stub (TX/THR empty)
int14h_handler:
    mov     ah, 0x60
    mov     al, 0x00
    iret

; INT 17h: printer status stub (not busy / selected)
int17h_handler:
    mov     ah, 0x90
    iret

; INT 1Ah: BDA tick counter and CMOS RTC reads
int1Ah_handler:
    sti
    cmp     ah, 0x00
    je      .get_ticks
    cmp     ah, 0x01
    je      .set_ticks
    cmp     ah, 0x02
    je      .read_rtc_time
    cmp     ah, 0x04
    je      .read_rtc_date

    mov     ah, 0x01
    stc
    jmp     .exit

.get_ticks:
    push    ds
    xor     bx, bx
    mov     ds, bx
    mov     dx, [ds:0x046C]
    mov     cx, [ds:0x046E]
    mov     al, [ds:0x0470]
    mov     byte [ds:0x0470], 0
    pop     ds
    clc
    jmp     .exit

.set_ticks:
    push    ds
    xor     bx, bx
    mov     ds, bx
    mov     [ds:0x046C], dx
    mov     [ds:0x046E], cx
    mov     byte [ds:0x0470], 0
    pop     ds
    clc
    jmp     .exit

.read_rtc_time:
    call    rtc_wait_uip

    ; CH=hour, CL=min, DH=sec (BCD), DL=DST flag
    mov     al, 0x04
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     ch, al

    mov     al, 0x02
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     cl, al

    mov     al, 0x00
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     dh, al
    xor     dl, dl
    clc
    jmp     .exit

.read_rtc_date:
    call    rtc_wait_uip

    ; CH=century, CL=year, DH=month, DL=day (BCD)
    mov     al, 0x32
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     ch, al

    mov     al, 0x09
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     cl, al

    mov     al, 0x08
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     dh, al

    mov     al, 0x07
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     dl, al
    clc

.exit:
    push    bp
    mov     bp, sp
    jc      .set_cf
    and     byte [bp + 6], 0xFE
    pop     bp
    iret
.set_cf:
    or      byte [bp + 6], 0x01
    pop     bp
    iret

; Wait for RTC Update-In-Progress (Reg 0x0A bit 7) to clear
rtc_wait_uip:
    push    cx
    mov     cx, 0xFFFF
.uip_loop:
    mov     al, 0x0A
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    test    al, 0x80
    jz      .uip_ready
    loop    .uip_loop
.uip_ready:
    pop     cx
    ret
