#!/usr/bin/env python3
"""Drives `pylon sftp --app` (cli/sftp_shell.resid) as the app does: framed
requests on standard input, answers and file bytes on standard output.

    sftp_app_drive.py PYLON PORT USER@HOST DIR

DIR is an empty remote directory. Prints one line per step; the interop
test checks them.
"""
import os
import struct
import subprocess
import sys

pylon, port, target, d = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].encode()
p = subprocess.Popen([pylon, 'sftp', '--app', '-p', port, target], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def read_frame():
    h = p.stdout.read(5)
    if len(h) < 5:
        return None, b''
    return h[0], p.stdout.read(struct.unpack('>I', h[1:])[0])


def send(t, b):
    p.stdin.write(bytes([t]) + struct.pack('>I', len(b)) + b)
    p.stdin.flush()


def req(op, *args, data=None):
    send(8, bytes([op]) + b''.join(struct.pack('>I', len(a)) + a for a in args))
    if data is not None:
        for i in range(0, len(data), 100000):
            send(9, data[i:i + 100000])
        send(9, b'')
    got = b''
    while True:
        t, b = read_frame()
        if t == 9:
            got += b
            continue
        return b, got


def ok(b):
    return 'ok' if b[:1] == b'\x00' else 'refused: ' + b[1:].decode(errors='replace')


def names(b):
    n, at, out = struct.unpack('>I', b[1:5])[0], 5, []
    for _ in range(n):
        ln = struct.unpack('>I', b[at:at + 4])[0]
        out.append(b[at + 4:at + 4 + ln].decode(errors='replace'))
        at += 4 + ln + 17
    return sorted(out)


t, home = read_frame()
print('ready', t, len(home) > 0)
blob = os.urandom(300000)
print('mkdir', ok(req(3, d + b'/new')[0]))
print('put', ok(req(8, d + b'/new/up.bin', b'\x00', data=blob)[0]))
print('put again', ok(req(8, d + b'/new/up.bin', b'\x00', data=blob)[0]))
b, got = req(7, d + b'/new/up.bin')
print('get', ok(b), 'intact' if got == blob else 'DIFFERENT')
print('copy tree', ok(req(6, d + b'/new', d + b'/new2')[0]))
print('copy into itself', ok(req(6, d + b'/new', d + b'/new/inner')[0]))
print('free name', req(10, d + b'/new2', b'up.bin')[0][1:].rsplit(b'/', 1)[1].decode())
print('move', ok(req(5, d + b'/new2/up.bin', d + b'/moved.bin')[0]))
print('move onto a file', ok(req(5, d + b'/new/up.bin', d + b'/moved.bin')[0]))
print('remove tree', ok(req(4, d + b'/new2')[0]))
print('list', ' '.join(names(req(1, d)[0])))
p.stdin.close()
print('exit', p.wait())
