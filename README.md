# IPO_Firmware

Independent bare-metal x86 Firmware service layer for QEMU and PC-AT compatible machines.

---

## 📋 Architecture & Runtime Services

`IPO_Firmware` executes in write-protected Shadow RAM at `0xF000:0x000C` (after validating the 12-byte header `"IPO_Firmware"` at `0xF000:0x0000`), receiving control either from a compatible external Boot ROM or from its standalone 256 KiB mirrored Reset Vector (`0xFFF0 -> 0xF000:0x000C`). It provides PC-compatible runtime interrupt services and performs automated multi-bus storage discovery before handing control to an MBR.

```text
Boot ROM Handover / Standalone Reset Vector (CS:IP = 0xF000:0x000C)
  │
  ▼
Low-Level Firmware Services Setup
  ├─ COM1 UART Serial initialization (115200 baud, 8N1)
  ├─ IVT & BDA setup: Registers INT 10h–17h, INT 1Ah, INT 1Ch, PIT Ch0 (18.2 Hz), PIC IRQs 0/1/2
  ├─ ACPI 1.0 tables in EBDA (0x9FC00): RSDP, RSDT, and MADT
  ├─ PCI Bus Enumeration (buses 0..3): VGA (0x03), Bridges (0x06), AHCI (0x01:0x06), NVMe (0x01:0x08), USB (0x0C:0x03), Network (0x02)
  ├─ Video Subsystem (when VGA found): Option ROM (0xC000:0003, chained via INT 42h) or native Mode 03h text
  ├─ A20 Gate: Enabled and verified via Fast A20 (port 0x92) with PS/2 KBC fallback
  ├─ Memory Detection: Boot ROM SCRATCH_TOTAL_RAM (0x0514) -> CMOS 0x34/0x35 -> CMOS 0x30/0x31 -> 128 MB default (E820 / E801)
  └─ PS/2 Keyboard Controller: Scan Code Set 2 -> Set 1 translation and keyboard IRQ1 enabled
  │
  ▼
Automated Multi-Bus Storage Discovery & MBR Loading
  ├─ Defaults 0x80/0x81 to ATA PIO; probes SATA AHCI (0x80), PCIe NVMe (0x80 or 0x81), and USB EHCI BOT (0x82)
  ├─ Probes drives 0x80..0x82 via INT 13h AH=42h, reading LBA 0 into 0x0000:0x7C00
  ├─ Validates MBR boot signature 0x55AA at offset 510
  │
  ▼
OS Handover (Standard PC MBR Handover)
  ├─ Sets DL = selected firmware drive ID (0x80 / 0x81 / 0x82)
  ├─ Sets DS = ES = SS = 0x0000, SP = 0x7C00, Flags: STI (interrupts enabled)
  └─ Jumps to loaded MBR at 0x0000:0x7C00
```

---

## 🛠️ Build Commands

```bash
# Install required build tools, QEMU, and hardware flashing dependencies
./install-dependencies.sh

# Compile firmware binary and construct production ROM
make

# Clean all build artifacts
make clean
```

---

## 🚀 Emulation & Running (`make run`)

`make run` allows isolated firmware execution, custom Boot ROM integration, and booting operating system storage media:

### 1. Standalone Execution (No arguments)
Runs firmware in QEMU using standalone production binary (`build/firmware.bin`):
```bash
make run
```

### 2. Running with an External Boot ROM
Embeds the firmware payload into a specified external Boot ROM image (`BOOTROM`, or aliases `BOOT_ROM`, `RAMBOOT`, `RAM_BOOT`, `ROM_BOOT`, `ROM_BIN`):
```bash
make run BOOTROM=path/to/bootrom.bin
```

### 3. Running with an OS Disk Image
Attaches a raw storage image (`OS` or alias `OS_IMAGE`):
```bash
make run OS=path/to/disk.img
```

### 4. Running with Boot ROM, Storage Controller, and Secondary Disk
Builds a ROM embedding the specified Boot ROM and boots the target OS:
```bash
make run BOOTROM=path/to/bootrom.bin OS=path/to/disk.img
make run OS=path/to/disk.img DRIVE_TYPE=ahci   # SATA AHCI (default: ide)
make run OS=path/to/disk.img DRIVE_TYPE=usb    # USB 2.0 EHCI Mass Storage
```

Additional `make run` variables supported in `mk/config.mk`:
- `DISK=path/to/secondary.img` (optional secondary IDE disk when `DRIVE_TYPE=ide`; auto-detects `disk.img` beside `OS`)
- `CPU=<model>` and `MEM=<MB>` (default `512` MiB; configured in `mk/config.mk`)
- `QEMU_EXTRA="..."` (extra arguments passed directly to `qemu-system-i386`, e.g., attaching an NVMe controller)

### 🔊 Audio Configuration
By default, QEMU connects the PC Speaker emulation to PulseAudio/PipeWire (`AUDIO=pa`). You can customize or disable the audio driver:
```bash
make run AUDIO=alsa ...   # Use ALSA
make run AUDIO=sdl ...    # Use SDL audio
make run AUDIO=none ...   # Disable audio connection
```

---

## 📦 Generated Artifacts

| File | Size | Description |
| :--- | :--- | :--- |
| `build/.bin/firmware.bin` | <= 32 KiB | Assembled firmware payload (begins with 12-byte magic `"IPO_Firmware"`, entry at `+0x0C`). Input artifact for embedding into an external Boot ROM. |
| `build/firmware.bin` | 256 KiB standalone (`4x 64 KiB` mirrored banks); otherwise supplied Boot ROM size | Complete firmware image for direct QEMU execution (`make run`) or physical flash chip programming. |

---

## 📜 Boot Handoff Interfaces

### Firmware Input (Boot ROM → Firmware)
Firmware receives control from the hardware reset bootloader (or standalone Reset Vector) with the machine in the following state:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0xF000:0x000C` | Entry in write-protected Shadow RAM (after 12-byte magic) |
| **Magic Header** | `0xF000:0x0000` | 12 ASCII bytes: `"IPO_Firmware"` |
| **Data Segments** | `DS = ES = SS = 0x0000` | Initialized by Firmware entry to `DS=ES=0xF000`, `SS=0x0000` |
| **Stack (`SS:SP`)** | `0x0000:0x7C00` | Initial stack pointer in DRAM; stack grows down below the MBR buffer |
| **Interrupt Flag (`IF`)** | `0` (`cli`) | Interrupts disabled until firmware registers IVT handlers |
| **Memory State** | Operational | DRAM initialized by Boot ROM (MRC) or host; Shadow RAM read-only (`PAM_RE`) |

### Firmware Output (Firmware → MBR / OS Bootloader)
Firmware hands over execution to the operating system bootloader using standard PC-AT conventions:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0x0000:0x7C00` | MBR entry point in conventional DRAM |
| **Boot Drive (`DL`)** | `0x80` / `0x81` / `0x82` | Firmware drive number selected by Firmware (`0x80`/`0x81` for ATA, AHCI, or NVMe; `0x82` for USB EHCI BOT) |
| **Data & Stack** | `DS = ES = SS = 0x0000`, `SP = 0x7C00` | Clean segments, stack grows downward from `0x7C00` |
| **Interrupt Flag (`IF`)** | `1` (`sti`) | Interrupts enabled, hardware timers and keyboard active |
| **Boot Sector Buffer** | `0x0000:0x7C00` (512 bytes) | First sector (LBA 0) loaded from boot drive |
| **MBR Signature** | `0x55AA` | Byte 510 = `0x55`, byte 511 = `0xAA` |

---

## 🛠️ Supported Firmware Interrupt Services (IVT)

| Interrupt | Function | Description |
| :--- | :--- | :--- |
| **INT 10h** | `AH=00h` | Set Video Mode (Mode 03h: 80x25 16-color text) |
| | `AH=01h` | Set Cursor Shape (supports bit 5 cursor hiding) |
| | `AH=02h` | Set Cursor Position (Row `DH`, Column `DL`) |
| | `AH=03h` | Get Cursor Position & Shape (returns `DH/DL`, `CH/CL`) |
| | `AH=0Eh` | Teletype Output with scrolling (mirrored to COM1 serial) |
| **INT 11h** | — | Equipment Determination (returns Equipment Word `0x4223` from BDA `0x0410` in `AX`) |
| **INT 12h** | — | Get Conventional Memory Size (returns `640` KB from BDA `0x0413` in `AX`) |
| **INT 13h** | `AH=00h` | Reset Disk System |
| | `AH=02h` | Read Sectors from Drive (Legacy CHS addressing, `0x80..0x83`) |
| | `AH=08h` | Get Drive Parameters (Geometry: Cylinders, Heads, Sectors, Drives) |
| | `AH=41h` | Installation Check / EDD Extensions (`BX=0x55AA` $\to$ `BX=0xAA55`) |
| | `AH=42h` | Extended Read Sectors via Disk Address Packet (DAP, LBA addressing, `0x80..0x83`) |
| **INT 14h** | `AH=03h` | Serial Port Services stub (returns `AH=0x60` line status, `AL=0x00` modem status) |
| **INT 15h** | `EAX=0xE820` | Query System Address Map (returns 4 SMAP entries; E820 entry 0 = 639 KB, EBDA + ROM Reserved `0x9FC00-0xFFFFF`, Extended RAM clamped to TOLUD `0xE0000000`) |
| | `AX=0xE801` | Get Memory Size for >64MB Configurations (`AX=CX` 1–16 MB in KB, `BX=DX` >16 MB in 64 KB blocks) |
| | `AX=0x2401` | Enable A20 Gate (Fast A20 via port `0x92` with PS/2 KBC `0xD1 -> 0xDF` fallback) |
| **INT 16h** | `AH=00h` / `AH=10h` | Read Keystroke / Extended Read Keystroke from PS/2 keyboard buffer (blocking) |
| | `AH=01h` / `AH=11h` | Check Keystroke availability (non-blocking, updates ZF flag) |
| | `AH=02h` | Get Keyboard Shift Status Flags (returns `BDA 0x0417` in `AL`) |
| **INT 17h** | — | Printer Services stub (returns `AH=0x90` not busy / selected) |
| **INT 1Ah** | `AH=00h` | Read System Timer Ticks (18.2 Hz ticks from BDA `0x046C`/`0x046E` and midnight flag `0x0470`) |
| | `AH=01h` | Set System Timer Ticks (`CX:DX` into `BDA 0x046C`/`0x046E`) |
| | `AH=02h` | Read RTC Time (BCD `CH` hours, `CL` minutes, `DH` seconds) |
| | `AH=04h` | Read RTC Date (BCD `CH` century, `CL` year, `DH` month, `DL` day) |
| **INT 1Ch** | — | User Timer Tick Hook (invoked from IRQ0 `INT 08h`, default stub handler) |

---

## 🔌 Hardware Subsystems & Features

- **PCI Enumeration & Resource Assignment:** Scans buses `0..3`, enables bus mastering / I/O / MMIO spaces, assigns missing BARs (`VGA` LFB `0xE0000000`, `AHCI` BAR5 `0xFEB00000`, `NVMe` 64-bit BAR0 `0xFEB40000` / cleared high dword, `USB` BAR0 `0xFEB80000`, `Network` Class `0x02` I/O `0xC000` or MMIO `0xFEBA0000`), and enables `PMBASE` (`0x0601`) on ISA/LPC bridges (`Class 0x06`).
- **Video Option ROM & Chaining:** Automatically detects PCI VGA adapters (`Class 0x03`), maps Expansion ROM BAR to `0xC0000`, verifies `0xAA55` + checksum, shadows `0xC0000-0xCFFFF` via PAM1/PAM2, executes entry point `0xC000:0003`, and chains the Option ROM handler to `INT 42h` while preserving `AH=0Eh` teletype mirroring to COM1. If absent, firmware falls back to its built-in native Mode 03h driver.
- **Storage Subsystems:** Auto-probes multiple bus architectures without user configuration:
  - **IDE / PATA:** Legacy ATA PIO (`0x1F0` / `0x170`).
  - **SATA AHCI:** PCI AHCI HBA memory-mapped I/O with FIS & command headers.
  - **PCIe NVMe:** PCI NVMe SSD with Admin & I/O submission/completion queues.
  - **USB 2.0 Mass Storage:** PCI EHCI controller with Bulk-Only Transport (BOT).
- **Dual Console Logging & Headless Safe:** Diagnostic messages are output simultaneously to COM1 UART (`115200 8N1`) and, when a PCI VGA adapter is detected (`SCRATCH_VGA_FOUND = 1`), to the VGA text screen. Bounded timeout loops prevent hangs when no serial receiver is attached.

---

## 🚦 Firmware POST Diagnostic Port 0x80 Codes

`IPO_Firmware` writes the following checkpoint to diagnostic port `0x80` (`POST_PORT` in `include/boot_constants.inc`):

| Hex Code | Symbol / Checkpoint | Status |
| :---: | :--- | :---: |
| `0x29` | `POST_DISK_SPINUP_WAIT` — Waiting for ATA primary drive ready (BSY clear / DRDY set) during physical spin-up (`int13.asm`) | Notice |

## 🧑‍💻 Authors

- [IPOleksenko](https://github.com/IPOleksenko) (owner) — Developer and creator of the idea.


# 📜 License

This project is licensed under the [MIT License][license].

[license]: ./LICENSE