#!/bin/bash
set -euo pipefail

# =============================================================================
# Update and install required packages for IPO_Firmware
# =============================================================================

echo "================================================================="
echo "[IPO_Firmware] Installing System Dependencies"
echo "================================================================="

echo "Updating package lists..."
sudo apt update || { echo "Failed to update package lists" >&2; exit 1; }

# Required packages for building, emulating, and flashing firmware to real hardware
REQUIRED_PACKAGES=(
    "build-essential"    # GNU Make, GCC, standard build toolchain
    "nasm"               # x86 assembler for 16-bit Real Mode firmware
    "python3"            # Python 3 for ROM packaging (tools/build_rom.py)
    "qemu-system-x86"    # QEMU emulator (qemu-system-i386)
    "qemu-system-gui"    # Audio and graphical display modules for QEMU
    "qemu-utils"         # Disk image utilities (qemu-img)
    "flashrom"           # Utility to flash firmware onto physical ROM chips
    "xxd"                # Hex viewer for inspecting ROM binaries
)

MISSING_PACKAGES=()

for PACKAGE in "${REQUIRED_PACKAGES[@]}"; do
    if dpkg -s "$PACKAGE" &> /dev/null; then
        echo "  [OK] $PACKAGE is already installed."
    else
        echo "  [..] $PACKAGE is missing. Queued for installation."
        MISSING_PACKAGES+=("$PACKAGE")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PACKAGES[*]}..."
    sudo apt install -y "${MISSING_PACKAGES[@]}" || {
        echo "Failed to install required packages!" >&2
        exit 1
    }
else
    echo "All required system packages are already installed."
fi

# =============================================================================
# Verify installation
# =============================================================================

echo ""
echo "================================================================="
echo "[IPO_Firmware] Verifying Installed Tools"
echo "================================================================="

FAILED=0
CHECK_COMMANDS=("nasm" "make" "python3" "qemu-system-i386" "qemu-img" "flashrom" "xxd")

for CMD in "${CHECK_COMMANDS[@]}"; do
    if command -v "$CMD" &> /dev/null; then
        CMD_PATH=$(command -v "$CMD")
        echo "  [FOUND] $CMD -> $CMD_PATH"
    else
        echo "  [MISSING] $CMD not found in PATH!" >&2
        FAILED=1
    fi
done

if [ $FAILED -ne 0 ]; then
    echo "Tools setup verification failed!" >&2
    exit 1
fi

echo "================================================================="
echo "[IPO_Firmware] All dependencies installed and verified successfully!"
echo "================================================================="
