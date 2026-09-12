# =============================================================================
#                 EMULATION / RUN TARGET
# =============================================================================

run: $(TARGET_ROM)
ifneq ($(ROM_BIN),)
	@echo "================================================================="
	@echo "[IPO_Firmware] Launching QEMU with BIOS Firmware"
	@echo "[IPO_Firmware] Embedded Boot ROM (RAM Boot): $(ROM_BIN)"
ifneq ($(OS_IMAGE),)
	@if [ ! -f "$(OS_IMAGE)" ]; then \
		echo "ERROR: OS storage media '$(OS_IMAGE)' not found!" >&2; \
		exit 1; \
	fi
	@echo "[IPO_Firmware] Booting OS from storage media: $(OS_IMAGE)"
endif
	@echo "================================================================="
else ifneq ($(OS_IMAGE),)
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
	@echo "[IPO_Firmware] Tip: To embed Boot ROM (RAM boot): make run BOOTROM=path/to/bootrom.bin"
	@echo "[IPO_Firmware] Tip: To boot an OS image:          make run OS=path/to/os.img"
	@echo "[IPO_Firmware] Tip: Combined invocation:         make run BOOTROM=... OS=..."
	@echo "================================================================="
endif
	$(QEMU) $(QEMU_FLAGS)

.PHONY: run
