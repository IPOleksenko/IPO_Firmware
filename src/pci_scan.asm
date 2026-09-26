; pci_scan.asm — PCI Bus Enumeration and Device Discovery
; Scans PCI buses to discover VGA, SATA AHCI, and USB host controllers.
; Stores discovered hardware info in safe Scratch RAM (Segment 0x0000).

BITS 16

; =============================================================================
; PCI Configuration Space Helper Routines (Local to Firmware)
; =============================================================================

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

; =============================================================================
; pci_scan_devices — Scan PCI buses 0..3 for boot-critical hardware
; Output: Updates Scratch RAM registry at 0x0000:0x0540..0x056F
; =============================================================================
pci_scan_devices:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Clear discovery flags in Scratch RAM
    mov     byte [es:SCRATCH_AHCI_FOUND], 0
    mov     byte [es:SCRATCH_USB_FOUND], 0
    mov     byte [es:SCRATCH_VGA_FOUND], 0

    ; Scan buses 0..3 (sufficient for root and secondary buses in standard PCs)
    xor     bx, bx                          ; BH = Bus (0..3), BL = Device (0..31)

.bus_loop:
    xor     bl, bl                          ; Device 0..31
.dev_loop:
    xor     cl, cl                          ; Function 0..7
.fn_loop:
    call    .check_function
    inc     cl
    cmp     cl, 8
    jb      .fn_loop

    inc     bl
    cmp     bl, 32
    jb      .dev_loop

    inc     bh
    cmp     bh, 4
    jb      .bus_loop

    pop     es
    popad
    ret

; -----------------------------------------------------------------------------
; Helper: .check_function
; Input: BH = Bus, BL = Device, CL = Function, ES = 0x0000
; Output: CF = 0 if device exists, CF = 1 if nonexistent (VID=0xFFFF)
; -----------------------------------------------------------------------------
.check_function:
    pushad

    ; Build base PCI address: 0x80000000 | (bus << 16) | (dev << 11) | (fn << 8)
    movzx   eax, bh
    shl     eax, 16
    movzx   edx, bl
    shl     edx, 11
    or      eax, edx
    movzx   edx, cl
    shl     edx, 8
    or      eax, edx
    mov     esi, eax                        ; ESI = Base PCI address for this bus:dev:fn

    ; Read Vendor ID / Device ID (reg 0x00)
    mov     eax, esi
    call    pci_read_dword
    cmp     ax, 0xFFFF
    je      .fn_absent
    test    ax, ax
    jz      .fn_absent

    ; Check for Power Management / ACPI controllers to enable ACPI I/O (PMBA = 0x0600)
    cmp     eax, 0x71138086                 ; Intel PIIX4 PM (i440FX)
    jne     .check_q35_pm

    ; 1. PIIX4 PMBASE (reg 0x40): base 0x0600 | bit 0 (RTE/enable) = 0x0601
    mov     eax, esi
    or      eax, 0x40
    mov     ecx, 0x00000601
    call    pci_write_dword

    ; 2. PIIX4 PMREGMISC (reg 0x80): set bit 0 (PMIOSE - PM I/O Space Enable)
    mov     eax, esi
    or      eax, 0x80
    call    pci_read_dword
    or      al, 0x01
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x80
    call    pci_write_dword

    ; 3. Enable I/O Space in Command register (offset 0x04)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x01
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword
    jmp     .pm_done

.check_q35_pm:
    cmp     eax, 0x29188086                 ; Intel ICH9 LPC / ACPI (Q35)
    jne     .pm_done

    ; 1. ICH9 PMBASE (reg 0x40): base 0x0600 | bit 0 (RTE/enable) = 0x0601
    mov     eax, esi
    or      eax, 0x40
    mov     ecx, 0x00000601
    call    pci_write_dword

    ; 2. ICH9 ACPI_CTRL (reg 0x44): set bit 7 (ACPI_EN)
    mov     eax, esi
    or      eax, 0x44
    call    pci_read_dword
    or      al, 0x80
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x44
    call    pci_write_dword

    ; 3. Enable I/O Space in Command register (offset 0x04)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x01
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

.pm_done:
    ; Read Class Code, Subclass, ProgIF (reg 0x08)
    ; Reg 0x08: [Class(31:24) | Subclass(23:16) | ProgIF(15:8) | RevID(7:0)]
    mov     eax, esi
    or      eax, 0x08
    call    pci_read_dword
    mov     edi, eax                        ; EDI = Class register value

    ; -------------------------------------------------------------------------
    ; 1. Check for VGA Display Controller: Class 0x03
    ; -------------------------------------------------------------------------
    shr     eax, 24                         ; AL = Class
    cmp     al, PCI_CLASS_DISPLAY
    jne     .check_storage

    ; Display device found!
    cmp     byte [es:SCRATCH_VGA_FOUND], 1
    je      .check_storage                  ; Already recorded primary VGA

    mov     byte [es:SCRATCH_VGA_FOUND], 1
    mov     byte [es:SCRATCH_VGA_BUS], bh
    mov     al, bl
    shl     al, 3
    or      al, cl
    mov     byte [es:SCRATCH_VGA_DEVFN], al

    ; Read Expansion ROM Base Address Register (reg 0x30)
    mov     eax, esi
    or      eax, 0x30
    call    pci_read_dword
    mov     dword [es:SCRATCH_VGA_ROMBAR], eax

.check_storage:
    ; -------------------------------------------------------------------------
    ; 2. Check for Mass Storage (Class 0x01)
    ; -------------------------------------------------------------------------
    mov     eax, edi
    shr     eax, 16
    and     ax, 0xFFFF                      ; AH = Class, AL = Subclass
    cmp     ah, PCI_CLASS_STORAGE
    jne     .check_usb

    cmp     al, PCI_SUBCLASS_AHCI
    je      .found_ahci

    ; Check for NVMe: Subclass 0x08 (Non-Volatile Memory)
    cmp     al, 0x08
    je      .found_nvme
    jmp     .check_usb

.found_ahci:
    cmp     byte [es:SCRATCH_AHCI_FOUND], 1
    je      .check_usb

    mov     byte [es:SCRATCH_AHCI_FOUND], 1
    mov     byte [es:SCRATCH_AHCI_BUS], bh
    mov     al, bl
    shl     al, 3
    or      al, cl
    mov     byte [es:SCRATCH_AHCI_DEVFN], al

    ; Read BAR5 (ABAR at offset 0x24)
    mov     eax, esi
    or      eax, 0x24
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    cmp     eax, 0x80000000
    jae     .ahci_bar_ok

    ; BAR5 unassigned — assign 0xFEB00000
    mov     ecx, 0xFEB00000
    mov     eax, esi
    or      eax, 0x24
    call    pci_write_dword
    mov     eax, 0xFEB00000

.ahci_bar_ok:
    mov     dword [es:SCRATCH_AHCI_BAR5], eax

    ; Enable Bus Master (bit 2), Memory Space (bit 1), and I/O Space (bit 0)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x07
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword
    jmp     .check_usb

.found_nvme:
    cmp     byte [es:SCRATCH_NVME_FOUND], 1
    je      .check_usb

    mov     byte [es:SCRATCH_NVME_FOUND], 1
    mov     byte [es:SCRATCH_NVME_BUS], bh
    mov     al, bl
    shl     al, 3
    or      al, cl
    mov     byte [es:SCRATCH_NVME_DEVFN], al

    ; Read 64-bit BAR0 at reg 0x10 and 0x14
    mov     eax, esi
    or      eax, 0x10
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    cmp     eax, 0x80000000
    jae     .nvme_bar_ok

    ; Assign 0xFEB40000
    mov     ecx, 0xFEB40000
    mov     eax, esi
    or      eax, 0x10
    call    pci_write_dword
    mov     eax, 0xFEB40000

.nvme_bar_ok:
    mov     dword [es:SCRATCH_NVME_BAR0], eax

    ; Clear high 32 bits of 64-bit BAR (reg 0x14)
    mov     ecx, 0
    mov     eax, esi
    or      eax, 0x14
    call    pci_write_dword

    ; Enable Bus Master (bit 2) and Memory Space (bit 1)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x06
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

.check_usb:
    ; -------------------------------------------------------------------------
    ; 3. Check for Serial Bus (Class 0x0C) -> USB (SubClass 0x03)
    ; -------------------------------------------------------------------------
    mov     eax, edi
    shr     eax, 16
    and     ax, 0xFFFF                      ; AH = Class, AL = Subclass
    cmp     ah, PCI_CLASS_SERIAL
    jne     .fn_present

    cmp     al, PCI_SUBCLASS_USB
    jne     .fn_present

    ; Check ProgIF: 0x20 = EHCI (USB 2.0), 0x30 = xHCI (USB 3.0)
    mov     eax, edi
    shr     eax, 8
    and     al, 0xFF                        ; AL = ProgIF

    cmp     al, PCI_PROGIF_EHCI
    jne     .try_xhci

    ; Found EHCI controller!
    cmp     byte [es:SCRATCH_USB_FOUND], 1
    je      .fn_present

    mov     byte [es:SCRATCH_USB_FOUND], 1
    mov     byte [es:SCRATCH_USB_TYPE], 1   ; 1 = EHCI
    mov     byte [es:SCRATCH_USB_BUS], bh
    mov     al, bl
    shl     al, 3
    or      al, cl
    mov     byte [es:SCRATCH_USB_DEVFN], al

    ; Read BAR0 (reg 0x10)
    mov     eax, esi
    or      eax, 0x10
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    cmp     eax, 0x80000000
    jae     .usb_bar_ok

    ; BAR0 unassigned — assign 0xFEB80000
    mov     ecx, 0xFEB80000
    mov     eax, esi
    or      eax, 0x10
    call    pci_write_dword
    mov     eax, 0xFEB80000

.usb_bar_ok:
    mov     dword [es:SCRATCH_USB_BAR0], eax

    ; Enable Bus Master (bit 2), Memory Space (bit 1), and I/O Space (bit 0)
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x07
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword
    jmp     .fn_present

.try_xhci:
    cmp     al, PCI_PROGIF_XHCI
    jne     .fn_present

    ; Found xHCI controller!
    cmp     byte [es:SCRATCH_USB_FOUND], 1
    je      .fn_present

    mov     byte [es:SCRATCH_USB_FOUND], 1
    mov     byte [es:SCRATCH_USB_TYPE], 2   ; 2 = xHCI
    mov     byte [es:SCRATCH_USB_BUS], bh
    mov     al, bl
    shl     al, 3
    or      al, cl
    mov     byte [es:SCRATCH_USB_DEVFN], al

    mov     eax, esi
    or      eax, 0x10
    call    pci_read_dword
    and     eax, 0xFFFFFFF0
    mov     dword [es:SCRATCH_USB_BAR0], eax

    ; Enable Bus Master + Memory Space
    mov     eax, esi
    or      eax, 0x04
    call    pci_read_dword
    or      al, 0x06
    mov     ecx, eax
    mov     eax, esi
    or      eax, 0x04
    call    pci_write_dword

.fn_present:
    popad
    clc
    ret

.fn_absent:
    popad
    stc
    ret
