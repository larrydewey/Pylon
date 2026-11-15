#!/usr/bin/env python3
"""A deliberately hostile SSH server for negative tests of the pylon CLI.

Each scenario sends a crafted handshake and the test checks that pylon
refuses it with the expected reason, before any key exchange completes.

    hostile_server.py PORT SCENARIO

Scenarios:
    no-strict       KEXINIT without kex-strict-s-v00 (no Terrapin fix)
    ignore-first    an IGNORE before KEXINIT (what Terrapin injects)
    huge-length     a packet length beyond the 256 KiB limit
    long-banner     a pre-version line longer than 255 bytes
    ssh1            an SSH-1.5 version line
    bad-padding     a KEXINIT whose padding length exceeds the packet
"""
import os
import socket
import struct
import sys


def sstr(b):
    if isinstance(b, str):
        b = b.encode()
    return struct.pack(">I", len(b)) + b


def packet(payload, pad=None):
    # Cleartext binary packet (RFC 4253 6), block size 8.
    if pad is None:
        pad = 8 - ((5 + len(payload)) % 8)
        if pad < 4:
            pad += 8
    body = bytes([pad]) + payload + os.urandom(pad)
    return struct.pack(">I", len(body)) + body


def kexinit(strict):
    kex = "curve25519-sha256,ext-info-s" + (",kex-strict-s-v00@openssh.com" if strict else "")
    p = bytes([20]) + os.urandom(16)
    for names in (kex, "ssh-ed25519", "chacha20-poly1305@openssh.com", "chacha20-poly1305@openssh.com",
                  "", "", "none", "none", "", ""):
        p += sstr(names)
    return p + b"\x00" + struct.pack(">I", 0)


def serve(port, scenario):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(1)
    c, _ = s.accept()
    c.settimeout(5)
    if scenario == "long-banner":
        c.sendall(b"x" * 300 + b"\r\nSSH-2.0-Hostile\r\n")
    elif scenario == "ssh1":
        c.sendall(b"SSH-1.5-Hostile\r\n")
    else:
        c.sendall(b"SSH-2.0-Hostile\r\n")
    if scenario == "no-strict":
        c.sendall(packet(kexinit(False)))
    elif scenario == "ignore-first":
        c.sendall(packet(bytes([2]) + sstr(b"injected")) + packet(kexinit(True)))
    elif scenario == "huge-length":
        c.sendall(struct.pack(">I", 10_000_000) + b"\x04" * 64)
    elif scenario == "bad-padding":
        p = kexinit(True)
        body = bytes([250]) + p + b"\x00" * 3
        c.sendall(struct.pack(">I", len(body)) + body)
    try:
        while c.recv(4096):
            pass
    except OSError:
        pass
    c.close()


if __name__ == "__main__":
    serve(int(sys.argv[1]), sys.argv[2])
