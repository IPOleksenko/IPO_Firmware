# =============================================================================
#                 FIRMWARE BUILD RULES
# =============================================================================

firmware: $(FIRMWARE_BIN)

# 1. Compile firmware payload (up to 32 KiB) for the documented boot handoff interface
$(FIRMWARE_PAYLOAD): $(SRCS)
	@mkdir -p $(BIN)
	$(ASM) $(ASM_FLAGS) $(SRC)/entry.asm -o $@
	@size=$$(stat -c %s $@); \
	echo "[IPO_Firmware] Firmware payload generated: $@ ($$size bytes)"; \
	if [ $$size -gt 32768 ]; then \
		echo "ERROR: firmware.bin exceeds 32KB payload limit ($$size bytes)!" >&2; \
		exit 1; \
	fi

ifneq ($(ROM_BIN),)
.PHONY: $(FIRMWARE_BIN)
endif

# 2. Build bootable binary image for QEMU emulation or hardware flashing
$(FIRMWARE_BIN): $(FIRMWARE_PAYLOAD) $(TOOLS)/build_rom.py
	@mkdir -p $(BUILD)
	@rom_target="$(ROM_BIN)"; \
	if [ -n "$$rom_target" ]; then \
		if [ ! -f "$$rom_target" ]; then \
			echo "ERROR: Boot ROM image '$$rom_target' not found!" >&2; \
			exit 1; \
		fi; \
		$(PYTHON) $(TOOLS)/build_rom.py $(FIRMWARE_PAYLOAD) $@ --bootrom "$$rom_target"; \
	else \
		$(PYTHON) $(TOOLS)/build_rom.py $(FIRMWARE_PAYLOAD) $@; \
	fi

.PHONY: firmware
