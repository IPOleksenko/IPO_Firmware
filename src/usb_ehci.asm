; usb_ehci.asm — USB 2.0 EHCI Host Controller & Mass Storage (BOT) Driver
; Discovers USB storage drives (flash drives), enumerates ports, and implements
; SCSI READ(10) via Bulk-Only Transport (BOT) for INT 13h boot.

BITS 16

; =============================================================================
; Memory Layout for EHCI USB Transfers (in safe low conventional memory)
; =============================================================================
EHCI_QH_ADDR        equ 0x2000      ; Queue Head (64 bytes aligned)
EHCI_QTD_ADDR       equ 0x2100      ; Queue Transfer Descriptor (32 bytes aligned)
EHCI_CBW_ADDR       equ 0x2200      ; 31-byte Command Block Wrapper
EHCI_CSW_ADDR       equ 0x2280      ; 13-byte Command Status Wrapper
EHCI_SETUP_ADDR     equ 0x2300      ; 8-byte Setup Packet

; =============================================================================
; usb_init — Initialize USB EHCI Host Controller and detect USB Flash Drive
; Returns: CF = 0 if USB flash drive detected, CF = 1 if none found
; =============================================================================
usb_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Check if EHCI was discovered by PCI scan
    cmp     byte [es:SCRATCH_USB_FOUND], 1
    jne     .usb_fail
    cmp     byte [es:SCRATCH_USB_TYPE], 1       ; 1 = EHCI
    je      .is_ehci
    cmp     byte [es:SCRATCH_USB_TYPE], 2       ; 2 = xHCI
    jne     .usb_fail
    mov     si, msg_xhci_note
    call    bios_log
    jmp     .usb_fail

.is_ehci:
    mov     esi, [es:SCRATCH_USB_BAR0]      ; ESI = EHCI Base Address
    test    esi, esi
    jz      .usb_fail

    ; Enable 4GB access via FS
    call    ahci_enable_unreal_mode

    ; 1. Read CAPLENGTH (offset 0x00, 1 byte)
    ; Operational Registers Base = BAR0 + CAPLENGTH
    a32 movzx ebp, byte [fs:esi + 0x00]
    add     ebp, esi                        ; EBP = OpRegs Base
    mov     [es:SCRATCH_USB_BAR0 + 4], ebp  ; Save OpRegs Base in Scratch RAM

    ; 2. Route all ports to EHCI: write 1 to CONFIGFLAG (OpRegs + 0x40)
    a32 mov dword [fs:ebp + 0x40], 0x00000001

    ; Clear 64-bit segment (CTRLDSSEGMENT at OpRegs + 0x10)
    a32 mov dword [fs:ebp + 0x10], 0x00000000

    ; 3. Read N_PORTS from HCSPARAMS (BAR0 + 0x04, bits 3:0)
    a32 mov eax, [fs:esi + 0x04]
    and     eax, 0x0F                       ; AL = number of ports (usually 2..8)
    mov     ecx, eax
    test    ecx, ecx
    jz      .usb_fail

    ; 4. Scan ports for connected device: PORTSC registers start at OpRegs + 0x44
    xor     ebx, ebx                        ; Port index 0..N-1
.port_scan:
    mov     edi, ebx
    shl     edi, 2                          ; port * 4
    add     edi, ebp
    add     edi, 0x44                       ; EDI = PORTSC address

    ; Read PORTSC: check bit 0 (Current Connect Status)
    a32 mov eax, [fs:edi]
    test    al, 0x01
    jnz     .port_found

    inc     ebx
    cmp     ebx, ecx
    jb      .port_scan

    ; No USB drive plugged in
    jmp     .usb_fail

.port_found:
    ; USB device found on port EBX!
    ; 5. Reset the port: set bit 8 (Port Reset) in PORTSC
    ; Write-1-to-clear status bits (bits 1, 3) must be preserved as 0
    a32 mov eax, [fs:edi]
    and     eax, ~0x002A                    ; Preserve R/W bits, clear status change bits
    or      eax, 0x00000100                 ; Set Port Reset (bit 8)
    a32 mov [fs:edi], eax

    ; Wait ~50ms for USB port reset pulse (using PIT counter or loop delay)
    mov     edx, 0x00020000
.wait_reset:
    dec     edx
    jnz     .wait_reset

    ; Clear Port Reset bit (bit 8 = 0)
    a32 mov eax, [fs:edi]
    and     eax, ~0x0000012A                ; Clear bit 8
    a32 mov [fs:edi], eax

    ; Wait ~10ms for port recovery and check Port Enable (bit 2)
    mov     edx, 0x0000FFFF
.wait_enable:
    a32 mov eax, [fs:edi]
    test    al, 0x04                        ; Port Enabled?
    jnz     .port_ready
    dec     edx
    jnz     .wait_enable

    ; Port didn't enable (likely Low/Full speed device handed off to companion controller)
    jmp     .usb_fail

.port_ready:
    ; 6. Start EHCI: set Run/Stop (bit 0) in USBCMD (OpRegs + 0x00)
    a32 mov eax, [fs:ebp + 0x00]
    or      eax, 0x00000001                 ; Run/Stop = 1
    a32 mov [fs:ebp + 0x00], eax

    ; Save active port PORTSC address for transfer operations
    mov     [es:SCRATCH_USB_BAR0 + 8], edi

    ; 7. Send SET_CONFIGURATION 1 to Control Endpoint 0 to activate Bulk endpoints
    call    usb_set_configuration_1

    ; 8. Test Unit Ready to clear SCSI Unit Attention (Power-on/Reset condition)
    call    usb_test_unit_ready

    pop     es
    popad
    clc
    ret

.usb_fail:
    pop     es
    popad
    stc
    ret

; =============================================================================
; usb_test_unit_ready — Send SCSI TEST UNIT READY (Opcode 0x00)
; Loops up to 5 times to allow drive to clear Unit Attention / spin up
; =============================================================================
usb_test_unit_ready:
    pushad

    mov     di, 5                           ; Up to 5 attempts
.tur_loop:
    mov     esi, EHCI_CBW_ADDR
    ; Dword 0: "USBC"
    a32 mov dword [fs:esi + 0x00], 0x43425355
    ; Dword 1: Tag
    a32 mov dword [fs:esi + 0x04], 0x00000002
    ; Dword 2: Data Transfer Length = 0
    a32 mov dword [fs:esi + 0x08], 0x00000000
    ; Byte 12: Flags = 0 (No data)
    a32 mov byte [fs:esi + 0x0C], 0x00
    ; Byte 13: LUN = 0
    a32 mov byte [fs:esi + 0x0D], 0x00
    ; Byte 14: Command Length = 6
    a32 mov byte [fs:esi + 0x0E], 0x06

    ; CDB: TEST UNIT READY (6 bytes of 0x00)
    a32 mov dword [fs:esi + 0x0F], 0x00000000
    a32 mov word  [fs:esi + 0x13], 0x0000

    ; Step 1: Send CBW (31 bytes, Bulk OUT EP 2)
    mov     al, 0                           ; PID = 0 (OUT)
    mov     cx, 31
    mov     edx, EHCI_CBW_ADDR
    mov     bl, 2                           ; Bulk OUT EP 2
    call    ehci_exec_transfer
    jc      .tur_retry

    ; Step 2: Receive CSW (13 bytes, Bulk IN EP 1)
    mov     al, 1                           ; PID = 1 (IN)
    mov     cx, 13
    mov     edx, EHCI_CSW_ADDR
    mov     bl, 1                           ; Bulk IN EP 1
    call    ehci_exec_transfer
    jc      .tur_retry

    ; Check CSW status at offset +12: 0 = Passed
    a32 mov al, byte [fs:EHCI_CSW_ADDR + 12]
    test    al, al
    jz      .tur_done

.tur_retry:
    ; Delay ~10ms between attempts
    mov     ecx, 0x0000FFFF
.tur_delay:
    dec     ecx
    jnz     .tur_delay

    dec     di
    jnz     .tur_loop

.tur_done:
    popad
    ret

; =============================================================================
; usb_read_sectors — Read sectors from USB flash drive via SCSI READ(10)
; Inputs:
;   EBX = Starting LBA
;   CX  = Sector count (1..128)
;   ES:DI = Target buffer address
; Output:
;   CF = 0 on success, CF = 1 on error (AH = status code)
; =============================================================================
usb_read_sectors:
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

    ; Retry loop counter on stack (or BP)
    push    word 3                          ; 3 attempts
.retry_read_loop:
    mov     esi, EHCI_CBW_ADDR

    ; -------------------------------------------------------------------------
    ; 1. Construct 31-byte Command Block Wrapper (CBW)
    ; -------------------------------------------------------------------------
    ; Dword 0: Signature "USBC" = 0x43425355
    a32 mov dword [fs:esi + 0x00], 0x43425355
    ; Dword 1: Tag = 0x00000001
    a32 mov dword [fs:esi + 0x04], 0x00000001
    ; Dword 2: Data Transfer Length = sectors * 512 bytes
    movzx   eax, cx
    shl     eax, 9                          ; sectors * 512
    a32 mov [fs:esi + 0x08], eax
    ; Byte 12: Flags = 0x80 (Data-In: device to host)
    a32 mov byte [fs:esi + 0x0C], 0x80
    ; Byte 13: LUN = 0
    a32 mov byte [fs:esi + 0x0D], 0x00
    ; Byte 14: Command Length = 10 bytes (SCSI READ(10))
    a32 mov byte [fs:esi + 0x0E], 10

    ; -------------------------------------------------------------------------
    ; SCSI READ(10) Command Block (10 bytes at offset +0x0F)
    ; -------------------------------------------------------------------------
    ; Opcode 0x28 = READ(10)
    a32 mov byte [fs:esi + 0x0F], 0x28
    a32 mov byte [fs:esi + 0x10], 0x00      ; Flags

    ; 32-bit LBA in Big-Endian:
    bswap   ebx                             ; Convert EBX to Big-Endian
    a32 mov [fs:esi + 0x11], ebx            ; LBA (bytes 2..5)
    bswap   ebx                             ; Restore original EBX

    a32 mov byte [fs:esi + 0x15], 0x00      ; Reserved

    ; 16-bit Transfer Length in Big-Endian (sectors):
    mov     al, ch                          ; High byte
    mov     ah, cl                          ; Low byte
    a32 mov [fs:esi + 0x16], ax             ; Count (bytes 7..8)
    a32 mov byte [fs:esi + 0x18], 0x00      ; Control

    ; -------------------------------------------------------------------------
    ; 2. Execute Async Transfers for BOT (Bulk-Only Transport)
    ;    Step A: Send 31-byte CBW on Bulk-OUT (Endpoint 2)
    ;    Step B: Receive 512-byte Sector Data on Bulk-IN (Endpoint 1) to EBP
    ;    Step C: Receive 13-byte CSW on Bulk-IN (Endpoint 1)
    ; -------------------------------------------------------------------------
    ; Step A: Send CBW
    mov     al, 0                           ; PID = 0 (OUT)
    push    cx
    mov     cx, 31                          ; Length = 31 bytes
    mov     edx, EHCI_CBW_ADDR              ; Source buffer
    mov     bl, 2                           ; Bulk OUT Endpoint 2
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    ; Step B: Receive Data
    push    cx
    movzx   eax, cx
    shl     eax, 9                          ; Sector count * 512
    mov     cx, ax
    mov     al, 1                           ; PID = 1 (IN)
    mov     edx, ebp                        ; Target buffer (0x7C00)
    mov     bl, 1                           ; Bulk IN Endpoint 1
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    ; Step C: Receive CSW
    mov     al, 1                           ; PID = 1 (IN)
    push    cx
    mov     cx, 13                          ; Length = 13 bytes
    mov     edx, EHCI_CSW_ADDR
    mov     bl, 1                           ; Bulk IN Endpoint 1
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    ; Check CSW status at offset +12: 0 = Passed
    a32 mov al, byte [fs:EHCI_CSW_ADDR + 12]
    test    al, al
    jz      .read_success                   ; Succeeded!

.read_failed_try:
    dec     word [esp]                      ; Decrement attempt count
    jnz     .retry_read_loop

    ; All retries exhausted
    add     esp, 2                          ; Clean stack
    pop     es
    pop     ds
    popad
    mov     ah, 0x04                        ; Sector read error
    stc
    ret

.read_success:
    add     esp, 2                          ; Clean stack
    pop     es
    pop     ds
    popad
    xor     ah, ah
    clc
    ret

; =============================================================================
; ehci_exec_transfer — Execute a single QH/qTD transaction on EHCI
; Inputs:
;   AL = PID (0=OUT, 1=IN, 2=SETUP)
;   CX = Transfer length (bytes)
;   EDX = Physical buffer pointer
;   BL = Endpoint number
; Returns: CF = 0 on success, CF = 1 on timeout/error
; =============================================================================
ehci_exec_transfer:
    pushad

    ; 1. Construct qTD at EHCI_QTD_ADDR
    mov     esi, EHCI_QTD_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00000001 ; Next qTD = Terminate
    a32 mov dword [fs:esi + 0x04], 0x00000001 ; Alt qTD = Terminate

    ; Build Token: Status(Active=0x80) | PID(AL << 8) | Cerr(3 << 10) | TotalBytes(CX << 16) | IOC(1 << 15)
    movzx   eax, al
    shl     eax, 8                          ; PID in bits [9:8]
    or      eax, 0x00008C80                 ; Active (bit 7) + Cerr=3 (bits 11:10) + IOC (bit 15)
    movzx   edi, cx
    shl     edi, 16                         ; Total bytes in bits [30:16]
    or      eax, edi
    a32 mov [fs:esi + 0x08], eax            ; Store Token

    ; Buffer Pointer 0 (offset +0x0C)
    a32 mov [fs:esi + 0x0C], edx
    a32 mov dword [fs:esi + 0x10], 0
    a32 mov dword [fs:esi + 0x14], 0
    a32 mov dword [fs:esi + 0x18], 0
    a32 mov dword [fs:esi + 0x1C], 0

    ; 2. Construct Queue Head at EHCI_QH_ADDR
    mov     esi, EHCI_QH_ADDR
    ; Dword 0: Horiz Pointer -> points to itself with Type = QH (bit 1 = 1)
    a32 mov dword [fs:esi + 0x00], (EHCI_QH_ADDR | 0x02)

    ; Dword 1: Endpoint Char: EpNum(BL << 8) | EPS(2 << 12, High-Speed) | MaxPacket | DTC(1 << 14)
    movzx   eax, bl
    shl     eax, 8                          ; Endpoint number
    test    bl, bl
    jnz     .bulk_char
    ; Control EP 0: MaxPacket = 64 (0x0040), C-flag = 1 (bit 27), H-flag = 1 (bit 15)
    or      eax, 0x0840E000
    jmp     .store_ep_char
.bulk_char:
    ; Bulk EP 1/2: MaxPacket = 512 (0x0200), H-flag = 1 (bit 15)
    or      eax, 0x0200E000
.store_ep_char:
    a32 mov [fs:esi + 0x04], eax

    ; Dword 2: Endpoint Caps: High-Bandwidth Mult = 1 (1 << 30)
    a32 mov dword [fs:esi + 0x08], 0x40000000

    ; Dword 3: Current qTD = 0
    a32 mov dword [fs:esi + 0x0C], 0

    ; Dword 4: Overlay Next qTD = EHCI_QTD_ADDR
    a32 mov dword [fs:esi + 0x10], EHCI_QTD_ADDR
    a32 mov dword [fs:esi + 0x14], 0x00000001 ; Alt qTD = Terminate
    a32 mov dword [fs:esi + 0x18], 0          ; Overlay Token = 0

    ; 3. Program ASYNCLISTADDR and Start Async Schedule
    xor     ax, ax
    mov     es, ax
    mov     ebp, [es:SCRATCH_USB_BAR0 + 4]  ; EBP = OpRegs Base
    a32 mov dword [fs:ebp + 0x18], EHCI_QH_ADDR

    ; Set ASE (bit 5) in USBCMD (OpRegs + 0x00)
    a32 mov eax, [fs:ebp + 0x00]
    or      eax, 0x00000020                 ; Async Schedule Enable
    a32 mov [fs:ebp + 0x00], eax

    ; 4. Poll qTD Token for completion (bit 7 = Active)
    mov     ecx, 0x000FFFFF
.poll_qtd:
    mov     esi, EHCI_QTD_ADDR
    a32 mov eax, [fs:esi + 0x08]
    test    al, 0x80                        ; Active bit still 1?
    jz      .qtd_done
    dec     ecx
    jnz     .poll_qtd

    ; Timeout! Stop schedule and exit
    jmp     .qtd_err

.qtd_done:
    ; Stop Async Schedule: clear ASE (bit 5)
    a32 mov eax, [fs:ebp + 0x00]
    and     eax, ~0x00000020
    a32 mov [fs:ebp + 0x00], eax

    popad
    clc
    ret

.qtd_err:
    ; Stop Async Schedule on error
    a32 mov eax, [fs:ebp + 0x00]
    and     eax, ~0x00000020
    a32 mov [fs:ebp + 0x00], eax

    popad
    stc
    ret

; =============================================================================
; usb_set_configuration_1 — Send SET_CONFIGURATION(1) to EP0
; Activates Mass Storage Bulk endpoints on the connected USB device
; =============================================================================
usb_set_configuration_1:
    pushad

    mov     esi, EHCI_SETUP_ADDR
    ; Setup packet: bmRequestType=0x00, bRequest=0x09 (SET_CONFIG), wValue=1, wIndex=0, wLength=0
    a32 mov dword [fs:esi + 0x00], 0x00010900
    a32 mov dword [fs:esi + 0x04], 0x00000000

    ; 1. Send SETUP packet (PID = 2, Length = 8, Endpoint = 0)
    mov     al, 2                           ; PID = 2 (SETUP)
    mov     cx, 8
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl                          ; Control EP 0
    call    ehci_exec_transfer

    ; 2. Status IN stage (PID = 1, Length = 0, Endpoint = 0)
    mov     al, 1                           ; PID = 1 (IN)
    xor     cx, cx                          ; 0 bytes
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl                          ; Control EP 0
    call    ehci_exec_transfer

    popad
    ret

msg_xhci_note db "  [USB] xHCI controller detected; EHCI driver skipped.", 10, 0
