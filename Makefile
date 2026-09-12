# =============================================================================
# IPO_Firmware — BIOS-compatible Firmware
# =============================================================================

.DEFAULT_GOAL := all

include mk/config.mk
include mk/firmware.mk
include mk/run.mk
include mk/clean.mk

all: firmware $(FIRMWARE_ROM)

.PHONY: all firmware run test clean
