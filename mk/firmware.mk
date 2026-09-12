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
