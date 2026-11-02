# IPO_Firmware

Independent bare-metal x86 Firmware service layer for QEMU and PC-AT compatible machines.

---

## 📋 Architecture & Runtime Services

`IPO_Firmware` executes in write-protected Shadow RAM at `0xF000:0x0004`, receiving control from a compatible external Boot ROM. It provides PC-compatible runtime interrupt services and performs automated multi-bus storage discovery before handing control to an MBR.

```text
Boot ROM Handover (CS:IP = 0xF000:0x0004, Shadow RAM)
  │
  ▼
Low-Level Firmware Services Setup
  ├─ IVT Installation: Registers INT 10h, INT 12h, INT 13h, INT 15h, INT 16h, INT 1Ah
  ├─ BDA (0x0040:0x0000) initialization & timer baseline
  ├─ Extended data area (EBDA, 0x9FC00) & ACPI 1.0 tables (RSDP, RSDT, MADT)
  ├─ PCI Bus Enumeration: Discovers VGA, AHCI, NVMe, USB, ATA controllers
  ├─ Video Subsystem: Video Option ROM execution (0xC000:0003) or native Mode 03h text
  ├─ Fast A20 Gate: Activated and verified via port 0x92
  ├─ Memory Detection: E820 / E801 memory map via CMOS 0x34/0x35 (with QEMU fw_cfg fallback)
  └─ PS/2 Controller: Configured for 8042 Scan Code Set 2 -> Set 1 translation
  │
  ▼
Automated Multi-Bus Storage Discovery & MBR Loading
  ├─ Probes ATA (IDE), SATA AHCI, NVMe PCIe, and USB 2.0 Mass Storage (EHCI BOT)
  ├─ Reads LBA 0 into 0x0000:0x7C00 via INT 13h AH=42h
  ├─ Validates MBR boot signature 0x55AA at offset 510
  │
  ▼
OS Handover (Standard PC MBR Handover)
  ├─ Sets DL = selected firmware drive ID (0x80/0x81 for ATA, AHCI, or NVMe; 0x82 for USB when initialized)
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
Embeds the firmware payload into a specified external Boot ROM image:
```bash
make run BOOTROM=path/to/bootrom.bin
```

### 3. Running with an OS Disk Image
Attaches a raw storage image as primary IDE master (`0x80`):
```bash
make run OS=path/to/disk.img
```

### 4. Running with Boot ROM and OS Image
Builds a ROM embedding the specified Boot ROM and boots the target OS:
```bash
make run BOOTROM=path/to/bootrom.bin OS=path/to/disk.img
```

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
| `build/.bin/firmware.bin` | <= 32 KiB | Assembled firmware payload (starts with `'IPO'` signature). Input artifact for a compatible external Boot ROM image builder. |
| `build/firmware.bin` | 256 KiB standalone; otherwise the supplied Boot ROM image size | Complete firmware image for direct QEMU execution (`make run`) or physical flash chip programming. |

---

## 📜 Boot Handoff Interfaces

### Firmware Input (Boot ROM → Firmware)
Firmware receives control from the hardware reset bootloader with the machine in the following state:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0xF000:0x0004` | Entry in write-protected Shadow RAM |
| **Magic Header** | `0xF000:0x0000` | 4 bytes: `'I', 'P', 'O'` (`0x004F5049`) |
| **Data Segments** | `DS = ES = 0x0000` | Base conventional segment |
| **Stack (`SS:SP`)** | `0x0000:0x7C00` | Initial stack pointer in DRAM; stack grows down below the MBR buffer |
| **Interrupt Flag (`IF`)** | `0` (`cli`) | Interrupts disabled until firmware registers IVT handlers |
| **Memory State** | Operational | DRAM initialized by Boot ROM (MRC); Shadow RAM write-protected |

### Firmware Output (Firmware → MBR / OS Bootloader)
Firmware hands over execution to the operating system bootloader using standard PC-AT conventions:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0x0000:0x7C00` | MBR entry point in conventional DRAM |
| **Boot Drive (`DL`)** | `0x80` / `0x81` / `0x82` | Firmware drive number selected by Firmware; `0x80` and `0x81` map storage devices, while `0x82` is USB when initialized |
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
| **INT 12h** | — | Get Conventional Memory Size (returns 639 KB in `AX`, reserving 1 KB for EBDA) |
| **INT 13h** | `AH=00h` | Reset Disk System |
| | `AH=08h` | Get Drive Parameters (Geometry: Cylinders, Heads, Sectors, Drives) |
| | `AH=41h` | Installation Check / EDD Extensions (`BX=0x55AA` $\to$ `BX=0xAA55`) |
| | `AH=42h` | Extended Read Sectors via Disk Address Packet (DAP, LBA addressing) |
| **INT 15h** | `EAX=0xE820` | Query System Address Map (returns SMAP entries, marks EBDA as Reserved) |
| | `AX=0xE801` | Get Memory Size for >64MB Configurations (extended memory) |
| | `AX=0x2401` | Fast A20 Gate Enable (via System Control Port A `0x92`) |
| **INT 16h** | `AH=00h` | Read Keystroke from PS/2 keyboard buffer (blocking) |
| | `AH=01h` / `AH=11h` | Check Keystroke availability (non-blocking, updates ZF flag) |
| **INT 1Ah** | `AH=00h` | Read System Timer Ticks (18.2 Hz ticks from BDA `0x0040:0x006C`) |

---

## 🔌 Hardware Subsystems & Features

- **Video Option ROM & Chaining:** Automatically detects PCI VGA adapters (`Class 0x03`), maps Expansion ROM BAR to `0xC0000`, validates `0xAA55` signature, executes entry point `0xC000:0003`, and chains the original handler to `INT 42h` while preserving teletype mirroring to COM1. If absent, firmware falls back to its built-in native Mode 03h driver.
- **Storage Subsystems:** Auto-probes multiple bus architectures without user configuration:
  - **IDE / PATA:** Legacy ATA PIO (`0x1F0` / `0x170`).
  - **SATA AHCI:** PCI AHCI HBA memory-mapped I/O with FIS & command headers.
  - **PCIe NVMe:** PCI NVMe SSD with Admin & I/O submission/completion queues.
  - **USB 2.0 Mass Storage:** PCI EHCI controller with Bulk-Only Transport (BOT).
- **Dual Console Logging & Headless Safe:** Diagnostic messages are output simultaneously to the VGA text screen and COM1 UART (`115200 8N1`). If no VGA or no serial receiver is connected, bounded timeout loops prevent system hangs.

---

## 🚦 Firmware POST Diagnostic Port 0x80 Codes

| Hex Code | Checkpoint / Milestone | Status |
| :---: | :--- | :---: |
| `0x20` | Firmware entry point reached (`0xF000:0x0004`) | Progress |
| `0x21` | PCI bus enumeration and device discovery completed | Progress |
| `0x22` | Real-mode Interrupt Vector Table (IVT) installed | Progress |
| `0x23` | ACPI 1.0 tables installed in EBDA (`0x9FC00`) | Progress |
| `0x24` | Video initialized (Option ROM or native Mode 03h) | Progress |
| `0x25` | Fast A20 Gate activated and verified | Progress |
| `0x26` | E820 / E801 memory map prepared in Scratch RAM | Progress |
| `0x27` | 8042 PS/2 keyboard controller initialized | Progress |
| `0x28` | Storage controllers initialized (ATA / AHCI / NVMe / USB) | Progress |
| `0x29` | Waiting for physical HDD spindle spinup (up to 15s timeout) | Notice |
| `0x30` | Commenced drive scan for bootable media (`0x80..0x82`) | Progress |
| `0x31` | Valid MBR signature `0xAA55` loaded at `0x0000:0x7C00` | Progress |
| `0xF0` | Jumping to MBR entry point (`0x0000:0x7C00`) — OS Handover | Success |
| **`0xEE`** | **ERROR:** No bootable media found on any storage device | **Error** |

## 🧑‍💻 Authors

- [IPOleksenko](https://github.com/IPOleksenko) (owner) — Developer and creator of the idea.


# 📜 License

This project is licensed under the [MIT License][license].

[license]: ./LICENSE