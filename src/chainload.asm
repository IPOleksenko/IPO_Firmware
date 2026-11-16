; Probe bootable disks (0x80..0x82), load MBR to 0x0000:0x7C00, and hand off execution.

BITS 16

chainload_boot:
    mov     dl, 0x80

.drive_scan_loop:
    push    dx

    mov     si, msg_probing
    call    fw_log
    mov     al, dl
    call    fw_log_hex_byte
    mov     si, msg_newline
    call    fw_log

    ; Read LBA 0 using INT 13h extended read
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     si, mbr_dap
    mov     ah, 0x42
    int     0x13
    pop     ds
    jnc     .read_ok

    push    ax
    mov     si, msg_dbg_err
    call    fw_log
    pop     ax
    mov     al, ah
    call    fw_log_hex_byte
    mov     si, msg_dbg_err_end
    call    fw_log
    jmp     .try_next_drive

.read_ok:
    ; Verify 0xAA55 MBR signature at offset 510 (0x7DFE)
    xor     ax, ax
    mov     es, ax
    mov     ax, [es:0x7DFE]
    cmp     ax, MBR_MAGIC
    je      .boot_drive_found

    push    ax
    mov     si, msg_dbg_bad_sig
    call    fw_log
    pop     ax
    push    ax
    call    fw_log_hex_byte                 ; low byte
    pop     ax
    mov     al, ah
    call    fw_log_hex_byte                 ; high byte
    mov     si, msg_newline
    call    fw_log

.try_next_drive:
    pop     dx
    inc     dl
    cmp     dl, 0x83
    jb      .drive_scan_loop

    mov     si, msg_no_boot
    call    fw_log
.halt:
    hlt
    jmp     .halt

.boot_drive_found:
    pop     dx
    push    dx
    mov     si, msg_booting
    call    fw_log
    mov     al, dl
    call    fw_log_hex_byte
    mov     si, msg_dots
    call    fw_log

    ; Clear display and reset BDA/hardware cursor before jumping to MBR
    call    vga_clear_screen
    xor     ax, ax
    mov     es, ax
    mov     word [es:0x0450], 0
    call    update_hw_cursor

    pop     dx

    ; MBR handoff ABI: 16-bit Real Mode, CS:IP=0000:7C00, DL=boot drive,
    ; DS=ES=SS=0000, SP=7C00, IF=1
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    xor     esp, esp
    mov     sp, 0x7C00
    sti

    jmp     MBR_SEG:MBR_OFF

align 4
mbr_dap:
    db 16                                   ; DAP size
    db 0                                    ; reserved
    dw 1                                    ; sector count
    dw MBR_OFF                              ; dst offset
    dw MBR_SEG                              ; dst segment
    dq 0                                    ; LBA 0

msg_probing     db "[IPO_Firmware] Probing drive 0x", 0
msg_newline     db 10, 0
msg_booting     db "[IPO_Firmware] Bootable storage found on drive 0x", 0
msg_dots        db "... Handing over to OS!", 10, 0
msg_no_boot     db "[IPO_Firmware] Boot Failure: No bootable disk found (missing 0x55AA). System halted.", 10, 0
msg_dbg_err     db "  -> Drive not ready (status AH=0x", 0
msg_dbg_err_end db ")", 10, 0
msg_dbg_bad_sig db "  -> Read OK but boot signature mismatch: 0x", 0
