# IPO_Firmware Contract & Architecture Specification

## 1. Overview
`IPO_Firmware` is an independent, bare-metal x86 BIOS service layer. It receives control from an early-stage Boot ROM and provides standard BIOS runtime interrupt services (`INT 10h`, `INT 13h`, `INT 15h`, `INT 16h`) and disk discovery. It chainloads standard MBR bootloaders under the standard PC-AT BIOS contract.

```
+-------------------------------------------------------------+
| Early-stage Boot ROM                                        |
+-------------------------------------------------------------+
                              |
                              v Handover (Contract 2)
+-------------------------------------------------------------+
| IPO_Firmware (RAM 0x0800:0x0004)                           |
| - IVT Setup (256 vectors initialized, default iret)         |
| - INT 10h (Teletype AH=0Eh, Modes AH=00h, Cursor AH=01h-03h)|
| - INT 13h (ATA/IDE PIO Driver, LBA28, DAP Extended Read)   |
| - INT 15h (E820 Memory Map via fw_cfg, E801 Memory Size)    |
| - Fast A20 Gate activation via port 0x92                    |
| - BDA (BIOS Data Area) population at 0x0040:0x0000          |
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
| **CS:IP** | `0x0800:0x0004` | Jump address (offset 4, immediately after magic header) |
| **Magic Header** | `0x0800:0x0000` | 4 bytes: `'I', 'P', 'O', 'F'` (`0x464F5049`) |
| **DS, ES** | `0x0000` | Base segment |
| **SS:SP** | `0x0000:0x7000` | Pre-established stack |
| **Interrupt Flag (IF)** | `0` (`cli`) | Disabled until IVT is populated |

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
  - `AH=00h`: Set Video Mode (Mode 03h: 80x25 16-color text)
  - `AH=01h`: Set Cursor Shape (support for bit 5 cursor hiding)
  - `AH=02h`: Set Cursor Position (`DH`=row, `DL`=column)
  - `AH=03h`: Get Cursor Position and Shape
  - `AH=0Eh`: Teletype character output (with automatic scrolling, CR, LF, BS handling)
- **INT 13h**:
  - `AH=00h`: Reset Disk System
  - `AH=08h`: Read Drive Parameters (CHS)
  - `AH=41h`: Extensions Installation Check (`BX=0x55AA` -> `BX=0xAA55`)
  - `AH=42h`: Extended Read Sectors from Drive via Disk Address Packet (DAP)
- **INT 15h**:
  - `EAX=E820h`: Query System Address Map ('SMAP')
  - `AX=E801h`: Get Memory Size for >64M Configurations
  - `AX=2401h`: Enable Fast A20 Gate
- **INT 16h**:
  - `AH=00h`, `AH=01h`: Non-blocking keyboard stubs

## 4. Verification & Testing
- `make`: Compiles `build/firmware.bin` and verifies that its size does not exceed the 32 KB threshold.
- `make test`: Packages `firmware.bin` with a self-contained stub Boot ROM (`build/stub_bootrom.bin`) into `build/test_rom.bin`, creates a 1MB test disk image containing `build/stub_mbr.bin`, launches QEMU with `-bios build/test_rom.bin -drive file=build/test_mbr.img,if=ide,index=0`, and validates all services end-to-end.

