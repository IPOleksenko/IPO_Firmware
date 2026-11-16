; USB EHCI host controller and Bulk-Only Transport (BOT) SCSI READ(10) driver

BITS 16

; EHCI DMA structures in low conventional memory
EHCI_QH_ADDR        equ 0x2000      ; Queue Head (64 B aligned)
EHCI_QTD_ADDR       equ 0x2100      ; Queue Transfer Descriptor (32 B aligned)
EHCI_CBW_ADDR       equ 0x2200      ; 31 B Command Block Wrapper
EHCI_CSW_ADDR       equ 0x2280      ; 13 B Command Status Wrapper
EHCI_SETUP_ADDR     equ 0x2300      ; 8 B Setup packet

; Probe EHCI ports, enumerate device, and issue TEST UNIT READY; returns CF=0 on success.
usb_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax

    cmp     byte [es:SCRATCH_USB_FOUND], 1
    jne     .usb_fail
    cmp     byte [es:SCRATCH_USB_TYPE], 1       ; EHCI
    je      .is_ehci
    cmp     byte [es:SCRATCH_USB_TYPE], 2       ; xHCI
    jne     .usb_fail
    mov     si, msg_xhci_note
    call    fw_log
    jmp     .usb_fail

.is_ehci:
    mov     esi, [es:SCRATCH_USB_BAR0]
    test    esi, esi
    jz      .usb_fail

    call    enable_unreal_mode

    ; Operational registers = BAR0 + CAPLENGTH (+0x00)
    a32 movzx ebp, byte [fs:esi + 0x00]
    add     ebp, esi
    mov     [es:SCRATCH_USB_BAR0 + 4], ebp

    ; Route ports to EHCI (CONFIGFLAG +0x40 = 1) and zero 64-bit segment (+0x10)
    a32 mov dword [fs:ebp + 0x40], 0x00000001
    a32 mov dword [fs:ebp + 0x10], 0x00000000

    ; N_PORTS from HCSPARAMS (+0x04 bits 3:0)
    a32 mov eax, [fs:esi + 0x04]
    and     eax, 0x0F
    mov     ecx, eax
    test    ecx, ecx
    jz      .usb_fail

    xor     ebx, ebx
.port_scan:
    mov     edi, ebx
    shl     edi, 2
    add     edi, ebp
    add     edi, 0x44                       ; PORTSC[port]

    a32 mov eax, [fs:edi]
    test    al, 0x01                        ; Current Connect Status
    jnz     .port_found

    inc     ebx
    cmp     ebx, ecx
    jb      .port_scan

    jmp     .usb_fail

.port_found:
    ; Assert Port Reset (bit 8) while leaving W1C status bits (bits 1, 3, 5) clear
    a32 mov eax, [fs:edi]
    and     eax, ~0x002A
    or      eax, 0x00000100
    a32 mov [fs:edi], eax

    ; ~50 ms reset pulse
    mov     edx, 0x00020000
.wait_reset:
    dec     edx
    jnz     .wait_reset

    a32 mov eax, [fs:edi]
    and     eax, ~0x0000012A                ; clear Port Reset + W1C bits
    a32 mov [fs:edi], eax

    ; ~10 ms recovery; check Port Enable (bit 2)
    mov     edx, 0x0000FFFF
.wait_enable:
    a32 mov eax, [fs:edi]
    test    al, 0x04
    jnz     .port_ready
    dec     edx
    jnz     .wait_enable

    ; Port did not enable (likely low/full-speed device for companion controller)
    jmp     .usb_fail

.port_ready:
    ; Start controller (USBCMD Run/Stop bit 0)
    a32 mov eax, [fs:ebp + 0x00]
    or      eax, 0x00000001
    a32 mov [fs:ebp + 0x00], eax

    mov     [es:SCRATCH_USB_BAR0 + 8], edi

    mov     byte [es:SCRATCH_USB_ADDR], 0
    mov     byte [es:SCRATCH_USB_TOGGLE_IN], 0
    mov     byte [es:SCRATCH_USB_TOGGLE_OUT], 0
    mov     byte [es:SCRATCH_USB_EP_IN], 1
    mov     byte [es:SCRATCH_USB_EP_OUT], 2

    call    usb_set_configuration_1
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

; Send SCSI TEST UNIT READY (0x00) up to 5 times to clear Unit Attention
usb_test_unit_ready:
    pushad
    push    es
    xor     ax, ax
    mov     es, ax

    mov     di, 5
.tur_loop:
    mov     esi, EHCI_CBW_ADDR
    a32 mov dword [fs:esi + 0x00], 0x43425355 ; 'USBC'
    a32 mov dword [fs:esi + 0x04], 0x00000002 ; tag
    a32 mov dword [fs:esi + 0x08], 0x00000000 ; transfer len
    a32 mov byte [fs:esi + 0x0C], 0x00        ; flags (none)
    a32 mov byte [fs:esi + 0x0D], 0x00        ; LUN
    a32 mov byte [fs:esi + 0x0E], 0x06        ; CDB len

    a32 mov dword [fs:esi + 0x0F], 0x00000000 ; TEST UNIT READY (6 B)
    a32 mov word  [fs:esi + 0x13], 0x0000

    ; Send 31 B CBW
    mov     al, 0
    mov     cx, 31
    mov     edx, EHCI_CBW_ADDR
    mov     bl, [es:SCRATCH_USB_EP_OUT]
    call    ehci_exec_transfer
    jc      .tur_retry

    ; Read 13 B CSW
    mov     al, 1
    mov     cx, 13
    mov     edx, EHCI_CSW_ADDR
    mov     bl, [es:SCRATCH_USB_EP_IN]
    call    ehci_exec_transfer
    jc      .tur_retry

    a32 mov al, byte [fs:EHCI_CSW_ADDR + 12]  ; 0 = passed
    test    al, al
    jz      .tur_done

.tur_retry:
    ; ~10 ms retry delay
    mov     ecx, 0x0000FFFF
.tur_delay:
    dec     ecx
    jnz     .tur_delay

    dec     di
    jnz     .tur_loop

.tur_done:
    pop     es
    popad
    ret

; Read sectors using SCSI READ(10) over BOT.
; Inputs: EBX=LBA, CX=count (1..128), ES:DI=dst buffer.
; Output: CF=0 on success, CF=1 with AH=status on error.
usb_read_sectors:
    pushad
    push    ds
    push    es

    call    enable_unreal_mode

    mov     ax, es
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, di
    add     eax, edx
    mov     ebp, eax                        ; physical dst buffer

    xor     ax, ax
    mov     es, ax

    push    word 3                          ; retry limit
.retry_read_loop:
    mov     esi, EHCI_CBW_ADDR

    ; 31 B CBW
    a32 mov dword [fs:esi + 0x00], 0x43425355 ; 'USBC'
    a32 mov dword [fs:esi + 0x04], 0x00000001
    movzx   eax, cx
    shl     eax, 9                          ; sectors * 512 B
    a32 mov [fs:esi + 0x08], eax
    a32 mov byte [fs:esi + 0x0C], 0x80      ; Data-In
    a32 mov byte [fs:esi + 0x0D], 0x00
    a32 mov byte [fs:esi + 0x0E], 10        ; SCSI READ(10) len

    a32 mov byte [fs:esi + 0x0F], 0x28      ; READ(10)
    a32 mov byte [fs:esi + 0x10], 0x00

    ; Big-endian 32-bit LBA
    bswap   ebx
    a32 mov [fs:esi + 0x11], ebx
    bswap   ebx

    a32 mov byte [fs:esi + 0x15], 0x00

    ; Big-endian 16-bit sector count
    mov     al, ch
    mov     ah, cl
    a32 mov [fs:esi + 0x16], ax
    a32 mov byte [fs:esi + 0x18], 0x00

    ; BOT CBW (OUT) -> Data (IN) -> CSW (IN)
    mov     al, 0
    push    cx
    mov     cx, 31
    mov     edx, EHCI_CBW_ADDR
    mov     bl, [es:SCRATCH_USB_EP_OUT]
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    push    cx
    movzx   eax, cx
    shl     eax, 9
    mov     cx, ax
    mov     al, 1
    mov     edx, ebp
    mov     bl, [es:SCRATCH_USB_EP_IN]
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    mov     al, 1
    push    cx
    mov     cx, 13
    mov     edx, EHCI_CSW_ADDR
    mov     bl, [es:SCRATCH_USB_EP_IN]
    call    ehci_exec_transfer
    pop     cx
    jc      .read_failed_try

    a32 mov al, byte [fs:EHCI_CSW_ADDR + 12]  ; 0 = passed
    test    al, al
    jz      .read_success

.read_failed_try:
    mov     bp, sp
    dec     word [bp]
    jnz     .retry_read_loop

    add     sp, 2
    pop     es
    pop     ds
    popad
    mov     ah, 0x04
    stc
    ret

.read_success:
    add     sp, 2
    pop     es
    pop     ds
    popad
    xor     ah, ah
    clc
    ret

; Execute single QH/qTD transfer.
; Inputs: AL=PID (0=OUT, 1=IN, 2=SETUP), CX=bytes, EDX=phys buf, BL=endpoint.
ehci_exec_transfer:
    pushad
    push    es

    xor     di, di
    mov     es, di
    mov     bh, al

    mov     esi, EHCI_QTD_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00000001 ; next qTD = terminate
    a32 mov dword [fs:esi + 0x04], 0x00000001 ; alt qTD = terminate

    ; Token: Active(0x80) | PID[9:8] | Cerr=3[11:10] | IOC(bit 15) | TotalBytes[30:16]
    movzx   eax, al
    shl     eax, 8
    or      eax, 0x00008C80
    movzx   edi, cx
    shl     edi, 16
    or      eax, edi

    ; Data toggle (bit 31): EP0 SETUP=DATA0, DATA/STATUS=DATA1; bulk uses saved toggle
    test    bl, bl
    jnz     .toggle_bulk
    cmp     bh, 2
    je      .toggle_ready
    or      eax, 0x80000000
    jmp     .toggle_ready
.toggle_bulk:
    cmp     bh, 1
    je      .toggle_bulk_in
    cmp     byte [es:SCRATCH_USB_TOGGLE_OUT], 0
    je      .toggle_ready
    or      eax, 0x80000000
    jmp     .toggle_ready
.toggle_bulk_in:
    cmp     byte [es:SCRATCH_USB_TOGGLE_IN], 0
    je      .toggle_ready
    or      eax, 0x80000000
.toggle_ready:
    a32 mov [fs:esi + 0x08], eax

    ; Page 0 and next 4 KiB page 1 for page-crossing transfers
    a32 mov [fs:esi + 0x0C], edx
    mov     eax, edx
    add     eax, 0x1000
    and     eax, 0xFFFFF000
    a32 mov [fs:esi + 0x10], eax
    a32 mov dword [fs:esi + 0x14], 0
    a32 mov dword [fs:esi + 0x18], 0
    a32 mov dword [fs:esi + 0x1C], 0

    mov     esi, EHCI_QH_ADDR
    a32 mov dword [fs:esi + 0x00], (EHCI_QH_ADDR | 0x02) ; self-loop, type=QH

    ; Endpoint capabilities: DevAddr | EpNum | EPS=HS(2) | DTC=1 | H=1 | MaxPacket
    movzx   eax, bl
    shl     eax, 8
    or      al, [es:SCRATCH_USB_ADDR]
    test    bl, bl
    jnz     .bulk_char
    or      eax, 0x0040E000                 ; EP0 MaxPacket=64
    jmp     .store_ep_char
.bulk_char:
    or      eax, 0x0200E000                 ; Bulk MaxPacket=512
.store_ep_char:
    a32 mov [fs:esi + 0x04], eax

    a32 mov dword [fs:esi + 0x08], 0x40000000 ; Mult=1
    a32 mov dword [fs:esi + 0x0C], 0
    a32 mov dword [fs:esi + 0x10], EHCI_QTD_ADDR
    a32 mov dword [fs:esi + 0x14], 0x00000001
    a32 mov dword [fs:esi + 0x18], 0

    mov     ebp, [es:SCRATCH_USB_BAR0 + 4]
    a32 mov dword [fs:ebp + 0x18], EHCI_QH_ADDR ; ASYNCLISTADDR

    a32 mov eax, [fs:ebp + 0x00]
    or      eax, 0x00000020                 ; Async Schedule Enable (ASE)
    a32 mov [fs:ebp + 0x00], eax

    mov     ecx, 0x000FFFFF
.poll_qtd:
    mov     esi, EHCI_QTD_ADDR
    a32 mov eax, [fs:esi + 0x08]
    test    al, 0x80                        ; Active
    jz      .qtd_done
    dec     ecx
    jnz     .poll_qtd

    jmp     .qtd_err

.qtd_done:
    ; Halted=0x40, DataBuf=0x20, Babble=0x10, XactErr=0x08
    test    al, 0x78
    jnz     .qtd_err

    ; Clear ASE
    a32 mov eax, [fs:ebp + 0x00]
    and     eax, ~0x00000020
    a32 mov [fs:ebp + 0x00], eax

    ; Save updated bulk data toggle from QH overlay token bit 31
    test    bl, bl
    jz      .skip_toggle_save
    mov     esi, EHCI_QH_ADDR
    a32 mov eax, [fs:esi + 0x18]
    shr     eax, 31
    cmp     bh, 1
    je      .save_toggle_in
    mov     [es:SCRATCH_USB_TOGGLE_OUT], al
    jmp     .skip_toggle_save
.save_toggle_in:
    mov     [es:SCRATCH_USB_TOGGLE_IN], al
.skip_toggle_save:
    pop     es
    popad
    clc
    ret

.qtd_err:
    a32 mov eax, [fs:ebp + 0x00]
    and     eax, ~0x00000020
    a32 mov [fs:ebp + 0x00], eax

    pop     es
    popad
    stc
    ret

; Assign address 1, parse Bulk IN/OUT endpoints from config descriptor, and set config 1.
usb_set_configuration_1:
    pushad
    push    es
    xor     ax, ax
    mov     es, ax

    ; SET_ADDRESS(1) on addr 0 / EP0
    mov     esi, EHCI_SETUP_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00010500
    a32 mov dword [fs:esi + 0x04], 0x00000000

    mov     al, 2                           ; SETUP
    mov     cx, 8
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl
    call    ehci_exec_transfer
    jc      .set_config_only

    mov     al, 1                           ; Status IN
    xor     cx, cx
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl
    call    ehci_exec_transfer
    jc      .set_config_only

    ; ~2 ms SetAddress recovery
    mov     ecx, 0x00004000
.addr_delay:
    dec     ecx
    jnz     .addr_delay
    mov     byte [es:SCRATCH_USB_ADDR], 1

    ; GET_DESCRIPTOR(Configuration, 32 B) to discover bulk endpoints
    a32 mov dword [fs:esi + 0x00], 0x02000680
    a32 mov dword [fs:esi + 0x04], 0x00200000

    mov     al, 2
    mov     cx, 8
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl
    call    ehci_exec_transfer
    jc      .set_config_only

    mov     al, 1
    mov     cx, 32
    mov     edx, EHCI_CSW_ADDR
    xor     bl, bl
    call    ehci_exec_transfer
    jc      .set_config_only

    mov     al, 0
    xor     cx, cx
    mov     edx, EHCI_CSW_ADDR
    xor     bl, bl
    call    ehci_exec_transfer

    ; Walk descriptor bytes for Bulk Endpoint descriptors (type=0x05, attr&3=0x02)
    mov     edi, EHCI_CSW_ADDR
    mov     cx, 26
.parse_desc:
    a32 mov al, [fs:edi + 1]                ; bDescriptorType
    cmp     al, 0x05
    jne     .next_desc_byte
    a32 mov al, [fs:edi + 3]                ; bmAttributes
    and     al, 0x03
    cmp     al, 0x02
    jne     .next_desc_byte
    a32 mov al, [fs:edi + 2]                ; bEndpointAddress
    mov     ah, al
    and     ah, 0x0F
    jz      .next_desc_byte
    test    al, 0x80                        ; bit 7: 1=IN, 0=OUT
    jz      .found_ep_out
    mov     [es:SCRATCH_USB_EP_IN], ah
    jmp     .next_desc_byte
.found_ep_out:
    mov     [es:SCRATCH_USB_EP_OUT], ah
.next_desc_byte:
    inc     edi
    loop    .parse_desc

.set_config_only:
    ; SET_CONFIGURATION(1)
    mov     esi, EHCI_SETUP_ADDR
    a32 mov dword [fs:esi + 0x00], 0x00010900
    a32 mov dword [fs:esi + 0x04], 0x00000000

    mov     al, 2
    mov     cx, 8
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl
    call    ehci_exec_transfer

    mov     al, 1
    xor     cx, cx
    mov     edx, EHCI_SETUP_ADDR
    xor     bl, bl
    call    ehci_exec_transfer

    ; Reset bulk toggles to DATA0 after SET_CONFIGURATION
    mov     byte [es:SCRATCH_USB_TOGGLE_IN], 0
    mov     byte [es:SCRATCH_USB_TOGGLE_OUT], 0

    pop     es
    popad
    ret

msg_xhci_note db "  [USB] xHCI controller detected; EHCI driver skipped.", 10, 0
