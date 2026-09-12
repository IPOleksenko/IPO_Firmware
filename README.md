# IPO_Firmware

Independent bare-metal x86 BIOS-compatible Firmware service layer for QEMU and PC-AT compatible machines.

---

## 📋 Architecture & Runtime Services

`IPO_Firmware` executes in low memory at `0x0800:0000` (physical `0x08000`), receiving control from an early-stage bootloader under **Contract 2**. It provides standard PC BIOS runtime interrupt services and performs automated disk discovery and MBR handover under **Contract 3**.

```text
Boot ROM Handover (CS:IP = 0x0800:0x0004)
  │
  ▼
Low-Level BIOS Services Setup
  ├─ IVT Installation: Registers INT 10h, INT 13h, INT 15h, INT 16h
  ├─ BIOS Data Area (BDA, 0x0040:0x0000) initialization
  ├─ VGA Subsystem: Configures Mode 03h (80x25 text), sets DAC palette & font
  ├─ Fast A20 Gate: Activated and verified via port 0x92
  ├─ Memory Detection: E820 / E801 memory map via fw_cfg with CMOS fallback
  └─ PS/2 Controller: Configured for 8042 Scan Code Set 2 -> Set 1 translation
  │
  ▼
Automated Drive Discovery & MBR Loading
  ├─ Probes ATA primary master (0x80) and slave (0x81) via INT 13h AH=42h
  ├─ Validates MBR signature 0x55AA at offset 510
  │
  ▼
OS Handover (Contract 3: Standard PC BIOS MBR Handover)
  ├─ Clears VGA text screen and resets hardware cursor
  ├─ Sets DL = Boot drive (0x80), DS = ES = SS = 0x0000, SP = 0x7C00, STI
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

## 📖 Specifications & Contracts

See [docs/CONTRACT.md](docs/CONTRACT.md) for full technical documentation:
- **Contract 2**: Input contract from Boot ROM (`0x0800:0004`, magic `'IPOF'`)
- **Contract 3**: Output contract to MBR (`0x0000:0x7C00`, `DL = drive`, interrupts enabled)