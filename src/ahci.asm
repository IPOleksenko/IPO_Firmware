; ahci.asm — SATA AHCI Controller Driver for x86 BIOS
; Implements AHCI HBA detection, port initialization, and sector reading via DMA.
; Uses Flat Real Mode (Unreal Mode with FS descriptor limit = 4GB) to access 32-bit MMIO.

BITS 16

; =============================================================================
; Unreal Mode Setup (enables FS to access full 4GB linear memory)
; =============================================================================
ahci_enable_unreal_mode:
    push    eax
    push    ebx
    push    ds

    cli
    ; Build 16-byte temporary GDT on stack:
    ; Selector 0x08: Flat 4GB Data (Base=0, Limit=4GB, G=1, D/B=0, P=1, DPL=0, S=1, Type=0x2)
    ; Value: 0x008F9200_0000FFFF
    push    dword 0x008F9200
    push    dword 0x0000FFFF
    ; Selector 0x00: Null Descriptor
    push    dword 0
    push    dword 0

    ; Compute 32-bit linear address of GDT on stack: (SS << 4) + SP
    mov     bx, ss
    movzx   ebx, bx
    shl     ebx, 4
    movzx   eax, sp
    add     ebx, eax                ; EBX = linear base of GDT

    ; Build 6-byte GDTR structure on stack
    push    ebx                     ; Linear Base (4 bytes)
    push    word 15                 ; Limit = 16 - 1 = 15 (2 bytes)

    ; Load GDTR
    mov     bx, sp
    lgdt    [ss:bx]

    ; Clean up GDTR from stack (6 bytes)
    add     sp, 6

    ; Enter protected mode briefly to load FS descriptor cache
    mov     eax, cr0
    or      al, 0x01
    mov     cr0, eax
    jmp     short $+2               ; Serialize CPU pipeline

    ; Load FS with flat 4GB selector (0x08)
    mov     ax, 0x08
    mov     fs, ax

    ; Exit protected mode back to real mode
    mov     eax, cr0
    and     al, 0xFE
    mov     cr0, eax
    jmp     FW_RAM_SEG:.real_mode           ; Far jump to flush prefetch queue and reload CS
.real_mode:

    ; Clean up GDT from stack (16 bytes)
    add     sp, 16

    pop     ds
    pop     ebx
    pop     eax
    ret

; =============================================================================
; ahci_init — Initialize AHCI Controller discovered by PCI scan
; Returns: CF = 0 on success (drive ready), CF = 1 if no SATA drive found
; =============================================================================
ahci_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Check if AHCI was found during PCI scan
    cmp     byte [es:SCRATCH_AHCI_FOUND], 1
    jne     .ahci_not_found

    ; Enable 4GB access via FS
    call    ahci_enable_unreal_mode

    mov     esi, [es:SCRATCH_AHCI_BAR5]     ; ESI = ABAR (AHCI Base Address)
    test    esi, esi
    jz      .ahci_not_found

    ; 1. Enable AHCI Mode: GHC.AE = 1 (ABAR + 0x04, bit 31)
    a32 mov eax, [fs:esi + 0x04]
    or      eax, 0x80000000
    a32 mov [fs:esi + 0x04], eax

    ; 2. Read Implemented Ports mask: PI (ABAR + 0x0C)
    a32 mov eax, [fs:esi + 0x0C]
    mov     [es:SCRATCH_AHCI_PORTS], eax
    test    eax, eax
    jz      .ahci_not_found

    ; 3. Probe ports 0..7 for connected SATA device
    xor     ecx, ecx                        ; Port index (0..7)
.port_loop:
    mov     eax, [es:SCRATCH_AHCI_PORTS]
    bt      eax, ecx
    jnc     .next_port                      ; Port not implemented

    ; Calculate Port MMIO base: PxBase = ABAR + 0x100 + (port * 0x80)
    mov     edi, ecx
    shl     edi, 7                          ; port * 128
    add     edi, 0x100
    add     edi, esi                        ; EDI = PxBase

    ; Check PxSSTS (SCR0) at offset +0x28: DET field (bits 3:0)
    ; DET == 3: Device detected and physical communication established
    a32 mov eax, [fs:edi + 0x28]
    and     al, 0x0F
    cmp     al, 0x03
    je      .port_connected

.next_port:
    inc     ecx
    cmp     ecx, 8
    jb      .port_loop

    ; No connected ports found
    jmp     .ahci_not_found

.port_connected:
    ; ECX is active port index, EDI is PxBase
    mov     byte [es:SCRATCH_AHCI_PORT_N], cl

    ; 4. Stop Port: clear PxCMD.ST (bit 0) and PxCMD.FRE (bit 4)
    a32 mov eax, [fs:edi + 0x18]
    and     eax, ~0x0011                    ; Clear bit 0 (ST) and bit 4 (FRE)
    a32 mov [fs:edi + 0x18], eax

    ; Small wait for CR (bit 15) and FR (bit 14) to clear
    mov     bp, 0x1000
.wait_stop:
    a32 mov eax, [fs:edi + 0x18]
    test    eax, 0xC000
    jz      .port_stopped
    dec     bp
    jnz     .wait_stop
.port_stopped:

    ; 5. Program Command List Base Address (PxCLB at +0x00)
    mov     dword [es:SCRATCH_AHCI_PORT_N + 1], edi ; Save PxBase for fast reads
    a32 mov dword [fs:edi + 0x00], AHCI_CMD_LIST_ADDR
    a32 mov dword [fs:edi + 0x04], 0        ; Upper 32 bits = 0

    ; 6. Program Received FIS Base Address (PxFB at +0x08)
    a32 mov dword [fs:edi + 0x08], AHCI_RX_FIS_ADDR
    a32 mov dword [fs:edi + 0x0C], 0        ; Upper 32 bits = 0

    ; 7. Clear errors: write 1s to PxSERR (offset +0x30) and clear PxIS (offset +0x10)
    a32 mov dword [fs:edi + 0x30], 0xFFFFFFFF
    a32 mov dword [fs:edi + 0x10], 0xFFFFFFFF

    ; 8. Start Port: set PxCMD.FRE (bit 4) and PxCMD.ST (bit 0)
    a32 mov eax, [fs:edi + 0x18]
    or      eax, 0x0011                     ; Set ST (bit 0) and FRE (bit 4)
    a32 mov [fs:edi + 0x18], eax

    pop     es
    popad
    clc
    ret

.ahci_not_found:
    pop     es
    popad
    stc
    ret

; =============================================================================
; ahci_read_sectors — Read sectors from SATA drive via AHCI DMA
; Inputs:
;   EBX = Starting LBA28/LBA48
;   CX  = Sector count (1..128)
;   ES:DI = Target buffer address
; Output:
;   CF = 0 on success, CF = 1 on error (AH = status code)
; =============================================================================
ahci_read_sectors:
    pushad
    push    ds
    push    es

    ; Calculate physical destination address: (ES << 4) + DI
    mov     ax, es
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, di
    add     eax, edx
    mov     ebp, eax                        ; EBP = 32-bit physical destination buffer

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)
    mov     edi, [es:SCRATCH_AHCI_PORT_N + 1] ; EDI = PxBase

    ; Ensure 4GB access via FS
    call    ahci_enable_unreal_mode

    ; -------------------------------------------------------------------------
    ; 1. Build Command Header (Slot 0 at AHCI_CMD_LIST_ADDR)
    ; -------------------------------------------------------------------------
    ; Flags (16-bit): CFL=5 (5 dwords FIS length) -> 0x0005
    ; PRDTL (16-bit): 1 entry -> 0x0001
    ; Dword 0: (PRDTL << 16) | CFL = 0x00010005
    mov     esi, AHCI_CMD_LIST_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00010005
    a32 mov dword [fs:esi + 0x04], 0        ; PRDBC = 0 (bytes transferred)
    a32 mov dword [fs:esi + 0x08], AHCI_CMD_TAB_ADDR ; Command Table Base
    a32 mov dword [fs:esi + 0x0C], 0        ; Upper 32 bits = 0

    ; -------------------------------------------------------------------------
    ; 2. Build Command Table (at AHCI_CMD_TAB_ADDR)
    ;    Offset 0x00: Host-to-Device Register FIS (20 bytes)
    ; -------------------------------------------------------------------------
    mov     esi, AHCI_CMD_TAB_ADDR

    ; Zero FIS memory
    a32 mov dword [fs:esi + 0x00], 0
    a32 mov dword [fs:esi + 0x04], 0
    a32 mov dword [fs:esi + 0x08], 0
    a32 mov dword [fs:esi + 0x0C], 0
    a32 mov dword [fs:esi + 0x10], 0

    ; FIS Dword 0: [Command(23:16) | 0x80(C-bit)(15:8) | FIS_TYPE(7:0)]
    ; ATA Command 0x25 = READ DMA EXT
    ; Value: (0x25 << 16) | (0x80 << 8) | 0x27 = 0x00258027
    a32 mov dword [fs:esi + 0x00], 0x00258027

    ; FIS Dword 1: [Device(31:24) | LBA_Mid(23:16) | LBA_Low(15:8) | LBA_0(7:0)]
    ; Device = 0x40 (LBA mode)
    mov     eax, ebx
    and     eax, 0x00FFFFFF                 ; LBA [23:0]
    or      eax, 0x40000000                 ; Set Device register bit 6 (LBA)
    a32 mov [fs:esi + 0x04], eax

    ; FIS Dword 2: [Features_High(31:24) | LBA_5(23:16) | LBA_4(15:8) | LBA_3(7:0)]
    mov     eax, ebx
    shr     eax, 24
    and     eax, 0x000000FF                 ; LBA [31:24]
    a32 mov [fs:esi + 0x08], eax

    ; FIS Dword 3: [Control(31:24) | ICC(23:16) | Count_High(15:8) | Count_Low(7:0)]
    movzx   eax, cx                         ; Sector count
    a32 mov [fs:esi + 0x0C], eax

    ; -------------------------------------------------------------------------
    ; 3. Build PRDT Entry 0 (at AHCI_CMD_TAB_ADDR + 0x80)
    ; -------------------------------------------------------------------------
    ; Data Base Address: physical buffer in EBP
    a32 mov [fs:esi + 0x80], ebp
    a32 mov dword [fs:esi + 0x84], 0        ; Upper 32 bits = 0
    a32 mov dword [fs:esi + 0x88], 0        ; Reserved = 0

    ; Byte count: (sectors * 512) - 1, bit 31 = Interrupt on Completion
    movzx   eax, cx
    shl     eax, 9                          ; sectors * 512 bytes
    dec     eax                             ; (byte_count - 1)
    or      eax, 0x80000000                 ; Set bit 31 (IOC)
    a32 mov [fs:esi + 0x8C], eax

    ; -------------------------------------------------------------------------
    ; 4. Issue Command: set bit 0 in PxCI (offset +0x38)
    ; -------------------------------------------------------------------------
    a32 mov dword [fs:edi + 0x38], 0x00000001

    ; -------------------------------------------------------------------------
    ; 5. Poll for completion: wait until PxCI bit 0 clears
    ; -------------------------------------------------------------------------
    mov     ecx, 0x000FFFFF                 ; Timeout counter
.poll_ci:
    a32 mov eax, [fs:edi + 0x38]
    test    eax, 0x00000001
    jz      .cmd_finished                   ; Bit cleared -> DMA complete!

    ; Check for error in PxTFD (offset +0x20)
    a32 mov eax, [fs:edi + 0x20]
    test    al, 0x01                        ; ERR bit (bit 0 of status)
    jnz     .cmd_error

    dec     ecx
    jnz     .poll_ci

    ; Timeout!
    jmp     .cmd_error

.cmd_finished:
    pop     es
    pop     ds
    popad
    xor     ah, ah
    clc
    ret

.cmd_error:
    pop     es
    pop     ds
    popad
    mov     ah, 0x04                        ; Sector read error
    stc
    ret
