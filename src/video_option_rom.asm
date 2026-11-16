; Map and execute PCI display Expansion ROM at 0xC000:0003, chaining INT 10h -> INT 42h.

BITS 16

; Returns CF=0 if an Option ROM initialized, CF=1 otherwise.
video_option_rom_init:
    pushad
    push    ds
    push    es

    xor     ax, ax
    mov     es, ax

    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    jne     .no_video_rom

    movzx   eax, byte [es:SCRATCH_VGA_BUS]
    shl     eax, 16
    movzx   edx, byte [es:SCRATCH_VGA_DEVFN]
    shl     edx, 8
    or      eax, edx
    mov     esi, eax                        ; base PCI address

    ; Map Expansion ROM BAR (reg 0x30) to 0x000C0000 with decode enable (bit 0)
    mov     eax, esi
    or      eax, 0x30
    mov     ecx, 0x000C0001
    call    pci_write_dword

    ; Enable I/O + MMIO decode in Command (reg 0x04)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x03
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

    ; Probe 0xAA55 ROM header at 0xC000:0x0000
    mov     ax, 0xC000
    mov     es, ax
    mov     ax, [es:0]

    push    ax
    mov     si, msg_dbg_video_rom_sig
    call    fw_log
    pop     ax
    push    ax
    mov     al, ah                          ; high byte first
    call    fw_log_hex_byte
    pop     ax
    call    fw_log_hex_byte
    mov     si, msg_newline
    call    fw_log

    cmp     word [es:0], 0xAA55
    jne     .no_video_rom

    ; Byte 2 is length in 512 B blocks; 8-bit sum must equal 0
    movzx   ecx, byte [es:2]
    test    ecx, ecx
    jz      .no_video_rom
    shl     ecx, 9

    xor     dl, dl
    xor     di, di
.chksum_loop:
    add     dl, [es:di]
    inc     di
    dec     ecx
    jnz     .chksum_loop

    test    dl, dl
    jnz     .no_video_rom

    mov     si, msg_dbg_video_rom_call
    call    fw_log

    ; Shadow Option ROM into DRAM (0xC0000..0xCFFFF) using host-bridge PAM1/PAM2
    push    esi
    push    ds
    push    es
    xor     ax, ax
    mov     ds, ax
    mov     bx, [ds:SCRATCH_HOST_DID]

    ; PAM = 0x22 (write-only to DRAM): reads hit PCI ROM, writes go to DRAM
    cmp     bx, 0x2500
    jae     .vrom_pam_write_q35
    mov     eax, 0x80000058
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFE                      ; legacy host bridge PAM1 (0x5A) / PAM2 (0x5B)
    mov     ax, 0x2222
    out     dx, ax
    jmp     .vrom_copy
.vrom_pam_write_q35:
    mov     eax, 0x80000090
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFD                      ; PCIe host bridge PAM1 (0x91)
    mov     al, 0x22
    out     dx, al
    inc     dx                              ; PAM2 (0x92)
    out     dx, al

.vrom_copy:
    mov     ax, 0xC000
    mov     ds, ax
    mov     es, ax
    movzx   ecx, byte [es:2]
    shl     ecx, 8                          ; words = (blocks * 512) / 2
    xor     si, si
    xor     di, di
    cld
    rep     movsw

    ; Switch PAM1..PAM2 to 0x33 (read/write DRAM)
    cmp     bx, 0x2500
    jae     .vrom_pam_rw_q35
    mov     eax, 0x80000058
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFE
    mov     ax, 0x3333
    out     dx, ax
    jmp     .vrom_chk_shadow
.vrom_pam_rw_q35:
    mov     eax, 0x80000090
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFD
    mov     al, 0x33
    out     dx, al
    inc     dx
    out     dx, al

.vrom_chk_shadow:
    pop     es
    pop     ds
    pop     esi

    ; Close ROM BAR if shadow DRAM stays readable; otherwise re-open ROM BAR
    ; and drop PAM override (handles setups where ROM BAR overrides PAM)
    mov     eax, esi
    or      eax, 0x30
    xor     ecx, ecx
    call    pci_write_dword
    cmp     word [es:0], 0xAA55
    je      .vrom_bar_done

    cmp     bx, 0x2500
    jae     .vrom_pam_off_q35
    mov     eax, 0x80000058
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFE
    xor     ax, ax
    out     dx, ax
    jmp     .vrom_reopen_bar
.vrom_pam_off_q35:
    mov     eax, 0x80000090
    mov     dx, 0x0CF8
    out     dx, eax
    mov     dx, 0x0CFD
    xor     al, al
    out     dx, al
    inc     dx
    out     dx, al
.vrom_reopen_bar:
    mov     eax, esi
    or      eax, 0x30
    mov     ecx, 0x000C0001
    call    pci_write_dword

.vrom_bar_done:
    ; PCI firmware spec: pass AH=bus, AL=devfn in AX
    push    ds
    xor     bx, bx
    mov     ds, bx
    mov     ah, [ds:SCRATCH_VGA_BUS]
    mov     al, [ds:SCRATCH_VGA_DEVFN]
    pop     ds

    ; Far call to Option ROM entry point at 0xC000:0x0003
    push    cs
    push    word .video_rom_ret
    push    word 0xC000
    push    word 0x0003
    retf

.video_rom_ret:
    ; Restore segments in case Option ROM modified DS/ES
    mov     ax, cs
    mov     ds, ax
    xor     ax, ax
    mov     es, ax

    ; Save Option ROM INT 10h vector at INT 42h (0x0108)
    mov     eax, [es:0x0040]
    mov     [es:0x0108], eax

    mov     byte [es:SCRATCH_VIDEO_ROM_ACTIVE], 1

    ; Keep firmware INT 10h installed so AH=0Eh mirrors to COM1 before INT 42h
    mov     word [es:0x0040], int10h_handler
    mov     word [es:0x0042], cs

    mov     si, msg_dbg_video_rom_done
    call    fw_log
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
