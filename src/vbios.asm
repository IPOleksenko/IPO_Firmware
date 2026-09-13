; vbios.asm — PCI Video Option ROM (VBIOS) Loader and Execution
; Discovers GPU Expansion ROM, maps and copies it to 0xC000:0000, and calls
; the 16-bit real-mode VBIOS entry point (0xC000:0003) to wake up physical displays.

BITS 16

; =============================================================================
; vbios_init — Search for GPU Option ROM and initialize real graphics hardware
; =============================================================================
vbios_init:
    pushad
    push    ds
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Check if VGA device was discovered during PCI enumeration
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .no_vbios

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
    mov     si, msg_dbg_vbios_sig
    call    bios_log
    pop     ax
    push    ax
    mov     al, ah                          ; Print high byte first
    call    bios_log_hex_byte
    pop     ax
    call    bios_log_hex_byte
    mov     si, msg_newline
    call    bios_log

    cmp     word [es:0], 0xAA55
    jne     .no_vbios

    ; Valid Option ROM detected!
    mov     si, msg_dbg_vbios_call
    call    bios_log

    ; -------------------------------------------------------------------------
    ; 3. Execute VBIOS Entry Point (Far Call to 0xC000:0x0003)
    ;    Per IBM PC & PCI 2.2 spec, VBIOS entry point is at offset 0x0003
    ; -------------------------------------------------------------------------
    push    cs
    push    word .vbios_ret
    push    word 0xC000
    push    word 0x0003
    retf                                    ; Far jump to 0xC000:0x0003 (simulates far call)

.vbios_ret:
    mov     si, msg_dbg_vbios_done
    call    bios_log
    ; VBIOS initialized! Graphics card is active and text mode is ready.
    pop     es
    pop     ds
    popad
    clc
    ret

.no_vbios:
    pop     es
    pop     ds
    popad
    stc
    ret

msg_dbg_vbios_sig   db "  [VBIOS] Signature at C000:0000 = 0x", 0
msg_dbg_vbios_call  db "  [VBIOS] Invoking VBIOS at C000:0003...", 10, 0
msg_dbg_vbios_done  db "  [VBIOS] Returned from VBIOS initialization.", 10, 0
