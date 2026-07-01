# ---- Configuration ----
CC       = $(RISCV_TOOLCHAIN)/bin/riscv32-unknown-elf-gcc
OBJCOPY  = $(RISCV_TOOLCHAIN)/bin/riscv32-unknown-elf-objcopy
CFLAGS   = -march=rv32im -mabi=ilp32 -O1 -nostdlib -nostartfiles -Wframe-larger-than=256 -Werror
LDFLAGS  = -Wl,-Tlink.ld

NAME = quicksort

SRC      = $(NAME).cpp
ELF      = $(NAME).elf
HEX      = $(NAME).hex
MAP      = $(NAME).map

# ---- Default target ----
all: $(HEX)

# Compile C into ELF
$(ELF): $(SRC) link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,-Map=$(MAP) -o $@ $(SRC)

# Convert ELF to Intel HEX
$(HEX): $(ELF)
	$(OBJCOPY) -O ihex $< $@

# Optional: inspect ELF (objdump)
dump: $(ELF)
	riscv32-unknown-linux-gnu-objdump -SC $(ELF) > $(NAME).dump

# Remove build artifacts
soft_clean:
	rm -f $(ELF) $(MAP)

clean:
	rm -f $(ELF) $(HEX) $(MAP)

.PHONY: all clean dump soft_clean
