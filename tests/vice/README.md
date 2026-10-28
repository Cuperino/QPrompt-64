# VICE test harness

Automated checks for the scroller, driven through VICE's remote monitor.

```bash
tests/vice/run_all.sh            # everything, baseline 7cbf4f5
tests/vice/run_all.sh <ref>      # compare screen content against another commit
```

A full run takes well under a minute. VICE runs in warp mode and is closed
after each check.

## Requirements

- cc65 (`ca65`, `ld65`)
- VICE as flatpak `net.sf.VICE`. `run_vice.sh` adds `--share=network`
  because the flatpak has no network access by default, and the remote
  monitor needs localhost.
- Python 3, plus `py65` for `kbtest.py` (`pip install py65`)

## Checks

| Script | What it checks |
|---|---|
| `race.py` | Beam race. Scrolls forward, reverse, forward. Store watchpoints on the first and last byte each copy writes per row. It fails if a row is written before the beam fetched it in the start frame, or after its fetch with the new YSCROLL when the copy started on time. Late-started copies tear by design (fluidity over tearing) and are listed but don't fail. |
| `content.py` | Screen regression. Dumps screen and colour RAM at every coarse step, 30 rows forward and back. `compare` checks two builds match and that scrolling back gives the same screens. The baseline is built with the working tree's glyph data (see below), so redrawn or added glyphs don't count as differences. |
| `kbtest.py` | `scan_keyboard` in the py65 simulator with a fake CIA. Checks matrix codes, SHIFT, CTRL/C= ignored, and cycle cost. |

## Pieces

- `build_debug.sh [ref [glyphs]]` assembles the working tree, or a git ref,
  into `build/<name>/` with an `ld65 -Ln` label file. With `glyphs`, the ref
  is built into `build/<ref>-glyphs/` with the working tree's glyph data.
- `splice_glyphs.py <from.s> <into.s>` copies the glyph data (the
  `tile_char_idx` through `tile_off_hi` tables and the `CHARSET` segment)
  from one source into another. Both blocks end at the next `; ====` section
  header, so a baseline must keep that layout.
- `run_vice.sh ntsc|pal` starts VICE with the remote monitor on
  `127.0.0.1:6510`, without autostart.
- `mon.py` is the monitor client. It also has `start_prompter()`, which boots
  to BASIC, loads the PRG, presses F5 via the KERNAL key buffer, and sets the
  speed step in `current_step`. It also has `force_reverse_patch()`, a
  debug-only patch that makes `read_keyboard` see SHIFT. The monitor can't
  hold keys, so this stands in for SHIFT LOCK.

## Notes

- Each monitor command reads until the `(C:$xxxx)` prompt. VICE sends one
  prompt on connect, and `Mon()` consumes it. If a client disconnects while
  VICE is stopped, later stops go to the GUI monitor window, so keep one
  connection per VICE session.
- `race.py` relies on labels `@s2_apply`, `@s2_late`, `@ss_go` and
  `@ss_late`, and on `@s2_apply+7` being the `STA $D011`. The content and
  keyboard checks only need labels that also exist in older builds.
