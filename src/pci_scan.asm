; PCI bus enumeration (buses 0..7), PIRQ/ELCR IRQ routing, BAR allocator, and boot device tracking

BITS 16

; PCI config space access (mechanism 1, 0xCF8/0xCFC)
pci_read_dword:
    push    edx
    and     eax, 0xFFFFFFFC
    or      eax, 0x80000000
    mov     dx, PCI_CONFIG_ADDR
    out     dx, eax
    mov     dx, PCI_CONFIG_DATA
    in      eax, dx
    pop     edx
    ret

pci_write_dword:
    push    edx
    push    eax
    and     eax, 0xFFFFFFFC
    or      eax, 0x80000000
    mov     dx, PCI_CONFIG_ADDR
    out     dx, eax
    mov     dx, PCI_CONFIG_DATA
    mov     eax, ecx
    out     dx, eax
    pop     eax
    pop     edx
    ret

; Scan PCI buses 0..7, slots 0..31 (multi-function aware)
pci_scan_devices:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax                          ; scratch RAM segment

    ; Reset discovered flags and BAR allocation cursors
    mov     byte [es:SCRATCH_AHCI_FOUND], 0
    mov     byte [es:SCRATCH_USB_FOUND], 0
    mov     byte [es:SCRATCH_VGA_FOUND], 0
    mov     byte [es:SCRATCH_NVME_FOUND], 0
    mov     byte [es:SCRATCH_VIDEO_ROM_ACTIVE], 0
    mov     dword [es:SCRATCH_DRV_TYPE_80], 0
    mov     word [es:SCRATCH_PCI_IO_NEXT], 0xC000
    mov     dword [es:SCRATCH_PCI_MMIO_NEXT], 0xFE800000

    xor     bx, bx                          ; BH = bus (0..7), BL = slot (0..31)

.bus_loop:
    xor     bl, bl
.dev_loop:
    ; Probe function 0 first before checking multi-function bit
    movzx   eax, bh
    shl     eax, 16
    movzx   edx, bl
    shl     edx, 11
    or      eax, edx
    call    pci_read_dword
    cmp     ax, 0xFFFF
    je      .next_dev
    test    ax, ax
    jz      .next_dev

    ; Header Type (reg 0x0C, bits 23:16)
    movzx   eax, bh
    shl     eax, 16
    movzx   edx, bl
    shl     edx, 11
    or      eax, edx
    or      eax, 0x0C
    call    pci_read_dword
    shr     eax, 16
    mov     ch, 1                           ; 1 function unless bit 7 is set
    test    al, 0x80
    jz      .scan_funcs
    mov     ch, 8

.scan_funcs:
    xor     cl, cl
.fn_loop:
    call    .process_function
    inc     cl
    cmp     cl, ch
    jb      .fn_loop

.next_dev:
    inc     bl
    cmp     bl, 32
    jb      .dev_loop

    inc     bh
    cmp     bh, 8
    jb      .bus_loop

    pop     es
    popad
    ret

; Input: BH=bus, BL=slot, CL=func, ES=0x0000
.process_function:
    pushad

    movzx   eax, bh
    shl     eax, 16
    movzx   edx, bl
    shl     edx, 11
    or      eax, edx
    movzx   edx, cl
    shl     edx, 8
    or      eax, edx
    mov     esi, eax                        ; base PCI config address

    mov     eax, esi
    call    pci_read_dword
    cmp     ax, 0xFFFF
    je      .fn_done
    test    ax, ax
    jz      .fn_done

    ; EDI = Class/Subclass/ProgIF/Rev (reg 0x08)
    mov     eax, esi
    or      eax, 0x08
    call    pci_read_dword
    mov     edi, eax

    ; Bridge devices (class 0x06)
    mov     eax, edi
    shr     eax, 24
    cmp     al, 0x06
    jne     .not_bridge

    mov     eax, edi
    shr     eax, 16
    and     al, 0xFF
    cmp     al, 0x00
    je      .fn_done                        ; leave host bridge untouched
    cmp     al, 0x01
    je      .setup_isa_bridge
    cmp     al, 0x80
    je      .setup_pm_controller
    jmp     .route_pci_irq

.setup_isa_bridge:
    ; Route PIRQ[A..D] -> IRQ [10, 10, 11, 11] on ISA/LPC bridge
    mov     eax, esi
    or      eax, 0x60
    mov     ecx, 0x0B0B0A0A
    call    pci_write_dword

    ; Set ELCR level-triggered bits for IRQ 9, 10, 11 (port 0x4D1 bits 1..3)
    mov     dx, 0x04D1
    in      al, dx
    or      al, 0x0E
    out     dx, al

    ; PCIe LPC bridges (DID >= 0x2900) also expose PIRQE..H and PMBASE
    mov     eax, esi
    call    pci_read_dword
    shr     eax, 16
    cmp     ax, 0x2900
    jb      .fn_done

    ; Route PIRQE..H (reg 0x68) on PCIe LPC bridge
    mov     eax, esi
    or      eax, 0x68
    mov     ecx, 0x0B0B0A0A
    call    pci_write_dword

.setup_pm_controller:
    ; Set ACPI PM I/O base = 0x0600 on power-management controller / LPC bridge
    mov     eax, esi
    or      eax, 0x40
    mov     ecx, 0x00000601
    call    pci_write_dword

    mov     eax, esi
    or      eax, 0x44
    call    pci_read_dword
    or      al, 0x80
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x44
    call    pci_write_dword

    mov     eax, esi
    or      eax, 0x80
    call    pci_read_dword
    or      al, 0x01
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x80
    call    pci_write_dword

    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x01                        ; enable PM I/O decode
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword
    jmp     .route_pci_irq

.not_bridge:
    ; Only configure BARs on Header Type 0 endpoints
    mov     eax, esi
    or      eax, 0x0C
    call    pci_read_dword
    shr     eax, 16
    and     al, 0x7F
    jnz     .route_pci_irq

    call    pci_allocate_endpoint_bars

    ; Enable Bus Master, Memory, and I/O in Command (reg 0x04)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x07
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

.route_pci_irq:
    ; Program Interrupt Line (0x3C) if Interrupt Pin (0x3D) is 1..4
    mov     eax, esi
    or      eax, 0x3C
    call    pci_read_dword
    mov     ecx, eax
    shr     ecx, 8
    and     ecx, 0xFF                       ; 1=INTA..4=INTD
    test    ecx, ecx
    jz      .check_boot_roles
    cmp     ecx, 4
    ja      .check_boot_roles

    ; Standard PCI swizzle: pirq = (slot + pin - 1) & 3
    movzx   edx, bl
    add     edx, ecx
    dec     edx
    and     edx, 3
    movzx   edx, byte [cs:pci_pirq_irq_map + edx]
    and     eax, 0xFFFFFF00
    or      eax, edx
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x3C
    call    pci_write_dword

.check_boot_roles:
    ; Record boot-relevant display, storage, and USB controllers
    mov     eax, edi
    shr     eax, 24                         ; class code
    cmp     al, PCI_CLASS_DISPLAY
    je      .record_vga
    cmp     al, PCI_CLASS_STORAGE
    je      .record_storage
    cmp     al, PCI_CLASS_SERIAL
    je      .record_usb
    jmp     .fn_done

.record_vga:
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    je      .fn_done
    mov     byte [es:SCRATCH_VGA_FOUND], 1
    mov     byte [es:SCRATCH_VGA_BUS], bh
    mov     eax, esi
    shr     eax, 8
    mov     byte [es:SCRATCH_VGA_DEVFN], al
    mov     eax, esi
    or      eax, 0x30
    call    pci_read_dword
    mov     dword [es:SCRATCH_VGA_ROMBAR], eax
    jmp     .fn_done

.record_storage:
    mov     eax, edi
    shr     eax, 16
    and     al, 0xFF                        ; AL = Subclass
    cmp     al, PCI_SUBCLASS_AHCI
    je      .record_ahci
    cmp     al, 0x08
    je      .record_nvme
    jmp     .fn_done

.record_ahci:
    cmp     byte [es:SCRATCH_AHCI_FOUND], 1
    je      .fn_done
    mov     byte [es:SCRATCH_AHCI_FOUND], 1
    mov     byte [es:SCRATCH_AHCI_BUS], bh
    mov     eax, esi
    shr     eax, 8
    mov     byte [es:SCRATCH_AHCI_DEVFN], al
    mov     eax, esi
    or      eax, 0x24
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    mov     dword [es:SCRATCH_AHCI_BAR5], eax
    jmp     .fn_done

.record_nvme:
    cmp     byte [es:SCRATCH_NVME_FOUND], 1
    je      .fn_done
    mov     byte [es:SCRATCH_NVME_FOUND], 1
    mov     byte [es:SCRATCH_NVME_BUS], bh
    mov     eax, esi
    shr     eax, 8
    mov     byte [es:SCRATCH_NVME_DEVFN], al
    mov     eax, esi
    or      eax, 0x10
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    mov     dword [es:SCRATCH_NVME_BAR0], eax
    jmp     .fn_done

.record_usb:
    mov     eax, edi
    shr     eax, 16
    and     al, 0xFF
    cmp     al, PCI_SUBCLASS_USB
    jne     .fn_done
    mov     eax, edi
    shr     eax, 8
    and     al, 0xFF                        ; AL = ProgIF
    cmp     al, PCI_PROGIF_EHCI
    je      .rec_ehci
    cmp     al, PCI_PROGIF_XHCI
    je      .rec_xhci
    jmp     .fn_done

.rec_ehci:
    mov     dl, 1
    jmp     .rec_usb_common
.rec_xhci:
    mov     dl, 2
.rec_usb_common:
    cmp     byte [es:SCRATCH_USB_FOUND], 1
    je      .fn_done
    mov     byte [es:SCRATCH_USB_FOUND], 1
    mov     byte [es:SCRATCH_USB_TYPE], dl
    mov     byte [es:SCRATCH_USB_BUS], bh
    mov     eax, esi
    shr     eax, 8
    mov     byte [es:SCRATCH_USB_DEVFN], al
    mov     eax, esi
    or      eax, 0x10
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    mov     dword [es:SCRATCH_USB_BAR0], eax

.fn_done:
    popad
    ret

; Size and assign unconfigured BAR0..BAR5 on a type-0 endpoint.
; Input: ESI = PCI base addr, EDI = class dword, ES = 0x0000.
; Disables I/O and MMIO decode while probing BAR masks, then restores Command.
pci_allocate_endpoint_bars:
    pushad

    ; Disable I/O and Mem decode (bits 0..1) while probing BAR masks
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    push    eax
    mov     ecx, eax
    and     ecx, ~0x0003
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

    mov     ebx, 0x10                       ; BAR offset (0x10..0x24)
.bar_loop:
    cmp     ebx, 0x28
    jae     .bars_done

    ; Skip legacy compatibility IDE BAR0..BAR3 (0x10..0x1C) on class 0x01/0x01
    mov     eax, edi
    shr     eax, 16
    cmp     ax, 0x0101
    jne     .probe_bar
    cmp     ebx, 0x20
    jae     .probe_bar
    ; ProgIF bit 0 (primary) / bit 2 (secondary) == 0 means fixed legacy ports
    mov     eax, edi
    shr     eax, 8
    test    al, 0x05
    jnz     .probe_bar
    add     ebx, 4
    jmp     .bar_loop

.probe_bar:
    mov     eax, esi
    or      eax, ebx
    call    pci_read_dword
    mov     ebp, eax                        ; original BAR value

    mov     ecx, 0xFFFFFFFF
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword
    mov     eax, esi
    or      eax, ebx
    call    pci_read_dword
    mov     edx, eax                        ; size mask
    mov     ecx, ebp
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword

    test    edx, edx
    jz      .next_bar
    cmp     edx, 0xFFFFFFFF
    je      .next_bar

    test    ebp, 0x01
    jnz     .handle_io_bar

    ; MMIO BAR (32-bit or 64-bit)
    mov     cl, 0
    mov     eax, ebp
    and     al, 0x06
    cmp     al, 0x04
    jne     .mmio_32_check
    mov     cl, 1                           ; 64-bit BAR
.mmio_32_check:
    mov     eax, ebp
    and     eax, 0xFFFFFFF0
    cmp     eax, 0x80000000
    jae     .mmio_advance                   ; already inside MMIO hole

    and     edx, 0xFFFFFFF0
    jz      .mmio_advance
    not     edx
    inc     edx                             ; MMIO BAR size in bytes

    ; Place primary display BAR0 at 0xE0000000 LFB
    mov     eax, edi
    shr     eax, 24
    cmp     al, PCI_CLASS_DISPLAY
    jne     .alloc_mmio_cursor
    cmp     ebx, 0x10
    jne     .alloc_mmio_cursor
    cmp     edx, 0x10000000
    ja      .alloc_mmio_cursor
    mov     ecx, 0xE0000000
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword
    jmp     .clear_hi64_check

.alloc_mmio_cursor:
    cmp     edx, 0x04000000                 ; cap single BAR at 64 MiB
    ja      .mmio_advance
    cmp     edx, 0x1000
    jae     .mmio_align_ok
    mov     edx, 0x1000
.mmio_align_ok:
    mov     eax, [es:SCRATCH_PCI_MMIO_NEXT]
    push    edx
    dec     edx
    add     eax, edx
    not     edx
    and     eax, edx
    pop     edx
    mov     ecx, eax
    add     ecx, edx
    cmp     ecx, 0xFEBF0000                 ; keep below 0xFEC00000 IOAPIC/LAPIC
    ja      .mmio_advance

    mov     [es:SCRATCH_PCI_MMIO_NEXT], ecx
    mov     ecx, eax
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword

.clear_hi64_check:
    mov     eax, ebp
    and     al, 0x06
    cmp     al, 0x04
    jne     .next_bar
    add     ebx, 4
    xor     ecx, ecx
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword                 ; zero upper 32 bits of 64-bit BAR
    jmp     .next_bar

.mmio_advance:
    test    cl, cl
    jz      .next_bar
    add     ebx, 4
    jmp     .next_bar

.handle_io_bar:
    mov     eax, ebp
    and     eax, 0x0000FFFC
    cmp     eax, 0x0100
    jae     .next_bar                       ; already allocated

    and     edx, 0xFFFFFFFC
    or      edx, 0xFFFF0000                 ; 16-bit I/O mask
    not     edx
    inc     edx                             ; I/O BAR size
    test    edx, edx
    jz      .next_bar
    cmp     edx, 0x1000
    ja      .next_bar

    mov     ecx, edx
    cmp     ecx, 0x0100
    jae     .io_step_ok
    mov     ecx, 0x0100
.io_step_ok:
    movzx   eax, word [es:SCRATCH_PCI_IO_NEXT]
    push    ecx
    dec     ecx
    add     eax, ecx
    not     ecx
    and     eax, ecx
    pop     ecx
    mov     edx, eax
    add     edx, ecx
    cmp     edx, 0xF000
    ja      .next_bar
    mov     [es:SCRATCH_PCI_IO_NEXT], dx

    or      eax, 0x01
    mov     ecx, eax
    mov     eax, esi
    or      eax, ebx
    call    pci_write_dword

.next_bar:
    add     ebx, 4
    jmp     .bar_loop

.bars_done:
    pop     ecx                             ; restore Command dword
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

    popad
    ret

; PIRQ[0..3] -> IRQ mapping
pci_pirq_irq_map:
    db 10, 10, 11, 11
