; chainload.asm — Discovers bootable disk, reads MBR to 0x7C00, and jumps
; Contract 3 fulfillment

BITS 16

chainload_boot:
    ; Search for bootable disk across ATA drives 0x80, 0x81, 0x82, 0x83
    mov     byte [current_drive], 0x80

.drive_scan_loop:
    mov     dl, [current_drive]

    ; Print probe message
    mov     si, msg_probing
    call    print_string
    mov     al, dl
    call    print_hex_byte
    mov     si, msg_newline
    call    print_string

    ; Prepare DAP for LBA 0 -> 0x0000:0x7C00
    mov     word [mbr_dap + 2], 1           ; 1 sector
    mov     word [mbr_dap + 4], MBR_OFF     ; Offset 0x7C00
    mov     word [mbr_dap + 6], MBR_SEG     ; Segment 0x0000
    mov     dword [mbr_dap + 8], 0          ; LBA 0 (low)
    mov     dword [mbr_dap + 12], 0         ; LBA 0 (high)

    ; Call INT 13h (our own disk service!)
    mov     dl, [current_drive]             ; Ensure DL contains the drive to read!
    push    ds
    mov     ax, FW_RAM_SEG
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
    inc     byte [current_drive]
    cmp     byte [current_drive], 0x82      ; Check 0x80 and 0x81 (Primary Master and Slave)
    jb      .drive_scan_loop

    ; No bootable drive found!
    mov     si, msg_no_boot
    call    bios_log
.halt:
    hlt
    jmp     .halt

.boot_drive_found:
    mov     dl, [current_drive]
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

    ; -------------------------------------------------------------------------
    ; Contract 3: Standard PC BIOS MBR Handover
    ;   CPU Mode: 16-bit real mode
    ;   CS:IP = 0x0000:0x7C00
    ;   DL = Boot drive number (0x80 for first HDD)
    ;   DS = ES = SS = 0x0000
    ;   SP = 0x7C00
    ;   sti (interrupts enabled)
    ; -------------------------------------------------------------------------
    mov     dl, [current_drive]
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
current_drive   db 0x80

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
msg_booting     db "[IPO_Firmware] Bootable MBR found on drive 0x", 0
msg_dots        db "... Launching MBR!", 10, 0
msg_no_boot     db "[IPO_Firmware] ERROR: No bootable disk found (missing 0x55AA)! System halted.", 10, 0
msg_dbg_err     db "  -> INT 13h read failed with AH=0x", 0
msg_dbg_bad_sig db "  -> Read OK but signature mismatch at 0x7DFE: 0x", 0
