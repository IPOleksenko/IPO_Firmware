; Real-mode SATA AHCI driver (uses FS 4 GiB unreal mode for 32-bit HBA MMIO and DMA)

BITS 16

; Load FS with a 4 GiB flat descriptor (G=1, D/B=0) using a temp stack GDT
enable_unreal_mode:
    push    eax
    push    ebx
    push    ds

    cli
    ; Selector 0x08: 4 GiB flat data, selector 0x00: null
    push    dword 0x008F9200
    push    dword 0x0000FFFF
    push    dword 0
    push    dword 0

    ; Linear GDT base = (SS << 4) + SP
    mov     bx, ss
    movzx   ebx, bx
    shl     ebx, 4
    movzx   eax, sp
    add     ebx, eax

    push    ebx
    push    word 15

    mov     bx, sp
    lgdt    [ss:bx]
    add     sp, 6

    mov     eax, cr0
    or      al, 0x01
    mov     cr0, eax
    jmp     short $+2                       ; serialize pipeline

    mov     ax, 0x08
    mov     fs, ax

    mov     eax, cr0
    and     al, 0xFE
    mov     cr0, eax
    jmp     FW_RAM_SEG:.real_mode           ; reload CS and flush prefetch queue
.real_mode:

    add     sp, 16

    pop     ds
    pop     ebx
    pop     eax
    ret

; Initialize first SATA disk on discovered AHCI HBA; returns CF=0 on success.
ahci_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax

    cmp     byte [es:SCRATCH_AHCI_FOUND], 1
    jne     .ahci_not_found

    call    enable_unreal_mode

    mov     esi, [es:SCRATCH_AHCI_BAR5]     ; ABAR
    test    esi, esi
    jz      .ahci_not_found

    ; Set GHC.AE (ABAR + 0x04 bit 31)
    a32 mov eax, [fs:esi + 0x04]
    or      eax, 0x80000000
    a32 mov [fs:esi + 0x04], eax

    ; Read PI (implemented ports mask at ABAR + 0x0C)
    a32 mov eax, [fs:esi + 0x0C]
    mov     [es:SCRATCH_AHCI_PORTS], eax
    test    eax, eax
    jz      .ahci_not_found

    xor     ecx, ecx
.port_loop:
    mov     eax, [es:SCRATCH_AHCI_PORTS]
    bt      eax, ecx
    jnc     .next_port

    ; PxBase = ABAR + 0x100 + (port * 0x80)
    mov     edi, ecx
    shl     edi, 7
    add     edi, 0x100
    add     edi, esi

    ; Assert SUD (bit 1) and POD (bit 2) in PxCMD (+0x18)
    a32 mov eax, [fs:edi + 0x18]
    or      eax, 0x00000006
    a32 mov [fs:edi + 0x18], eax

    ; PxSSTS (+0x28) DET[3:0] == 3 means device present and PHY up
    a32 mov eax, [fs:edi + 0x28]
    and     al, 0x0F
    cmp     al, 0x03
    jne     .next_port

    ; Skip ATAPI (0xEB140101), Port Multiplier (0x96690101), SEMB (0xC33C0101)
    a32 mov eax, [fs:edi + 0x24]
    cmp     eax, 0xEB140101
    je      .next_port
    cmp     eax, 0x96690101
    je      .next_port
    cmp     eax, 0xC33C0101
    je      .next_port
    jmp     .port_connected

.next_port:
    inc     ecx
    cmp     ecx, 32
    jb      .port_loop

    jmp     .ahci_not_found

.port_connected:
    mov     byte [es:SCRATCH_AHCI_PORT_N], cl

    ; Stop port: clear PxCMD.ST (bit 0) and PxCMD.FRE (bit 4)
    a32 mov eax, [fs:edi + 0x18]
    and     eax, ~0x0011
    a32 mov [fs:edi + 0x18], eax

    ; Wait for PxCMD.CR (bit 15) and PxCMD.FR (bit 14) to clear
    mov     bp, 0x1000
.wait_stop:
    a32 mov eax, [fs:edi + 0x18]
    test    eax, 0xC000
    jz      .port_stopped
    dec     bp
    jnz     .wait_stop
.port_stopped:

    ; Program PxCLB (+0x00) and PxFB (+0x08)
    mov     dword [es:SCRATCH_AHCI_PXBASE], edi
    a32 mov dword [fs:edi + 0x00], AHCI_CMD_LIST_ADDR
    a32 mov dword [fs:edi + 0x04], 0

    a32 mov dword [fs:edi + 0x08], AHCI_RX_FIS_ADDR
    a32 mov dword [fs:edi + 0x0C], 0

    ; Clear PxSERR (+0x30) and PxIS (+0x10)
    a32 mov dword [fs:edi + 0x30], 0xFFFFFFFF
    a32 mov dword [fs:edi + 0x10], 0xFFFFFFFF

    ; Start port: set PxCMD.FRE (bit 4) and PxCMD.ST (bit 0)
    a32 mov eax, [fs:edi + 0x18]
    or      eax, 0x0011
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

; Read sectors using AHCI DMA.
; Inputs: EBX=LBA, CX=count (1..128), ES:DI=dst buffer.
; Output: CF=0 on success, CF=1 with AH=status on error.
ahci_read_sectors:
    pushad
    push    ds
    push    es

    ; Linear destination = (ES << 4) + DI
    mov     ax, es
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, di
    add     eax, edx
    mov     ebp, eax

    xor     ax, ax
    mov     es, ax
    mov     edi, [es:SCRATCH_AHCI_PXBASE]

    call    enable_unreal_mode

    ; Command header slot 0: PRDTL=1, CFL=5 dwords -> 0x00010005
    mov     esi, AHCI_CMD_LIST_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00010005
    a32 mov dword [fs:esi + 0x04], 0
    a32 mov dword [fs:esi + 0x08], AHCI_CMD_TAB_ADDR
    a32 mov dword [fs:esi + 0x0C], 0

    ; 20 B Host-to-Device Register FIS at AHCI_CMD_TAB_ADDR
    mov     esi, AHCI_CMD_TAB_ADDR

    a32 mov dword [fs:esi + 0x00], 0
    a32 mov dword [fs:esi + 0x04], 0
    a32 mov dword [fs:esi + 0x08], 0
    a32 mov dword [fs:esi + 0x0C], 0
    a32 mov dword [fs:esi + 0x10], 0

    ; FIS DW0: ATA READ DMA EXT (0x25), C=1 (0x80), FIS type 0x27
    a32 mov dword [fs:esi + 0x00], 0x00258027

    ; FIS DW1: Device=0x40 (LBA) | LBA[23:0]
    mov     eax, ebx
    and     eax, 0x00FFFFFF
    or      eax, 0x40000000
    a32 mov [fs:esi + 0x04], eax

    ; FIS DW2: LBA[31:24]
    mov     eax, ebx
    shr     eax, 24
    and     eax, 0x000000FF
    a32 mov [fs:esi + 0x08], eax

    ; FIS DW3: sector count
    movzx   eax, cx
    a32 mov [fs:esi + 0x0C], eax

    ; PRDT entry 0 (+0x80)
    a32 mov [fs:esi + 0x80], ebp
    a32 mov dword [fs:esi + 0x84], 0
    a32 mov dword [fs:esi + 0x88], 0

    ; DBC = (sectors * 512) - 1, bit 31 = IOC
    movzx   eax, cx
    shl     eax, 9
    dec     eax
    or      eax, 0x80000000
    a32 mov [fs:esi + 0x8C], eax

    ; Issue slot 0 in PxCI (+0x38)
    a32 mov dword [fs:edi + 0x38], 0x00000001

    mov     ecx, 0x000FFFFF
.poll_ci:
    a32 mov eax, [fs:edi + 0x38]
    test    eax, 0x00000001
    jz      .cmd_finished

    a32 mov eax, [fs:edi + 0x20]            ; PxTFD ERR bit 0
    test    al, 0x01
    jnz     .cmd_error

    dec     ecx
    jnz     .poll_ci

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
    mov     ah, 0x04
    stc
    ret
