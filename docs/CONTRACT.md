# IPO_Firmware Contract & Architecture Specification

## 1. Overview
`IPO_Firmware` is an independent, bare-metal x86 BIOS service layer. It receives control from an early-stage Boot ROM and provides standard BIOS runtime interrupt services (`INT 10h`, `INT 13h`, `INT 15h`, `INT 16h`) and disk discovery. It chainloads standard MBR bootloaders under the standard PC-AT BIOS contract.

It is designed to run in **Shadow RAM at segment `0xF000`** (`0xF0000–0xFFFFF`), protected by chipset PAM registers as Read-Only, preventing operating systems or bootloaders from corrupting firmware code and interrupt vectors.

```
+-------------------------------------------------------------+
| Early-stage Boot ROM (e.g., IPO_Boot_ROM)                  |
+-------------------------------------------------------------+
                              |
                              v Handover (Contract 2: Shadow RAM)
+-------------------------------------------------------------+
| IPO_Firmware (Shadow RAM 0xF000:0x0004)                     |
| - IVT Setup (256 vectors initialized, segment = dynamic CS) |
| - INT 10h (Teletype AH=0Eh, Modes AH=00h, Cursor AH=01h-03h)|
| - INT 13h (ATA/IDE PIO Driver, LBA28, DAP Extended Read)   |
| - INT 15h (E820 Memory Map, CMOS Memory Size, E801, A20)    |
| - Fast A20 Gate activation via port 0x92                    |
| - BDA (BIOS Data Area) population at 0x0040:0x0000          |
| - PS/2 8042 Keyboard Controller translation (Set 2 -> Set 1)|
| - Discovers bootable disk (LBA 0, signature 0x55AA)        |
| - Loads MBR to 0x0000:0x7C00                                |
| - Far jump to MBR: jmp 0x0000:0x7C00                        |
+-------------------------------------------------------------+
                              |
                              v Handover (Contract 3)
+-------------------------------------------------------------+
| Standard MBR Bootloader (e.g. boot.bin)                     |
+-------------------------------------------------------------+
```

## 2. Input Contract (Contract 2: Boot_ROM -> Firmware)

| Register / State | Value | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode |
| **CS:IP** | `0xF000:0x0004` | Jump address in Shadow RAM (immediately after magic header) |
| **Magic Header** | `0xF000:0x0000` | 4 bytes: `'I', 'P', 'O', 'F'` (`0x464F5049`) |
| **DS, ES** | `0x0000` | Base segment |
| **SS:SP** | `0x0000:0x7000` | Pre-established stack in DRAM |
| **Interrupt Flag (IF)** | `0` (`cli`) | Disabled until IVT is populated |
| **Memory State** | Operational | DRAM initialized by Boot ROM (MRC); Shadow RAM write-protected |

## 3. Output Contract (Contract 3: Firmware -> MBR)

Firmware reproduces the exact environment expected from standard PC BIOS implementations (SeaBIOS / Award / AMI):

| Register / State | Value | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode |
| **CS:IP** | `0x0000:0x7C00` | MBR entry point |
| **DL** | `0x80` (or `0x81`..) | BIOS Drive Number of the booted storage device |
| **DS, ES, SS** | `0x0000` | Clean zero segment registers |
| **SP** | `0x7C00` | Stack grows downward from 0x7C00 |
| **Interrupt Flag (IF)** | `1` (`sti`) | Interrupts enabled |
| **Memory at 0x7C00** | 512 bytes | First sector (LBA 0) read from boot drive |
| **MBR Signature** | `0x55AA` | Byte 510 = `0x55`, byte 511 = `0xAA` |

### BIOS Services Available to MBR:
- **INT 10h**:
  - `AH=00h`: Set Video Mode (Mode 03h: 80x25 16-color text, programs VGA Sequencer, CRTC, GC, AC, DAC)
  - `AH=01h`: Set Cursor Shape (support for bit 5 cursor hiding)
  - `AH=02h`: Set Cursor Position (row DH, column DL)
  - `AH=03h`: Get Cursor Position & Shape
  - `AH=0Eh`: Teletype Output with auto-scroll (preserves row 0 title banner) & serial COM1 mirror
- **INT 13h**:
  - `AH=00h`: Reset Disk System
  - `AH=08h`: Get Drive Parameters
  - `AH=41h`: Installation Check / Extensions Check (`BX=0x55AA` -> `BX=0xAA55`)
  - `AH=42h`: Extended Read Sectors via Disk Address Packet (DAP, LBA28 ATA PIO)
- **INT 15h**:
  - `EAX=0xE820`: Query System Address Map (returns SMAP descriptor entries, protects `0x9FC00–0x100000` as Reserved)
  - `AX=0xE801`: Get Memory Size for >64MB Configurations
  - `AX=0x2401`: Fast A20 Gate Enable
- **INT 16h**:
  - Keyboard input services (Scan Code translation handled by 8042 PS/2 controller)

## 4. Hardware Independence
- **Dynamic Segment Binding:** IVT entries are registered using the runtime `CS` register, allowing firmware to run from `0xF000` (Shadow RAM) or any arbitrary segment.
- **Pure Register/Stack State:** Drive probing and DAP parameters maintain mutable state on the CPU stack and conventional memory, avoiding writes to write-protected Shadow RAM.
- **Physical Memory Detection:** Probes standard AT/ATX CMOS RTC registers (`0x34`/`0x35`) first, falling back to QEMU `fw_cfg` if CMOS reports zero.
