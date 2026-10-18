#!/usr/bin/env python3
"""
build_rom.py — Constructs a production-ready x86 PC-AT BIOS ROM image
Target: Real Hardware (EPROM / Flash ROM 27C020, SST39SF020, W29C020) & Emulators (QEMU)

Modes:
1. Standalone Production ROM (no --bootrom):
   - Layout of 64KB bank (mapped to F000:0000 - F000:FFFF):
       * Offset 0x0000: Firmware Payload (Magic 'IPOF' at 0x0000, entry at 0x0004)
       * Offset 0xFFF0: Power-on CPU Reset Vector (jmp far F000:0004 -> EA 04 00 00 F0)
       * Offset 0xFFF5: Release Date string "MM/DD/YY" (8 bytes ASCII: "01/01/26")
       * Offset 0xFFFD: Sub-model byte (0x00)
       * Offset 0xFFFE: System Model byte (0xFC = IBM PC-AT / 386+ Architecture)
       * Offset 0xFFFF: 8-bit Checksum byte (making 64KB sum modulo 256 == 0)
   - 4x 64KB banks mirrored across 256KB for physical ROM chip and QEMU compatibility.

2. Embedded Boot ROM Mode (--bootrom <path>):
   - Embeds firmware payload at offset 0x30000 (196608, F000:0000) inside the provided
     external Boot ROM (e.g. IPO_Boot_Rom) adhering to Contract 2.
"""

import sys
import os
import argparse

BANK_SIZE = 65536       # 64 KB
ROM_SIZE  = 262144      # 256 KB (4 x 64 KB banks)
FW_OFFSET = 196608      # 0x30000 (offset for F000:0000 in 256KB ROM)

def main():
    parser = argparse.ArgumentParser(description="Construct BIOS ROM image")
    parser.add_argument("raw_fw", help="Input raw firmware binary (assembled from entry.asm)")
    parser.add_argument("output_rom", help="Output ROM file path")
    parser.add_argument("--bootrom", help="Path to external Boot ROM binary to embed firmware into", default=None)
    args = parser.parse_args()

    if not os.path.exists(args.raw_fw):
        print(f"ERROR: Raw firmware file '{args.raw_fw}' not found!", file=sys.stderr)
        sys.exit(1)

    with open(args.raw_fw, "rb") as f:
        fw_code = f.read()

    max_payload = BANK_SIZE - 16
    if len(fw_code) > max_payload:
        print(f"ERROR: Firmware code size ({len(fw_code)} bytes) exceeds max 64K bank payload ({max_payload} bytes)!", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(os.path.abspath(args.output_rom)), exist_ok=True)

    if args.bootrom:
        # Embedded Boot ROM mode (Contract 2: Boot ROM -> Firmware)
        if not os.path.exists(args.bootrom):
            print(f"ERROR: Boot ROM binary '{args.bootrom}' not found!", file=sys.stderr)
            sys.exit(1)

        with open(args.bootrom, "rb") as f:
            bootrom_data = bytearray(f.read())

        if len(bootrom_data) < BANK_SIZE:
            print(f"ERROR: Boot ROM binary size ({len(bootrom_data)} bytes) is smaller than 64KB!", file=sys.stderr)
            sys.exit(1)

        # In any x86 flash ROM (256KB, 512KB, 1MB, 2MB, 4MB, etc.), segment 0xF000:0x0000
        # is mapped to the top 64KB of the flash chip: (flash_size - 65536)
        fw_offset = len(bootrom_data) - BANK_SIZE
        bootrom_data[fw_offset:fw_offset + len(fw_code)] = fw_code
        rom_data = bootrom_data

        with open(args.output_rom, "wb") as f:
            f.write(rom_data)

        print(f"[build_rom] Created Boot ROM-embedded ROM: {args.output_rom} ({len(rom_data)} bytes)")
        print(f"            - Embedded Boot ROM: {args.bootrom} ({len(bootrom_data)} bytes / {len(bootrom_data)//1024} KB)")
        print(f"            - Firmware offset:   0x{fw_offset:08X} ({fw_offset} bytes)")
        print(f"            - Firmware size:     {len(fw_code)} bytes (Magic 'IPOF' at 0xF000:0x0000)")
    else:
        # Standalone Production ROM mode (direct hardware reset vector)
        bank = bytearray(b"\xFF" * BANK_SIZE)
        bank[0:len(fw_code)] = fw_code

        # Offset 0xFFF0 (physical 0xFFFF0): Power-On CPU Reset Vector
        bank[0xFFF0:0xFFF5] = b"\xEA\x04\x00\x00\xF0"

        # Offset 0xFFF5: Standard BIOS Date (MM/DD/YY)
        bank[0xFFF5:0xFFFD] = b"01/01/26"

        # Offset 0xFFFD: Sub-model byte
        bank[0xFFFD] = 0x00

        # Offset 0xFFFE: System Model Byte (0xFC = IBM PC-AT / 386+ Compatible)
        bank[0xFFFE] = 0xFC

        # Offset 0xFFFF: Checksum byte (sum of all 65536 bytes modulo 256 must be 0)
        current_sum = sum(bank[:0xFFFF]) % 256
        checksum_byte = (256 - current_sum) % 256
        bank[0xFFFF] = checksum_byte

        # 4x 64KB mirrored across 256KB
        rom_data = bank * (ROM_SIZE // BANK_SIZE)

        with open(args.output_rom, "wb") as f:
            f.write(rom_data)

        print(f"[build_rom] Created production ROM: {args.output_rom} ({len(rom_data)} bytes)")
        print(f"            - Payload size: {len(fw_code)} bytes")
        print(f"            - Reset Vector: 0xF000:0x0004 (at offset 0xFFF0 in 64KB bank)")
        print(f"            - Model Byte:   0xFC (IBM PC-AT)")
        print(f"            - Checksum:     0x{checksum_byte:02X} (verified modulo 256 == 0)")
        print(f"            - Banks:        {ROM_SIZE // BANK_SIZE}x 64KB mirrored (compatible with 64K/128K/256K hardware)")

if __name__ == "__main__":
    main()
