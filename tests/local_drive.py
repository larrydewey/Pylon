#!/usr/bin/env python3
"""Drive `pylon-local` (the local shell, SPEC 13) and check what it can't reach.

    local_drive.py PYLON_LOCAL

Sets up a home directory with Pylon's files in it (PYLON_HOME under
~/.config/pylon, a known_hosts holding a marker) and an agent socket
(SSH_AUTH_SOCK, a listener that records every connection), checks that a
process outside the local shell reaches both (the control), then starts
the local shell with that environment and checks, through its terminal:

  - the shell runs, takes the size it is given, and its exit status is
    pylon-local's;
  - SSH_AUTH_SOCK and PYLON_HOME are not in its environment;
  - Pylon's known_hosts cannot be read (not by its path, not by any path:
    the home directory it sees is its own);
  - the agent's socket cannot be connected to, and the listener never
    saw a connection;
  - this driver's process (Pylon's side) is not visible to it: its
    /proc/PID/environ, which names the socket, cannot be read;
  - it has no network interface but loopback (no --share-net).

Run as root, it also runs the same checks as an unprivileged user
(nobody), the case of a desktop.
"""
import os
import pwd
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

SECRET = b"SECRET-OF-PYLON-HOME-7f3a"


def frame(ty, payload):
    return bytes([ty]) + struct.pack(">I", len(payload)) + payload


class Agent:
    """A Unix socket listener that records connections."""

    def __init__(self, path):
        self.hits = 0
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.bind(path)
        os.chmod(path, 0o777)
        self.s.listen(8)
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while True:
            try:
                c, _ = self.s.accept()
            except OSError:
                return
            self.hits += 1
            c.close()


def drive(local, env, home, ph, sock, preexec=None):
    p = subprocess.Popen([local, "20", "70"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, preexec_fn=preexec)
    buf, out = b"", b""
    ready = False
    status = []

    def pump(timeout):
        nonlocal buf, out, ready
        r, _, _ = select.select([p.stdout], [], [], timeout)
        if not r:
            return True
        chunk = os.read(p.stdout.fileno(), 65536)
        if not chunk:
            return False
        buf += chunk
        while len(buf) >= 5:
            n = struct.unpack(">I", buf[1:5])[0]
            if len(buf) < 5 + n:
                break
            if buf[0] == 4:
                ready = True
            elif buf[0] == 1:
                out += buf[5:5 + n]
            elif buf[0] == 5 and n == 1:
                status.append(buf[5])
            buf = buf[5 + n:]
        return True

    def until(needle, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            if needle in out:
                return
            if not pump(0.2):
                break
        err = p.stderr.read().decode(errors="replace") if p.poll() is not None else ""
        raise SystemExit(f"timed out waiting for {needle!r}; output {out[-600:]!r}; stderr {err!r}")

    def send(ty, payload):
        try:
            p.stdin.write(frame(ty, payload))
            p.stdin.flush()
        except BrokenPipeError:
            raise SystemExit(f"pylon-local ended ({p.wait()}); output {out[-600:]!r}; stderr {p.stderr.read().decode(errors='replace')!r}")

    end = time.time() + 20
    while not ready and time.time() < end:
        if not pump(0.2):
            break
    if not ready:
        raise SystemExit(f"pylon-local never said ready; stderr {p.stderr.read().decode(errors='replace')!r}")
    send(2, struct.pack(">HH", 33, 111))
    time.sleep(0.3)

    def run(cmd, tag):
        before = len(out)
        # The marker as typed (and echoed) differs from the marker printed.
        send(1, cmd.encode() + f"; echo {tag}-don''e\r".encode())
        until(f"{tag}-done\r\n".encode())
        return out[before:]

    run("stty size; echo works-$((6*7))", "a")
    if b"33 111" not in out or b"works-42" not in out:
        raise SystemExit(f"the local shell did not run or took no size: {out[-400:]!r}")
    got = run("echo env=[$SSH_AUTH_SOCK][$PYLON_HOME][$XDG_RUNTIME_DIR]", "b")
    if b"env=[][][]" not in got:
        raise SystemExit(f"Pylon's environment leaked into the local shell: {got!r}")
    got = run(f"cat {ph}/known_hosts; cat ~/.config/pylon/known_hosts; ls -a {home} {home}/.config 2>&1", "c")
    if SECRET in got:
        raise SystemExit(f"the local shell read PYLON_HOME: {got!r}")
    got = run(f"for f in {sock} /proc/{os.getpid()}/environ /proc/1/environ; do cat $f >/dev/null 2>&1 && echo read:$f; done", "d")
    if b"read:" + sock.encode() in got or f"read:/proc/{os.getpid()}".encode() in got:
        raise SystemExit(f"the local shell reached Pylon's side: {got!r}")
    py = shutil.which("python3")
    if py and py.startswith(("/usr/", "/bin/")):
        got = run(f"{py} -c \"import socket; s = socket.socket(socket.AF_UNIX); s.connect('{sock}'); print('CONN' + 'ECTED')\" 2>&1 | tail -1", "e")
        if b"CONNECTED" in got:
            raise SystemExit(f"the local shell connected to the agent's socket: {got!r}")
    got = run("echo IFACES=$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\\n' ,)", "f")
    m = re.search(rb"IFACES=([a-z0-9,]*)\r\n", got)
    ifaces = [x for x in m.group(1).split(b",") if x] if m else None
    if ifaces != [b"lo"]:
        raise SystemExit(f"the local shell has network interfaces {ifaces!r}, want only lo")
    send(2, struct.pack(">HH", 41, 97))
    time.sleep(0.5)
    got = run("stty size", "g")
    if b"41 97\r\n" not in got:
        raise SystemExit(f"a resize did not reach the local shell: {got!r}")
    send(1, b"exit 7\r")
    while pump(1):
        pass
    p.wait(timeout=20)
    # The status frame: the process's own exit status is lost after the
    # launcher confines itself (resid_sandbox_confine).
    if status != [7]:
        raise SystemExit(f"pylon-local reported exit status {status}, want [7]; stderr {p.stderr.read()!r}")


def main():
    local = os.path.abspath(sys.argv[1])
    users = [None]
    if os.getuid() == 0:
        users.append(pwd.getpwnam("nobody"))
    for u in users:
        t = tempfile.mkdtemp(prefix="pylon-local-")
        os.chmod(t, 0o755)
        home = os.path.join(t, "home")
        ph = os.path.join(home, ".config", "pylon")
        os.makedirs(ph)
        with open(os.path.join(ph, "known_hosts"), "wb") as f:
            f.write(b"example.org:22 ssh-ed25519 AAAA " + SECRET + b"\n")
        sock = os.path.join(t, "agent.sock")
        agent = Agent(sock)
        if u is not None:
            for root, dirs, files in os.walk(home):
                for n in dirs + files + [""]:
                    os.chown(os.path.join(root, n), u.pw_uid, u.pw_gid)
        # The control: outside the local shell, both are reachable.
        with open(os.path.join(ph, "known_hosts"), "rb") as f:
            assert SECRET in f.read()
        c = socket.socket(socket.AF_UNIX)
        c.connect(sock)
        c.close()
        time.sleep(0.2)
        if agent.hits != 1:
            raise SystemExit("control: the agent listener did not see the outside connection")
        env = {"HOME": home, "PYLON_HOME": ph, "SSH_AUTH_SOCK": sock, "PATH": "/usr/bin:/bin", "SHELL": os.environ.get("TEST_SHELL", "/bin/bash"),
               "XDG_RUNTIME_DIR": t, "LANG": "C.UTF-8", "USER": u.pw_name if u else "root"}
        pre = None
        if u is not None:
            def pre(u=u):
                os.setgroups([])
                os.setgid(u.pw_gid)
                os.setuid(u.pw_uid)
        drive(local, env, home, ph, sock, pre)
        if agent.hits != 1:
            raise SystemExit(f"the agent's socket saw {agent.hits - 1} connection(s) from the local shell")
        print(f"local shell ok as {u.pw_name if u else pwd.getpwuid(os.getuid()).pw_name}: no PYLON_HOME, no agent socket, no Pylon processes, no network")
        agent.s.close()
        shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    main()
