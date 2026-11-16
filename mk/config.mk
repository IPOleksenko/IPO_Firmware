# Toolchain binaries

ASM     := nasm
PYTHON  := python3
QEMU    := qemu-system-i386

# Project layout

SRC     := src
BUILD   := build
BIN     := $(BUILD)/.bin
INC     := include
TOOLS   := tools

# Output binaries

# Raw firmware payload (max 32 KiB)
FIRMWARE_PAYLOAD := $(BIN)/firmware.bin

# Final ROM image for emulation or flash chips
FIRMWARE_BIN := $(BUILD)/firmware.bin
TARGET_BIN   := $(FIRMWARE_BIN)

# Input sources

SRCS    := $(SRC)/entry.asm \
           $(SRC)/pci_scan.asm \
           $(SRC)/video_option_rom.asm \
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
           $(INC)/boot_constants.inc

# Assembler flags

ASM_FLAGS := -f bin -I$(INC) -I$(SRC)

# Emulation options

# Optional stage-1 ROM image to embed (BOOTROM=/path/to/rom.bin)
BOOTROM   ?=
BOOT_ROM  ?= $(BOOTROM)
RAMBOOT   ?= $(BOOT_ROM)
RAM_BOOT  ?= $(RAMBOOT)
ROM_BOOT  ?= $(RAM_BOOT)
ROM_BIN   ?= $(ROM_BOOT)

# Optional OS disk image (OS=/path/to/disk.img)
OS       ?=
OS_IMAGE ?= $(OS)
CPU      ?= pentium3
MEM      ?= 512

# Base emulator flags
QEMU_FLAGS := -M pc -cpu $(CPU) -m $(MEM) -bios $(TARGET_BIN) -serial stdio

# PC speaker audio backend
AUDIO ?= pa
ifneq ($(AUDIO),none)
QEMU_FLAGS += -audiodev $(AUDIO),id=pa -machine pcspk-audiodev=pa
endif

# Attach OS image according to DRIVE_TYPE (ide, ahci, or usb)
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
