#!/usr/bin/env python3
"""Mutation fuzzing of the pylon client through a proxy in front of sshd.

    fuzz_proxy.py ITERATIONS SSHD_PORT -- PYLON_COMMAND...

For each iteration, a proxy on a free port relays the client's bytes
unchanged and corrupts the server's bytes (one to four random byte flips,
truncations or insertions, placed in the cleartext handshake or anywhere
in the stream), then runs PYLON_COMMAND with "{port}" replaced by the
proxy's port.

The client must end every run cleanly: exit status 0 (the mutation hit
bytes nothing depends on, e.g. random padding) or 1 with a "pylon:"
message. A signal, an abort, another status, a hang (beyond 45 s) or
success with corrupted *authenticated* data counts as a failure, and the
seed is printed so the case can be replayed.
"""
import os
import random
import socket
import subprocess
import sys
import threading


def relay(src, dst, mutate, rng, budget):
    seen = 0
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if mutate:
                data = bytearray(data)
                for _ in range(rng.randint(0, 2)):
                    if budget[0] <= 0:
                        break
                    if rng.random() < 0.6 and seen > budget[1]:
                        continue
                    i = rng.randrange(len(data))
                    op = rng.random()
                    if op < 0.7:
                        data[i] ^= 1 << rng.randrange(8)
                    elif op < 0.85:
                        del data[i:i + rng.randint(1, 8)]
                    else:
                        data[i:i] = os.urandom(rng.randint(1, 8))
                    budget[0] -= 1
                seen += len(data)
                data = bytes(data)
            dst.sendall(data)
    except OSError:
        pass
    for s in (src, dst):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


OUTCOMES = {}


def one(seed, sshd_port, cmd):
    rng = random.Random(seed)
    lst = socket.socket()
    lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # A fixed port (FUZZ_PORT) lets the host be pinned once under it:
    # Pylon pins keys per host and port.
    lst.bind(("127.0.0.1", int(os.environ.get("FUZZ_PORT", "0"))))
    lst.listen(1)
    port = lst.getsockname()[1]

    def serve():
        c, _ = lst.accept()
        s = socket.create_connection(("127.0.0.1", sshd_port))
        # [mutations left, prefer the first N bytes (cleartext handshake)]
        budget = [int(os.environ.get("FUZZ_MUTATIONS", rng.randint(1, 4))), rng.choice([1500, 4000, 1 << 30])]
        a = threading.Thread(target=relay, args=(c, s, False, rng, budget), daemon=True)
        b = threading.Thread(target=relay, args=(s, c, True, rng, budget), daemon=True)
        a.start()
        b.start()
        a.join()
        b.join()

    threading.Thread(target=serve, daemon=True).start()
    argv = [x.replace("{port}", str(port)) for x in cmd]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=45)
    except subprocess.TimeoutExpired:
        return "hang"
    lst.close()
    out = p.stdout + p.stderr
    if p.returncode == 1 and "pylon:" in out:
        OUTCOMES["refused"] = OUTCOMES.get("refused", 0) + 1
        return None
    if p.returncode == 0:
        expect = os.environ.get("FUZZ_EXPECT", "")
        OUTCOMES["completed"] = OUTCOMES.get("completed", 0) + 1
        return None if expect in p.stdout else f"exit 0 with unexpected output: {p.stdout[-200:]!r}"
    return f"exit {p.returncode}: {out.strip()[-300:]}"


def main():
    n = int(sys.argv[1])
    sshd_port = int(sys.argv[2])
    cmd = sys.argv[sys.argv.index("--") + 1:]
    base = random.randrange(1 << 30)
    failures = 0
    for i in range(n):
        seed = base + i
        r = one(seed, sshd_port, cmd)
        if r:
            failures += 1
            print(f"FAIL seed={seed}: {r}")
    print(f"fuzz: {n} runs, {failures} failures, outcomes {OUTCOMES} (base seed {base})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
