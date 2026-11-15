#!/usr/bin/env python3
"""Drive `pylon --app` (a session over framed pipes, no terminal).

    app_drive.py PYLON [ARGS...] USER@HOST

Sends a size and keystrokes as frames, reads the host's output frames,
checks the remote terminal took the size and ran the command, then ends
the shell and checks pylon's exit status follows it.
"""
import os
import select
import struct
import subprocess
import sys
import time


def frame(ty, payload):
    return bytes([ty]) + struct.pack(">I", len(payload)) + payload


def main():
    argv = sys.argv[1:]
    p = subprocess.Popen([argv[0], "--app"] + argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    buf, out = b"", b""

    def read_until(needle, timeout=20):
        nonlocal buf, out
        end = time.time() + timeout
        while time.time() < end:
            if needle in out:
                return
            r, _, _ = select.select([p.stdout], [], [], 0.2)
            if r:
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk:
                    break
                buf += chunk
                while len(buf) >= 5:
                    n = struct.unpack(">I", buf[1:5])[0]
                    if len(buf) < 5 + n:
                        break
                    if buf[0] == 1:
                        out += buf[5:5 + n]
                    buf = buf[5 + n:]
                if needle in out:
                    return
        raise SystemExit(f"timed out waiting for {needle!r}; got {out[-300:]!r}; stderr {p.stderr.read1(4000)!r}")

    def send(ty, payload):
        p.stdin.write(frame(ty, payload))
        p.stdin.flush()

    send(2, struct.pack(">HH", 33, 111))
    time.sleep(1.5)
    send(1, b"stty size; echo app-$((40+2))\r")
    read_until(b"app-42")
    read_until(b"33 111")
    send(1, b"exit 4\r")
    code = p.wait(timeout=20)
    if code != 4:
        raise SystemExit(f"pylon --app exited {code}, want 4")
    print("app ok")


if __name__ == "__main__":
    main()
