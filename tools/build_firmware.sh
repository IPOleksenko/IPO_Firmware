#!/usr/bin/env bash
# build_firmware.sh — Builds a 256KB test ROM combining stub_bootrom and firmware.bin
#
# Arguments:
#   $1 = Path to firmware.bin
#   $2 = Path to stub_bootrom.bin
#   $3 = Output test ROM file (e.g. build/test_rom.bin)

set -euo pipefail

FW_BIN="${1}"
BOOTROM_BIN="${2}"
OUTPUT_ROM="${3}"
ROMSIZE=262144
FW_OFFSET=196608   # 0x30000 (0xF000:0000)
STUB_OFFSET=260096 # 0x3F800 (0xF000:0xF800)

mkdir -p "$(dirname "$OUTPUT_ROM")"

if [ ! -f "$FW_BIN" ]; then
    echo "ERROR: Firmware binary '$FW_BIN' not found!" >&2
    exit 1
fi

if [ ! -f "$BOOTROM_BIN" ]; then
    echo "ERROR: Boot ROM binary '$BOOTROM_BIN' not found!" >&2
    exit 1
fi

rom_input_size=$(stat -c %s "$BOOTROM_BIN")

if [ "$rom_input_size" -eq "$ROMSIZE" ]; then
    # Input is already a full 256KB Boot ROM image
    # Copy it to output and embed firmware.bin at FW_OFFSET
    cp "$BOOTROM_BIN" "$OUTPUT_ROM"
    fw_size=$(stat -c %s "$FW_BIN")
    echo "[build_firmware] Embedding Firmware: $FW_BIN ($fw_size bytes) into 256KB Boot ROM at offset $FW_OFFSET (0x$(printf '%X' $FW_OFFSET))"
    dd if="$FW_BIN" of="$OUTPUT_ROM" bs=1 seek="$FW_OFFSET" conv=notrunc status=none
else
    # Input is a small bootrom stub (e.g. stub_bootrom.bin)
    # 1. Create 256KB filled with 0xFF
    python3 -c "import sys; sys.stdout.buffer.write(b'\xFF' * $ROMSIZE)" > "$OUTPUT_ROM"
    # 2. Embed firmware.bin at FW_OFFSET
    dd if="$FW_BIN" of="$OUTPUT_ROM" bs=1 seek="$FW_OFFSET" conv=notrunc status=none
    # 3. Embed bootrom stub at STUB_OFFSET
    dd if="$BOOTROM_BIN" of="$OUTPUT_ROM" bs=1 seek="$STUB_OFFSET" conv=notrunc status=none
fi

echo "[build_firmware] ROM created: $OUTPUT_ROM ($ROMSIZE bytes)"

