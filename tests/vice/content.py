#!/usr/bin/env python3
"""Screen-content regression check.

Scrolls forward N coarse rows, then back to the start, and dumps screen RAM
and colour RAM (low nibble) at the entry of every coarse scroll routine, when
the previous coarse step is complete.

  dump:    content.py dump <labels.txt> <scroll.prg> <out.json> [rows]
  compare: content.py compare <old.json> <new.json>

compare checks the two builds match at every (direction, row) position, and
that scrolling back returns the same screens as scrolling forward.  Needs VICE
running with run_vice.sh for dump.  Exit code 0 = pass.
"""
import json
import sys
from mon import STOP, load_labels, start_prompter, force_reverse_patch


def dump(labels, prg, out, nrows):
    lab = load_labels(labels)
    m = start_prompter(9, prg, lab)
    up, dn = lab['scroll_screen_up'], lab['scroll_screen_down']
    rlo = lab['rows_from_start_lo']
    rk_addr, rk_patch, _ = force_reverse_patch(m, lab)
    m.cmd("break exec %04x" % up)
    m.cmd("break exec %04x" % dn)
    res, phase = [], "f"

    def snap(tag):
        lo, hi = m.mem(rlo, rlo + 1)
        res.append(dict(tag=tag, rows=lo + 256 * hi,
                        scr=m.mem(0x0400, 0x07e7),
                        col=[x & 15 for x in m.mem(0xd800, 0xdbe7)]))
        return lo + 256 * hi

    while True:
        pc = int(STOP.search(m.go()).group(2), 16)
        r = snap(phase)
        if phase == "f" and r >= nrows:
            m.cmd("> %04x %s" % (rk_addr, rk_patch))
            phase = "r"
        elif phase == "r" and pc == dn and r <= 1:
            # the IRQ stops reversing at the start; let the last step finish
            m.cmd("del")
            m.cmd("break exec %04x" % lab['@state2'])
            for _ in range(30):
                m.go()
            m.cmd("del")
            snap("e")
            break
    m.cmd("quit")
    json.dump(res, open(out, "w"))
    print("dumped %d positions" % len(res))


def compare(old, new):
    def keyed(path):
        return {(d["tag"], d["rows"]): d for d in json.load(open(path))}
    O, N = keyed(old), keyed(new)
    bad = 0
    for k in sorted(set(O) & set(N)):
        ds = {i // 40 for i in range(1000) if O[k]["scr"][i] != N[k]["scr"][i]}
        dc = {i // 40 for i in range(1000) if O[k]["col"][i] != N[k]["col"][i]}
        if ds or dc:
            bad += 1
            print(k, "screen rows differ", sorted(ds), "colour rows differ", sorted(dc))
    only = len(set(O) ^ set(N))
    print("compared %d positions, %d only in one dump, %d mismatches" % (
        len(set(O) & set(N)), only, bad))
    for name, D in (("old", O), ("new", N)):
        mm = [k[1] for k in D if k[0] == "r" and ("f", k[1]) in D
              and (D[k]["scr"] != D[("f", k[1])]["scr"] or D[k]["col"] != D[("f", k[1])]["col"])]
        if mm:
            bad += 1
            print(name, "scrolling back differs from scrolling forward at rows", sorted(mm))
    print("PASS" if bad == 0 and only == 0 else "FAIL")
    return 0 if bad == 0 and only == 0 else 1


if __name__ == "__main__":
    if sys.argv[1] == "dump":
        dump(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 30)
    else:
        sys.exit(compare(sys.argv[2], sys.argv[3]))
