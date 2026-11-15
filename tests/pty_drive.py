#!/usr/bin/env python3
"""Drive an interactive pylon session through a real pseudo-terminal.

    pty_drive.py PYLON -p PORT USER@HOST

Starts pylon on a pty (so it takes the interactive path), types a command
whose output can only come from the remote shell, checks it, resizes the
local terminal and checks the remote side saw the new size (window-change),
pastes a long line (more than one read), then exits the shell and checks
pylon's exit status follows the remote one.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time


def read_until(fd, needle, timeout=15):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if needle in buf:
                return buf
    raise SystemExit(f"timed out waiting for {needle!r}; got {buf[-400:]!r}")


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(sys.argv[1], sys.argv[1:])
    set_size(fd, 30, 100)
    time.sleep(1.0)
    os.write(fd, b"PS1='$ '; echo marker-$((6*7))\r")
    read_until(fd, b"marker-42")
    os.write(fd, b"stty size\r")
    read_until(fd, b"30 100")
    set_size(fd, 40, 120)
    time.sleep(1.2)
    os.write(fd, b"stty size\r")
    read_until(fd, b"40 120")
    long = b"x" * 6000
    os.write(fd, b"echo " + long + b" | wc -c\r")
    read_until(fd, b"6001")
    os.write(fd, b"exit 3\r")
    _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    if code != 3:
        raise SystemExit(f"pylon exited {code}, want 3")
    print("interactive ok")


if __name__ == "__main__":
    main()
