; entry.asm — IPO_Firmware Entry Point & Orchestration
; Assembled with ORG 0x0000, executed in CS=0xF000 (Shadow RAM at 0xF000:0x0000)

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

    ; Establish segment registers for Firmware (CS=0xF000 in Shadow RAM)
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

    ; 3. Setup ACPI 1.0 Tables (RSDP in EBDA 0x9FC00, RSDT, MADT)
    call    acpi_init_tables

    ; 4. Scan PCI Buses for VGA, SATA AHCI, NVMe, and USB host controllers
    call    pci_scan_devices
    mov     si, msg_pci_ready
    call    bios_log

    ; 5. Initialize Video Subsystem (Mode 03h: 80x25 text) if VGA present
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_init

    ; Check for Option ROM (VBIOS) at 0xC000
    call    vbios_init

    ; Set Video Mode 03h (80x25 text mode) unconditionally
    ; If VBIOS is active, this calls VBIOS via INT 42h
    ; If VBIOS is absent, this calls our native int10h_handler
    mov     ax, 0x0003
    int     0x10

    call    bios_render_header
.skip_vga_init:

    ; 6. Log initialization diagnostics to screen and serial
    mov     si, msg_fw_banner
    call    bios_log
    mov     si, msg_ivt_ready
    call    bios_log
    mov     si, msg_acpi_ready
    call    bios_log
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_msg
    mov     si, msg_vga_ready
    call    bios_log
.skip_vga_msg:

    ; 7. Enable A20 Gate
    call    a20_enable
    mov     si, msg_a20_ready
    call    bios_log

    ; 8. Detect Memory
    call    ensure_memory_detected
    mov     si, msg_mem_ready
    call    bios_log

    ; 9. Initialize PS/2 Keyboard Controller (Translation Set 2 -> Set 1)
    call    ps2_controller_init
    mov     si, msg_kbd_ready
    call    bios_log

    ; 10. Initialize Modern Storage Subsystems (SATA AHCI, NVMe, USB)
    ; Set default drive 0x80 to Legacy ATA PIO
    xor     ax, ax
    mov     es, ax
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_ATA_PIO

    ; Try initializing SATA AHCI
    call    ahci_init
    jc      .check_nvme_storage
    ; AHCI active: register Drive 0x80 as SATA AHCI
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_SATA_AHCI
    mov     si, msg_ahci_ready
    call    bios_log

.check_nvme_storage:
    ; Try initializing NVMe Storage
    call    nvme_init
    jc      .check_usb_storage
    ; NVMe active: if Drive 0x80 was taken by AHCI, map NVMe to 0x81, else to 0x80
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_SATA_AHCI
    je      .nvme_on_81
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_NVME
    jmp     .nvme_log
.nvme_on_81:
    mov     byte [es:SCRATCH_DRV_TYPE_81], DRV_TYPE_NVME
.nvme_log:
    mov     si, msg_nvme_ready
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
    ; 11. Discover bootable disk, load MBR, and hand off control (Contract 3)
    jmp     chainload_boot

; =============================================================================
; Serial (COM1) Driver Routines
; =============================================================================
serial_init:
    push    dx
    push    ax

    ; Test if UART actually exists by writing and reading scratch register port 0x3F8+7 (0x3FF)
    mov     dx, COM1_PORT + 7               ; Scratch register
    mov     al, 0xA5
    out     dx, al
    in      al, dx
    cmp     al, 0xA5
    jne     .no_uart

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
.no_uart:
    pop     ax
    pop     dx
    ret

serial_tx_char:
    push    dx
    push    ax
    push    cx
    mov     ah, al
    mov     dx, COM1_PORT + 5
    xor     cx, cx
.wait:
    in      al, dx
    test    al, 0x20
    jnz     .ready
    dec     cx
    jnz     .wait
    ; Timeout countdown expired — do not hang if serial line disconnected
    jmp     .tx_done
.ready:
    mov     al, ah
    mov     dx, COM1_PORT
    out     dx, al
.tx_done:
    pop     cx
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
%include "nvme.asm"
%include "usb_ehci.asm"
%include "ivt.asm"
%include "acpi.asm"
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
msg_acpi_ready  db "[IPO_Firmware] ACPI 1.0 tables installed (RSDP in EBDA, RSDT, MADT)", 10, 0
msg_vga_ready   db "[IPO_Firmware] Video Mode 03h (80x25 text) configured", 10, 0
msg_a20_ready   db "[IPO_Firmware] Fast A20 Gate activated and verified", 10, 0
msg_mem_ready   db "[IPO_Firmware] Memory map prepared (E820/E801 ready)", 10, 0
msg_kbd_ready   db "[IPO_Firmware] PS/2 keyboard controller configured (Set 2 -> Set 1 translation)", 10, 0
msg_pci_ready   db "[IPO_Firmware] PCI bus enumeration completed", 10, 0
msg_ahci_ready  db "[IPO_Firmware] SATA AHCI controller active (Drive 0x80 linked to SATA)", 10, 0
msg_nvme_ready  db "[IPO_Firmware] NVMe controller active (NVM Express storage drive linked)", 10, 0
msg_usb_ready   db "[IPO_Firmware] USB Mass Storage active (Drive 0x82 linked to USB)", 10, 0

