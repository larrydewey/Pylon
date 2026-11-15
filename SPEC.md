# Pylon: A Security-First Remote Terminal

**Draft 1 -- 2026-11-15.**

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
2. **Keys never live in Pylon.** Every signature is made by
   [Symbolon](https://github.com/larrydewey/symbolon): threshold or
   imported keys, a consent sheet per signature that shows the server the
   session is bound to, revocation and rotation across every host. Pylon
   holds no private key, ever.
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
7. User authentication through Symbolon
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

- **G1 No private keys in Pylon.** Pylon never sees, stores or derives a
  user private key (7).
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
- **G9 Revocation is total.** Revoking a device in Symbolon ends its
  Pylon sessions' ability to re-attach and to authenticate anywhere (10.4).

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
   approves it on a *second* device of their quorum. A network attacker
   (A1) must then deceive two devices on two paths, or the principal's
   out-of-band check.

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

## 7. User authentication through Symbolon

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
therefore cannot obtain a signature for another host.

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

### 7.4 Desktop

On Linux, Windows and macOS the core speaks the same protocol to
`SSH_AUTH_SOCK`, normally `symbolon ssh-agent`. Pylon refuses an agent
socket not owned by the principal.

### 7.5 Duress

When Symbolon is unlocked under its duress profile, the identities it
lists are the duress subset; Pylon additionally hides hosts marked
*sensitive* in their entry. Pylon has no duress state of its own.

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
child, `filesystem` scoped to file transfers) and, where the kernel
allows, applies Landlock (no filesystem access outside `$HOME` and the
cache) and a seccomp filter before accepting packets.

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

- **Silence.** A packet that does not authenticate is dropped with no
  reply. Handshake initiations carry a MAC over the server's static key
  (WireGuard `mac1`), so a scanner that does not know the key gets
  nothing; under load the server answers with a cookie (`mac2`).
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

To attach to a session from a device (the same one after its ticket
expired, or another of the principal's devices), Pylon runs the SSH
bootstrap again (5-8): it is a fresh, host-verified, Symbolon-signed
login, and `session_list` in 9.2 offers the sessions to resume. A
revoked device cannot sign (Symbolon), so it cannot re-attach (G9);
tickets already held by a revoked device are invalidated at its next
contact because Symbolon's revocation also instructs every live Pylon
on the principal's other devices to send `pylond` a `revoke(c_static)`
control message.

## 11. Streams: forwards and files

- **Forwards.** Local, remote and dynamic (SOCKS5) forwards, over SSH
  `direct-tcpip`/`tcpip-forward` and over Pylon streams when the session
  is on Pylon, surviving roaming. Remote forwards bind loopback only
  unless the host entry says otherwise. Each forward is listed on the
  session screen with its byte counters.
- **Files.** SFTP v3 over SSH, and on Pylon a resumable transfer stream
  with per-chunk BLAKE2s hashes so an interrupted transfer continues
  where it stopped. Remote file names are displayed escaped (no control
  characters, bidi overrides or look-alike path separators) and never
  used as local paths without the principal choosing a destination.

## 12. The terminal emulator

A VT/xterm-compatible emulator in Resid, shared by the app and `pylond`.
Hostile output (A2) is assumed:

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
- The Resid standard library needs: ML-KEM-768 (FIPS 203), BLAKE2s,
  and a non-blocking standard-input read for the CLI.

## 17. Phases

| Phase | Content |
|---|---|
| 0 | SSH transport core in Resid: profile of 5 (key exchange `curve25519-sha256` only until Resid has ML-KEM), host verification against pinned keys, agent authentication with session binding, exec and shell channels; `pylon` CLI; interop tests against OpenSSH. *Done except interactive shells and `Secret(T)` keying material.* |
| 1 | Android app: host list, terminal emulator, Symbolon IPC, host trust of 6 with sync, SFTP, forwards, ProxyJump. |
| 2 | `pylond`: delivery (8), Pylon protocol (9), persistent sessions, screen sync and scrollback (10), Pylon streams (11). Linux desktop app. |
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
