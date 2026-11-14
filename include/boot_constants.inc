; boot_constants.inc — Firmware and boot constants (16-bit Real Mode, Shadow RAM 0xF000:0x0000)

%ifndef BOOT_CONSTANTS_INC
%define BOOT_CONSTANTS_INC

; Firmware memory layout
FW_RAM_SEG          equ 0xF000      ; Shadow RAM segment
FW_ENTRY_OFF        equ 0x000C      ; Entry point offset past 12-byte magic

; MBR load destination
MBR_SEG             equ 0x0000
MBR_OFF             equ 0x7C00
MBR_MAGIC           equ 0xAA55      ; 0x55, 0xAA at offset 510-511

; Stack layout
FW_STACK_PTR        equ 0x7C00      ; Stack below MBR load area (0x7C00 -> 0x7000)

; Hardware and I/O ports
COM1_PORT           equ 0x03F8
VGA_TEXT_SEG        equ 0xB800
CRT_ADDR_PORT       equ 0x03D4

; ATA Primary Channel
ATA_PRI_DATA        equ 0x01F0
ATA_PRI_SEC_CNT     equ 0x01F2
ATA_PRI_LBA_LO      equ 0x01F3
ATA_PRI_LBA_MID     equ 0x01F4
ATA_PRI_LBA_HI      equ 0x01F5
ATA_PRI_DRIVE_HEAD  equ 0x01F6
ATA_PRI_STATUS      equ 0x01F7
ATA_PRI_CTRL        equ 0x03F6

; CMOS Ports
CMOS_INDEX_PORT     equ 0x0070
CMOS_DATA_PORT      equ 0x0071

; PCI Configuration Ports and Class Codes
PCI_CONFIG_ADDR     equ 0x0CF8
PCI_CONFIG_DATA     equ 0x0CFC
PCI_CLASS_STORAGE   equ 0x01
PCI_SUBCLASS_AHCI   equ 0x06
PCI_CLASS_DISPLAY   equ 0x03
PCI_CLASS_SERIAL    equ 0x0C
PCI_SUBCLASS_USB    equ 0x03
PCI_PROGIF_EHCI     equ 0x20
PCI_PROGIF_XHCI     equ 0x30

; Scratch RAM offsets (Segment 0x0000)
SCRATCH_HOST_DID    equ 0x050A      ; word: Host Bridge Device ID
SCRATCH_MEM_FLAG    equ 0x0510      ; byte: 1 = memory already detected
SCRATCH_TOTAL_RAM   equ 0x0514      ; dword: total RAM in bytes
SCRATCH_RAM_1_16M   equ 0x0518      ; word: RAM 1-16MB in KB
SCRATCH_RAM_ABOVE16 equ 0x051A      ; word: RAM above 16MB in 64KB blocks

; Device Registry in Scratch RAM
SCRATCH_AHCI_FOUND  equ 0x0540
SCRATCH_AHCI_BUS    equ 0x0541
SCRATCH_AHCI_DEVFN  equ 0x0542
SCRATCH_AHCI_PORT_N equ 0x0543
SCRATCH_AHCI_BAR5   equ 0x0544
SCRATCH_AHCI_PORTS  equ 0x0548
SCRATCH_AHCI_PXBASE equ 0x054C

SCRATCH_USB_FOUND   equ 0x0550
SCRATCH_USB_TYPE    equ 0x0551      ; 1 = EHCI, 2 = xHCI
SCRATCH_USB_BUS     equ 0x0552
SCRATCH_USB_DEVFN   equ 0x0553
SCRATCH_USB_BAR0    equ 0x0554
SCRATCH_USB_ADDR       equ 0x055C
SCRATCH_USB_TOGGLE_IN  equ 0x055D
SCRATCH_USB_TOGGLE_OUT equ 0x055E
SCRATCH_USB_EP_IN      equ 0x055F
SCRATCH_USB_EP_OUT     equ 0x0563

SCRATCH_VGA_FOUND        equ 0x0560
SCRATCH_VGA_BUS          equ 0x0561
SCRATCH_VGA_DEVFN        equ 0x0562
SCRATCH_VGA_ROMBAR       equ 0x0564
SCRATCH_VIDEO_ROM_ACTIVE equ 0x0568

SCRATCH_NVME_FOUND    equ 0x0580
SCRATCH_NVME_BUS      equ 0x0581
SCRATCH_NVME_DEVFN    equ 0x0582
SCRATCH_NVME_BAR0     equ 0x0584
SCRATCH_NVME_NSID     equ 0x0588
SCRATCH_NVME_SEC_SIZE equ 0x058C
SCRATCH_NVME_SQ_TAIL  equ 0x058E
SCRATCH_NVME_CQ_HEAD  equ 0x058F
SCRATCH_E820_COUNT    equ 0x0590
SCRATCH_NVME_CQ_PHASE equ 0x0592
SCRATCH_E820_TABLE    equ 0x0598

; Drive Types for INT 13h dispatch
SCRATCH_DRV_TYPE_80 equ 0x0570      ; 0=None, 1=ATA_PIO, 2=SATA_AHCI, 3=USB_BOT, 4=NVME
SCRATCH_DRV_TYPE_81 equ 0x0571
SCRATCH_DRV_TYPE_82 equ 0x0572
SCRATCH_DRV_TYPE_83 equ 0x0573

DRV_TYPE_NONE       equ 0x00
DRV_TYPE_ATA_PIO    equ 0x01
DRV_TYPE_SATA_AHCI  equ 0x02
DRV_TYPE_USB_BOT    equ 0x03
DRV_TYPE_NVME       equ 0x04

; Buffers for AHCI and NVMe transfers in lower conventional memory (0x1000-0x6FFF)
AHCI_CMD_LIST_ADDR  equ 0x1000      ; 1KB Command List (1024-byte aligned)
AHCI_RX_FIS_ADDR    equ 0x1400      ; 256B Received FIS (256-byte aligned)
AHCI_CMD_TAB_ADDR   equ 0x1800      ; Command Table + PRDT (128-byte aligned)

NVME_ADMIN_SQ_ADDR  equ 0x3000
NVME_ADMIN_CQ_ADDR  equ 0x4000
NVME_IO_SQ_ADDR     equ 0x5000
NVME_IO_CQ_ADDR     equ 0x6000

; POST Diagnostic Port 0x80
POST_PORT           equ 0x80
POST_DISK_SPINUP_WAIT equ 0x29

%endif ; BOOT_CONSTANTS_INC
