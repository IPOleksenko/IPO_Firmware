# =============================================================================
#                     TOOLS
# =============================================================================

ASM     := nasm
QEMU    := qemu-system-i386

# =============================================================================
#                 PROJECT DIRECTORIES
# =============================================================================

SRC     := src
BUILD   := build
INC     := include
TOOLS   := tools
TESTS   := tests

# =============================================================================
#                 OUTPUT ARTIFACTS
# =============================================================================

FIRMWARE_BIN := $(BUILD)/firmware.bin
FIRMWARE_ROM := $(BUILD)/firmware_rom.bin
RUN_ROM      := $(BUILD)/firmware_run_rom.bin
TEST_ROM     := $(BUILD)/test_rom.bin
TEST_MBR     := $(BUILD)/test_mbr.img

# =============================================================================
#                 SOURCES
# =============================================================================

SRCS    := $(SRC)/entry.asm \
           $(SRC)/ivt.asm \
           $(SRC)/int10.asm \
           $(SRC)/int13.asm \
           $(SRC)/int15.asm \
           $(SRC)/a20.asm \
           $(SRC)/kbd.asm \
           $(SRC)/chainload.asm \
           $(SRC)/font8x16.bin \
           $(SRC)/vga_dac.bin \
           $(INC)/contract.inc

# =============================================================================
#                 FLAGS
# =============================================================================

ASM_FLAGS := -f bin -I$(INC) -I$(SRC)

# =============================================================================
#                 EMULATION RUN ARGUMENTS
# =============================================================================

# Boot ROM / RAM Boot binary to embed into ROM (optional: make run BOOTROM=/path/to/bootrom.bin)
BOOTROM   ?=
BOOT_ROM  ?= $(BOOTROM)
RAMBOOT   ?= $(BOOT_ROM)
RAM_BOOT  ?= $(RAMBOOT)
ROM_BOOT  ?= $(RAM_BOOT)
ROM_BIN   ?= $(ROM_BOOT)

# Resolve convenience shorthands (e.g. BOOTROM=1, RAMBOOT=default)
ifeq ($(ROM_BIN),1)
ROM_BIN := ../IPO_Boot_Rom/build/bootrom_template.bin
else ifeq ($(ROM_BIN),default)
ROM_BIN := ../IPO_Boot_Rom/build/bootrom_template.bin
endif

# Target OS storage media (optional argument: make run OS=/path/to/disk.img)
OS       ?=
OS_IMAGE ?= $(OS)
MEM      ?= 8192

# Determine active ROM for emulation:
# If Boot ROM / RAM boot is provided, build RUN_ROM; otherwise run standalone FIRMWARE_ROM
ifeq ($(ROM_BIN),)
TARGET_ROM := $(FIRMWARE_ROM)
else
TARGET_ROM := $(RUN_ROM)
endif

# Base QEMU flags for running Firmware BIOS
QEMU_FLAGS := -M pc -m $(MEM) -bios $(TARGET_ROM) -serial stdio

# If an OS storage media image is supplied, attach it as primary IDE master (disk 0x80)
ifneq ($(OS_IMAGE),)
QEMU_FLAGS += -drive format=raw,file=$(OS_IMAGE),if=ide,index=0
# Optional secondary disk (e.g. IPO_OS disk pool)
DISK ?=
ifneq ($(DISK),)
QEMU_FLAGS += -drive format=raw,file=$(DISK),if=ide,index=1
else ifneq ($(wildcard $(dir $(OS_IMAGE))disk.img),)
QEMU_FLAGS += -drive format=raw,file=$(dir $(OS_IMAGE))disk.img,if=ide,index=1
else ifneq ($(wildcard $(dir $(OS_IMAGE))../build/disk.img),)
QEMU_FLAGS += -drive format=raw,file=$(dir $(OS_IMAGE))../build/disk.img,if=ide,index=1
endif
endif

QEMU_FLAGS += $(QEMU_EXTRA)
