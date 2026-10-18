# =============================================================================
#                 FIRMWARE BUILD RULES
# =============================================================================

firmware: $(FIRMWARE_BIN)

# 1. Compile pure firmware payload (< 32 KB) conforming to Contract 1 & Contract 2
$(FIRMWARE_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(ASM) $(ASM_FLAGS) $(SRC)/entry.asm -o $@
	@size=$$(stat -c %s $@); \
	echo "[IPO_Firmware] Firmware payload generated: $@ ($$size bytes)"; \
	if [ $$size -gt 32768 ]; then \
		echo "ERROR: firmware.bin exceeds 32KB payload limit ($$size bytes)!" >&2; \
		exit 1; \
	fi

ifneq ($(ROM_BIN),)
.PHONY: $(FIRMWARE_ROM)
endif

# 2. Build bootable ROM image for QEMU emulation or hardware flashing
$(FIRMWARE_ROM): $(FIRMWARE_BIN) $(TOOLS)/build_rom.py
	@mkdir -p $(BUILD)
	@rom_target="$(ROM_BIN)"; \
	if [ -n "$$rom_target" ]; then \
		if [ ! -f "$$rom_target" ]; then \
			echo "ERROR: Boot ROM image '$$rom_target' not found!" >&2; \
			exit 1; \
		fi; \
		$(PYTHON) $(TOOLS)/build_rom.py $(FIRMWARE_BIN) $@ --bootrom "$$rom_target"; \
	else \
		$(PYTHON) $(TOOLS)/build_rom.py $(FIRMWARE_BIN) $@; \
	fi

.PHONY: firmware
