# =============================================================================
#                 EMULATION / RUN TARGET
# =============================================================================

run: $(FIRMWARE_ROM)
ifneq ($(OS_IMAGE),)
	@if [ ! -f "$(OS_IMAGE)" ]; then \
		echo "ERROR: OS storage media '$(OS_IMAGE)' not found!" >&2; \
		exit 1; \
	fi
	@echo "================================================================="
	@echo "[IPO_Firmware] Launching QEMU with BIOS Firmware"
	@echo "[IPO_Firmware] Booting OS from storage media: $(OS_IMAGE)"
	@echo "================================================================="
else
	@echo "================================================================="
	@echo "[IPO_Firmware] Launching QEMU with BIOS Firmware (standalone)"
	@echo "[IPO_Firmware] Tip: To boot an OS image, use: make run OS=path/to/os.img"
	@echo "================================================================="
endif
	$(QEMU) $(QEMU_FLAGS)

.PHONY: run
