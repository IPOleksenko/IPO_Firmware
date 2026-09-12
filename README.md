# IPO_Firmware

Independent x86 BIOS-compatible Firmware layer for QEMU / PC-AT machines.

## Purpose

`IPO_Firmware` implements the core runtime services of a PC BIOS:
- Full Interrupt Vector Table (IVT) initialization (`INT 10h`, `INT 13h`, `INT 15h`, `INT 16h`).
- VGA Mode 03h (80x25 text console) driver with teletype output and cursor control.
- ATA/IDE PIO Mode disk driver supporting LBA28 and Extended Read (DAP, INT 13h AH=42h).
- Memory detection via QEMU `fw_cfg` interface (INT 15h E820 / E801) and CMOS fallback.
- Fast A20 Gate activation via port `0x92`.
- Automated storage media discovery (scanning drives `0x80`, `0x81`), MBR loading to `0x0000:0x7C00`, and standard BIOS handoff.

## Build Commands

```bash
# Build firmware binary
make

# Run automated verification test in QEMU
make test

# Clean artifacts
make clean
```

## Generated Artifacts

- `build/firmware.bin`: Compiled firmware binary (starts with 4-byte `IPOF` magic, max size 32 KB).
- `build/test_rom.bin`: 256 KB test ROM embedding `firmware.bin` and an isolated stub Boot ROM for testing.
- `build/test_mbr.img`: 1 MB raw disk image embedding `stub_mbr.bin` for testing MBR handover.

## Documentation

See [docs/CONTRACT.md](docs/CONTRACT.md) for full interface, register states, and memory map specifications.