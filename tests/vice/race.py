#!/usr/bin/env python3
"""Beam-race check for the coarse scroll copy.

Scrolls forward, then reverse, then forward again at a fixed speed step and
records, for every text row, the first and last write each coarse copy makes
(store watchpoints on screen and colour RAM).  For each copy it checks:

  EARLY  a row written in the start frame before the beam fetched it with the
         old YSCROLL (shows new content with old scroll: always a bug)
  LATE   a row written after the beam fetched it in the first frame with the
         new YSCROLL (tearing)

Copies that start on time (raster <= ON_TIME_LINE) must have no LATE rows.
Copies that start later, or whose step the IRQ showed before the copy started
(cs_late), race the beam by design (fluidity over tearing); they are listed
but do not fail the run.

usage: race.py <labels.txt> <scroll.prg> ntsc|pal [step] [n_fwd] [n_rev]
Needs VICE running with run_vice.sh.  Exit code 0 = pass.
"""
import sys
from mon import Mon, STOP, load_labels, start_prompter, force_reverse_patch

ON_TIME_LINE = 80

lab = load_labels(sys.argv[1])
prg = sys.argv[2]
LPF, CPL = {"ntsc": (263, 65), "pal": (312, 63)}[sys.argv[3]]
step = int(sys.argv[4]) if len(sys.argv) > 4 else 9
NF = int(sys.argv[5]) if len(sys.argv) > 5 else 8
NR = int(sys.argv[6]) if len(sys.argv) > 6 else 5      # keep < NF (document start)

apply_sta = lab['@s2_apply'] + 7    # lda next_fine / sta fine_scroll / ora # -> sta VIC_CTRL1
late_at = lab['@s2_late']
ss_go = lab['@ss_go']
ss_late = lab['@ss_late']

m = start_prompter(step, prg, lab)
assert m.mem(apply_sta, apply_sta) == [0x8d], "label offset changed: @s2_apply+7 is not STA"
rk_addr, rk_patch, rk_orig = force_reverse_patch(m, lab)

# First and last byte each direction writes per row:
#   up   (column loops, x = 39..0): screen col 39 first, colour col 0 last
#   down (unrolled, col 0..39):     screen col 0 first,  colour col 39 last
watch = {}


def set_watches(cols):
    m.cmd("del")
    watch.clear()
    for a in (apply_sta, late_at, ss_go, ss_late):
        m.cmd("break exec %04x" % a)
    for r in range(25):
        for a in (0x0400 + r * 40 + cols[0], 0xd800 + r * 40 + cols[1]):
            watch[a] = r
            m.cmd("watch store %04x" % a)


set_watches((39, 0))
ev = []
phase, ncoarse, idle, late_shown = "fwd", 0, 0, 0
while True:
    g = STOP.search(m.go())
    if not g:
        print("unexpected monitor output")
        sys.exit(2)
    kind, addr, lin, cyc, pc, A, sw = g.groups()
    addr, lin, cyc, sw = int(addr, 16), int(lin), int(cyc), int(sw)
    fstart = sw - lin * CPL - cyc                   # cycle count at line 0 of this frame
    if kind == "exec" and addr == apply_sta:
        ev.append(("v", sw, fstart, int(A, 16) & 7))
        idle += 1
        if idle > 600:
            print("no coarse scroll for 600 frames in phase", phase)
            break
    elif kind == "exec" and addr == late_at:
        late_shown += 1
    elif kind == "exec" and addr in (ss_go, ss_late):
        ev.append(("c", sw, fstart, lin, phase, addr == ss_late))
        ncoarse += 1
        idle = 0
        if phase == "fwd" and ncoarse >= NF:
            m.cmd("> %04x %s" % (rk_addr, rk_patch))
            set_watches((0, 39))
            phase, ncoarse = "rev", 0
        elif phase == "rev" and ncoarse >= NR:
            m.cmd("> %04x %s" % (rk_addr, " ".join("%02x" % b for b in rk_orig)))
            set_watches((39, 0))
            phase, ncoarse = "fwd2", 0
        elif phase == "fwd2" and ncoarse >= NR:
            break
    else:
        ev.append(("w", sw, fstart, watch[addr], lin, cyc))
m.cmd("del")
m.cmd("quit")

# ---- analysis ---------------------------------------------------------------
copies, cur = [], None
for i, e in enumerate(ev):
    if e[0] == "c":
        prev = [v for v in ev[:i] if v[0] == "v"]
        nxt = [v for v in ev[i:] if v[0] == "v"]
        late = e[5]
        # vblank that shows this copy's step: the next one, or (late) the last one
        vc = (prev[-1] if prev else None) if late else (nxt[0] if nxt else None)
        cur = dict(line=e[3], dir=e[4], late=late, F=e[2], vc=vc,
                   fs_old=prev[-1][3] if prev else 7, margin=None, rows=set(), early=0)
        copies.append(cur)
    elif e[0] == "w" and cur and cur["vc"]:
        _, t, fst, r, lin, cyc = e
        vc = cur["vc"]
        if not cur["late"] and t < vc[1] and fst == cur["F"]:
            fetch = 48 + cur["fs_old"] + 8 * r
            if lin < fetch or (lin == fetch and cyc < 55):
                cur["early"] += 1
        deadline = vc[2] + LPF * CPL + (48 + vc[3] + 8 * r) * CPL + 14
        mg = deadline - t
        cur["margin"] = mg if cur["margin"] is None else min(cur["margin"], mg)
        if mg < 0:
            cur["rows"].add(r)

fail = 0
for c in copies:
    if c["margin"] is None:
        continue                      # last copy: run ended before its writes
    by_design = c["late"] or c["line"] > ON_TIME_LINE
    status = "ok"
    if c["early"]:
        status = "FAIL early writes"
        fail += 1
    elif c["rows"]:
        if by_design:
            status = "tears (late start, by design)"
        else:
            status = "FAIL late rows"
            fail += 1
    print("%-4s start line %3d%s  min margin %6d cy  late rows %-24s %s" % (
        c["dir"], c["line"], " (step shown first)" if c["late"] else "",
        c["margin"], sorted(c["rows"]) or "-", status))
print("copies=%d  step shown before copy=%d  failures=%d  -> %s" % (
    len(copies), late_shown, fail, "PASS" if fail == 0 else "FAIL"))
sys.exit(1 if fail else 0)
