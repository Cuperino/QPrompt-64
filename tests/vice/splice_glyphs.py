#!/usr/bin/env python3
"""Copy the glyph data from one scroll.s into another.

  splice_glyphs.py <from.s> <into.s>

Replaces two blocks in <into.s> with the ones from <from.s>:
  - tile_char_idx / tile_sets / tile_off_lo / tile_off_hi (RODATA)
  - the CHARSET segment
Each block runs from its start marker to the first '; ====' section header
after its last label.
Used so a baseline build draws the same glyphs as the working tree, and the
content check only reports differences in the scroll engine.
"""
import sys

# (start marker, last label inside the block)
BLOCKS = (("\ntile_char_idx:", "\ntile_off_hi:"),
          ('\n.segment "CHARSET"', '\n.segment "CHARSET"'))


def block(src, start, last):
    a = src.index(start)
    b = src.index("\n; ====", src.index(last, a))
    return a, b


def main(frm, into):
    s_from = open(frm).read()
    s_into = open(into).read()
    for start, last in BLOCKS:
        fa, fb = block(s_from, start, last)
        ia, ib = block(s_into, start, last)
        s_into = s_into[:ia] + s_from[fa:fb] + s_into[ib:]
    open(into, "w").write(s_into)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
