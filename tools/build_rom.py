#!/usr/bin/env python3
"""Package the firmware payload into a standalone 256 KiB ROM or embed it into a stage-1 ROM.

Standalone mode fills a 64 KiB bank (mapped to F000:0000 - F000:FFFF) with the
reset vector at 0xFFF0, release date at 0xFFF5, PC-AT model byte 0xFC at
0xFFFE, and an 8-bit checksum at 0xFFFF, mirrored four times to 256 KiB.

Embedded mode (--bootrom) places the payload into the final 64 KiB bank
(F000:0000) of the supplied stage-1 ROM image.
"""

import sys
import os
import argparse

BANK_SIZE = 65536       # 64 KiB
ROM_SIZE  = 262144      # 256 KiB (4 x 64 KiB banks)
FW_OFFSET = 196608      # F000:0000 offset in a 256 KiB ROM

def main():
    parser = argparse.ArgumentParser(description="Construct firmware ROM image")
    parser.add_argument("raw_fw", help="Input raw firmware binary (assembled from entry.asm)")
    parser.add_argument("output_rom", help="Output ROM file path")
    parser.add_argument("--bootrom", help="Path to external Boot ROM binary to embed firmware into", default=None)
    args = parser.parse_args()

    if not os.path.exists(args.raw_fw):
        print(f"ERROR: Raw firmware file '{args.raw_fw}' not found!", file=sys.stderr)
        sys.exit(1)

    with open(args.raw_fw, "rb") as f:
        fw_code = f.read()

    if fw_code[:12] != b"IPO_Firmware":
        print("ERROR: Firmware binary missing 'IPO_Firmware' magic header at offset 0x0000!", file=sys.stderr)
        sys.exit(1)

    max_payload = BANK_SIZE - 16
    if len(fw_code) > max_payload:
        print(f"ERROR: Firmware code size ({len(fw_code)} bytes) exceeds max 64 KiB bank payload ({max_payload} bytes)!", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(os.path.abspath(args.output_rom)), exist_ok=True)

    if args.bootrom:
        # Embed into top 64 KiB bank of an existing ROM
        if not os.path.exists(args.bootrom):
            print(f"ERROR: Boot ROM binary '{args.bootrom}' not found!", file=sys.stderr)
            sys.exit(1)

        with open(args.bootrom, "rb") as f:
            bootrom_data = bytearray(f.read())

        if len(bootrom_data) < BANK_SIZE:
            print(f"ERROR: Boot ROM binary size ({len(bootrom_data)} bytes) is smaller than 64 KiB!", file=sys.stderr)
            sys.exit(1)

        # Segment F000:0000 maps to the final 64 KiB bank of the ROM chip
        fw_offset = len(bootrom_data) - BANK_SIZE
        bootrom_data[fw_offset:fw_offset + len(fw_code)] = fw_code
        rom_data = bootrom_data

        with open(args.output_rom, "wb") as f:
            f.write(rom_data)

        print(f"[build_rom] Created Boot ROM-embedded ROM: {args.output_rom} ({len(rom_data)} bytes)")
        print(f"            - Embedded Boot ROM: {args.bootrom} ({len(bootrom_data)} bytes / {len(bootrom_data)//1024} KiB)")
        print(f"            - Firmware offset:   0x{fw_offset:08X} ({fw_offset} bytes)")
        print(f"            - Firmware size:     {len(fw_code)} bytes (Magic 'IPO_Firmware' at 0xF000:0x0000)")
    else:
        # Standalone 256 KiB ROM
        bank = bytearray(b"\xFF" * BANK_SIZE)
        bank[0:len(fw_code)] = fw_code

        # 0xFFF0 (phys 0xFFFF0): far jmp F000:000C
        bank[0xFFF0:0xFFF5] = b"\xEA\x0C\x00\x00\xF0"

        # 0xFFF5: release date (MM/DD/YY)
        bank[0xFFF5:0xFFFD] = b"01/01/26"

        # 0xFFFD: sub-model byte
        bank[0xFFFD] = 0x00

        # 0xFFFE: system model byte (0xFC = PC-AT)
        bank[0xFFFE] = 0xFC

        # 0xFFFF: checksum byte so the 64 KiB bank sums to 0 mod 256
        current_sum = sum(bank[:0xFFFF]) % 256
        checksum_byte = (256 - current_sum) % 256
        bank[0xFFFF] = checksum_byte

        # Mirror bank across 256 KiB
        rom_data = bank * (ROM_SIZE // BANK_SIZE)

        with open(args.output_rom, "wb") as f:
            f.write(rom_data)

        print(f"[build_rom] Created production ROM: {args.output_rom} ({len(rom_data)} bytes)")
        print(f"            - Payload size: {len(fw_code)} bytes")
        print(f"            - Reset Vector: 0xF000:0x000C (at offset 0xFFF0 in 64 KiB bank)")
        print(f"            - Model Byte:   0xFC (IBM PC-AT)")
        print(f"            - Checksum:     0x{checksum_byte:02X} (verified modulo 256 == 0)")
        print(f"            - Banks:        {ROM_SIZE // BANK_SIZE}x 64 KiB mirrored (compatible with 64 KiB/128 KiB/256 KiB hardware)")

if __name__ == "__main__":
    main()
