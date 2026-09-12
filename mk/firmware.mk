# =============================================================================
#                 FIRMWARE BUILD RULES
# =============================================================================

firmware: $(FIRMWARE_BIN)

$(FIRMWARE_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(ASM) $(ASM_FLAGS) $(SRC)/entry.asm -o $@
	@size=$$(stat -c %s $@); \
	echo "[IPO_Firmware] Binary generated: $@ ($$size bytes)"; \
	if [ $$size -gt 32768 ]; then \
		echo "ERROR: firmware.bin exceeds 32KB limit ($$size bytes)!" >&2; \
		exit 1; \
	fi

# Build bootable ROM embedding this firmware for standalone execution / testing
$(FIRMWARE_ROM): $(FIRMWARE_BIN) $(BUILD)/stub_bootrom.bin $(TOOLS)/build_firmware.sh
	$(TOOLS)/build_firmware.sh $(FIRMWARE_BIN) $(BUILD)/stub_bootrom.bin $@

# Build customized ROM embedding this firmware into specified Boot ROM / RAM boot
$(RUN_ROM): $(FIRMWARE_BIN) $(TOOLS)/build_firmware.sh
	@rom_target="$(ROM_BIN)"; \
	if [ -d "$$rom_target" ]; then \
		if [ -f "$$rom_target/build/bootrom_template.bin" ]; then \
			rom_target="$$rom_target/build/bootrom_template.bin"; \
		elif [ -f "$$rom_target/build/bootrom.bin" ]; then \
			rom_target="$$rom_target/build/bootrom.bin"; \
		else \
			echo "[IPO_Firmware] Building Boot ROM in $$rom_target..."; \
			$(MAKE) -C "$$rom_target" bootrom || exit 1; \
			rom_target="$$rom_target/build/bootrom_template.bin"; \
		fi; \
	fi; \
	if [ ! -f "$$rom_target" ]; then \
		if [ "$$rom_target" = "../IPO_Boot_Rom/build/bootrom_template.bin" ] && [ -d "../IPO_Boot_Rom" ]; then \
			echo "[IPO_Firmware] Building IPO_Boot_Rom..."; \
			$(MAKE) -C ../IPO_Boot_Rom bootrom || exit 1; \
		fi; \
	fi; \
	if [ ! -f "$$rom_target" ]; then \
		echo "ERROR: Boot ROM / RAM boot image '$$rom_target' not found!" >&2; \
		echo "Usage: make run [BOOTROM=path/to/bootrom.bin] [OS=path/to/os.img]" >&2; \
		exit 1; \
	fi; \
	$(TOOLS)/build_firmware.sh $(FIRMWARE_BIN) "$$rom_target" $@

# -----------------------------------------------------------------------------
# Standalone Testing Artifacts
# -----------------------------------------------------------------------------
$(BUILD)/stub_bootrom.bin: $(TESTS)/stub_bootrom.asm
	@mkdir -p $(BUILD)
	$(ASM) -f bin -o $@ $<

$(BUILD)/stub_mbr.bin: $(TESTS)/stub_mbr.asm
	@mkdir -p $(BUILD)
	$(ASM) -f bin -o $@ $<

$(TEST_MBR): $(BUILD)/stub_mbr.bin
	@mkdir -p $(BUILD)
	cp $< $@
	truncate -s 1M $@

$(TEST_ROM): $(FIRMWARE_BIN) $(BUILD)/stub_bootrom.bin $(TOOLS)/build_firmware.sh
	$(TOOLS)/build_firmware.sh $(FIRMWARE_BIN) $(BUILD)/stub_bootrom.bin $@

test: $(TEST_ROM) $(TEST_MBR)
	$(TESTS)/run_qemu_test.sh $(TEST_ROM) $(TEST_MBR)

.PHONY: firmware test

