; video_option_rom.asm — PCI Video Option ROM Loader and Execution
; Discovers GPU Expansion ROM, maps and copies it to 0xC000:0000, and calls
; the 16-bit real-mode Video Option ROM entry point (0xC000:0003).

BITS 16

; =============================================================================
; video_option_rom_init — Search for GPU Option ROM and initialize graphics hardware
; =============================================================================
video_option_rom_init:
    pushad
    push    ds
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Check if VGA device was discovered during PCI enumeration
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .no_video_rom

    ; Build base PCI address for VGA controller
    movzx   eax, byte [es:SCRATCH_VGA_BUS]
    shl     eax, 16
    movzx   edx, byte [es:SCRATCH_VGA_DEVFN]
    shl     edx, 8
    or      eax, edx
    mov     esi, eax                        ; ESI = Base PCI address

    ; -------------------------------------------------------------------------
    ; 1. Enable Expansion ROM Decode in PCI Config Space (offset 0x30)
    ;    Set base address to 0x000C0000 and bit 0 = 1 (Address Decode Enable)
    ; -------------------------------------------------------------------------
    mov     eax, esi
    or      eax, 0x30
    mov     ecx, 0x000C0001                 ; Base 0x000C0000 | Decode Enable
    call    pci_write_dword

    ; Also ensure Memory Space is enabled in PCI Command (reg 0x04)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x03                        ; Enable I/O Space + Memory Space
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

    ; -------------------------------------------------------------------------
    ; 2. Check for Option ROM Signature at 0xC000:0x0000
    ;    Must start with 0x55, 0xAA (word 0xAA55)
    ; -------------------------------------------------------------------------
    mov     ax, 0xC000
    mov     es, ax
    mov     ax, [es:0]

    ; Print detected signature
    push    ax
    mov     si, msg_dbg_video_rom_sig
    call    fw_log
    pop     ax
    push    ax
    mov     al, ah                          ; Print high byte first
    call    fw_log_hex_byte
    pop     ax
    call    fw_log_hex_byte
    mov     si, msg_newline
    call    fw_log

    cmp     word [es:0], 0xAA55
    jne     .no_video_rom

    ; -------------------------------------------------------------------------
    ; 2b. Verify Option ROM Length & Checksum
    ;     Byte 2 = length in 512-byte blocks. Sum of all bytes mod 256 must be 0.
    ; -------------------------------------------------------------------------
    movzx   ecx, byte [es:2]
    test    ecx, ecx
    jz      .no_video_rom
    shl     ecx, 9                          ; Length in bytes (ecx = count * 512)

    xor     dl, dl                          ; Checksum accumulator
    xor     di, di
.chksum_loop:
    add     dl, [es:di]
    inc     di
    dec     ecx
    jnz     .chksum_loop

    test    dl, dl
    jnz     .no_video_rom                   ; Checksum invalid -> do not execute!

    ; Valid Option ROM detected!
    mov     si, msg_dbg_video_rom_call
    call    fw_log

    ; -------------------------------------------------------------------------
    ; 3. Execute Video Option ROM Entry Point (Far Call to 0xC000:0x0003)
    ;    Per PCI 2.2 spec, the Video Option ROM entry point is at offset 0x0003
    ; -------------------------------------------------------------------------
    push    cs
    push    word .video_rom_ret
    push    word 0xC000
    push    word 0x0003
    retf                                    ; Far jump to 0xC000:0x0003 (simulates far call)

.video_rom_ret:
    ; Restore Firmware segments in case the Option ROM altered them
    mov     ax, cs
    mov     ds, ax
    xor     ax, ax
    mov     es, ax

    ; Save the Option ROM INT 10h vector at 0x0000:0x0040 to INT 42h (0x0000:0x0108)
    mov     eax, [es:0x0040]
    mov     [es:0x0108], eax

    ; Set SCRATCH_VIDEO_ROM_ACTIVE flag
    mov     byte [es:SCRATCH_VIDEO_ROM_ACTIVE], 1

    ; Reinstall Firmware int10h_handler at INT 10h (0x0000:0x0040)
    ; This enables teletype mirroring to COM1 while delegating rendering to INT 42h
    mov     word [es:0x0040], int10h_handler
    mov     word [es:0x0042], cs

    mov     si, msg_dbg_video_rom_done
    call    fw_log
    ; Option ROM initialized; the graphics card and text mode are ready.
    pop     es
    pop     ds
    popad
    clc
    ret

.no_video_rom:
    pop     es
    pop     ds
    popad
    stc
    ret

msg_dbg_video_rom_sig  db "  [Video ROM] Signature at C000:0000 = 0x", 0
msg_dbg_video_rom_call db "  [Video ROM] Invoking entry point C000:0003...", 10, 0
msg_dbg_video_rom_done db "  [Video ROM] Returned from initialization.", 10, 0
