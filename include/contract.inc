; contract.inc — Contract constants for IPO_Firmware
; Target Architecture: x86 (16-bit Real Mode)
; Execution Mode: Shadow RAM at 0xF000:0x0000

%ifndef CONTRACT_INC
%define CONTRACT_INC

; =============================================================================
; 1. Firmware Memory Layout (Shadow RAM Mode)
; =============================================================================

; Firmware executes from Shadow RAM at segment 0xF000
; Boot_ROM copies ROM content to DRAM at 0xF0000 and locks PAM read-only
FW_RAM_SEG          equ 0xF000      ; Shadow RAM segment (was 0x0800)
FW_ENTRY_OFF        equ 0x0004      ; Entry point offset (immediately after 4-byte magic)
FW_MAGIC            equ 0x464F5049  ; "IPOF" in little-endian dword

; MBR load destination (Contract 3)
MBR_SEG             equ 0x0000
MBR_OFF             equ 0x7C00
MBR_MAGIC           equ 0xAA55      ; 0x55, 0xAA at offset 510-511

; Stack layout
FW_STACK_SEG        equ 0x0000
FW_STACK_PTR        equ 0x7000      ; Below MBR load area (0x7000 down to 0x6000)

; =============================================================================
; 2. Hardware / I/O Ports
; =============================================================================
COM1_PORT           equ 0x03F8      ; Serial UART COM1 port
VGA_TEXT_SEG        equ 0xB800      ; Video memory base for 80x25 text mode
CRT_ADDR_PORT       equ 0x03D4      ; CRT controller index port
CRT_DATA_PORT       equ 0x03D5      ; CRT controller data port

; ATA Primary Channel
ATA_PRI_DATA        equ 0x01F0
ATA_PRI_ERROR       equ 0x01F1      ; Read: error, Write: features
ATA_PRI_SEC_CNT     equ 0x01F2
ATA_PRI_LBA_LO      equ 0x01F3
ATA_PRI_LBA_MID     equ 0x01F4
ATA_PRI_LBA_HI      equ 0x01F5
ATA_PRI_DRIVE_HEAD  equ 0x01F6
ATA_PRI_STATUS      equ 0x01F7      ; Read: status, Write: command
ATA_PRI_CTRL        equ 0x03F6      ; Device control

; ATA Secondary Channel
ATA_SEC_DATA        equ 0x0170
ATA_SEC_STATUS      equ 0x0177
ATA_SEC_CTRL        equ 0x0376

; CMOS Ports
CMOS_INDEX_PORT     equ 0x0070
CMOS_DATA_PORT      equ 0x0071

; QEMU fw_cfg Ports (optional enhancement — CMOS is primary)
FW_CFG_PORT_SEL     equ 0x0510
FW_CFG_PORT_DATA    equ 0x0511
FW_CFG_ID_RAM_SIZE  equ 0x0001

; PCI Configuration Ports
PCI_CONFIG_ADDR     equ 0x0CF8
PCI_CONFIG_DATA     equ 0x0CFC

; PCI Class Codes
PCI_CLASS_STORAGE   equ 0x01
PCI_SUBCLASS_IDE    equ 0x01
PCI_SUBCLASS_AHCI   equ 0x06
PCI_CLASS_DISPLAY   equ 0x03
PCI_SUBCLASS_VGA    equ 0x00
PCI_CLASS_SERIAL    equ 0x0C
PCI_SUBCLASS_USB    equ 0x03
PCI_PROGIF_UHCI     equ 0x00
PCI_PROGIF_OHCI     equ 0x10
PCI_PROGIF_EHCI     equ 0x20
PCI_PROGIF_XHCI     equ 0x30

; =============================================================================
; 3. BIOS Data Area (BDA) Addresses (Segment 0x0040)
; =============================================================================
BDA_SEG             equ 0x0040

; =============================================================================
; 4. Scratch RAM Offsets (Segment 0x0000, safe conventional memory)
; =============================================================================
SCRATCH_SEG         equ 0x0000
SCRATCH_MEM_FLAG    equ 0x0510      ; byte: 1 = memory already detected
SCRATCH_TOTAL_RAM   equ 0x0514      ; dword: total RAM in bytes
SCRATCH_RAM_1_16M   equ 0x0518      ; word: RAM 1-16MB in KB
SCRATCH_RAM_ABOVE16 equ 0x051A      ; word: RAM above 16MB in 64KB blocks

; Device Registry in Scratch RAM
SCRATCH_AHCI_FOUND  equ 0x0540      ; byte: 1 = AHCI controller detected
SCRATCH_AHCI_BUS    equ 0x0541      ; byte: PCI bus
SCRATCH_AHCI_DEVFN  equ 0x0542      ; byte: PCI dev/fn
SCRATCH_AHCI_PORT_N equ 0x0543      ; byte: active boot port index
SCRATCH_AHCI_BAR5   equ 0x0544      ; dword: AHCI ABAR (BAR5) physical base address
SCRATCH_AHCI_PORTS  equ 0x0548      ; dword: Implemented ports mask (PI)

SCRATCH_USB_FOUND   equ 0x0550      ; byte: 1 = USB controller detected
SCRATCH_USB_TYPE    equ 0x0551      ; byte: 1 = EHCI, 2 = xHCI
SCRATCH_USB_BUS     equ 0x0552      ; byte: PCI bus
SCRATCH_USB_DEVFN   equ 0x0553      ; byte: PCI dev/fn
SCRATCH_USB_BAR0    equ 0x0554      ; dword: USB MMIO/IO Base address

SCRATCH_VGA_FOUND   equ 0x0560      ; byte: 1 = VGA controller detected
SCRATCH_VGA_BUS     equ 0x0561      ; byte: PCI bus
SCRATCH_VGA_DEVFN   equ 0x0562      ; byte: PCI dev/fn
SCRATCH_VGA_ROMBAR  equ 0x0564      ; dword: Expansion ROM BAR address

; Drive Types for INT 13h dispatch (stored in Scratch RAM)
SCRATCH_DRV_TYPE_80 equ 0x0570      ; byte: 0=None, 1=ATA_PIO, 2=SATA_AHCI, 3=USB_BOT
SCRATCH_DRV_TYPE_81 equ 0x0571      ; byte
SCRATCH_DRV_TYPE_82 equ 0x0572      ; byte
SCRATCH_DRV_TYPE_83 equ 0x0573      ; byte

DRV_TYPE_NONE       equ 0x00
DRV_TYPE_ATA_PIO    equ 0x01
DRV_TYPE_SATA_AHCI  equ 0x02
DRV_TYPE_USB_BOT    equ 0x03

; Fixed safe buffers for AHCI and USB transfers in lower conventional memory
; Region 0x1000 - 0x2FFF is safely above BDA/Scratch and below Firmware Stack (0x6000),
; completely free from OS Kernel (loaded at 0x10000) and MBR (0x7C00).
AHCI_CMD_LIST_ADDR  equ 0x1000      ; 1KB Command List (1024-byte aligned)
AHCI_RX_FIS_ADDR    equ 0x1400      ; 256 bytes Received FIS (256-byte aligned)
AHCI_CMD_TAB_ADDR   equ 0x1800      ; Command Table + PRDT (128-byte aligned)

%endif ; CONTRACT_INC
