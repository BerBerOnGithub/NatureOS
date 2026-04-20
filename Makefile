# ===========================================================================
# Makefile - ClaudeOS Build System (ISO edition)
# ===========================================================================

ASM      := nasm
ASMFLAGS := -f bin

BOOT_BIN   := build/boot.bin
STAGE2_BIN := build/stage2.bin
KERNEL_BIN := build/kernel.bin
FS_BIN     := build/fs.bin
FLAT_IMG   := build/claudeos_flat.img
ISO        := claudeos.iso

# Sector layout - aligned to 2048-byte CD sectors (4 x 512-byte sectors each)
# 2048-LBA 0 = 512-sector 0: boot.bin + stage2 (preloaded by El Torito)
# 2048-LBA 1 = 512-sector 4: kernel
# 2048-LBA 51= 512-sector 204: FS
KERNEL_START_SECTOR := 4
FS_START_SECTOR     := 204
FS_SECTORS          := 1600
FLAT_SECTORS        := $(shell echo $$(($(FS_START_SECTOR) + $(FS_SECTORS))))

DATA_IMG   := data.img

.PHONY: all run clean

all: $(ISO) $(DATA_IMG)

$(DATA_IMG):
	python3 mkdata.py

$(BOOT_BIN): boot.asm | build
	$(ASM) $(ASMFLAGS) -o $@ $<
	@SIZE=$$(wc -c < $@); \
	if [ $$SIZE -ne 512 ]; then echo "ERROR: boot.bin must be 512 bytes"; exit 1; fi
	@echo "[OK] boot.bin (512 bytes)"

$(STAGE2_BIN): stage2.asm | build
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[OK] stage2.bin ($$(wc -c < $@) bytes)"

$(KERNEL_BIN): kernel.asm | build
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[OK] kernel.bin ($$(wc -c < $@) bytes)"

$(FS_BIN): $(wildcard apps/*) | build
	python3 mkfs.py

# Build flat binary image (boot + stage2 + kernel + fs packed together)
# xorriso will embed this as the El Torito no-emulation boot image.
# The BIOS loads sector 0 (boot.bin), which loads stage2 from sectors 2-3,
# which loads kernel+fs using INT 13h AH=0x42 LBA reads on the same drive.
$(FLAT_IMG): $(BOOT_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(FS_BIN)
	dd if=/dev/zero      of=$@ bs=512 count=$(FLAT_SECTORS) 2>/dev/null
	dd if=$(BOOT_BIN)    of=$@ bs=512 count=1  conv=notrunc 2>/dev/null
	dd if=$(STAGE2_BIN)  of=$@ bs=512 seek=1   conv=notrunc 2>/dev/null
	dd if=$(KERNEL_BIN)  of=$@ bs=512 seek=$(KERNEL_START_SECTOR) conv=notrunc 2>/dev/null
	dd if=$(FS_BIN)      of=$@ bs=512 seek=$(FS_START_SECTOR) conv=notrunc 2>/dev/null
	@echo "Flat image built: $@ ($$(wc -c < $@) bytes)"

# Wrap the flat image in an ISO using El Torito no-emulation boot
$(ISO): $(FLAT_IMG)
	xorriso -as mkisofs \
	    -o $(ISO) \
	    -b claudeos_flat.img \
	    -no-emul-boot \
	    -boot-load-size 4 \
	    build/
	@echo "$(ISO) built!"

build:
	mkdir -p build

run: $(ISO) $(DATA_IMG)
	qemu-system-x86_64 \
	    -cdrom $(ISO) \
	    -drive format=raw,file=$(DATA_IMG),if=ide,index=2 \
	    -boot d \
	    -m 32M -display sdl -no-reboot \
	    -cpu qemu64 \
	    -nic user,model=e1000

clean:
	rm -rf build $(ISO)