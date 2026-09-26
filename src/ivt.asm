; ivt.asm — Interrupt Vector Table (IVT) and BDA Setup
; Populates all 256 interrupt vectors at 0x0000:0x0000 with proper hardware
; EOI handlers and standard BIOS services (INT 10h, 11h, 12h, 13h, 14h, 15h, 16h, 17h, 1Ah, 1Ch).

BITS 16

%include "contract.inc"

ivt_setup:
    push    es
    push    di
    push    cx
    push    ax
    push    bx

    mov     bx, cs                          ; BX = CS (0xF000 in Shadow RAM mode)

    ; 1. Point all 256 vectors to default_int_handler
    xor     ax, ax
    mov     es, ax
    xor     di, di

    mov     cx, 256
.loop_default:
    mov     word [es:di], default_int_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_default

    ; 2. Install Master PIC Hardware IRQ Handlers (INT 08h - 0x0F)
    ; Vectors 0x20..0x3C
    mov     cx, 8
    mov     di, 0x0020
.loop_pic1:
    mov     word [es:di], pic1_default_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_pic1

    ; 3. Install Slave PIC Hardware IRQ Handlers (INT 70h - 77h)
    ; Vectors 0x01C0..0x01DC (0x70 * 4 = 0x01C0)
    mov     cx, 8
    mov     di, 0x01C0
.loop_pic2:
    mov     word [es:di], pic2_default_handler
    mov     word [es:di+2], bx
    add     di, 4
    loop    .loop_pic2

    ; 4. Dedicated IRQ Handlers
    ; IRQ 0 (INT 08h): System Timer Tick
    mov     word [es:0x0020], int08h_timer_handler
    mov     word [es:0x0022], bx

    ; IRQ 1 (INT 09h): PS/2 Keyboard IRQ
    mov     word [es:0x0024], int09h_keyboard_handler
    mov     word [es:0x0026], bx

    ; 5. Register Implemented BIOS Service Interrupt Handlers
    ; INT 10h (Video Services) — Vector 0x10 * 4 = 0x0040
    mov     word [es:0x0040], int10h_handler
    mov     word [es:0x0042], bx

    ; INT 11h (Equipment Check) — Vector 0x11 * 4 = 0x0044
    mov     word [es:0x0044], int11h_handler
    mov     word [es:0x0046], bx

    ; INT 12h (Conventional Memory Size) — Vector 0x12 * 4 = 0x0048
    mov     word [es:0x0048], int12h_handler
    mov     word [es:0x004A], bx

    ; INT 13h (Disk Services) — Vector 0x13 * 4 = 0x004C
    mov     word [es:0x004C], int13h_handler
    mov     word [es:0x004E], bx

    ; INT 14h (Serial Services) — Vector 0x14 * 4 = 0x0050
    mov     word [es:0x0050], int14h_handler
    mov     word [es:0x0052], bx

    ; INT 15h (System Services / E820) — Vector 0x15 * 4 = 0x0054
    mov     word [es:0x0054], int15h_handler
    mov     word [es:0x0056], bx

    ; INT 16h (Keyboard Services) — Vector 0x16 * 4 = 0x0058
    mov     word [es:0x0058], int16h_handler
    mov     word [es:0x005A], bx

    ; INT 17h (Printer Services) — Vector 0x17 * 4 = 0x005C
    mov     word [es:0x005C], int17h_handler
    mov     word [es:0x005E], bx

    ; INT 1Ah (Time of Day / RTC) — Vector 0x1A * 4 = 0x0068
    mov     word [es:0x0068], int1Ah_handler
    mov     word [es:0x006A], bx

    ; INT 1Ch (User Timer Tick Hook) — Vector 0x1C * 4 = 0x0070
    mov     word [es:0x0070], default_int_handler
    mov     word [es:0x0072], bx

    ; 6. Setup Standard BDA (BIOS Data Area) at 0x0040:0x0000 (0x0400)
    mov     word [es:0x0400], 0x03F8            ; COM1 base I/O port address
    mov     word [es:0x040E], 0x9FC0            ; EBDA Base Segment (0x9FC0:0x0000)
    mov     word [es:0x0410], 0x4223            ; Equipment word (color 80x25, mouse, coprocessor, floppy)
    mov     word [es:0x0413], 640               ; Base memory = 640 KB (0x0280)
    mov     byte [es:0x0417], 0                 ; Keyboard shift status flags
    mov     word [es:0x041A], 0x001E            ; Keyboard buffer head
    mov     word [es:0x041C], 0x001E            ; Keyboard buffer tail
    mov     dword [es:0x046C], 0                ; Timer tick counter
    mov     byte [es:0x0470], 0                 ; Midnight wrap flag
    mov     byte [es:0x0475], 1                 ; Number of hard disk drives
    mov     word [es:0x0480], 0x001E            ; Keyboard buffer start offset
    mov     word [es:0x0482], 0x003E            ; Keyboard buffer end offset

    pop     bx
    pop     ax
    pop     cx
    pop     di
    pop     es
    ret

; =============================================================================
; PIC EOI Handlers
; =============================================================================

; Master PIC (IRQ 0-7) Default Handler
pic1_default_handler:
    push    ax
    mov     al, 0x20
    out     0x20, al                            ; Send EOI to Master PIC
    pop     ax
    iret

; Slave PIC (IRQ 8-15) Default Handler
pic2_default_handler:
    push    ax
    mov     al, 0x20
    out     0xA0, al                            ; Send EOI to Slave PIC
    out     0x20, al                            ; Send EOI to Master PIC
    pop     ax
    iret

; Default Unhandled Software Interrupt
default_int_handler:
    iret

; =============================================================================
; IRQ 0 (INT 08h): System Timer Tick Handler
; Increments 32-bit tick count in BDA, handles midnight wrap, and calls INT 1Ch
; =============================================================================
int08h_timer_handler:
    push    ds
    push    eax

    xor     ax, ax
    mov     ds, ax                              ; DS = 0x0000

    mov     eax, [ds:0x046C]                    ; BDA 32-bit timer tick counter
    inc     eax
    cmp     eax, 0x001800B0                     ; 1,573,040 ticks (~24 hours at 18.2065 Hz)
    jb      .tick_stored
    xor     eax, eax                            ; Reset tick count
    mov     byte [ds:0x0470], 1                 ; Set midnight flag

.tick_stored:
    mov     [ds:0x046C], eax

    ; Call user timer tick hook (INT 1Ch)
    int     0x1C

    ; Send EOI to Master PIC
    mov     al, 0x20
    out     0x20, al

    pop     eax
    pop     ds
    iret

; =============================================================================
; IRQ 1 (INT 09h): PS/2 Keyboard Hardware Interrupt
; Reads scancode from port 0x60, inserts into BDA buffer, and sends EOI
; =============================================================================
int09h_keyboard_handler:
    push    ds
    push    ax
    push    bx
    push    si

    xor     ax, ax
    mov     ds, ax                              ; DS = 0x0000

    in      al, 0x60                            ; Read scancode from Keyboard Controller

    ; Put key into BDA circular buffer
    mov     si, [ds:0x041C]                     ; SI = buffer tail
    mov     bx, si
    add     bx, 2
    cmp     bx, [ds:0x0482]                     ; End of buffer (0x003E)?
    jb      .wrap_ok
    mov     bx, [ds:0x0480]                     ; Wrap to start (0x001E)
.wrap_ok:
    cmp     bx, [ds:0x041A]                     ; Buffer full (tail == head)?
    je      .kbd_eoi                            ; Drop scancode if buffer full

    ; Write scancode into buffer at [0x0400 + SI]
    mov     [ds:0x0400 + si], al
    mov     byte [ds:0x0400 + si + 1], 0
    mov     [ds:0x041C], bx                     ; Update tail

.kbd_eoi:
    mov     al, 0x20
    out     0x20, al                            ; EOI to Master PIC

    pop     si
    pop     bx
    pop     ax
    pop     ds
    iret

; =============================================================================
; INT 11h: Equipment Determination
; Returns: AX = Equipment Word from BDA 0x0410
; =============================================================================
int11h_handler:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [ds:0x0410]
    pop     ds
    iret

; =============================================================================
; INT 12h: Conventional Memory Size
; Returns: AX = Memory size in KB (0 to 640) from BDA 0x0413
; =============================================================================
int12h_handler:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [ds:0x0413]
    pop     ds
    iret

; =============================================================================
; INT 14h: Serial Port Services
; =============================================================================
int14h_handler:
    ; AH=03h: Get port status
    mov     ah, 0x60                            ; Line status: Transmitter empty, THR empty
    mov     al, 0x00                            ; Modem status
    iret

; =============================================================================
; INT 16h: Keyboard BIOS Services
; =============================================================================
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
    mov     si, [ds:0x041A]                     ; Head
    cmp     si, [ds:0x041C]                     ; Tail
    jne     .consume_key
    hlt                                         ; Wait for keyboard interrupt
    jmp     .wait_key

.consume_key:
    mov     ax, [ds:0x0400 + si]
    add     si, 2
    cmp     si, [ds:0x0482]
    jb      .head_ok
    mov     si, [ds:0x0480]
.head_ok:
    mov     [ds:0x041A], si                     ; Advance head
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

    ; No key available: set ZF in caller FLAGS
    or      byte [bp + 10], 0x40                ; Bit 6 = ZF
    xor     ax, ax
    pop     bp
    pop     si
    pop     ds
    iret

.key_ready:
    ; Key available: clear ZF in caller FLAGS, return next key in AX
    and     byte [bp + 10], ~0x40               ; Clear ZF
    mov     ax, [ds:0x0400 + si]
    pop     bp
    pop     si
    pop     ds
    iret

.fn_get_shift:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     al, [ds:0x0417]                     ; BDA keyboard shift flags
    pop     ds
    iret

; =============================================================================
; INT 17h: Printer Services
; =============================================================================
int17h_handler:
    mov     ah, 0x90                            ; Status: Printer not busy / selected
    iret

; =============================================================================
; INT 1Ah: Time of Day Services
; =============================================================================
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
    mov     dx, [ds:0x046C]                     ; Low word
    mov     cx, [ds:0x046E]                     ; High word
    mov     al, [ds:0x0470]                     ; Midnight flag
    mov     byte [ds:0x0470], 0                 ; Clear midnight flag
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
    ; CH = hours, CL = minutes, DH = seconds in BCD
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
    xor     dl, dl                              ; Daylight savings = 0
    clc
    jmp     .exit

.read_rtc_date:
    ; CH = century, CL = year, DH = month, DL = day in BCD
    mov     al, 0x32                            ; Century
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     ch, al

    mov     al, 0x09                            ; Year
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     cl, al

    mov     al, 0x08                            ; Month
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     dh, al

    mov     al, 0x07                            ; Day
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
