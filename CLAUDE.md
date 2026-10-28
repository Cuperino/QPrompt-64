# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Requires the **cc65 toolchain** (`ca65` assembler, `ld65` linker).

```bash
make          # assemble + link → scroll.prg
make clean    # remove scroll.o and scroll.prg
```

Output is a standard C64 `.prg` file loadable in VICE or on real hardware.

## Testing

```bash
tests/vice/run_all.sh [baseline-ref]   # ~20 s: keyboard unit test, beam race NTSC+PAL, screen content vs baseline
```

Drives VICE (flatpak `net.sf.VICE`) through its remote monitor; see `tests/vice/README.md`. Run it after any change to the scroll, IRQ or render code, NTSC first.

## Architecture

Single-file 6502 assembly project (`scroll.s`) — a C64 teleprompter with smooth vertical scrolling, velocity control, and a left-border-open sprite effect.

### Memory Layout (c64scroll.cfg)

| Region    | Address       | Contents                              |
|-----------|---------------|---------------------------------------|
| ZEROPAGE  | $0002–$001F   | 30 bytes for working variables        |
| LOADADDR  | $07FF–$0800   | 2-byte PRG load address               |
| MAIN      | $0801–$207F   | STARTUP + CODE + RODATA, fill=yes     |
| SPRITES   | $2000         | Forced start within MAIN for VIC-II   |

BASIC SYS stub at $0801 jumps to code at $080D.

### Program Flow

1. **Config screen** — user adjusts `baseSpeed` and `accelerationCurvature` with cursor keys, RETURN starts
2. **Velocity table build** — uses BASIC ROM float routines (FPWRT, FMULT, etc.) to compute `speed = baseSpeed * step^curvature` for steps 0–9 as 8.8 fixed-point
3. **Init** — clear screen, set color RAM (3-tier: white/light-gray/white), configure sprites, install raster IRQ chain
4. **Main loop** — services coarse scroll requests (`cs_pending`: 1=up, 2=down) by calling `scroll_screen_up` / `scroll_screen_down`; exits to config/editor only when no started copy is waiting for its YSCROLL update (`cs_commit`)

### Raster IRQ Chain (5-point)

```
State 0 (raster 119) → State 3 (137→138) → State 1 (175) → State 2 (250) → State 0
```

- **State 0**: Zone on — set dark gray background for reading region
- **State 3**: Double-IRQ CSEL border-open — cycle-exact unrolled loop for 21 sprite lines (140–160), 3-cycle dodge window
- **State 1**: Zone off — restore black background
- **State 2**: Scroll update — show `next_fine` (computed last frame) in YSCROLL, scan the keyboard matrix itself (`scan_keyboard`, replaces the KERNAL scan), accumulate 8.8 velocity, compute the next frame's `next_fine` and set `cs_pending` when it needs a coarse scroll. If a request was not started in time, the step is shown anyway (`cs_late`) and the copy races the beam — fluid motion is preferred over avoiding tearing.

### Coarse Scroll Pipeline (beam chasing)

Fine scroll is pipelined one frame so the coarse copy can start before its result is shown. The main loop starts the copy at raster ≥57 (row 0 already fetched, `coarse_start`), sets `cs_commit`, and the next vblank applies the new YSCROLL. Each row is therefore rewritten after the beam fetched it in the current frame and before its fetch in the next one. The screen is split into bands processed top-down; each band waits (`wait_beam_past`) until the beam has fetched its bottom row. Up uses compact column loops; down is fully unrolled and saves each band's bottom row for the next band. Zone colour remaps (rows 8/15 up, 9/16 down) happen inline. Neither direction ever holds a frame: a copy starts as soon as row 0 is fetched, even late in the frame, and if the vblank passes first the IRQ shows the step anyway (`cs_late`) and the copy races the beam. Fluidity is preferred over avoiding tearing. While a request is unstarted, further motion stops at the row boundary rather than requesting a second coarse step.

### Velocity System

Keys 1–9,0 map to steps 0–9. Step 0 = still. SHIFT LOCK inverts direction. Per-frame: fractional accumulator adds `velocity_table[step]`, integer part = pixels to scroll. Forward decrements `fine_scroll` (7→0, then coarse up); reverse increments (0→7, then coarse down).

### CSEL Border-Open Technique

Sprites sit in the left border area. To prevent the VIC-II border flip-flop from activating, CSEL is toggled between cycles 53–56 of each raster line (the comparison window). Double-IRQ stabilization (pass 1 at raster 137 re-arms to 138, exits via $EA81 quick RTI) ensures ≤2-cycle jitter. The `BORDER_LINE` macro handles per-line restore (cycle ~15) and dodge (cycle ~54).

### Key Conventions

- **Screen codes** not PETSCII: `sc_A`–`sc_Z` = $01–$1A, `__` = space ($20), `_c` = comma, `_d` = period
- **IRQ exits**: all raster IRQ states exit via `$EA81` (quick RTI); the KERNAL handler (`$EA31`) does not run during scrolling — `scan_keyboard` mirrors the key into `$CB`/`$C5` so the KERNAL doesn't see a held key as a new press afterwards
- Self-modifying code used in `build_velocity_table` (save/restore X via immediate operand patching)
- BASIC ROM float routines called at startup only (GIVAYF, MOVFM, MOVFA, FPWRT, FMULT, GETADR, FOUT, MOVMF) — safe because KERNAL IRQs are still active and no custom IRQ chain is installed yet
