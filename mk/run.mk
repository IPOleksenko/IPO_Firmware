# =============================================================================
#                 EMULATION / RUN TARGET
# =============================================================================

run: $(FIRMWARE_ROM)
	@if [ ! -f "$(OS_IMAGE)" ]; then \
		echo "ERROR: OS storage media '$(OS_IMAGE)' not found!" >&2; \
		echo "Usage: make run OS=/path/to/disk.img" >&2; \
		exit 1; \
	fi
	@echo "================================================================="
	@echo "[IPO_Firmware] Launching QEMU with BIOS Firmware"
	@echo "[IPO_Firmware] Booting OS from storage media: $(OS_IMAGE)"
	@echo "================================================================="
	$(QEMU) $(QEMU_FLAGS)

.PHONY: run
