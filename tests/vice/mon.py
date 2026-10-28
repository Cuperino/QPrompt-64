"""Minimal client for the VICE text remote monitor (port 6510)."""
import re
import socket
import time

PROMPT = re.compile(rb"\(C:\$[0-9a-f]{4}\) $")

# Stop message for a breakpoint/watchpoint, e.g.
#   #1 (Stop on  exec 113b)  251/$0fb,  28/$1c
#   .C:113b  8D 11 D0    STA $D011   - A:17 X:00 ... N.-.....  117681553
STOP = re.compile(
    r"Stop on\s+(exec|store) ([0-9a-f]{4})\)\s+(\d+)/\$[0-9a-f]+,\s+(\d+)/\$[0-9a-f]+\n"
    r"\.C:([0-9a-f]{4}).*?A:([0-9a-fA-F]{2}).*?(\d+)\s*\n", re.S)


def load_labels(path):
    """Read an ld65 -Ln label file into {name: address}."""
    lab = {}
    for line in open(path):
        _, addr, name = line.split()
        lab[name[1:]] = int(addr, 16)
    return lab


class Mon:
    def __init__(self, port=6510):
        for _ in range(100):
            try:
                self.s = socket.create_connection(("127.0.0.1", port))
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("VICE remote monitor not reachable (is run_vice.sh running?)")
        try:
            self._until_prompt(3)          # VICE greets with a prompt on connect
        except socket.timeout:
            pass

    def _drain(self):
        self.s.setblocking(False)
        try:
            while self.s.recv(65536):
                pass
        except (BlockingIOError, socket.error):
            pass
        self.s.setblocking(True)

    def _until_prompt(self, timeout):
        self.s.settimeout(timeout)
        out = b""
        while not PROMPT.search(out):
            d = self.s.recv(65536)
            if not d:
                break
            out += d
        return out.decode(errors="replace")

    def cmd(self, c, timeout=10):
        """Send a monitor command and return its output (up to the prompt)."""
        self._drain()
        self.s.sendall((c + "\n").encode())
        if c == "quit":
            return ""
        return self._until_prompt(timeout)

    def go(self, timeout=60):
        """Continue until the next breakpoint/watchpoint stop."""
        self._drain()
        self.s.sendall(b"x\n")
        return self._until_prompt(timeout)

    def mem(self, a, b):
        out = self.cmd("m %04x %04x" % (a, b))
        bs = []
        for line in out.splitlines():
            m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+)+)", line)
            if m:
                bs += [int(x, 16) for x in m.group(2).split()]
        return bs[:b - a + 1]


def start_prompter(step, prg, lab):
    """Boot to BASIC, load prg, press F5 on the config screen and set the
    velocity step (same effect as pressing a number key)."""
    m = Mon()
    m.cmd("break exec e5cd")               # KERNAL waiting for a key: BASIC ready
    m.go()
    m.cmd("del")
    m.cmd('l "%s" 0' % prg)
    m.cmd("break exec %04x" % lab['@cfg_loop'])
    m.s.sendall(b"g 080d\n")
    m._until_prompt(60)
    m.cmd("del")
    m.cmd("> 0277 87")                     # F5 into the KERNAL key buffer
    m.cmd("> 00c6 01")
    m.cmd("break exec %04x" % lab['@state2'])
    m.go()                                 # scroll mode IRQ is running
    m.cmd("del")
    m.cmd("> 000b %02x" % step)            # current_step
    return m


def force_reverse_patch(m, lab):
    """Debug-only code patch that makes read_keyboard see SHIFT held.
    Returns (address, patch bytes, original bytes)."""
    a = lab['read_keyboard'] + 3
    orig = m.mem(a, a + 2)
    if orig[0] == 0xad:                    # lda kb_shift   -> lda #1 / nop
        return a, "a9 01 ea", orig
    if orig[0] == 0x29:                    # and #$01 (KERNAL SHIFT flag) -> ora #$01
        return a, "09 01", orig
    raise RuntimeError("unknown read_keyboard code at $%04x: %s" % (a, orig))
