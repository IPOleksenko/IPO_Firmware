#!/usr/bin/env bash
# run_qemu_test.sh — Automated test runner for IPO_Firmware in QEMU
#
# Arguments:
#   $1 = Path to test ROM binary (default: build/test_rom.bin)
#   $2 = Path to test MBR image  (default: build/test_mbr.img)

set -euo pipefail

ROM="${1:-build/test_rom.bin}"
MBR_IMG="${2:-build/test_mbr.img}"
EXPECTED_MBR="[Test_OS] OS MBR reached successfully!"
EXPECTED_ALL="[Test_OS] ALL FIRMWARE BIOS SERVICES VERIFIED!"
TIMEOUT_SECS=6

if [ ! -f "$ROM" ]; then
    echo "ERROR: Test ROM '$ROM' does not exist!" >&2
    exit 1
fi

if [ ! -f "$MBR_IMG" ]; then
    echo "ERROR: Test MBR image '$MBR_IMG' does not exist!" >&2
    exit 1
fi

echo "[test] Launching QEMU with -bios $ROM -drive file=$MBR_IMG..."

LOGFILE=$(mktemp)
timeout -s KILL "${TIMEOUT_SECS}s" qemu-system-i386 \
    -M pc \
    -bios "$ROM" \
    -drive format=raw,file="$MBR_IMG",if=ide,index=0 \
    -display none \
    -serial stdio \
    -device isa-debug-exit,iobase=0x501,iosize=2 \
    -no-reboot \
    -no-shutdown < /dev/null > "$LOGFILE" 2>&1 || true

OUTPUT=$(cat "$LOGFILE")
rm -f "$LOGFILE"

echo "────────────────────────────────────────"
echo "QEMU Serial Output:"
echo "$OUTPUT"
echo "────────────────────────────────────────"

if echo "$OUTPUT" | grep -Fq "$EXPECTED_MBR" && echo "$OUTPUT" | grep -Fq "$EXPECTED_ALL"; then
    echo "✅ PASS: IPO_Firmware successfully chainloaded MBR and validated all BIOS services!"
    exit 0
else
    echo "❌ FAIL: Expected verification markers were not found in output!" >&2
    exit 1
fi
