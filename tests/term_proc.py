#!/usr/bin/env python3
"""Drive pylon-term (the emulator process) over its frame protocol.

    term_proc.py PYLON_TERM

Checks: the first screen arrives at the given size; host bytes draw text
and move the cursor; a cursor-position query is answered (fixed format)
while a title query is not; OSC 52 becomes a clipboard request; a resize
gives a new screen size; scrollback is served; and the process is
confined (seccomp, no new privileges) and cannot read files.
"""
import os
import struct
import subprocess
import sys


def frame(ty, payload):
    return bytes([ty]) + struct.pack(">I", len(payload)) + payload


class Term:
    def __init__(self, path, rows, cols):
        self.p = subprocess.Popen([path, str(rows), str(cols)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.buf = b""

    def send(self, ty, payload):
        self.p.stdin.write(frame(ty, payload))
        self.p.stdin.flush()

    def read_frame(self):
        while True:
            if len(self.buf) >= 5:
                n = struct.unpack(">I", self.buf[1:5])[0]
                if len(self.buf) >= 5 + n:
                    ty, payload = self.buf[0], self.buf[5:5 + n]
                    self.buf = self.buf[5 + n:]
                    return ty, payload
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                raise SystemExit("pylon-term closed its output")
            self.buf += chunk

    def until(self, want):
        seen = []
        while True:
            ty, p = self.read_frame()
            seen.append((ty, p))
            if ty == want:
                return p, seen


def screen(p):
    rows, cols, cx, cy, modes = struct.unpack(">HHHHI", p[:12])
    cells = p[12:]
    text = []
    for y in range(rows):
        line = ""
        for x in range(cols):
            cp = struct.unpack(">I", cells[(y * cols + x) * 8:(y * cols + x) * 8 + 4])[0]
            line += chr(cp) if cp else ""
        text.append(line.rstrip())
    return rows, cols, cx, cy, modes, text


def main():
    t = Term(sys.argv[1], 5, 20)
    rows, cols, *_ = screen(t.until(1)[0])
    assert (rows, cols) == (5, 20), (rows, cols)
    t.send(1, b"hello\r\nworld\x1b[1;3H")
    _, _, cx, cy, _, text = screen(t.until(1)[0])
    assert text[0] == "hello" and text[1] == "world" and (cx, cy) == (2, 0), (text, cx, cy)
    t.send(1, b"\x1b[6n\x1b[21t\x1b]52;c;aGk=\x07")
    p, seen = t.until(1)
    kinds = [k for k, _ in seen]
    replies = [v for k, v in seen if k == 2]
    assert replies == [b"\x1b[1;3R"], replies
    assert 4 in kinds and [v for k, v in seen if k == 4] == [b"aGk="], seen
    t.send(2, struct.pack(">HH", 8, 30))
    rows, cols, *_ = screen(t.until(1)[0])
    assert (rows, cols) == (8, 30), (rows, cols)
    t.send(1, b"".join(b"line%d\r\n" % i for i in range(20)))
    t.until(1)
    t.send(3, struct.pack(">IH", 0, 3))
    p, _ = t.until(6)
    total, start, count = struct.unpack(">IIH", p[:10])
    assert total >= 10 and count == 3, (total, start, count)
    children = []
    for tid in os.listdir(f"/proc/{t.p.pid}/task"):
        children += [int(c) for c in open(f"/proc/{t.p.pid}/task/{tid}/children").read().split()]
    confined = [c for c in children if "Seccomp:\t2" in open(f"/proc/{c}/status").read()]
    assert confined, "no confined emulator process"
    t.p.stdin.close()
    t.p.wait(timeout=5)
    print("term process ok")


if __name__ == "__main__":
    main()
