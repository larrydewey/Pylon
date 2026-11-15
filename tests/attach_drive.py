#!/usr/bin/env python3
"""Re-attach to a terminal pylond keeps, from a new client.

    attach_drive.py PYLON -p PORT --pylond PYLOND USER@HOST

Starts a terminal over the Pylon protocol, leaves a mark in the shell's
environment and on the screen, then kills the client outright (an app
closed, a phone that died). A second client lists the sessions and a third
attaches: the screen comes back (repainted from pylond's emulator) and the
shell is the same one (the mark is still set). Its exit status ends the
session.
"""
import os
import pty
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from pty_drive import read_until, set_size  # noqa: E402


def start(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(argv[0], argv)
    set_size(fd, 30, 100)
    return pid, fd


def main():
    base = sys.argv[1:]
    pid, fd = start(base)
    time.sleep(1.0)
    os.write(fd, b"PS1='$ '; export MARK=kept-$((40+2)); echo screen-$((7*6))\r")
    read_until(fd, b"screen-42")
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    listed = subprocess.run(base[:-1] + ["--sessions", base[-1]], capture_output=True, text=True, timeout=60)
    if "attached" not in listed.stdout and "detached" not in listed.stdout:
        raise SystemExit(f"no session listed: {listed.stdout!r} {listed.stderr!r}")
    pid2, fd2 = start(base[:-1] + ["--attach", base[-1]])
    read_until(fd2, b"screen-42")
    os.write(fd2, b"echo got-$MARK\r")
    read_until(fd2, b"got-kept-42")
    os.write(fd2, b"exit 5\r")
    _, status = os.waitpid(pid2, 0)
    code = os.waitstatus_to_exitcode(status)
    if code != 5:
        raise SystemExit(f"pylon exited {code}, want 5")
    print("reattach ok")


if __name__ == "__main__":
    main()
