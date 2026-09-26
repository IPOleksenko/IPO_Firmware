# IPO_Firmware

Independent bare-metal x86 BIOS-compatible Firmware service layer for QEMU and PC-AT compatible machines.

---

## 📋 Architecture & Runtime Services

`IPO_Firmware` executes in write-protected Shadow RAM at `0xF000:0x0004` (or `0x0800:0000` in chainload mode), receiving control from an early hardware reset loader (Boot ROM) under **Contract 2**. It provides standard PC BIOS runtime interrupt services and performs automated multi-bus storage discovery and MBR handover under **Contract 3**.

```text
Boot ROM Handover (CS:IP = 0xF000:0x0004, Shadow RAM)
  │
  ▼
Low-Level BIOS Services Setup
  ├─ IVT Installation: Registers INT 10h, INT 12h, INT 13h, INT 15h, INT 16h, INT 1Ah
  ├─ BIOS Data Area (BDA, 0x0040:0x0000) initialization & timer baseline
  ├─ Extended BIOS Data Area (EBDA, 0x9FC00) & ACPI 1.0 tables (RSDP, RSDT, MADT)
  ├─ PCI Bus Enumeration: Discovers VGA, AHCI, NVMe, USB, ATA controllers
  ├─ Video Subsystem: VBIOS Option ROM execution (0xC000:0003) or native Mode 03h text
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
OS Handover (Contract 3: Standard PC BIOS MBR Handover)
  ├─ Sets DL = Boot drive ID (0x80 = primary disk, 0x81, 0x82 = USB)
  ├─ Sets DS = ES = SS = 0x0000, SP = 0x7C00, Flags: STI (interrupts enabled)
  └─ Jumps to loaded MBR at 0x0000:0x7C00
```

---

## 🛠️ Build Commands

```bash
# Compile firmware binary and construct default standalone ROM
make

# Run automated headless verification test in QEMU (validates IVT, INT 10h/13h/15h, MBR chainload)
make test

# Clean all build artifacts
make clean
```

---

## 🚀 Emulation & Running (`make run`)

`make run` allows isolated firmware execution, custom Boot ROM integration, and booting operating system storage media:

### 1. Standalone Execution (No arguments)
Runs firmware with built-in stub bootloader and no attached OS:
```bash
make run
```

### 2. Running with an External Boot ROM
Embeds `firmware.bin` into a specified external Boot ROM:
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
| `build/firmware.bin` | < 32 KB | Assembled BIOS firmware payload (starts with `'IPOF'` signature) |
| `build/firmware_rom.bin` | 262,144 B | Default 256 KB ROM embedding `firmware.bin` and an internal stub Boot ROM |
| `build/firmware_run_rom.bin` | 262,144 B | Custom 256 KB ROM generated when embedding an external Boot ROM |
| `build/test_rom.bin` | 262,144 B | Dedicated testing ROM image used by `make test` |
| `build/test_mbr.img` | 1,048,576 B | 1 MB test disk image embedding MBR validation code for `make test` |

---

## 📜 System Contracts

### Contract 2: Input Contract (Boot ROM → Firmware)
Firmware receives control from the hardware reset bootloader with the machine in the following state:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0xF000:0x0004` | Entry in write-protected Shadow RAM (or `0x0800:0x0004` in chainload) |
| **Magic Header** | `0xF000:0x0000` | 4 bytes: `'I', 'P', 'O', 'F'` (`0x464F5049`) |
| **Data Segments** | `DS = ES = 0x0000` | Base conventional segment |
| **Stack (`SS:SP`)** | `0x0000:0x7000` | Safe stack in DRAM below MBR buffer |
| **Interrupt Flag (`IF`)** | `0` (`cli`) | Interrupts disabled until firmware registers IVT handlers |
| **Memory State** | Operational | DRAM initialized by Boot ROM (MRC); Shadow RAM write-protected |

### Contract 3: Output Contract (Firmware → MBR / OS Bootloader)
Firmware hands over execution to the operating system bootloader adhering strictly to standard PC-AT BIOS conventions:
| Parameter | State | Description |
| :--- | :--- | :--- |
| **CPU Mode** | 16-bit Real Mode | Standard real mode execution |
| **Entry Point (`CS:IP`)** | `0x0000:0x7C00` | MBR entry point in conventional DRAM |
| **Boot Drive (`DL`)** | `0x80` / `0x81` / `0x82` | BIOS Drive ID (`0x80` = primary disk/SATA/NVMe, `0x81` = secondary, `0x82` = USB) |
| **Data & Stack** | `DS = ES = SS = 0x0000`, `SP = 0x7C00` | Clean segments, stack grows downward from `0x7C00` |
| **Interrupt Flag (`IF`)** | `1` (`sti`) | Interrupts enabled, hardware timers and keyboard active |
| **Boot Sector Buffer** | `0x0000:0x7C00` (512 bytes) | First sector (LBA 0) loaded from boot drive |
| **MBR Signature** | `0x55AA` | Byte 510 = `0x55`, byte 511 = `0xAA` |

---

## 🛠️ Supported BIOS Interrupt Services (IVT)

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

- **VBIOS Option ROM & Chaining:** Automatically detects PCI VGA adapters (`Class 0x03`), maps Expansion ROM BAR to `0xC0000`, validates `0xAA55` signature, executes entry point `0xC000:0003`, and chains the original handler to `INT 42h` while preserving teletype mirroring to COM1. If absent, firmware falls back to its built-in native Mode 03h driver.
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
| `0x24` | Video initialized (VBIOS Option ROM or native Mode 03h) | Progress |
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