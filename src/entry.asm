; entry.asm — IPO_Firmware Entry Point & Orchestration
; Assembled with ORG 0x0000, executed in CS=0x0800 (Physical 0x08000)

BITS 16
ORG 0x0000

%include "contract.inc"

; =============================================================================
; Offset 0x0000: Magic Signature Header (Validated by Boot_Rom)
; =============================================================================
dd      FW_MAGIC                            ; 0x464F5049 ("IPOF")

; =============================================================================
; Offset 0x0004: Entry Point (Boot_Rom jumps here under Contract 2)
; =============================================================================
firmware_entry:
    cli
    cld

    ; Establish segment registers for Firmware (CS=0x0800)
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    ; Setup stack
    xor     ax, ax
    mov     ss, ax
    mov     sp, FW_STACK_PTR

    ; 1. Initialize serial port
    call    serial_init

    ; 2. Setup Interrupt Vector Table (IVT) and BDA
    call    ivt_setup

    ; 3. Initialize Video Subsystem (Mode 03h: 80x25 text) via our own INT 10h
    mov     ax, 0x0003
    int     0x10
    call    bios_render_header

    ; 4. Log initialization diagnostics to screen and serial
    mov     si, msg_fw_banner
    call    bios_log
    mov     si, msg_ivt_ready
    call    bios_log
    mov     si, msg_vga_ready
    call    bios_log

    ; 5. Enable A20 Gate
    call    a20_enable
    mov     si, msg_a20_ready
    call    bios_log

    ; 6. Detect Memory
    call    ensure_memory_detected
    mov     si, msg_mem_ready
    call    bios_log

    ; 7. Initialize PS/2 Keyboard Controller (Translation Set 2 -> Set 1)
    call    ps2_controller_init
    mov     si, msg_kbd_ready
    call    bios_log

    ; 8. Discover bootable disk, load MBR, and hand off control (Contract 3)
    jmp     chainload_boot

; =============================================================================
; Serial (COM1) Driver Routines
; =============================================================================
serial_init:
    push    dx
    push    ax
    mov     dx, COM1_PORT + 1
    xor     al, al
    out     dx, al
    mov     dx, COM1_PORT + 3
    mov     al, 0x80
    out     dx, al
    mov     dx, COM1_PORT + 0
    mov     al, 0x01
    out     dx, al
    mov     dx, COM1_PORT + 1
    xor     al, al
    out     dx, al
    mov     dx, COM1_PORT + 3
    mov     al, 0x03
    out     dx, al
    mov     dx, COM1_PORT + 2
    mov     al, 0xC7
    out     dx, al
    mov     dx, COM1_PORT + 4
    mov     al, 0x0B
    out     dx, al
    pop     ax
    pop     dx
    ret

serial_tx_char:
    push    dx
    push    ax
    mov     ah, al
    mov     dx, COM1_PORT + 5
.wait:
    in      al, dx
    test    al, 0x20
    jz      .wait
    mov     al, ah
    mov     dx, COM1_PORT
    out     dx, al
    pop     ax
    pop     dx
    ret

serial_print:
    push    si
    push    ax
.loop:
    lodsb
    test    al, al
    jz      .done
    cmp     al, 10
    jne     .send
    push    ax
    mov     al, 13
    call    serial_tx_char
    pop     ax
.send:
    call    serial_tx_char
    jmp     .loop
.done:
    pop     ax
    pop     si
    ret

; =============================================================================
; BIOS Dual Logger (COM1 Serial + VGA Teletype via INT 10h)
; =============================================================================
bios_log:
    push    si
    push    ax
.loop:
    lodsb
    test    al, al
    jz      .done
    cmp     al, 10
    jne     .send
    push    ax
    mov     al, 13
    call    serial_tx_char
    pop     ax
.send:
    call    serial_tx_char
    push    bx
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    pop     bx
    jmp     .loop
.done:
    pop     ax
    pop     si
    ret

bios_log_hex_byte:
    push    ax
    push    bx
    push    dx

    mov     dh, al
    shr     al, 4
    call    .print_nibble
    mov     al, dh
    and     al, 0x0F
    call    .print_nibble

    pop     dx
    pop     bx
    pop     ax
    ret
.print_nibble:
    cmp     al, 9
    jbe     .digit
    add     al, 'A' - 10
    jmp     .emit
.digit:
    add     al, '0'
.emit:
    call    serial_tx_char
    push    bx
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    pop     bx
    ret

; =============================================================================
; Included Modules
; =============================================================================
%include "ivt.asm"
%include "int10.asm"
%include "int13.asm"
%include "int15.asm"
%include "a20.asm"
%include "kbd.asm"
%include "chainload.asm"

; =============================================================================
; Messages & Data
; =============================================================================
msg_fw_banner   db "[IPO_Firmware] BIOS-compatible Firmware initialized at 0x0800:0000", 10, 0
msg_ivt_ready   db "[IPO_Firmware] IVT installed (INT 10h, 13h, 15h, 16h registered)", 10, 0
msg_vga_ready   db "[IPO_Firmware] Video Mode 03h (80x25 text) configured", 10, 0
msg_a20_ready   db "[IPO_Firmware] Fast A20 Gate activated and verified", 10, 0
msg_mem_ready   db "[IPO_Firmware] Memory map prepared (E820/E801 ready)", 10, 0
msg_kbd_ready   db "[IPO_Firmware] PS/2 keyboard controller configured (Set 2 -> Set 1 translation)", 10, 0

