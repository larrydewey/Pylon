#!/usr/bin/env python3
"""Drive `pylon --app` (a session over framed pipes, no terminal).

    app_drive.py PYLON [ARGS...] USER@HOST

Sends a size and keystrokes as frames, reads the host's output frames,
checks the remote terminal took the size and ran the command, then ends
the shell and checks pylon's exit status follows it.
"""
import os
import select
import socket
import struct
import subprocess
import sys
import time


def frame(ty, payload):
    return bytes([ty]) + struct.pack(">I", len(payload)) + payload


def main():
    argv = sys.argv[1:]
    # --bridge-agent: play the app's part for the agent (PYLON_AGENT=app):
    # each type-3 frame goes to the agent at SSH_AUTH_SOCK, its reply back.
    bridge = argv[0] == "--bridge-agent"
    if bridge:
        argv = argv[1:]
    env = dict(os.environ, PYLON_AGENT="app") if bridge else None
    p = subprocess.Popen([argv[0], "--app"] + argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    agent = None
    if bridge:
        agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        agent.connect(os.environ["SSH_AUTH_SOCK"])
    bridged = 0
    ready = False
    buf, out = b"", b""

    def read_until(needle, timeout=20, ready_wait=False):
        nonlocal buf, out, ready, bridged
        end = time.time() + timeout
        while time.time() < end:
            if (ready if ready_wait else needle in out):
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
                    if buf[0] == 4:
                        ready = True
                    if buf[0] == 1:
                        out += buf[5:5 + n]
                    elif buf[0] == 3 and agent is not None:
                        bridged += 1
                        agent.sendall(buf[5:5 + n])
                        def take(k):
                            got = b""
                            while len(got) < k:
                                c = agent.recv(k - len(got))
                                if not c:
                                    raise SystemExit("the agent closed the connection")
                                got += c
                            return got
                        head = take(4)
                        body = take(struct.unpack(">I", head)[0])
                        send(3, head + body)
                    buf = buf[5 + n:]
                if (ready if ready_wait else needle in out):
                    return
        raise SystemExit(f"timed out waiting for {needle!r}; got {out[-300:]!r}")

    def send(ty, payload):
        p.stdin.write(frame(ty, payload))
        p.stdin.flush()

    # Nothing but agent replies until the core says the terminal is ready.
    read_until(b"", ready_wait=True)
    send(2, struct.pack(">HH", 33, 111))
    time.sleep(0.5)
    send(1, b"stty size; echo app-$((40+2))\r")
    read_until(b"app-42")
    read_until(b"33 111")
    send(1, b"exit 4\r")
    code = p.wait(timeout=20)
    if code != 4:
        raise SystemExit(f"pylon --app exited {code}, want 4")
    if bridge and bridged < 2:
        raise SystemExit(f"only {bridged} agent requests came through the app")
    print("app ok" + (f" (agent through the app: {bridged} requests)" if bridge else ""))


if __name__ == "__main__":
    main()
