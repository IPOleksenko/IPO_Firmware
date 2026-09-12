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

# Target OS storage media (passed as argument: make run OS=/path/to/os.img)
OS       ?= ../build/IPO_OS.img
OS_IMAGE ?= $(OS)
DISK1    ?= $(wildcard ../build/disk.img)
CDROM    ?= $(wildcard ../build/disk.iso)
MEM      ?= 8192

# Emulates booting specifically from storage media (IDE disk index 0)
QEMU_FLAGS := -M pc -m $(MEM) -bios $(FIRMWARE_ROM) \
              -drive format=raw,file=$(OS_IMAGE),if=ide,index=0

ifneq ($(DISK1),)
QEMU_FLAGS += -drive format=raw,file=$(DISK1),if=ide,index=1
endif

ifneq ($(CDROM),)
QEMU_FLAGS += -cdrom $(CDROM)
endif

QEMU_FLAGS += -serial stdio $(QEMU_EXTRA)
