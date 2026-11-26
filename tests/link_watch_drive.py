#!/usr/bin/env python3
"""What the app hears when the Pylon protocol's link goes quiet (SPEC 9.8).

    link_watch_drive.py PYLON [ARGS...] USER@HOST

Runs `pylon --app` over the Pylon protocol with PYLON_TEST_GONE_SECS=20,
and freezes the session daemon (SIGSTOP) to silence the link:

  1. typing into a silent link: frame 6, state 1 (reconnecting), within
     seconds; the daemon back: state 0 (reconnected), and the keys typed
     meanwhile arrive;
  2. silent past the limit: frame 6, state 2 (gone), pylon exits 255 and
     names the session (frame 10 gave its id);
  3. `--session ID` from a new client picks the same shell up again.
"""
import os
import select
import signal
import struct
import subprocess
import sys
import time


def frame(ty, payload):
    return bytes([ty]) + struct.pack(">I", len(payload)) + payload


def daemons():
    # Only this test's daemons (PYLOND_HASH: the build pushed), never
    # another pylond the machine runs.
    h = os.environ.get("PYLOND_HASH", "[0-9a-f]*")
    out = subprocess.run(["pgrep", "-f", f"pylond-{h} serve"], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def freeze(on):
    for pid in daemons():
        try:
            os.kill(pid, signal.SIGSTOP if on else signal.SIGCONT)
        except ProcessLookupError:
            pass


class App:
    def __init__(self, argv, extra=()):
        env = dict(os.environ, PYLON_TEST_GONE_SECS="20")
        self.p = subprocess.Popen([argv[0], "--app", *extra] + argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        self.buf, self.out, self.err = b"", b"", b""
        self.ready = False
        self.states = []   # (state, note) from frame 6
        self.session = None

    def send(self, ty, payload):
        self.p.stdin.write(frame(ty, payload))
        self.p.stdin.flush()

    def pump(self, until, timeout, what):
        end = time.time() + timeout
        while time.time() < end:
            if until():
                return
            r, _, _ = select.select([self.p.stdout, self.p.stderr], [], [], 0.2)
            if self.p.stderr in r:
                self.err += os.read(self.p.stderr.fileno(), 65536)
            if self.p.stdout in r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    break
                self.buf += chunk
                while len(self.buf) >= 5:
                    n = struct.unpack(">I", self.buf[1:5])[0]
                    if len(self.buf) < 5 + n:
                        break
                    t, body = self.buf[0], self.buf[5:5 + n]
                    if t == 1:
                        self.out += body
                    elif t == 4:
                        self.ready = True
                    elif t == 6:
                        self.states.append((body[0], body[1:].decode()))
                    elif t == 10 and n == 4:
                        self.session = struct.unpack(">I", body)[0]
                    self.buf = self.buf[5 + n:]
        if not until():
            freeze(False)
            raise SystemExit(f"timed out waiting for {what}; states {self.states}, out {self.out[-200:]!r}, err {self.err[-300:]!r}")


def main():
    argv = sys.argv[1:]
    a = App(argv)
    a.pump(lambda: a.ready, 30, "the terminal")
    a.send(2, struct.pack(">HH", 24, 80))
    a.send(1, b"echo watch-$((1+1))\r")
    a.pump(lambda: b"watch-2" in a.out, 20, "the first command")
    a.pump(lambda: a.session is not None, 15, "the session id (frame 10)")

    # 1. Silent while keys wait for an acknowledgment: reconnecting, then back.
    freeze(True)
    t0 = time.time()
    a.send(1, b"echo watch-$((2+1))\r")
    a.pump(lambda: any(s == 1 for s, _ in a.states), 10, "state 1 (reconnecting)")
    quiet_after = time.time() - t0
    note = [n for s, n in a.states if s == 1][0]
    if "No answer from the host" not in note:
        raise SystemExit(f"reconnecting note: {note!r}")
    time.sleep(3)
    freeze(False)
    a.pump(lambda: any(s == 0 for s, _ in a.states), 10, "state 0 (reconnected)")
    back = [n for s, n in a.states if s == 0][0]
    if not back.startswith("Reconnected after"):
        raise SystemExit(f"reconnected note: {back!r}")
    a.pump(lambda: b"watch-3" in a.out, 10, "the keys typed while it was quiet")

    # 2. Silent past the limit (20 s here, 15 minutes otherwise): gone.
    freeze(True)
    a.pump(lambda: any(s == 2 for s, _ in a.states), 40, "state 2 (gone)")
    code = a.p.wait(timeout=10)
    a.err += a.p.stderr.read()
    freeze(False)
    if code != 255:
        raise SystemExit(f"pylon --app exited {code} when the link was gone, want 255")
    if f"(session {a.session})".encode() not in a.err:
        raise SystemExit(f"the gone message does not name session {a.session}: {a.err[-400:]!r}")

    # 3. A new client picks the same shell up with --session.
    b = App(argv, ["--session", str(a.session)])
    b.pump(lambda: b.ready, 30, "the second terminal")
    b.send(2, struct.pack(">HH", 24, 80))
    b.pump(lambda: f"attaching to session {a.session}".encode() in b.err, 10, "the attach")
    b.pump(lambda: b"watch-3" in b.out, 10, "the repainted screen")
    b.send(1, b"exit 6\r")
    code = b.p.wait(timeout=20)
    if code != 6:
        raise SystemExit(f"the picked-up shell exited {code}, want 6")
    print(f"link watch ok (reconnecting after {quiet_after:.1f} s, session {a.session})")


if __name__ == "__main__":
    main()
