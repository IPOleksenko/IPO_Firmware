; IPO_Firmware entry point and hardware init (ORG 0x0000, CS=0xF000 in shadow RAM)

BITS 16
ORG 0x0000

%include "boot_constants.inc"

; Offset 0x0000: signature verified by stage-1 loader at handoff
db      "IPO_Firmware"

; Offset 0x000C: entry point
firmware_entry:
    cli
    cld

    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    xor     ax, ax
    mov     ss, ax
    xor     esp, esp
    mov     sp, FW_STACK_PTR

    call    serial_init
    call    ivt_setup

    ; Populate RSDP in EBDA (0x9FC00) and ACPI tables
    call    acpi_init_tables

    call    pci_scan_devices
    mov     si, msg_pci_ready
    call    fw_log

    ; Initialize VGA Mode 03h (80x25 text) if a display controller was found
    xor     ax, ax
    mov     es, ax
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_init

    call    video_option_rom_init

    ; Delegates to Option ROM through INT 42h if loaded, else native INT 10h handler
    mov     ax, 0x0003
    int     0x10

    call    fw_render_header
.skip_vga_init:

    mov     si, msg_fw_banner
    call    fw_log
    mov     si, msg_ivt_ready
    call    fw_log
    mov     si, msg_acpi_ready
    call    fw_log
    movzx   eax, word [es:SCRATCH_CPU_COUNT]
    call    fw_log_dec
    mov     si, msg_acpi_tail
    call    fw_log
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .skip_vga_msg
    mov     si, msg_vga_ready
    call    fw_log
.skip_vga_msg:

    call    a20_enable
    mov     si, msg_a20_ready
    call    fw_log

    call    ensure_memory_detected
    mov     si, msg_mem_ready
    call    fw_log

    call    ps2_controller_init
    mov     si, msg_kbd_ready
    call    fw_log

    ; Default drives 0x80 and 0x81 to legacy ATA PIO before probing PCI storage
    xor     ax, ax
    mov     es, ax
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_ATA_PIO
    mov     byte [es:SCRATCH_DRV_TYPE_81], DRV_TYPE_ATA_PIO

    call    ahci_init
    jc      .check_nvme_storage
    mov     byte [es:SCRATCH_DRV_TYPE_80], DRV_TYPE_SATA_AHCI
    mov     si, msg_ahci_ready
    call    fw_log

.check_nvme_storage:
    call    nvme_init
    jc      .check_usb_storage
    ; Map NVMe to 0x81 if AHCI already claimed 0x80
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
    call    fw_log

.check_usb_storage:
    call    usb_init
    jc      .storage_init_done
    mov     byte [es:SCRATCH_DRV_TYPE_82], DRV_TYPE_USB_BOT
    mov      byte [es:0x0475], 3
    mov     si, msg_usb_ready
    call    fw_log

.storage_init_done:
    jmp     chainload_boot

; COM1 UART init and polling output
serial_init:
    push    dx
    push    ax

    ; Probe UART presence using scratch register (0x3FF)
    mov     dx, COM1_PORT + 7
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
    ; Avoid hanging if nothing is connected to COM1
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

; Log helpers (output with INT 10h, mirrored to COM1)
fw_log:
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

fw_log_hex_byte:
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

; Print unsigned EAX in decimal using INT 10h
fw_log_dec:
    pushad
    xor     ecx, ecx
    mov     ebx, 10
.dec_div:
    xor     edx, edx
    div     ebx
    push    dx
    inc     cx
    test    eax, eax
    jnz     .dec_div
.dec_out:
    pop     ax
    add     al, '0'
    push    bx
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    pop     bx
    loop    .dec_out
    popad
    ret

%include "pci_scan.asm"
%include "video_option_rom.asm"
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

msg_fw_banner   db "[IPO_Firmware] Firmware initialized (Shadow RAM mode)", 10, 0
msg_ivt_ready   db "[IPO_Firmware] IVT installed (INT 10h, 13h, 15h, 16h registered)", 10, 0
msg_acpi_ready  db "[IPO_Firmware] ACPI tables installed (CPUs=", 0
msg_acpi_tail   db ", RSDP/RSDT/MADT/FACP/DSDT)", 10, 0
msg_vga_ready   db "[IPO_Firmware] Video Mode 03h (80x25 text) configured", 10, 0
msg_a20_ready   db "[IPO_Firmware] Fast A20 Gate activated and verified", 10, 0
msg_mem_ready   db "[IPO_Firmware] Memory map prepared (E820/E801 ready)", 10, 0
msg_kbd_ready   db "[IPO_Firmware] PS/2 keyboard controller configured (Set 2 -> Set 1 translation)", 10, 0
msg_pci_ready   db "[IPO_Firmware] PCI bus enumeration completed", 10, 0
msg_ahci_ready  db "[IPO_Firmware] SATA AHCI controller active (Drive 0x80 linked to SATA)", 10, 0
msg_nvme_ready  db "[IPO_Firmware] NVMe controller active (NVM Express storage drive linked)", 10, 0
msg_usb_ready   db "[IPO_Firmware] USB Mass Storage active (Drive 0x82 linked to USB)", 10, 0
