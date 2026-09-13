; entry.asm — IPO_Firmware Entry Point & Orchestration
; Assembled with ORG 0x0000, executed in CS=0x0800 (Physical 0x08000)

BITS 16
ORG 0x0000

%include "contract.inc"

; =============================================================================
; Offset 0x0000: Magic Signature Header (Validated by Boot_ROM)
; =============================================================================
dd      FW_MAGIC                            ; 0x464F5049 ("IPOF")

; =============================================================================
; Offset 0x0004: Entry Point (Boot_ROM jumps here under Contract 2)
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

    ; 3. Scan PCI Buses for VGA, SATA AHCI, and USB host controllers
    call    pci_scan_devices
    mov     si, msg_pci_ready
    call    bios_log

    ; 4. Initialize Video Subsystem (Mode 03h: 80x25 text) via built-in VGA INT 10h
    mov     ax, 0x0003
    int     0x10
    call    bios_render_header

    ; 5. Log initialization diagnostics to screen and serial
    mov     si, msg_fw_banner
    call    bios_log
    mov     si, msg_ivt_ready
    call    bios_log
    mov     si, msg_vga_ready
    call    bios_log

    ; 6. Enable A20 Gate
    call    a20_enable
    mov     si, msg_a20_ready
    call    bios_log

    ; 7. Detect Memory
    call    ensure_memory_detected
    mov     si, msg_mem_ready
    call    bios_log

    ; 8. Initialize PS/2 Keyboard Controller (Translation Set 2 -> Set 1)
    call    ps2_controller_init
    mov     si, msg_kbd_ready
    call    bios_log

    ; 9. Initialize Modern Storage Subsystems (SATA AHCI & USB)
    ; Set default drive 0x80 to Legacy ATA PIO
    xor     ax, ax
    mov     es, ax
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_ATA_PIO

    ; Try initializing SATA AHCI
    call    ahci_init
    jc      .check_usb_storage
    ; AHCI active: register Drive 0x80 as SATA AHCI
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_SATA_AHCI
    mov     si, msg_ahci_ready
    call    bios_log

.check_usb_storage:
    ; Try initializing USB Mass Storage
    call    usb_init
    jc      .storage_init_done
    ; USB drive active: register Drive 0x82 as USB Flash Drive
    mov     byte [es:SCRATCH_DRV_TYPE_82], DRV_TYPE_USB_BOT
    mov     si, msg_usb_ready
    call    bios_log

.storage_init_done:
    ; 10. Discover bootable disk, load MBR, and hand off control (Contract 3)
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
    push    bx
.loop:
    lodsb
    test    al, al
    jz      .done
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    jmp     .loop
.done:
    pop     bx
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
    push    bx
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    pop     bx
    ret

; =============================================================================
; Included Modules
; =============================================================================
%include "pci_scan.asm"
%include "vbios.asm"
%include "ahci.asm"
%include "usb_ehci.asm"
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
msg_fw_banner   db "[IPO_Firmware] BIOS-compatible Firmware initialized (Shadow RAM mode)", 10, 0
msg_ivt_ready   db "[IPO_Firmware] IVT installed (INT 10h, 13h, 15h, 16h registered)", 10, 0
msg_vga_ready   db "[IPO_Firmware] Video Mode 03h (80x25 text) configured", 10, 0
msg_a20_ready   db "[IPO_Firmware] Fast A20 Gate activated and verified", 10, 0
msg_mem_ready   db "[IPO_Firmware] Memory map prepared (E820/E801 ready)", 10, 0
msg_kbd_ready   db "[IPO_Firmware] PS/2 keyboard controller configured (Set 2 -> Set 1 translation)", 10, 0
msg_pci_ready   db "[IPO_Firmware] PCI bus enumeration completed", 10, 0
msg_ahci_ready  db "[IPO_Firmware] SATA AHCI controller active (Drive 0x80 linked to SATA)", 10, 0
msg_usb_ready   db "[IPO_Firmware] USB Mass Storage active (Drive 0x82 linked to USB)", 10, 0

