#!/usr/bin/env python3
"""Check keystroke timing obfuscation (SPEC 5) on the wire.

    timing_check.py SSHD_PORT PROXY_PORT -- PYLON_COMMAND...   ("{port}" = proxy port)

Runs an interactive pylon session on a pty through a recording proxy, types
a line one key at a time with irregular gaps, and looks at the packets the
client sent while typing:

  * every packet has the size of a one-key packet (chaff and real keys are
    indistinguishable by length),
  * the gaps between packets sit on the 20 ms grid, not on the typist's
    rhythm,
  * there are more packets than keys (chaff fills the silent ticks), and
    chaff continues after the last key.

With --no-obfuscate-keystrokes in the command the same checks must fail
(the test is meaningful only if it can tell the difference): pass
--expect-plain to assert that instead.
"""
import os
import pty
import select
import socket
import sys
import threading
import time

EVENTS = []          # (monotonic time, bytes) client -> server
LOCK = threading.Lock()


def proxy(listen_port, sshd_port, ready):
    lst = socket.socket()
    lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", listen_port))
    lst.listen(1)
    ready.set()
    c, _ = lst.accept()
    s = socket.create_connection(("127.0.0.1", sshd_port))
    for x in (c, s):
        x.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def pump(a, b, record):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                if record:
                    with LOCK:
                        EVENTS.append((time.monotonic(), len(d)))
                b.sendall(d)
        except OSError:
            pass
        for x in (a, b):
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    threading.Thread(target=pump, args=(c, s, True), daemon=True).start()
    threading.Thread(target=pump, args=(s, c, False), daemon=True).start()


def drain(fd, secs):
    end = time.time() + secs
    out = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    return out


def main():
    expect_plain = "--expect-plain" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--expect-plain"]
    sshd_port, port = int(args[0]), int(args[1])
    cmd = [a.replace("{port}", str(port)) for a in args[args.index("--") + 1:]]
    ready = threading.Event()
    threading.Thread(target=proxy, args=(port, sshd_port, ready), daemon=True).start()
    ready.wait()
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(cmd[0], cmd)
    out = drain(fd, 3.0)                       # login, prompt
    os.write(fd, b"stty -echo; PS1='$ '\r")
    drain(fd, 2.5)                             # let any chaff period end
    with LOCK:
        start = len(EVENTS)
    t0 = time.monotonic()
    gaps = [0.037, 0.113, 0.051, 0.290, 0.009, 0.071, 0.143, 0.023, 0.205, 0.061]
    for g in gaps:
        os.write(fd, b"x")
        time.sleep(g)
    t_last = time.monotonic()
    drain(fd, 2.5)                             # chaff tail
    os.write(fd, b"\x15exit\r")                # ^U clears the line
    drain(fd, 1.0)
    os.waitpid(pid, 0)
    with LOCK:
        ev = [e for e in EVENTS[start:] if e[0] >= t0 and e[0] <= t_last + 2.4]
    if len(ev) < 2:
        raise SystemExit(f"too few packets recorded: {ev}")
    sizes = sorted(set(n for _, n in ev))
    deltas = [(b[0] - a[0]) * 1000 for a, b in zip(ev, ev[1:])]
    off_grid = [d for d in deltas if min(d % 20.0, 20.0 - (d % 20.0)) > 6.0]
    after = [e for e in ev if e[0] > t_last + 0.1]
    obfuscated = len(sizes) == 1 and len(off_grid) <= len(deltas) // 10 and len(ev) > len(gaps) and len(after) > 10
    print(f"packets {len(ev)} for {len(gaps)} keys; sizes {sizes}; off-grid gaps {len(off_grid)}/{len(deltas)}; after last key {len(after)}")
    if expect_plain:
        if obfuscated:
            raise SystemExit("expected plain timing, but the traffic looks obfuscated")
        print("plain timing as expected")
        return
    if not obfuscated:
        raise SystemExit("keystroke timing is not obfuscated")
    print("timing obfuscated")


if __name__ == "__main__":
    main()
