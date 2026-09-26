; acpi.asm — ACPI 1.0 Table Generation in EBDA (0x9FC00)
; Generates RSDP, RSDT, and MADT tables for multiprocessor/APIC operating systems.
; Placed in EBDA (conventional RAM) so tables are writable and dynamically checksummed.

BITS 16

%include "contract.inc"

EBDA_SEG        equ 0x9FC0
EBDA_RSDP_OFF   equ 0x0000      ; Physical 0x9FC00
EBDA_RSDT_OFF   equ 0x0040      ; Physical 0x9FC40
EBDA_MADT_OFF   equ 0x0080      ; Physical 0x9FC80

acpi_init_tables:
    pushad
    push    ds
    push    es

    mov     ax, EBDA_SEG
    mov     es, ax

    ; -------------------------------------------------------------------------
    ; 1. Build MADT (Multiple APIC Description Table) at EBDA + 0x0080
    ; -------------------------------------------------------------------------
    mov     di, EBDA_MADT_OFF

    ; Header (36 bytes)
    mov     dword [es:di + 0x00], 'APIC'         ; Signature: "APIC"
    mov     dword [es:di + 0x04], 44             ; Total Length = 44 bytes
    mov     byte  [es:di + 0x08], 1              ; Revision = 1
    mov     byte  [es:di + 0x09], 0              ; Checksum (computed below)
    mov     dword [es:di + 0x0A], 'IPO '         ; OEMID
    mov     word  [es:di + 0x0E], '  '
    mov     dword [es:di + 0x10], 'IPOF'         ; OEM Table ID
    mov     dword [es:di + 0x14], 'W   '
    mov     dword [es:di + 0x18], 1              ; OEM Revision
    mov     dword [es:di + 0x1C], 'IPO '         ; Creator ID
    mov     dword [es:di + 0x20], 1              ; Creator Revision

    ; MADT Fields: Local APIC Base Address (0xFEE00000) and PC-AT Flags
    mov     dword [es:di + 0x24], 0xFEE00000     ; Local APIC Physical Address
    mov     dword [es:di + 0x28], 1              ; Flags: 1 = PC-AT Dual 8259 PIC compatible

    ; Entry 0: Processor Local APIC (Type 0, Length 8)
    mov     byte  [es:di + 0x2C], 0              ; Type 0 = Local APIC
    mov     byte  [es:di + 0x2D], 8              ; Length = 8 bytes
    mov     byte  [es:di + 0x2E], 0              ; ACPI Processor ID = 0
    mov     byte  [es:di + 0x2F], 0              ; APIC ID = 0 (BSP)
    mov     dword [es:di + 0x30], 1              ; Flags: 1 = Enabled

    ; Compute MADT Checksum (sum of all 44 bytes mod 256 == 0)
    mov     si, di
    mov     cx, 44
    call    .compute_table_checksum
    mov     [es:di + 0x09], al

    ; -------------------------------------------------------------------------
    ; 2. Build RSDT (Root System Description Table) at EBDA + 0x0040
    ; -------------------------------------------------------------------------
    mov     di, EBDA_RSDT_OFF

    ; Header (36 bytes)
    mov     dword [es:di + 0x00], 'RSDT'         ; Signature: "RSDT"
    mov     dword [es:di + 0x04], 40             ; Total Length = 36 + 4 = 40 bytes
    mov     byte  [es:di + 0x08], 1              ; Revision = 1
    mov     byte  [es:di + 0x09], 0              ; Checksum (computed below)
    mov     dword [es:di + 0x0A], 'IPO '         ; OEMID
    mov     word  [es:di + 0x0E], '  '
    mov     dword [es:di + 0x10], 'IPOF'         ; OEM Table ID
    mov     dword [es:di + 0x14], 'W   '
    mov     dword [es:di + 0x18], 1              ; OEM Revision
    mov     dword [es:di + 0x1C], 'IPO '         ; Creator ID
    mov     dword [es:di + 0x20], 1              ; Creator Revision

    ; Entry 0: Pointer to MADT (Physical 0x9FC80)
    mov     dword [es:di + 0x24], 0x0009FC80

    ; Compute RSDT Checksum (sum of all 40 bytes mod 256 == 0)
    mov     si, di
    mov     cx, 40
    call    .compute_table_checksum
    mov     [es:di + 0x09], al

    ; -------------------------------------------------------------------------
    ; 3. Build RSDP (Root System Description Pointer) at EBDA + 0x0000
    ; -------------------------------------------------------------------------
    mov     di, EBDA_RSDP_OFF

    ; "RSD PTR " (8 bytes)
    mov     dword [es:di + 0x00], 'RSD '
    mov     dword [es:di + 0x04], 'PTR '
    mov     byte  [es:di + 0x08], 0              ; Checksum (computed below)
    mov     dword [es:di + 0x09], 'IPO '         ; OEMID
    mov     word  [es:di + 0x0D], '  '
    mov     byte  [es:di + 0x0F], 0              ; Revision 0 (ACPI 1.0)
    mov     dword [es:di + 0x10], 0x0009FC40     ; 32-bit physical address of RSDT

    ; Compute RSDP Checksum (sum of 20 bytes mod 256 == 0)
    mov     si, di
    mov     cx, 20
    call    .compute_table_checksum
    mov     [es:di + 0x08], al

    pop     es
    pop     ds
    popad
    ret

; Helper: Computes the 8-bit checksum byte so total sum % 256 == 0
; Input: ES:SI = table start, CX = length in bytes
; Output: AL = checksum byte to store
.compute_table_checksum:
    push    cx
    push    si
    xor     al, al
.sum_loop:
    add     al, [es:si]
    inc     si
    loop    .sum_loop
    neg     al                              ; 2's complement: (sum + neg_sum) % 256 == 0
    pop     si
    pop     cx
    ret
