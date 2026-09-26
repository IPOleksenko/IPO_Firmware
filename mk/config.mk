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
           $(SRC)/pci_scan.asm \
           $(SRC)/vbios.asm \
           $(SRC)/ahci.asm \
           $(SRC)/nvme.asm \
           $(SRC)/usb_ehci.asm \
           $(SRC)/ivt.asm \
           $(SRC)/acpi.asm \
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

# Boot ROM binary to embed into ROM (optional: make run BOOTROM=/path/to/bootrom.bin)
BOOTROM   ?=
BOOT_ROM  ?= $(BOOTROM)
RAMBOOT   ?= $(BOOT_ROM)
RAM_BOOT  ?= $(RAMBOOT)
ROM_BOOT  ?= $(RAM_BOOT)
ROM_BIN   ?= $(ROM_BOOT)

# Target OS storage media (optional argument: make run OS=/path/to/disk.img)
OS       ?=
OS_IMAGE ?= $(OS)
CPU      ?= pentium3
MEM      ?= 512

# Determine active ROM for emulation:
# If Boot ROM is provided, build RUN_ROM; otherwise run standalone FIRMWARE_ROM
ifeq ($(ROM_BIN),)
TARGET_ROM := $(FIRMWARE_ROM)
else
TARGET_ROM := $(RUN_ROM)
endif

# Base QEMU flags for running Firmware BIOS
QEMU_FLAGS := -M pc -cpu $(CPU) -m $(MEM) -bios $(TARGET_ROM) -serial stdio

# Audio configuration for PC Speaker
AUDIO ?= pa
ifneq ($(AUDIO),none)
QEMU_FLAGS += -audiodev $(AUDIO),id=pa -machine pcspk-audiodev=pa
endif

# If an OS storage media image is supplied, attach it according to DRIVE_TYPE (ide, ahci, or usb)
ifneq ($(OS_IMAGE),)
DRIVE_TYPE ?= ide
ifeq ($(DRIVE_TYPE),ahci)
QEMU_FLAGS += -device ahci,id=ahci -device ide-hd,drive=sata_disk,bus=ahci.0 -drive id=sata_disk,file=$(OS_IMAGE),format=raw,if=none
else ifeq ($(DRIVE_TYPE),usb)
QEMU_FLAGS += -device usb-ehci,id=ehci -device usb-storage,bus=ehci.0,drive=usb_disk -drive id=usb_disk,file=$(OS_IMAGE),format=raw,if=none
else
QEMU_FLAGS += -drive format=raw,file=$(OS_IMAGE),if=ide,index=0
# Optional secondary disk
DISK ?=
ifneq ($(DISK),)
QEMU_FLAGS += -drive format=raw,file=$(DISK),if=ide,index=1
else ifneq ($(wildcard $(dir $(OS_IMAGE))disk.img),)
QEMU_FLAGS += -drive format=raw,file=$(dir $(OS_IMAGE))disk.img,if=ide,index=1
endif
endif
endif

QEMU_FLAGS += $(QEMU_EXTRA)
