#!/usr/bin/env python3
"""A minimal SSH server for mlkem768x25519-sha256, to check Pylon's
post-quantum hybrid key exchange against independent primitives (OpenSSL's
ML-KEM-768, X25519, Ed25519 and AES-GCM, through pyca/cryptography).

    pq_server.py PORT HOSTKEY_SEED_HEX MODE      (MODE: ok | bad-ct)

It offers only mlkem768x25519-sha256 (with strict kex), ssh-ed25519 and
aes256-gcm@openssh.com; computes S_REPLY, K = SHA-256(K_mlkem || K_x25519)
and H per draft-ietf-sshm-mlkem-hybrid-kex; switches keys; decrypts the
client's first encrypted packet (its SERVICE_REQUEST); and answers with an
encrypted DISCONNECT whose text the test looks for. "bad-ct" corrupts the
ML-KEM ciphertext after encapsulating, so the client's K differs and the
host signature must fail to verify.
"""
import hashlib
import os
import socket
import struct
import sys

from cryptography.hazmat.primitives.asymmetric import ed25519, mlkem, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def s(b):
    if isinstance(b, str):
        b = b.encode()
    return struct.pack(">I", len(b)) + b


def namelist(*names):
    return s(",".join(names))


def packet(payload):
    pad = 8 - ((5 + len(payload)) % 8)
    if pad < 4:
        pad += 8
    body = bytes([pad]) + payload + os.urandom(pad)
    return struct.pack(">I", len(body)) + body


class Conn:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def need(self, n):
        while len(self.buf) < n:
            d = self.sock.recv(65536)
            if not d:
                raise EOFError
            self.buf += d

    def line(self):
        while b"\n" not in self.buf:
            self.need(len(self.buf) + 1)
        i = self.buf.index(b"\n")
        ln, self.buf = self.buf[:i], self.buf[i + 1:]
        return ln.rstrip(b"\r")

    def clear_packet(self):
        self.need(4)
        n = struct.unpack(">I", self.buf[:4])[0]
        self.need(4 + n)
        body, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
        return body[1:len(body) - body[0]]

    def gcm_packet(self, key, iv):
        self.need(4)
        n = struct.unpack(">I", self.buf[:4])[0]
        self.need(4 + n + 16)
        aad, ct = self.buf[:4], self.buf[4:4 + n + 16]
        self.buf = self.buf[4 + n + 16:]
        body = AESGCM(key).decrypt(iv, ct, aad)
        return body[1:len(body) - body[0]]


def gcm_seal(key, iv, payload):
    pad = 16 - ((1 + len(payload)) % 16)
    if pad < 4:
        pad += 16
    body = bytes([pad]) + payload + os.urandom(pad)
    aad = struct.pack(">I", len(body))
    return aad + AESGCM(key).encrypt(iv, body, aad)


def derive(k_enc, h, letter, sid, n):
    out = hashlib.sha256(k_enc + h + letter + sid).digest()
    while len(out) < n:
        out += hashlib.sha256(k_enc + h + out).digest()
    return out[:n]


def main():
    port, seed, mode = int(sys.argv[1]), bytes.fromhex(sys.argv[2]), sys.argv[3]
    hk = ed25519.Ed25519PrivateKey.from_private_bytes(seed)
    hk_pub = hk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    k_s = s("ssh-ed25519") + s(hk_pub)
    lst = socket.socket()
    lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", port))
    lst.listen(4)
    while True:
        sock, _ = lst.accept()
        try:
            serve(Conn(sock), hk, k_s, mode)
        except (EOFError, OSError, ValueError) as e:
            print(f"connection ended: {e!r}", flush=True)
        sock.close()


def serve(c, hk, k_s, mode):
    v_s = b"SSH-2.0-PylonPQReference"
    c.sock.sendall(v_s + b"\r\n")
    v_c = c.line()
    i_c = c.clear_packet()
    i_s = (bytes([20]) + os.urandom(16) + namelist("mlkem768x25519-sha256", "kex-strict-s-v00@openssh.com")
           + namelist("ssh-ed25519") + namelist("aes256-gcm@openssh.com") * 2 + namelist() * 2
           + namelist("none") * 2 + namelist() * 2 + b"\x00" + struct.pack(">I", 0))
    c.sock.sendall(packet(i_s))
    init = c.clear_packet()
    assert init[0] == 30, init[0]
    n = struct.unpack(">I", init[1:5])[0]
    c_init = init[5:5 + n]
    assert len(c_init) == 1184 + 32, len(c_init)
    k_pq, ct = mlkem.MLKEM768PublicKey.from_public_bytes(c_init[:1184]).encapsulate()
    xs = x25519.X25519PrivateKey.generate()
    k_cl = xs.exchange(x25519.X25519PublicKey.from_public_bytes(c_init[1184:]))
    s_pk = xs.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    if mode == "bad-ct":
        ct = bytes([ct[0] ^ 1]) + ct[1:]
    s_reply = ct + s_pk
    k_enc = s(hashlib.sha256(k_pq + k_cl).digest())
    h = hashlib.sha256(s(v_c) + s(v_s) + s(i_c) + s(i_s) + s(k_s) + s(c_init) + s(s_reply) + k_enc).digest()
    sig = s("ssh-ed25519") + s(hk.sign(h))
    c.sock.sendall(packet(bytes([31]) + s(k_s) + s(s_reply) + s(sig)))
    c.sock.sendall(packet(bytes([21])))
    nk = c.clear_packet()
    assert nk == bytes([21]), nk
    iv_c, iv_s = derive(k_enc, h, b"A", h, 12), derive(k_enc, h, b"B", h, 12)
    key_c, key_s = derive(k_enc, h, b"C", h, 32), derive(k_enc, h, b"D", h, 32)
    req = c.gcm_packet(key_c, iv_c)        # strict kex: sequence numbers restart; GCM uses its own counter
    print(f"SERVER-DECRYPTED type {req[0]}: {req[5:].decode(errors='replace')}", flush=True)
    msg = bytes([1]) + struct.pack(">I", 11) + s("post-quantum handshake verified by the reference server") + s("")
    c.sock.sendall(gcm_seal(key_s, iv_s, msg))


if __name__ == "__main__":
    main()
