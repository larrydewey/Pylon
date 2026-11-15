# Pylon: A Security-First Remote Terminal

**Draft 2 -- 2026-11-15 (hardening revision, see Appendix A).**

## Abstract

Pylon is a remote terminal client (SSH, file transfer, port forwarding,
roaming sessions and, later, a confined local shell) meant to replace
Termius, ConnectBot, JuiceSSH and the SSH half of Termux. It is built on
three decisions:

1. **SSH stays on the wire to servers, strictly profiled.** Every host a
   person reaches already runs `sshd`; a client cannot replace the server
   population, and most of SSH's practical weaknesses (trust on first use,
   algorithm downgrade, Terrapin, agent-forwarding abuse, loose key
   management, keystroke timing) are fixable from the client side.
2. **Keys live in Symbolon by default.** Every signature is made by
   [Symbolon](https://github.com/larrydewey/symbolon): threshold or
   imported keys, a consent sheet per signature that shows the server the
   session is bound to, revocation and rotation across every host. Pylon
   can also be used without Symbolon (hardware keys, another agent, or an
   imported key file), behind an explicit warning of what is lost (7.6);
   every other protection of this specification applies either way.
3. **Where both ends are Pylon, Pylon speaks its own protocol.** After an
   SSH login, Pylon pushes a small, signed, hash-verified `pylond` to the
   host over the same SSH connection (no root, no prior install), then
   moves the session onto a roaming UDP protocol chained to the SSH
   handshake: forward secrecy, post-quantum hybrid keys, rekeying, silent
   to scanners, and sessions that survive network changes, sleep and days
   of absence, with re-attach from any of the person's devices.

The protocol code, the terminal emulator and `pylond` are written in
[Resid](https://github.com/larrydewey/Resid): total parsers, checked
arithmetic, `Secret(T)` for keying material, and capabilities declared
and checked transitively. The app is Flutter (Android first; Linux,
Windows, macOS and iOS in later phases), sharing patterns with Symbolon's
app.

## Table of contents

1. Conventions
2. Threat model
3. Security goals
4. Architecture
5. The SSH profile
6. Host trust
7. User authentication and key custody
8. Delivering `pylond`
9. The Pylon protocol
10. Sessions, screen sync and re-attach
11. Streams: forwards and files
12. The terminal emulator
13. The local shell
14. Storage and synchronization
15. Platform integration
16. Implementation requirements
17. Phases
18. Open questions
A. Hardening review (Draft 2)

## 1. Conventions

MUST, SHOULD and MAY are as in RFC 2119. *Principal*: the person using
Pylon. *Host*: a server reached over SSH. *Device*: one of the principal's
phones or computers running Pylon. *Agent*: the Symbolon agent (the app on
Android, `symbolon ssh-agent` on desktop). `H`: the SSH exchange hash of
the first key exchange of a connection, which is also its session
identifier (RFC 4253 7.2).

## 2. Threat model

### 2.1 Adversaries

- **A1 Network attacker.** Reads, drops, reorders, injects and replays
  packets on any path; controls DNS without DNSSEC; runs captive portals.
- **A2 Malicious or compromised host.** Sends hostile terminal output,
  hostile file names, oversized or malformed protocol messages; tries to
  get signatures usable against *other* hosts; tries to abuse forwarded
  agents or ports.
- **A3 Lost or stolen device.** Has the device locked or unlocked for a
  short time.
- **A4 Hostile app on the device.** Another app on the same phone, without
  root: tries to talk to Pylon's or Symbolon's IPC, read Pylon's storage,
  or overlay its consent sheet.
- **A5 Release-key attacker.** Steals a maintainer's signing key and tries
  to push a malicious `pylond` or app update.
- **A6 Coercion.** Forces the principal to unlock (handled by Symbolon's
  duress profile; Pylon follows it, 7.5).
- **A7 Future quantum adversary.** Records traffic today to decrypt later.

### 2.2 Trust assumptions

The device OS kernel and the Symbolon agent are trusted. Hosts are
trusted only with what the principal does on them: a host can see its own
session, never another host's, and never a signature usable elsewhere.

### 2.3 Non-goals

Hiding *that* the principal connects to a host; protecting a host from
the principal; protecting a session from root on the host it runs on.

## 3. Security goals

- **G1 No private keys in Pylon.** With Symbolon (the default), a
  hardware key or an external agent, Pylon never sees, stores or derives
  a user private key (7). The one exception is the opt-in imported key
  file of 7.6 (tier D), which the principal accepts behind a warning.
- **G2 No unverified host.** No session data and no authentication
  request is sent before the host key is verified under the host trust
  policy (6). There is no click-through "accept new key" path by default.
- **G3 Host-bound signatures.** Every user signature names the host key
  and the session `H`; the agent refuses signatures for a session other
  than the one bound (7.2).
- **G4 No downgrade.** Only the algorithms of Section 5 are offered or
  accepted; strict key exchange is required.
- **G5 Forward secrecy, including against A7.** Every SSH key exchange is
  ephemeral; the Pylon protocol uses a hybrid X25519 + ML-KEM-768
  exchange and rekeys (9.5).
- **G6 Verified code on hosts.** `pylond` runs on a host only if its hash
  matches a release whose provenance Pylon verified (8).
- **G7 Hostile output is contained.** Terminal output cannot write the
  clipboard, read back the screen or settings, run commands, or spoof
  Pylon's own UI without the principal's consent (12).
- **G8 Isolation of the local shell.** The local shell cannot reach SSH
  sessions, the host database or the agent (13).
- **G9 Revocation is total.** Revoking a device or key in Symbolon ends
  its Pylon sessions' ability to re-attach and to authenticate anywhere
  (10.4), without any other device having to be online.
- **G10 A stolen device acts alone on nothing.** Holding an unlocked
  device does not by itself let anyone authenticate to a host or re-attach
  to a session: each needs a fresh signature through the key's custodian
  (Symbolon's quorum and consent, a key touch, or a biometric) (10.4).
- **G11 Small pre-authentication surface.** `pylond` handles nothing from
  an unauthenticated network peer except one MAC check (9.4), and runs
  confined or not at all (8.4).

## 4. Architecture

```
 ┌──────────────── device ─────────────────┐        ┌──────── host ────────┐
 │ Pylon app (Flutter)                     │        │                      │
 │   UI, terminal view, host list          │        │  sshd (unchanged)    │
 │        │ FFI / process                  │  SSH   │     │ exec           │
 │ pylon-core (Resid)  ────────────────────┼────────┼─────┘                │
 │   ssh client, pylon protocol, vt,       │        │  pylond (Resid,      │
 │   host trust, bootstrap                 │  UDP   │   pushed, as user)   │
 │        │ sign requests                  ├────────┤   sessions, PTYs,    │
 │ Symbolon agent (separate app/process)   │        │   screen state       │
 │   consent sheet, threshold signing      │        └──────────────────────┘
 │                                         │
 │ local shell (separate UID / sandbox) ───┼── no IPC to the above
 └─────────────────────────────────────────┘
```

- **pylon-core** is a library written as sans-I/O state machines: bytes in,
  bytes and events out. The app owns sockets, timers and the PTY view;
  the core owns every parser and every cryptographic decision. The same
  core runs in `pylon` (a command-line client used for testing and on
  desktop) and `pylond`.
- **pylond** is the same code compiled as a static server binary for
  x86-64 and AArch64 Linux (8).
- **The app** never parses protocol bytes and never holds keys; it renders
  what the core reports and forwards the principal's input.

## 5. The SSH profile

Pylon speaks SSH 2.0 (RFC 4250-4254) restricted to the following. An
algorithm not listed is neither offered nor accepted.

| Purpose | Algorithms, in preference order |
|---|---|
| Key exchange | `mlkem768x25519-sha256`, `sntrup761x25519-sha512`, `curve25519-sha256` (and `@libssh.org` alias) |
| Host key | `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `rsa-sha2-512`, `rsa-sha2-256` (RSA ≥ 2048 bits), and their `-cert-v01@openssh.com` forms |
| Cipher | `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com` |
| MAC | none (AEAD only; no `hmac-*`, no encrypt-and-MAC or MAC-then-encrypt modes) |
| Compression | `none` |
| User signature | as host key, plus whatever the agent supports among them |

Further rules:

- **Strict key exchange** (`kex-strict-c-v00@openssh.com`, the Terrapin
  fix) MUST be offered, and a server that does not offer
  `kex-strict-s-v00@openssh.com` is refused by default (a per-host
  exception exists for old embedded devices, shown as a warning badge on
  the host). Under strict kex, sequence numbers reset at each NEWKEYS and
  any unexpected message during kex ends the connection.
- **ext-info** (RFC 8308) is sent; `server-sig-algs` decides the RSA
  signature algorithm and `publickey-hostbound@openssh.com` enables
  host-bound authentication (7.2).
- **No SHA-1, no DH groups, no CBC, no CTR, no Encrypt-then-MAC.** These
  are not configuration; they are absent from the code.
- **Limits.** Packets ≤ 256 KiB; the version line ≤ 255 bytes and at most
  1024 lines of pre-banner noise; name-lists ≤ 64 KiB; every parser is
  total (malformed input is a value, not an abort).
- **Rekey** after 1 GiB in either direction or one hour, whichever first.
- **Keystroke timing.** Interactive input is sent in fixed 20 ms frames
  padded with `SSH_MSG_PING`/chaff when the server supports
  `ping@openssh.com`, as OpenSSH 9.5 does.
- **Agent forwarding is off** and there is no setting that forwards the
  agent wholesale. A host that needs to reach another host uses
  ProxyJump (the client connects through it; nothing is forwarded), or a
  *restricted forward*: a per-hop agent channel whose every request is
  host-bound and shown on the device's consent sheet with the full path
  (`device → bastion → db1`).
- **X11 forwarding** is not implemented.

## 6. Host trust

### 6.1 Sources

A host key is accepted only through one of:

1. **A host certificate** (`*-cert-v01@openssh.com`) signed by a CA the
   principal or their Symbolon organization trusts for that host name,
   within its validity window, with the host name among its principals.
2. **SSHFP records** (RFC 4255, SHA-256 only) for the host name, validated
   with DNSSEC by Pylon's own resolver (not the OS's AD bit).
3. **A pinned key** in the principal's synced host database (6.3).
4. **First use under quorum.** A key seen for the first time is shown
   with its fingerprint and art; to pin it, the principal either compares
   it with an out-of-band value (paste or QR of `ssh-keygen -lf`), or
   approves it on a *second* device of their quorum, which fetches the
   host key itself over a *different network path* (its cellular link,
   or Symbolon's relay and witnesses connecting from their own vantage
   points). Two devices on the same Wi-Fi do not count: one attacker on
   that network would deceive both. A network attacker (A1) must then
   deceive several vantage points on independent paths, or the
   principal's out-of-band check.

Plain trust-on-first-use is available per host only, never globally, and
is marked on the host.

### 6.2 Changes

A host key that differs from the pinned one ends the connection before
authentication. The screen says what changed (old and new fingerprints,
when the old one was pinned and by which device) and offers only:
disconnect, or start the first-use procedure again (6.1.4), which
re-pins on approval and records the event in the host's history. There is
no "connect anyway once".

### 6.3 The host database

Host entries (names, addresses, ports, user names, pinned keys, CA
trust, jump paths, per-host policy) are Symbolon vault items of a new
type `pylon-host`, synchronized end-to-end encrypted by Symbolon. The
database holds no secrets but is integrity-critical; it is protected by
Symbolon's vault MACs, so a malicious sync server cannot add a pin.

## 7. User authentication and key custody

### 7.1 Keys

User keys are Symbolon `ssh` items: threshold ECDSA P-256 keys (no single
party holds the private key) or imported OpenSSH keys. Pylon learns only
public keys, from the agent's identity list. OpenSSH user certificates
issued to those keys are stored with the host entry and presented when
present.

### 7.2 Binding

After the key exchange and before user authentication, Pylon:

1. sends the agent `session-bind@openssh.com` with the host key, `H`, and
   the host's signature over `H` from the key exchange; the agent checks
   that signature itself (Symbolon already does: `checked_bind`);
2. authenticates with `publickey-hostbound-v00@openssh.com` when the
   server advertises it, so the signed data contains the host key, and
   plain `publickey` otherwise.

The agent's consent sheet shows the user name, the host's fingerprint and
pinned name, and the key; it refuses a request whose session or host
differs from the bound one (Symbolon `refused`). A malicious host (A2)
therefore cannot obtain a signature for another host. The name on the
sheet comes from the host database Symbolon itself holds (6.3), matched
by host key, never from a string Pylon passes along, so a compromised
Pylon cannot relabel a host.

**Consent fatigue.** A prompt on every connection trains the principal
to approve without reading. Symbolon therefore MAY remember an approval
for one (host key, user key, user name) triple for a short window
(default 10 minutes, set per host), never across a change of host key
and never for hosts marked *sensitive*, which always prompt. Re-attach
(10.4) and restricted forwarding (5) always prompt.

### 7.3 Android IPC

On Android the agent is the Symbolon app. Pylon binds to an exported
`SshAgentService` protected by a `signature`-level permission
(`dev.symbolon.permission.SSH_SIGN`), granted only to apps signed by the
keys Symbolon pins (Pylon's release keys), and Symbolon additionally
checks the caller's package name and signing certificate digest on every
call (`getCallingUid` → `PackageManager`). The interface carries the
agent protocol's messages unchanged (`request-identities`,
`extension(session-bind)`, `sign-request`), so the desktop and Android
paths share one code path in the core. The consent sheet is Symbolon's
own activity, with `FLAG_SECURE` and overlay protection
(`setHideOverlayWindows`) against A4.

The interface, exactly (v1): Pylon binds `Intent("dev.symbolon.action.SSH_AGENT")`
in package `dev.symbolon.app`, only after checking that package's sole
signer against the Symbolon release certificates Pylon pins (SHA-256);
each call is one `transact(FIRST_CALL_TRANSACTION)` whose data parcel
holds the interface token `dev.symbolon.ISshAgent` and one byte array,
a whole agent request message (length prefix included), and whose reply
parcel holds no exception and one byte array, the whole reply message.
Calls block until the principal answers the consent sheet; Pylon never
makes them on its main thread. In the core the agent is then reached
through the app (`PYLON_AGENT=app` with `--app`): requests leave as
frames of type 3 and replies return as frames of type 3, and the app
sends nothing else until the core's ready frame (type 4).

### 7.4 Desktop

On Linux, Windows and macOS the core speaks the same protocol to
`SSH_AUTH_SOCK`, normally `symbolon ssh-agent`. Pylon refuses an agent
socket not owned by the principal.

### 7.5 Duress

When Symbolon is unlocked under its duress profile, the identities it
lists are the duress subset; Pylon additionally hides hosts marked
*sensitive* in their entry. Pylon has no duress state of its own.

### 7.6 Without Symbolon

Pylon can be used without Symbolon. Only key custody changes: the SSH
profile (5), host trust (6), the terminal hardening (12), the delivery
and confinement of `pylond` (8) and every other requirement apply
unchanged. Three custodians are supported besides Symbolon, in
decreasing order of safety:

| Tier | Custodian | What it keeps | What it loses |
|---|---|---|---|
| A | Symbolon (default) | everything in this specification | -- |
| B | Hardware key: a FIDO2 security key (`sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`, user presence required per signature) or a non-exportable Android Keystore key (StrongBox where present, user authentication with a biometric or device credential per use) | the key cannot be copied off the hardware; each signature needs a touch or biometric | quorum, revocation everywhere, synced host trust, duress; losing the device or key loses the credential |
| C | External agent at `SSH_AUTH_SOCK` (desktop: OpenSSH, KeePassXC, gpg-agent) | whatever that agent provides | as B, and usually per-signature consent; agents without `session-bind@openssh.com` cannot refuse a signature meant for another session (Pylon still uses host-bound authentication, so the signed data names the host) |
| D | Imported key file: an OpenSSH private key imported into Pylon, immediately wrapped by a non-exportable Keystore key that requires user authentication per use; Pylon never writes the plaintext | encryption at rest and a biometric per use | as C, and the private key exists in Pylon's process memory while signing; a compromise of the app or the device's OS exposes it |

**The warning.** Choosing tier B, C or D for the first time shows a
full-screen warning that must be acknowledged by an explicit action
(typing *I understand* or holding a button, not a single tap):

> **You are about to use Pylon without Symbolon.**
> Your SSH key will live in one place. If this device is lost, stolen or
> compromised, whoever holds it can log in to every server that trusts
> this key, and you cannot revoke it everywhere at once. Pylon cannot
> confirm each login with you or prevent a signature from being reused
> elsewhere, cannot keep your trusted hosts in sync across your devices,
> and has no duress protection. Hosts you pin here are pinned on this
> device only.
> Pylon's other protections still apply. Only the safety of your key
> changes.

Tier D adds: *"This key was a file. Copies may exist in backups, other
machines or old disks: treat it as exposed and plan to replace it."*

After acknowledgement there is no repeated nagging (repeated warnings
are tuned out): hosts and sessions using a tier B, C or D key carry a
permanent, quiet badge that opens the explanation, and the key's screen
offers a one-step move into Symbolon (which imports OpenSSH keys and,
for tier D, then offers to rotate the key on every host, Symbolon
26.3).

**Host trust without Symbolon.** Without a quorum there is no
second-device approval (6.1.4): a key is pinned from an out-of-band
fingerprint, a host certificate or SSHFP with DNSSEC. Without Symbolon's
vault the host database is local to the device, protected by a
Keystore-held MAC key.

**Policy.** An organization's Symbolon policy can forbid tiers B-D for
its hosts, or allow only tier B.

## 8. Delivering `pylond`

### 8.1 Goal

Pylon works on any host the principal can SSH into, with nothing
installed beforehand and no root, the way `salt-ssh` ships its thin
bundle, but with one small static binary whose identity is checked on
every launch.

### 8.2 The binary

`pylond` is a static Resid executable (no C library) for `x86_64` and
`aarch64` Linux, about 1-2 MB. Each release carries a COSE provenance
signature (`residc verify`) binding source, code and builder. **The
release signing key is a Symbolon threshold key**: a release needs a
quorum of maintainers' devices (A5 must compromise several).

The app ships the `pylond` binaries of its own release and verifies their
provenance at build time and again at first use on the device.

Provenance alone does not stop a quorum that is coerced or colludes. A
release is accepted by clients only when, in addition, it is:

- **Reproducible.** The build is reproducible from the tagged source
  with the pinned Resid toolchain, and at least one builder independent
  of the signers has published the same hash.
- **Logged.** The release hash and its signatures appear in a public,
  append-only transparency log (a Merkle log with signed tree heads;
  clients check an inclusion proof and gossip tree heads through
  Symbolon's sync). A malicious release cannot be shown to one victim
  without being visible to everyone.
- **Monotonic.** Clients never push a `pylond` older than one they have
  pushed before or than the app's own release, and the app refuses to be
  downgraded (Android APK signature scheme v3 with key rotation; version
  codes only increase). A revoked release (listed in the log) is
  replaced on the next connection.

### 8.3 Procedure

Over the verified, authenticated SSH connection, with a fixed command
string that contains no data from the host:

1. **Probe**: `uname -m`, `$HOME`, whether `~/.cache` is on a `noexec`
   mount, and the hash of `~/.cache/pylon/pylond-<sha256>` if present.
2. **Upload** only when that file is absent or its hash differs: write
   `pylond-<sha256>.tmp` in `~/.cache/pylon` (directory mode `0700`,
   created if needed, refused if it exists with another owner or wider
   mode), `fsync`, rename into place, mode `0500`.
3. **Launch**: hash the file again and `exec` it in the same command, so
   no other process can swap it between check and use. On a `noexec`
   mount, the bytes are piped into a `memfd_create` file (via a 200-byte
   POSIX shell + `/proc/self/fd` sequence documented in the source) and
   executed from memory.
4. **Bootstrap**: `pylond` speaks the bootstrap exchange (9.2) on its
   stdin/stdout, which are the SSH channel, then detaches.

A per-host policy MAY forbid pushing (an organization requires an
installed, pinned `pylond`), and `pylon forget HOST` removes the cache
and ends the host's sessions.

### 8.4 Confinement on the host

`pylond` runs as the principal, never as root. It declares only the Resid
capabilities it needs (`network`, `terminal`, `process` for the PTY
child, `filesystem` scoped to file transfers). Before it opens its UDP
socket it applies a seccomp filter (the system calls of its event loop,
PTY and transfer paths only) and Landlock (no filesystem access outside
`$HOME` and its cache). The PTY's shell is a separate process outside
this confinement, as the principal expects of a login shell.

Confinement is not best-effort: on a kernel without Landlock or seccomp
filters, `pylond` refuses to listen and Pylon stays on SSH for that host
(with a note on the host saying why), unless the host entry explicitly
allows an unconfined `pylond`.

## 9. The Pylon protocol

### 9.1 Overview

UDP, one port per `pylond` (chosen from a range, default 60000-61000,
configurable per host). Inspired by WireGuard's packet layer and Noise,
with session state as in Mosh, but chained to SSH so it needs no PKI of
its own.

### 9.2 Bootstrap exchange (inside SSH)

Over the SSH exec channel of 8.3:

```
C → S : "PYLON1" || c_static_x25519 || c_mlkem_ek || nonce_c
S → C : "PYLON1" || s_static_x25519 || mlkem_ct || port || session_list || nonce_s
```

Both sides compute `psk = HKDF-SHA256(salt = H, ikm = X25519(c,s) ||
ML-KEM-shared, info = "pylon/1 bootstrap" || nonce_c || nonce_s)`. Binding
`H` chains the Pylon session to the verified host key (6) and the
principal's authentication (7). The device keeps `s_static` and `psk` as
a *session ticket* in hardware-backed storage (Android Keystore wraps
it); `pylond` keeps `c_static` in its authorized-client list for the
session.

### 9.3 Handshake (UDP)

Noise `IKpsk2_25519_ChaChaPoly_BLAKE2s` with the hybrid extension: the
initiator also sends an ML-KEM-768 encapsulation to the server's
long-term ML-KEM key from 9.2, mixed into the chaining key (as in
PQ-WireGuard designs). One round trip; the first packet already carries
the client's identity and proves knowledge of `psk`.

### 9.4 Packet layer

```
type(1) | receiver_index(4) | counter(8) | ChaCha20-Poly1305(payload)
```

- **Silence and a minimal pre-authentication surface.** Every packet
  from a peer that has not completed a handshake must first pass a MAC
  keyed by a value only bootstrapped clients know (`mac1`, keyed by a
  hash of the server's static key and the bootstrap PSK, both delivered
  only inside SSH); anything else is dropped with no reply and no state.
  That one constant-time MAC check over a fixed-size packet is the whole
  code path an unauthenticated network peer can reach (G11); the Noise
  handshake, ML-KEM decapsulation and everything after run only for
  packets that passed it. Under load the server answers with a cookie
  (`mac2`) and does no asymmetric work.
- **Binding.** `pylond` binds only the address it reported in the
  bootstrap (by default the address the SSH connection arrived on), not
  the wildcard address.
- **Replay.** A 2048-packet sliding window per receive key.
- **Roaming.** The server sends to the address of the most recent
  authenticated packet, so a phone moving from Wi-Fi to cellular
  continues without a handshake.
- **Padding.** Payloads are padded to multiples of 64 bytes;
  keystrokes are batched into 20 ms frames with chaff as in 5.

### 9.5 Rekeying

A new handshake every 2 minutes of activity or 2^60 messages, whichever
first (WireGuard's schedule); keys older than 3 minutes are refused.
Each handshake is ephemeral-ephemeral plus static and hybrid PQ, giving
forward secrecy per rekey period, also against A7.

### 9.6 Streams

Inside the packet layer, a small multiplex: stream 0 is control,
stream 1 the terminal state (10), others forwards and files (11).
Each stream has its own reliability: state sync for the terminal,
ordered retransmission with selective acknowledgement for forwards and
files.

### 9.7 Version 1 as implemented (experimental)

`core/proto.resid`, `core/link.resid`, `cli/pylond.resid`. The sections
above are the target; v1 implements this subset, and is off unless
`--pylond FILE` is given. **The v1 handshake is not a verified Noise
pattern; 16 requires a formal model and an external review before it is
enabled by default.**

Bootstrap (stdin/stdout of `pylond serve` over the verified SSH exec
channel, after the hash check of 8.3):

```
C → S  "PYLON1" | c_static (32) | c_kem_ek (1184)                       1222 bytes
S → C  "PYLON1" | port (2) | s_static (32) | kem_ct (1088) | sid (16)   1144 bytes
psk = HKDF-SHA256(salt "pylon/1 bootstrap", ikm K_kem, info c_static | s_static | sid)
```

`pylond` writes nothing to the SSH channel after its reply, so the client
closes SSH and `pylond` outlives it. The UDP socket is bound to the
server address from `SSH_CONNECTION`, never the wildcard. (Not yet:
`H` in the salt; v1 relies on the SSH channel for authenticity of both
messages.)

Handshake, `h0 = SHA-256("pylon/1 IKpsk-hybrid")`, Noise-style chaining:

```
init  1 | idx_c (4) | e_c (32) | ek_e (1184) | AEAD(timestamp) (28) | mac1 (16)      1268 bytes
      ck ← HKDF(ck, DH(e_c, S)); ck ← HKDF(ck, DH(c, S)); (ck, k) ← HKDF2(ck, psk)
resp  2 | idx_s (4) | idx_c (4) | e_s (32) | ct_e (1088) | AEAD() (16) | mac1 (16)   1164 bytes
      ck ← HKDF(ck, DH(e_s, e_c)); ck ← HKDF(ck, DH(e_s, c)); ck ← HKDF(ck, K_kem_e);
      (ck, k) ← HKDF2(ck, psk)
keys  (initiator→responder, responder→initiator) = HKDF2(ck, "")
mac1  HMAC-SHA256(SHA-256("pylon/1 mac1" | S | psk), packet without mac1)[0..16]
```

A fresh ML-KEM-768 key per handshake gives each session key post-quantum
forward secrecy. `pylond` answers only an init with a valid mac1 and a
timestamp newer than the last accepted one; anything else gets no reply.

Data: `4 | receiver_idx (4) | counter (8, LE) | ChaCha20-Poly1305(frame)`,
2048-slot replay window, roaming to the source of the latest
authenticated packet. Frames, one per datagram:

```
OPEN 1 | sid (4) | port (2) | host length (1) | host      client → pylond only
DATA 2 | sid (4) | offset (8) | bytes
ACK  3 | sid (4) | offset (8)
FIN  4 | sid (4) | offset (8)
RST  5 | sid (4)
PING 6
```

Go-back-N per stream, 256 KiB window, 300 ms retransmission timeout.

Further frames (v1): `SHELL 7 | sid | rows (2) | cols (2)` starts the
principal's login shell on a pseudo-terminal, `RESIZE 9 | sid | rows |
cols`, `ATTACH 10 | sid | session (4) | rows | cols` joins a kept
terminal (its first bytes repaint the screen from pylond's emulator),
`LIST 11 | nonce` / `SESSIONS 12 | nonce | entries`; a terminal's FIN
carries its exit code. Terminal streams are "external": the link queues
their bytes and the program moves them, so only pylond holds the right
to start processes.

Session daemon (10.3, 10.4): the first `pylond serve` for a server
address becomes the principal's daemon, with a control socket in a 0700
per-user runtime directory (`$XDG_RUNTIME_DIR` or `/tmp`, `pylon-UID`);
later ones hand their bootstrap to it and exit, so every re-attach rides
a fresh SSH login. Clients silent for 15 minutes are dropped; their
terminals detach and keep running. Lifetime: `--keep` (7 days) without a
client while terminals run, `--idle` (600 s) otherwise, `--ephemeral` 60 s.

Rekeying (9.5): the client starts a new handshake every 2 minutes;
pylond switches keys when it answers and refuses data under keys older
than 3 minutes. Streams carry on.

Limits of v1: `-L` forwards only over the Pylon protocol (`-D`/`-R` stay
on SSH), an IPv4 literal host, no padding to 64 bytes, no cookie
(`mac2`), no resume over UDP alone with a ticket (re-attach always takes
a new SSH login, which is stricter than 10.4 requires).

Confinement (8.4) as built: the daemon forks a PTY broker (the only
process that can start the login shell; masters come back over a socket),
then confines itself before reading any datagram: Landlock (all rights
beneath `$HOME` and the runtime directory, reading beneath `/etc`, never
execute) and a seccomp allowlist of its event loop's system calls. Both
are per thread, so the runtime continues the daemon in a forked,
single-threaded child; the original process only waits on it. Without
Landlock pylond refuses to serve unless the client passes
`--allow-unconfined` for that host.

## 10. Sessions, screen sync and re-attach

### 10.1 Screen synchronization

`pylond` runs the PTY and a terminal emulator (the same Resid emulator
as the client, 12). It sends the client *diffs between screen states*
(Mosh's State Synchronization Protocol idea): a lost packet is never
retransmitted, only superseded, so the latest screen always arrives.
The client predicts the effect of typed characters locally and
underlines predictions until confirmed.

### 10.2 Scrollback

Unlike Mosh, lines scrolled off the top are kept in a ring in `pylond`
(default 10 000 lines, configurable) and in the client; after a
reconnection the client asks for the range it is missing.

### 10.3 Lifetime

Sessions are **persistent by default**: `pylond` detaches from the SSH
connection and keeps the PTY and screen when the client sleeps, roams or
is closed. It exits after the last session has had no client for the
idle limit (default 7 days) or on `pylon forget`. A session started
with `--ephemeral` ends when its client disconnects for more than a
short grace period (default 60 s).

### 10.4 Re-attach

A session ticket (9.2) lets a device *continue* a live connection:
roaming, rekeying and short gaps (default up to 15 minutes without an
authenticated packet) need nothing more. It does not let a device
*resume* one. Re-attaching after a longer gap, after the app was closed,
or from another device requires a **fresh user signature**:

1. The client sends `attach(session, c_static, nonce_c)` over the Pylon
   handshake, or runs the SSH bootstrap again (5-8) when it has no valid
   ticket.
2. `pylond` answers with a challenge binding its static key, the
   session, the client's static key and a fresh nonce.
3. The client has the challenge signed by the principal's key through its
   custodian (Symbolon's consent sheet, which always prompts for an
   attach; or a key touch or biometric in tiers B-D) as an `SSHSIG`
   with namespace `attach@pylon`.
4. `pylond` verifies the signature against the principal's own
   `~/.ssh/authorized_keys` (and user CA, if configured), read at that
   moment.

So an unlocked stolen phone cannot resume a session without the key's
custodian (G10), and revoking a key (Symbolon removes it from
`authorized_keys` on the hosts it manages, Symbolon 26.3) or a device
(its share can no longer sign) cuts off re-attach on every host at
once, with no other device needing to be online to tell `pylond` (G9).
Tickets are stored wrapped by the platform keystore with user
authentication required, and expire after 12 hours regardless.

## 11. Streams: forwards and files

- **Forwards.** Local, remote and dynamic (SOCKS5) forwards, over SSH
  `direct-tcpip`/`tcpip-forward` and over Pylon streams when the session
  is on Pylon, surviving roaming. Remote forwards bind loopback only
  unless the host entry says otherwise. Each forward is listed on the
  session screen with its byte counters.
- **Local forwards on a shared loopback.** On Android, `127.0.0.1` is
  shared by every app on the device (A4): a local forward to a database
  or admin panel is open to all of them. Pylon therefore:
  - offers forwards consumed inside Pylon (its own browser view and its
    file and SSH clients) without opening a socket at all;
  - for a forward other apps must use, accepts a connection only from the
    app the principal picked when creating it (the connecting UID is
    checked per connection with `ConnectivityManager.getConnectionOwnerUid`,
    Android 10+), and otherwise shows a warning naming the risk before
    the forward opens;
  - closes forwards when the session goes to the background, unless the
    principal pinned them open.
- **Files.** SFTP v3 over SSH, and on Pylon a resumable transfer stream
  with per-chunk BLAKE2s hashes so an interrupted transfer continues
  where it stopped. Remote file names are displayed escaped (no control
  characters, bidi overrides or look-alike path separators) and never
  used as local paths without the principal choosing a destination.

## 12. The terminal emulator

A VT/xterm-compatible emulator in Resid, shared by the app and `pylond`.
Hostile output (A2) is assumed, and since the emulator is the largest
parser of attacker-controlled bytes in the client, it is **isolated**:
on Android it runs in an `isolatedProcess` service (no network, no
storage, no binder access to Symbolon) that receives channel bytes and
returns screen cells; the process that holds connections and the
Symbolon binding never parses host output. On desktop the same split
uses a separate process under seccomp. A bug in the emulator then
yields a process that can draw one terminal and nothing else. Within
the emulator:

- **Clipboard** (OSC 52): writes require a per-host grant; reads are not
  implemented.
- **No read-back.** DECRQSS, title reporting (`CSI 21 t`), font and
  color queries that echo attacker-controlled strings back as input are
  not implemented or answer fixed values.
- **Paste.** Bracketed paste is always used when the program enabled it;
  a paste containing a newline or control characters into a program
  that did not is shown for confirmation.
- **Hyperlinks** (OSC 8) show their real target before opening.
- **No spoofing of Pylon.** Pylon's own prompts (host trust, consent
  hand-off, errors) are drawn outside the terminal area, never inside it.
- **Limits.** Bounded sequence lengths, bounded image protocols (none in
  v1), and a parser that is a total state machine.

## 13. The local shell

A Termux-like local userland is a later phase (17), and is **isolated by
construction**:

- It runs as a separate Android app UID (a companion package
  `dev.pylon.local`), or in an `isolatedProcess` service where the
  userland allows, never in Pylon's process.
- It has no access to Pylon's storage, no binding to Symbolon's agent
  service (the signature permission is not granted to it), and no IPC to
  Pylon other than a terminal byte stream Pylon renders.
- Pylon can SSH *from* the local shell only through a socket the
  principal explicitly exposes for that session, which goes through the
  same host trust and consent as any other connection.

## 14. Storage and synchronization

Pylon stores no secrets of its own except Pylon session tickets (9.2),
wrapped by the platform's hardware keystore and never synchronized.
Host entries, known keys, CA trust, snippets and settings are Symbolon
vault items (6.3), synchronized by Symbolon. Logs never contain terminal
content.

## 15. Platform integration

- **Android (phase 1).** Foreground service for live sessions; an
  extra-keys row (Esc, Ctrl, Alt, Tab, arrows, `|~/-`); hardware
  keyboard support; `FLAG_SECURE` on the terminal (configurable);
  network change listener that nudges the Pylon protocol to re-send from
  the new address.
- **Keyboards.** Third-party input methods see every keystroke,
  including passwords typed at a `sudo` prompt. The terminal requests
  no personalized learning and no suggestions from the input method,
  warns once when the active input method is not a system one, and
  offers Pylon's own in-app keyboard, switched to automatically when the
  screen shows a password prompt (echo off on the PTY, reported by
  `pylond`; or a recognised prompt over plain SSH).
- **Clipboard.** Copies from the terminal are marked sensitive
  (`ClipDescription.EXTRA_IS_SENSITIVE`, Android 13+), are kept out of
  cross-device clipboard sync, and are cleared after 60 seconds.
- **Screenshots and recents.** `FLAG_SECURE` keeps terminal content out
  of screenshots, screen recording and the recents thumbnail by default.
- **Linux desktop (phase 2).** Tabs and splits; `SSH_AUTH_SOCK` to
  `symbolon ssh-agent`; `pylon` CLI.
- **Windows, macOS, iOS (phase 3+).** Requires Symbolon on those
  platforms first; the core needs Resid targets for them.

## 16. Implementation requirements

- All protocol, cryptographic and terminal-parsing code is Resid.
  Keying material is `Secret(UInt(8))`; it leaves only through named
  `declassify` points (the AEAD calls).
- Every parser is total and has a fuzz target; the SSH client is tested
  in CI against OpenSSH (several versions) and Dropbear, with algorithm
  restrictions on both sides, and against fault injection (truncated,
  reordered and Terrapin-style manipulated handshakes).
- **Formal analysis before use.** The Pylon bootstrap (9.2), handshake
  (9.3), re-attach (10.4) and the binding of session-bind to host-bound
  authentication (7.2) are modelled in Tamarin or ProVerif, with goals
  G2, G3, G5, G9 and G10 as lemmas, before phase 2 ships; the models
  live in `models/` and run in CI.
- **External review.** The Pylon protocol and `pylond` get an
  independent security review before they are enabled by default.
- The Resid standard library needs: ML-KEM-768 (FIPS 203), BLAKE2s,
  and a non-blocking standard-input read for the CLI.

## 17. Phases

| Phase | Content |
|---|---|
| 0 | SSH transport core in Resid: profile of 5 (key exchange `mlkem768x25519-sha256` and `curve25519-sha256`; `sntrup761x25519-sha512` not implemented), host verification against pinned keys, agent authentication with session binding, exec and shell channels; `pylon` CLI; interop tests against OpenSSH. *Done: exec and interactive shells with keystroke obfuscation, local forwarding, `Secret(T)` keying material.* |
| 1 | Android app: host list, terminal emulator, Symbolon IPC, host trust of 6 with sync, SFTP, forwards, ProxyJump. |
| 1b | Without Symbolon (7.6): hardware keys, external agents, imported key files, with the warning. |
| 2 | `pylond`: delivery (8) with reproducible, logged releases; Pylon protocol (9); persistent sessions with signed re-attach, screen sync and scrollback (10); Pylon streams (11); formal models and external review. Linux desktop app. |
| 3 | Restricted agent forwarding, SSHFP/DNSSEC resolver, host and user certificates, organization policy. |
| 4 | Local shell (13). Windows, macOS, iOS. |
| 5 | Direct Pylon authentication without SSH on hosts that run `pylond`: Symbolon-signed handshakes and optional host attestation (SEV-SNP, TDX, TPM via Resid's `lib/verify/`). |

## 18. Open questions

1. Whether to pin `pylond` releases per organization (allow-list of
   hashes in the organization's Symbolon policy) in addition to
   provenance.
2. UDP-blocked networks: a TCP/TLS-tunnelled fallback for the Pylon
   protocol, or fall back to SSH.
3. Whether the second-device first-use approval (6.1.4) should go
   through Symbolon's quorum channel or a direct device-to-device QR.

## Appendix A. Hardening review (Draft 2)

A review of Draft 1 against its own threat model. Each finding names the
adversary, what Draft 1 allowed, and the change.

| # | Adversary | Finding in Draft 1 | Change |
|---|---|---|---|
| H1 | A3 | A session ticket alone let a device resume a session, so an unlocked stolen phone could re-attach to a live shell without any signature; revocation depended on another of the principal's devices being online to tell `pylond`. | Tickets continue connections, never resume them; re-attach needs a fresh signature verified by `pylond` against `authorized_keys`; 12-hour ticket lifetime; G10 (10.4). |
| H2 | A1 | `pylond` is a new network listener running as the principal; a pre-authentication bug would be remote code execution without SSH. | Pre-authentication surface reduced to one MAC check keyed by bootstrap-only values; bind the reported address only; confinement mandatory or no `pylond`; G11 (8.4, 9.4). |
| H3 | A2 | The terminal emulator parsed hostile output in the process that holds the Symbolon binding. | Emulator in an isolated process with no network, storage or binder access (12). |
| H4 | A4 | Local forwards on Android bind the loopback shared by every app. | In-app consumption without sockets; per-connection UID check; warning; close in background (11). |
| H5 | A4 | Third-party keyboards see passwords typed into the terminal; the clipboard leaks to other apps and devices. | Input-method flags, in-app keyboard for password prompts, sensitive and expiring clipboard (15). |
| H6 | A1 | Second-device first-use approval could be satisfied by two devices on the same Wi-Fi. | The second check must use an independent network path (6.1.4). |
| H7 | A5 | A coerced or colluding release quorum could still ship a malicious `pylond`, possibly to one victim only. | Reproducible builds, a public transparency log with inclusion proofs, rollback protection (8.2). |
| H8 | -- | Consent on every connection leads to blind approval; the host name on the sheet came from Pylon. | Short approval window per (host, key, user), never for sensitive hosts or attach; names from Symbolon's own host database (7.2). |
| H9 | -- | The Pylon protocol had no proof obligation. | Tamarin/ProVerif models of bootstrap, handshake and attach before phase 2; external review before default-on (16). |
| H10 | -- | Pylon required Symbolon; people who will not run it would keep using weaker clients. | Tiers B-D behind an explicit, acknowledged warning; only key custody changes (7.6). |

Implementation findings in the phase-0 code, fixed with this revision:

- **I1** The socket read deadline was absolute, so a consent sheet held
  open past 30 seconds failed the login. The deadline is now re-armed
  after the agent signs.
- **I2** A server exceeding the channel window or maximum packet size,
  or sending data for a channel that is not open, was not treated as a
  protocol error. It now ends the session.
- **I3** Keying material was handled as public integers. The ephemeral
  X25519 key, the shared secret K, every derived key and all cipher
  state are now `Secret(UInt(8))`, computed with Resid's secret-typed
  X25519, SHA-256, ChaCha20, Poly1305 and AES-GCM, and leave the secret
  domain only at five named publication functions (sealed bytes, frame
  lengths, verified plaintext, H, the GCM IV field), each marked
  `@robust_exempt` with its reason so `residc verify` lists them.
- **I4** Encoding K as an mpint branches on its leading bytes in common
  implementations (OpenSSH's included), a timing signal of the kind the
  Raccoon attack exploited in TLS. Pylon hashes all 64 possible
  encodings and keeps the right results with `ct_pick_bytes` (Resid
  `lib/word.resid`), its condition from `ct_nonzero` over K's bytes, so
  nothing branches on, indexes by or publishes any part of K
  (known-answer tests in `tests/kex_test.resid` cover every shape).
  Resid gained `ct_nonzero`, `ct_pick_bytes` and `@selects`, and its
  key-entropy check (E0270) now counts a constant-time choice as a
  selection of its arms: the derivation, checked on its own, verifies
  as resting on the exchange's draw. A masked xor is still, correctly,
  not trusted, since it can cancel.
- **I6** *Open.* E0270 still warns at about 30 sites in Pylon's
  transport. The cause is the check's precision, not the keys, and it was
  diagnosed down to three places in Resid's `compiler/ekey.resid`:
  (a) reading a field of a value that is "one of" several alternatives
  gives up when one alternative is a parameter passed through unchanged
  (`return c;` beside `return C { ... }`), and falls back to every field
  of the record; (b) a merge of more than four alternatives (`ek_meet`)
  drops record fields entirely; (c) applying a summary that passes one
  parameter through (`ek_subst`) concatenates it onto an empty base,
  which also drops fields. A requirement on `Conn.tx` (where the cipher
  key lives) therefore spreads to the socket number and the receive
  buffer, which hold nothing unpredictable. Fixing all three brings
  Pylon from 31 sites to 14, but the combination of (a) and (b) makes the
  check exceed the compiler's 4 GB budget when Resid compiles itself,
  and no pair improves on today's count, so none is landed yet. Pylon's
  `recv_packet` was rewritten with one success and one failure return,
  which avoids (b) there, and the transport's functions return a
  connection rebuilt field by field (`same(c)`) instead of their
  argument, which avoids (a): with today's compiler Pylon is at 12 sites
  (from 31). Extending the rebuilds to `auth.resid` made it worse (112):
  more precision exposes interior sites without resolving them, so the
  remaining sites need the analysis itself to scale (bound (a)+(b) by
  record size, or memoize field reads), or cipher state threaded outside
  the connection record.
- **I7** An event loop could wait on a second packet that never came:
  after a transport-level message (OpenSSH's host-keys announcement),
  the reader looked for the next connection message before returning,
  so a forwarding session stalled for 30 seconds and then failed.
  Event loops now handle exactly one packet per readable socket
  (`next_once`); request/reply steps keep waiting (`next_msg`).
- **I5** The parsers had no fuzz targets. `tests/fuzz_proxy.py` mutates a
  real sshd's byte stream (bit flips, deletions, insertions, in the
  cleartext handshake and in encrypted traffic) and requires every run to
  end in a clean refusal or the exact expected output.
