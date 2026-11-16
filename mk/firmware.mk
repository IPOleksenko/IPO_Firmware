# Firmware build rules

firmware: $(FIRMWARE_BIN)

# Assemble raw firmware payload (max 32 KiB)
$(FIRMWARE_PAYLOAD): $(SRCS)
	@mkdir -p $(BIN)
	$(ASM) $(ASM_FLAGS) $(SRC)/entry.asm -o $@
	@size=$$(stat -c %s $@); \
	echo "[IPO_Firmware] Firmware payload generated: $@ ($$size bytes)"; \
	if [ $$size -gt 32768 ]; then \
		echo "ERROR: firmware.bin exceeds 32 KiB payload limit ($$size bytes)!" >&2; \
		exit 1; \
	fi

ifneq ($(ROM_BIN),)
.PHONY: $(FIRMWARE_BIN)
endif

# Build final ROM image for emulation or flash chips
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
