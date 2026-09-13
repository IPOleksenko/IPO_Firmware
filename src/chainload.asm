; chainload.asm — Discovers bootable disk, reads MBR to 0x7C00, and jumps
; Contract 3 fulfillment

BITS 16

chainload_boot:
    ; Search for bootable disk across ATA drives 0x80, 0x81
    mov     dl, 0x80

.drive_scan_loop:
    push    dx                              ; Preserve current drive across calls

    ; Print probe message
    mov     si, msg_probing
    call    print_string
    mov     al, dl
    call    print_hex_byte
    mov     si, msg_newline
    call    print_string

    ; Call INT 13h (our own disk service!)
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     si, mbr_dap
    mov     ah, 0x42
    int     0x13
    pop     ds
    jnc     .read_ok

    ; Error reading drive
    push    ax
    mov     si, msg_dbg_err
    call    print_string
    pop     ax
    mov     al, ah
    call    print_hex_byte
    mov     si, msg_newline
    call    print_string
    jmp     .try_next_drive

.read_ok:
    ; Check MBR signature 0x55AA at offset 510 (physical 0x7DFE)
    xor     ax, ax
    mov     es, ax
    mov     ax, [es:0x7DFE]
    cmp     ax, MBR_MAGIC
    je      .boot_drive_found

    push    ax
    mov     si, msg_dbg_bad_sig
    call    print_string
    pop     ax
    push    ax
    call    print_hex_byte                  ; Low byte
    pop     ax
    mov     al, ah
    call    print_hex_byte                  ; High byte
    mov     si, msg_newline
    call    print_string

.try_next_drive:
    pop     dx                              ; Restore current drive
    inc     dl                              ; Next drive (0x80 -> 0x81 -> 0x82)
    cmp     dl, 0x83                        ; Check 0x80, 0x81 (HDD/SATA) and 0x82 (USB Flash)
    jb      .drive_scan_loop

    ; No bootable drive found!
    mov     si, msg_no_boot
    call    bios_log
.halt:
    hlt
    jmp     .halt

.boot_drive_found:
    pop     dx                              ; Restore boot drive into DL
    push    dx                              ; Keep safe on stack during logging
    mov     si, msg_booting
    call    bios_log
    mov     al, dl
    call    bios_log_hex_byte
    mov     si, msg_dots
    call    bios_log

    ; Clear screen and reset cursor so booted OS has a clean console
    call    vga_clear_screen
    xor     ax, ax
    mov     es, ax
    mov     word [es:0x0450], 0
    call    update_hw_cursor

    pop     dx                              ; Restore DL = Boot drive number (0x80 for first HDD)

    ; -------------------------------------------------------------------------
    ; Contract 3: Standard PC BIOS MBR Handover
    ;   CPU Mode: 16-bit real mode
    ;   CS:IP = 0x0000:0x7C00
    ;   DL = Boot drive number (0x80 for first HDD)
    ;   DS = ES = SS = 0x0000
    ;   SP = 0x7C00
    ;   sti (interrupts enabled)
    ; -------------------------------------------------------------------------
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti

    jmp     MBR_SEG:MBR_OFF

; =============================================================================
; Helper Print Utilities using bios_log
; =============================================================================
print_string:
    call    bios_log
    ret

print_hex_byte:
    call    bios_log_hex_byte
    ret

align 4
mbr_dap:
    db 16                                   ; Size = 16
    db 0                                    ; Reserved = 0
    dw 1                                    ; Sector count = 1
    dw MBR_OFF                              ; Offset = 0x7C00
    dw MBR_SEG                              ; Segment = 0x0000
    dq 0                                    ; LBA 0

msg_probing     db "[IPO_Firmware] Probing drive 0x", 0
msg_newline     db 10, 0
msg_booting     db "[IPO_Firmware] Bootable storage found on drive 0x", 0
msg_dots        db "... Handing over to OS!", 10, 0
msg_no_boot     db "[IPO_Firmware] Boot Failure: No bootable disk found (missing 0x55AA). System halted.", 10, 0
msg_dbg_err     db "  -> Drive not ready (status AH=0x", 0
msg_dbg_bad_sig db "  -> Read OK but boot signature mismatch: 0x", 0
