#!/usr/bin/env bash
# build_firmware.sh — Builds a 256KB test ROM combining stub_bootrom and firmware.bin
#
# Arguments:
#   $1 = Path to firmware.bin
#   $2 = Path to stub_bootrom.bin
#   $3 = Output test ROM file (e.g. build/test_rom.bin)

set -euo pipefail

FW_BIN="${1}"
STUB_ROM_BIN="${2}"
OUTPUT_ROM="${3}"
ROMSIZE=262144
FW_OFFSET=196608   # 0x30000 (0xF000:0000)
STUB_OFFSET=260096 # 0x3F800 (0xF000:0xF800)

mkdir -p "$(dirname "$OUTPUT_ROM")"

# 1. Create 256KB filled with 0xFF
python3 -c "import sys; sys.stdout.buffer.write(b'\xFF' * $ROMSIZE)" > "$OUTPUT_ROM"

# 2. Embed firmware.bin at FW_OFFSET
dd if="$FW_BIN" of="$OUTPUT_ROM" bs=1 seek="$FW_OFFSET" conv=notrunc status=none

# 3. Embed stub_bootrom.bin at STUB_OFFSET
dd if="$STUB_ROM_BIN" of="$OUTPUT_ROM" bs=1 seek="$STUB_OFFSET" conv=notrunc status=none

echo "[build_firmware] Test ROM created: $OUTPUT_ROM ($ROMSIZE bytes)"
