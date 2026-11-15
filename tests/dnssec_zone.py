#!/usr/bin/env python3
"""Signed test zones for Pylon's DNSSEC validator (SPEC 6.1.2).

A small, independent DNSSEC signer and authoritative-plus-recursive
answerer (it answers every query from a tree of zones it holds), written
from RFC 4034, 4035 and 5155 with Python's `cryptography` for the
signatures. Two uses:

  dnssec_zone.py fixtures OUT.resid
      Writes the recorded responses of tests/dnssec_test.resid: one
      scenario per case (secure SSHFP, NSEC and NSEC3 denial, insecure
      delegation and opt-out, bogus signatures, expired RRSIGs, a wrong
      DS, ...), every message as it would come off the wire.

  dnssec_zone.py serve PORTFILE ANCHORFILE SSHFPFILE [MODE]
      A resolver on 127.0.0.1 (UDP and TCP, a free port written to
      PORTFILE) for the interoperability tests: a test root and a signed
      zone `localhost.` holding the SSHFP records in SSHFPFILE (lines as
      `ssh-keygen -r localhost` prints them). The root's DS goes to
      ANCHORFILE. MODE: "secure" (default), "tc" (every UDP answer
      truncated, so the client must use TCP), "bogus" (SSHFP signatures
      corrupted), "insecure" (localhost. delegated without a DS).
"""

import hashlib
import os
import socket
import struct
import sys
import threading
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

T_A, T_NS, T_CNAME, T_SOA, T_DS, T_SSHFP, T_RRSIG, T_NSEC, T_DNSKEY, T_NSEC3, T_NSEC3PARAM = 1, 2, 5, 6, 43, 44, 46, 47, 48, 50, 51

# ---------------------------------------------------------------- names


def wire(name):
    name = name.rstrip(".")
    if not name:
        return b"\x00"
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def labels(name):
    name = name.rstrip(".").lower()
    return name.split(".") if name else []


def text(ls):
    return ".".join(ls) + "." if ls else "."


def canon_key(name):
    return [l.encode() for l in reversed(labels(name))]


def parent(name):
    return text(labels(name)[1:])


def is_under(a, b):
    la, lb = labels(a), labels(b)
    return len(la) >= len(lb) and (not lb or la[-len(lb):] == lb)


def b32hex(b):
    alpha = "0123456789abcdefghijklmnopqrstuv"
    bits, n, out = 0, 0, ""
    for x in b:
        n = (n << 8) | x
        bits += 8
        while bits >= 5:
            bits -= 5
            out += alpha[(n >> bits) & 31]
    if bits:
        out += alpha[(n << (5 - bits)) & 31]
    return out


def nsec3_hash(name, salt, iters):
    h = hashlib.sha1(wire(name.lower()) + salt).digest()
    for _ in range(iters):
        h = hashlib.sha1(h + salt).digest()
    return h


def bitmap(types):
    out = b""
    windows = {}
    for t in sorted(set(types)):
        windows.setdefault(t >> 8, []).append(t & 255)
    for w in sorted(windows):
        bs = bytearray(max(windows[w]) // 8 + 1)
        for t in windows[w]:
            bs[t // 8] |= 0x80 >> (t % 8)
        out += bytes([w, len(bs)]) + bytes(bs)
    return out


# ---------------------------------------------------------------- keys


class Key:
    def __init__(self, alg, flags, bits=2048):
        self.alg, self.flags = alg, flags
        if alg in (5, 8):
            self.priv = rsa.generate_private_key(public_exponent=65537, key_size=bits)
            n = self.priv.public_key().public_numbers().n.to_bytes(bits // 8, "big")
            self.pub = b"\x03\x01\x00\x01" + n
        elif alg == 13:
            self.priv = ec.generate_private_key(ec.SECP256R1())
            nums = self.priv.public_key().public_numbers()
            self.pub = nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")
        elif alg == 15:
            self.priv = ed25519.Ed25519PrivateKey.generate()
            from cryptography.hazmat.primitives import serialization
            self.pub = self.priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        else:
            raise ValueError(alg)
        self.rdata = struct.pack(">HBB", flags, 3, alg) + self.pub
        ac = sum(b if i & 1 else b << 8 for i, b in enumerate(self.rdata))
        self.tag = (ac + ((ac >> 16) & 0xFFFF)) & 0xFFFF

    def sign(self, data):
        if self.alg == 8:
            return self.priv.sign(data, padding.PKCS1v15(), hashes.SHA256())
        if self.alg == 5:
            return self.priv.sign(data, padding.PKCS1v15(), hashes.SHA1())
        if self.alg == 13:
            r, s = decode_dss_signature(self.priv.sign(data, ec.ECDSA(hashes.SHA256())))
            return r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return self.priv.sign(data)

    def ds(self, owner, dtype=2):
        h = hashlib.sha256 if dtype == 2 else hashlib.sha384
        return struct.pack(">HBB", self.tag, self.alg, dtype) + h(wire(owner.lower()) + self.rdata).digest()


# ---------------------------------------------------------------- zones


class Zone:
    def __init__(self, apex, alg=None, split=False, denial="nsec", salt=b"", iters=0, optout=False, signed=True, zsk_bits=2048):
        self.apex = text(labels(apex))
        self.signed = signed
        self.denial, self.salt, self.iters, self.optout = denial, salt, iters, optout
        self.keys = []
        if signed:
            if split:
                self.keys = [Key(alg, 257), Key(alg, 256, zsk_bits)]
            else:
                self.keys = [Key(alg, 257)]
        self.rr = {}  # (owner, type) -> [rdata]
        self.children = {}  # child apex -> secure (DS present)
        self.add(self.apex, T_SOA, wire("ns." + self.apex) + wire("h." + self.apex) + struct.pack(">IIIII", 1, 3600, 600, 86400, 300))
        self.add(self.apex, T_NS, wire("ns." + self.apex))
        for k in self.keys:
            self.add(self.apex, T_DNSKEY, k.rdata)

    @property
    def ksk(self):
        return self.keys[0]

    @property
    def zsk(self):
        return self.keys[-1]

    def add(self, owner, t, rdata):
        self.rr.setdefault((text(labels(owner)), t), []).append(rdata)

    def delegate(self, child, ds_rdatas):
        child = text(labels(child))
        self.add(child, T_NS, wire("ns." + child))
        for d in ds_rdatas:
            self.add(child, T_DS, d)
        self.children[child] = bool(ds_rdatas)

    def delegation_of(self, name):
        """The delegation point at or above name (below the apex), or None."""
        for c in self.children:
            if is_under(name, c):
                return c
        return None

    def owners(self):
        return sorted({o for (o, t) in self.rr if not self._occluded(o)}, key=canon_key)

    def _occluded(self, o):
        d = self.delegation_of(o)
        return d is not None and d != o

    def names_with_ents(self):
        names = set(self.owners())
        for o in list(names):
            ls = labels(o)
            apex_n = len(labels(self.apex))
            for k in range(apex_n, len(ls)):
                names.add(text(ls[len(ls) - k:]))
        return sorted(names, key=canon_key)

    def types_at(self, o):
        return sorted(t for (oo, t) in self.rr if oo == o)

    def signs(self, o, t):
        if not self.signed:
            return False
        d = self.delegation_of(o)
        if d == o and t == T_NS:
            return False  # delegation NS is not signed
        return True

    # -- denial chains --
    def build_denial(self):
        if not self.signed:
            return
        if self.denial == "nsec":
            os_ = self.owners()
            for i, o in enumerate(os_):
                nxt = os_[(i + 1) % len(os_)]
                ts = self.types_at(o) + [T_RRSIG, T_NSEC]
                self.add(o, T_NSEC, wire(nxt) + bitmap(ts))
        else:
            self.add(self.apex, T_NSEC3PARAM, struct.pack(">BBHB", 1, 0, self.iters, len(self.salt)) + self.salt)
            entries = []
            for n in self.names_with_ents():
                if self._occluded(n):
                    continue
                ts = self.types_at(n)
                if self.optout and n in self.children and not self.children[n]:
                    continue  # an unsigned delegation, opted out
                if ts and not (n in self.children and not self.children[n]):
                    ts = ts + [T_RRSIG]
                entries.append((nsec3_hash(n, self.salt, self.iters), n, ts))
            entries.sort()
            self.nsec3 = []
            for i, (h, n, ts) in enumerate(entries):
                nh = entries[(i + 1) % len(entries)][0]
                owner = b32hex(h) + "." + self.apex
                rd = struct.pack(">BBHB", 1, 1 if self.optout else 0, self.iters, len(self.salt)) + self.salt + bytes([20]) + nh + bitmap(ts)
                self.add(owner, T_NSEC3, rd)
                self.nsec3.append((h, nh, owner))

    def nsec3_match(self, name):
        h = nsec3_hash(name, self.salt, self.iters)
        for (oh, nh, owner) in self.nsec3:
            if oh == h:
                return owner
        return None

    def nsec3_cover(self, name):
        h = nsec3_hash(name, self.salt, self.iters)
        for (oh, nh, owner) in self.nsec3:
            if (oh < h < nh) or (nh <= oh and (h > oh or h < nh)):
                return owner
        return None

    def nsec_cover(self, name):
        os_ = self.owners()
        for i, o in enumerate(os_):
            nxt = os_[(i + 1) % len(os_)]
            after = canon_key(o) < canon_key(name)
            if after and (canon_key(nxt) <= canon_key(o) or canon_key(name) < canon_key(nxt)):
                return o
        return None


class Signer:
    def __init__(self, now, life=30 * 86400):
        self.inc, self.exp = now - 3600, now + life
        self.tamper = {}  # (owner, type) -> "sig" | "expired" | "notyet" | "strip"

    def rrsig(self, zone, owner, t, rdatas, ttl=3600):
        mode = self.tamper.get((owner, t))
        if mode == "strip":
            return []
        inc, exp = self.inc, self.exp
        if mode == "expired":
            inc, exp = self.inc - 60 * 86400, self.inc - 30 * 86400
        if mode == "notyet":
            inc, exp = self.exp + 86400, self.exp + 60 * 86400
        key = zone.ksk if t == T_DNSKEY else zone.zsk
        ls = labels(owner)
        nl = len(ls) - (1 if ls and ls[0] == "*" else 0)
        head = struct.pack(">HBBIIIH", t, key.alg, nl, ttl, exp, inc, key.tag) + wire(zone.apex)
        data = head
        for rd in sorted(set(rdatas)):
            data += wire(owner.lower()) + struct.pack(">HHIH", t, 1, ttl, len(rd)) + rd
        sig = key.sign(data)
        if mode == "sig":
            sig = sig[:-1] + bytes([sig[-1] ^ 1])
        return [head + sig]


# ---------------------------------------------------------------- answering


class World:
    def __init__(self, zones, signer):
        self.zones = {z.apex: z for z in zones}
        self.signer = signer
        for z in zones:
            z.build_denial()
        self.overrides = {}  # (qname, qtype) -> callable(msg sections) for scenario tweaks

    def zone_for(self, qname, qtype):
        best = None
        for apex in self.zones:
            if is_under(qname, apex) and (best is None or len(labels(apex)) > len(labels(best))):
                if qtype == T_DS and apex == qname and apex != ".":
                    continue
                best = apex
        return self.zones[best]

    def rrset(self, z, owner, t, sec):
        rds = z.rr.get((owner, t), [])
        out = [(owner, t, rd) for rd in rds]
        if rds and z.signs(owner, t):
            out += [(owner, T_RRSIG, s) for s in self.signer.rrsig(z, owner, t, rds)]
        sec.extend(out)

    def answer(self, qname, qtype):
        qname = text(labels(qname))
        z = self.zone_for(qname, qtype)
        an, ns = [], []
        rcode = 0
        d = z.delegation_of(qname)
        if d is not None and not (qtype == T_DS and d == qname):
            # A referral would go to the child: our tree holds every zone, so
            # this is a delegation to a zone we do not serve (an unsigned one).
            return 2, an, ns
        if (qname, qtype) in z.rr:
            self.rrset(z, qname, qtype, an)
        elif (qname, T_CNAME) in z.rr:
            self.rrset(z, qname, T_CNAME, an)
        else:
            exists = qname in z.names_with_ents()
            self.rrset(z, z.apex, T_SOA, ns)
            if not exists:
                rcode = 3
            if z.signed:
                self.deny(z, qname, exists, ns)
        return rcode, an, ns

    def deny(self, z, qname, exists, ns):
        want = []
        if z.denial == "nsec":
            if exists:
                if (qname, T_NSEC) in z.rr:
                    want.append(qname)
                else:
                    want.append(z.nsec_cover(qname))  # an empty non-terminal
            else:
                c = z.nsec_cover(qname)
                want.append(c)
                ce = self.closest_existing(z, qname)
                w = z.nsec_cover("*." + ce)
                want.append(w)
            for o in dict.fromkeys(want):
                self.rrset(z, o, T_NSEC, ns)
        else:
            m = z.nsec3_match(qname) if exists else None
            if m:
                want.append(m)
            else:
                ce = self.closest_existing(z, qname)
                want.append(z.nsec3_match(ce))
                nc = text(labels(qname)[len(labels(qname)) - len(labels(ce)) - 1:])
                want.append(z.nsec3_cover(nc))
                if not exists:
                    want.append(z.nsec3_cover("*." + ce))
            for o in dict.fromkeys(w for w in want if w):
                self.rrset(z, o, T_NSEC3, ns)

    def closest_existing(self, z, qname):
        names = set(z.names_with_ents())
        ls = labels(qname)
        for k in range(len(ls) - 1, -1, -1):
            c = text(ls[len(ls) - k:])
            if c in names:
                return c
        return z.apex


def encode_rr(owner, t, rd, qname, ttl=3600):
    name = b"\xc0\x0c" if owner.lower() == qname.lower() else wire(owner)
    return name + struct.pack(">HHIH", t, 1, ttl, len(rd)) + rd


def message(mid, qname, qtype, rcode, an, ns, tc=False):
    flags = 0x8000 | 0x0100 | 0x0080 | rcode | (0x0200 if tc else 0)
    if tc:
        an, ns = [], []
    head = struct.pack(">HHHHHH", mid, flags, 1, len(an), len(ns), 1)
    body = wire(qname) + struct.pack(">HH", qtype, 1)
    for (o, t, rd) in an:
        body += encode_rr(o, t, rd, qname)
    for (o, t, rd) in ns:
        body += encode_rr(o, t, rd, qname)
    return head + body + b"\x00\x00\x29\x04\xd0\x00\x00\x80\x00\x00\x00"


# ---------------------------------------------------------------- fixtures

NOW = 1790000000  # 2026-09-21


def sshfp_rd(alg, fptype, fp):
    return bytes([alg, fptype]) + fp


def fixture_world(signer):
    """. (RSA/SHA-256, KSK+ZSK) -> test. (ECDSA P-256, KSK+ZSK, NSEC3) ->
    example.test. (Ed25519, NSEC), n3.test. (Ed25519, NSEC3 with an empty
    non-terminal), oo.test. (NSEC3 opt-out), plain.test. (unsigned)."""
    root = Zone(".", 8, split=True)
    test = Zone("test", 13, split=True, denial="nsec3", salt=b"\xab\xcd", iters=3)
    ex = Zone("example.test", 15)
    n3 = Zone("n3.test", 15, denial="nsec3", salt=b"\x01", iters=1)
    oo = Zone("oo.test", 13, denial="nsec3", salt=b"", iters=0, optout=True)
    plain = Zone("plain.test", signed=False)
    old = Zone("old.test", 5)
    weak = Zone("weak.test", 8, split=True, zsk_bits=1024)
    weak.add("h.weak.test", T_SSHFP, sshfp_rd(4, 2, hashlib.sha256(b"k").digest()))
    many = Zone("many.test", 15, denial="nsec3", salt=b"\x07", iters=200)
    many.add("h.many.test", T_A, bytes([192, 0, 2, 5]))
    root.delegate("test", [test.ksk.ds("test")])
    test.delegate("example.test", [ex.ksk.ds("example.test")])
    test.delegate("n3.test", [n3.ksk.ds("n3.test", 4)])
    test.delegate("oo.test", [oo.ksk.ds("oo.test")])
    test.delegate("plain.test", [])
    test.delegate("old.test", [old.ksk.ds("old.test")])
    test.delegate("weak.test", [weak.ksk.ds("weak.test")])
    test.delegate("many.test", [many.ksk.ds("many.test")])
    oo.delegate("u.oo.test", [])
    oo.add("www.oo.test", T_A, bytes([192, 0, 2, 9]))
    fp_ed = hashlib.sha256(b"host-key-ed25519").digest()
    fp_rsa = hashlib.sha256(b"host-key-rsa").digest()
    ex.add("host.example.test", T_A, bytes([192, 0, 2, 1]))
    ex.add("host.example.test", T_SSHFP, sshfp_rd(4, 2, fp_ed))
    ex.add("host.example.test", T_SSHFP, sshfp_rd(1, 2, fp_rsa))
    ex.add("host.example.test", T_SSHFP, sshfp_rd(4, 1, hashlib.sha1(b"x").digest()))
    ex.add("nossh.example.test", T_A, bytes([192, 0, 2, 2]))
    ex.add("alias.example.test", T_CNAME, wire("host.example.test"))
    n3.add("h.n3.test", T_SSHFP, sshfp_rd(4, 2, fp_ed))
    n3.add("a.n3.test", T_A, bytes([192, 0, 2, 3]))
    n3.add("x.y.n3.test", T_A, bytes([192, 0, 2, 4]))
    plain.add("host.plain.test", T_SSHFP, sshfp_rd(4, 2, fp_ed))
    return World([root, test, ex, n3, oo, plain, old, many, weak], signer), root


# Every scenario: (name, query name, tweak). The tweak changes the world
# or a message before the walk's queries are recorded.
def scenarios():
    def strip_rr(t):
        def f(q, msg):
            rcode, an, ns = msg
            return rcode, [r for r in an if r[1] != t and not (r[1] == T_RRSIG and struct.unpack(">H", r[2][:2])[0] == t)], ns
        return f

    def drop_wild_nsec(q, msg):
        rcode, an, ns = msg
        if rcode != 3:
            return msg
        ds = [r for r in ns if r[1] in (T_NSEC, T_NSEC3)]
        if not ds:
            return msg
        last = ds[-1][0]  # the record proving no wildcard comes last
        return rcode, an, [r for r in ns if r[0] != last]

    def servfail(q, msg):
        return 2, [], []

    return [
        ("secure", "host.example.test", {}),
        ("nodata-nsec", "nossh.example.test", {}),
        ("nxdomain-nsec", "missing.example.test", {}),
        ("nsec3-secure", "h.n3.test", {}),
        ("nsec3-nodata", "a.n3.test", {}),
        ("nsec3-ent", "y.n3.test", {}),
        ("nsec3-nxdomain", "zz.n3.test", {}),
        ("nsec3-nxdomain-deep", "q.a.n3.test", {}),
        ("insecure", "host.plain.test", {}),
        ("optout", "h.u.oo.test", {}),
        ("cname", "alias.example.test", {}),
        ("unsupported-alg", "h.old.test", {}),
        ("weak-rsa", "h.weak.test", {}),
        ("nsec3-iterations", "h.many.test", {}),
        ("bogus-sig", "host.example.test", {"sig": ("host.example.test.", T_SSHFP)}),
        ("expired", "host.example.test", {"expired": ("host.example.test.", T_SSHFP)}),
        ("notyet", "host.example.test", {"notyet": ("host.example.test.", T_SSHFP)}),
        ("stripped", "host.example.test", {"msg": ("host.example.test.", T_SSHFP, strip_rr(T_RRSIG))}),
        ("bogus-nsec", "nossh.example.test", {"sig": ("nossh.example.test.", T_NSEC)}),
        ("nx-no-wildcard", "missing.example.test", {"msg": ("missing.example.test.", T_DS, drop_wild_nsec)}),
        ("nsec3-nx-no-wildcard", "q.a.n3.test", {"msg": ("q.a.n3.test.", T_DS, drop_wild_nsec)}),
        ("wrong-ds", "host.example.test", {"wrong_ds": True}),
        ("servfail", "host.example.test", {"msg": ("example.test.", T_DNSKEY, servfail)}),
        ("bogus-ds-sig", "host.example.test", {"sig": ("example.test.", T_DS)}),
        ("bogus-root-sig", "host.example.test", {"sig": (".", T_DNSKEY)}),
        ("bogus-test-ds-sig", "host.example.test", {"sig": ("test.", T_DS)}),
    ]


def record_walk(world, qname, tweak):
    """The responses a validating walk of qname asks for, recorded for
    every name and type it might ask (a superset: the walk takes what it
    needs)."""
    out = []
    ls = labels(qname)
    asks = [(".", T_DNSKEY)]
    for k in range(1, len(ls) + 1):
        a = text(ls[len(ls) - k:])
        asks += [(a, T_DS), (a, T_DNSKEY)]
    asks.append((text(ls), T_SSHFP))
    for (n, t) in asks:
        msg = world.answer(n, t)
        if "msg" in tweak and tweak["msg"][0] == n and tweak["msg"][1] == t:
            msg = tweak["msg"][2]((n, t), msg)
        out.append((n, t, message(0, n, t, *msg)))
    return out


def write_fixtures(path):
    lines = []
    anchor = None
    for (name, q, tweak) in scenarios():
        signer = Signer(NOW)
        for mode in ("sig", "expired", "notyet", "strip"):
            if mode in tweak:
                signer.tamper[tweak[mode]] = mode
        world, root = fixture_world(signer)
        if tweak.get("wrong_ds"):
            test = world.zones["test."]
            test.rr[("example.test.", T_DS)] = [Key(15, 257).ds("example.test")]
        a = root.ksk.ds(".")
        for (n, t, m) in record_walk(world, q, tweak):
            lines.append("%s|%s|%d|%s|%s" % (name, q, t, n, m.hex()))
        lines.append("%s|%s|0|anchor|%s" % (name, q, "%d %d %d %s" % (struct.unpack(">H", a[:2])[0], a[2], a[3], a[4:].hex())))
    with open(path, "w") as f:
        f.write("// Generated by tests/dnssec_zone.py (fixtures); do not edit.\n")
        f.write("// Each entry: SCENARIO|QNAME|QTYPE|ASKED-NAME|HEX of the response (id 0),\n")
        f.write("// or SCENARIO|QNAME|0|anchor|the test root's DS. Signed for now = %d.\n\n" % NOW)
        f.write("pub Int fx_now() { return %d; }\n\n" % NOW)
        f.write("pub List(Str) fx_entries() {\n    return [\n")
        f.write(",\n".join('        "%s"' % l for l in lines))
        f.write("\n    ];\n}\n")


# ---------------------------------------------------------------- serving


def serve(portfile, anchorfile, sshfpfile, mode):
    signer = Signer(int(time.time()))
    root = Zone(".", 15)
    lh = Zone("localhost", 13, split=True, denial="nsec3", salt=b"\x42", iters=1)
    if mode == "insecure":
        lh = Zone("localhost", signed=False)
        root.delegate("localhost", [])
    else:
        root.delegate("localhost", [lh.ksk.ds("localhost")])
    for line in open(sshfpfile):
        f = line.split()
        if len(f) >= 6 and f[2] == "SSHFP":
            lh.add("localhost", T_SSHFP, sshfp_rd(int(f[3]), int(f[4]), bytes.fromhex(f[5])))
    lh.add("localhost", T_A, bytes([127, 0, 0, 1]))
    if mode == "bogus":
        signer.tamper[("localhost.", T_SSHFP)] = "sig"
    world = World([root, lh], signer)
    a = root.ksk.ds(".")
    with open(anchorfile, "w") as f:
        f.write("%d %d %d %s\n" % (struct.unpack(">H", a[:2])[0], a[2], a[3], a[4:].hex()))

    def respond(data, tcp):
        if len(data) < 17:
            return None
        mid = struct.unpack(">H", data[:2])[0]
        i, ls = 12, []
        while data[i]:
            ls.append(data[i + 1:i + 1 + data[i]].decode("ascii", "replace"))
            i += 1 + data[i]
        qtype = struct.unpack(">H", data[i + 1:i + 3])[0]
        qname = text([l.lower() for l in ls])
        rcode, an, ns = world.answer(qname, qtype)
        return message(mid, qname, qtype, rcode, an, ns, tc=(mode == "tc" and not tcp))

    for _ in range(50):  # a UDP and a TCP socket on the same free port
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("127.0.0.1", 0))
        port = u.getsockname()[1]
        t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            t.bind(("127.0.0.1", port))
            break
        except OSError:
            u.close()
            t.close()
    t.listen(8)

    def tcp_loop():
        while True:
            c, _ = t.accept()
            try:
                c.settimeout(5)
                n = struct.unpack(">H", c.recv(2))[0]
                q = b""
                while len(q) < n:
                    q += c.recv(n - len(q))
                r = respond(q, True)
                if r:
                    c.sendall(struct.pack(">H", len(r)) + r)
            except Exception:
                pass
            c.close()

    threading.Thread(target=tcp_loop, daemon=True).start()
    with open(portfile + ".tmp", "w") as f:
        f.write("%d\n" % port)
    os.rename(portfile + ".tmp", portfile)
    while True:
        q, src = u.recvfrom(4096)
        try:
            r = respond(q, False)
        except Exception:
            r = None
        if r:
            u.sendto(r, src)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "fixtures":
        write_fixtures(sys.argv[2])
    elif len(sys.argv) >= 5 and sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else "secure")
    else:
        sys.exit(__doc__)
