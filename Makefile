# C64 Smooth Scroll — Makefile
# Requires cc65 toolchain (ca65, ld65)

AS      = ca65
LD      = ld65
TARGET  = scroll.prg
SRC     = scroll.s
OBJ     = scroll.o
CFG     = c64scroll.cfg

.PHONY: all clean

all: $(TARGET)

$(OBJ): $(SRC)
	$(AS) -t c64 -o $(OBJ) $(SRC)

$(TARGET): $(OBJ) $(CFG)
	$(LD) -C $(CFG) -o $(TARGET) $(OBJ)

clean:
	rm -f $(OBJ) $(TARGET)
