#!/usr/bin/env python3
"""Check the Pylon protocol's padding on the wire (SPEC 9.4).

    pad_check.py UDPPORT -- COMMAND...

Captures the loopback traffic to and from pylond's UDP port (a raw
packet socket: needs root) while COMMAND runs, and checks that every data
packet (type 4) seals a multiple of 64 bytes: its length less the 16-byte
header and the 16-byte tag. Prints "padded N" with the number of data
packets seen and their distinct sizes.
"""
import socket
import subprocess
import sys
import threading
import time

port = int(sys.argv[1])
cmd = sys.argv[sys.argv.index("--") + 1:]
sizes = []
stop = threading.Event()


def capture():
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
    s.bind(("lo", 0))
    s.settimeout(0.2)
    while not stop.is_set():
        try:
            f = s.recv(65535)
        except socket.timeout:
            continue
        if len(f) < 14 + 20 + 8 or f[12:14] != b"\x08\x00":
            continue
        ip = f[14:]
        ihl = (ip[0] & 15) * 4
        if ip[9] != 17:
            continue
        udp = ip[ihl:]
        sport, dport = int.from_bytes(udp[0:2], "big"), int.from_bytes(udp[2:4], "big")
        if port not in (sport, dport):
            continue
        payload = udp[8:]
        if payload and payload[0] == 4:
            sizes.append(len(payload))


t = threading.Thread(target=capture)
t.start()
time.sleep(0.3)
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
time.sleep(0.5)
stop.set()
t.join()
bad = [n for n in sizes if (n - 32) % 64 != 0]
if not sizes or bad:
    print("not padded: %d data packets, bad sizes %s" % (len(sizes), sorted(set(bad))[:10]))
    sys.exit(1)
print("padded %d data packets, sizes %s" % (len(sizes), sorted(set(sizes))))
