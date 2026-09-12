# =============================================================================
# IPO_Firmware Makefile — Independent BIOS-compatible Firmware Build System
# =============================================================================

ASM         := nasm
BUILD       := build
ASM_FLAGS   := -f bin -Iinclude -Isrc

SRCS        := src/entry.asm \
               src/ivt.asm \
               src/int10.asm \
               src/int13.asm \
               src/int15.asm \
               src/a20.asm \
               src/chainload.asm \
               include/contract.inc

.DEFAULT_GOAL := all

all: $(BUILD)/firmware.bin

$(BUILD)/firmware.bin: $(SRCS)
	@mkdir -p $(BUILD)
	$(ASM) $(ASM_FLAGS) src/entry.asm -o $@
	@size=$$(stat -c %s $@); \
	echo "[IPO_Firmware] Binary generated: $@ ($$size bytes)"; \
	if [ $$size -gt 32768 ]; then \
		echo "ERROR: firmware.bin exceeds 32KB limit ($$size bytes)!" >&2; \
		exit 1; \
	fi

# -----------------------------------------------------------------------------
# Standalone Testing Targets
# -----------------------------------------------------------------------------
$(BUILD)/stub_bootrom.bin: tests/stub_bootrom.asm
	@mkdir -p $(BUILD)
	$(ASM) -f bin -o $@ $<

$(BUILD)/stub_mbr.bin: tests/stub_mbr.asm
	@mkdir -p $(BUILD)
	$(ASM) -f bin -o $@ $<

$(BUILD)/test_mbr.img: $(BUILD)/stub_mbr.bin
	@mkdir -p $(BUILD)
	cp $< $@
	truncate -s 1M $@

$(BUILD)/test_rom.bin: $(BUILD)/firmware.bin $(BUILD)/stub_bootrom.bin tools/build_firmware.sh
	tools/build_firmware.sh $(BUILD)/firmware.bin $(BUILD)/stub_bootrom.bin $@

test: $(BUILD)/test_rom.bin $(BUILD)/test_mbr.img
	tests/run_qemu_test.sh $(BUILD)/test_rom.bin $(BUILD)/test_mbr.img

clean:
	rm -rf $(BUILD)

.PHONY: all test clean
