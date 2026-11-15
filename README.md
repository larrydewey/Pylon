# Pylon

A security-first remote terminal: SSH, file transfer, port forwarding and
roaming sessions, meant to replace Termius, ConnectBot, JuiceSSH and the
SSH side of Termux.

- **Strict SSH to every server.** A small modern subset (ML-KEM-768 +
  X25519 hybrid, curve25519, AEAD
  ciphers only, Ed25519/ECDSA/RSA-SHA2), strict key exchange (the Terrapin
  fix) required, no trust on first use, host keys pinned only against a
  fingerprint you obtained out of band.
- **No keys in Pylon.** Every signature comes from
  [Symbolon](https://github.com/larrydewey/symbolon) (threshold keys, a
  consent sheet per signature), bound to the session and the host key
  (`session-bind@openssh.com`, `publickey-hostbound-v00@openssh.com`), so a
  host can never obtain a signature usable elsewhere. Pylon also works
  without Symbolon (a hardware key, another agent, or an imported key
  file), behind an explicit warning of what that gives up (SPEC 7.6).
- **Pylon-to-Pylon when possible.** After an SSH login, Pylon can push a
  signed, hash-verified `pylond` to the host over the same connection and
  move the session onto a roaming, post-quantum, forward-secret UDP
  protocol chained to the SSH handshake, with persistent sessions you can
  re-attach from any of your devices (phase 2).

The protocol code is written in [Resid](https://github.com/larrydewey/Resid).
The design is in [SPEC.md](SPEC.md).

## Status

Phase 0: the SSH transport core and the `pylon` command-line client.

| | |
|---|---|
| Key exchange | `mlkem768x25519-sha256` (post-quantum hybrid, ML-KEM-768 from Resid) first, then `curve25519-sha256`; strict kex and ext-info |
| Host keys | `ssh-ed25519`, `ecdsa-sha2-nistp256/384`, `rsa-sha2-512/256` (RSA ≥ 2048) |
| Ciphers | `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com` |
| Authentication | agent keys over `SSH_AUTH_SOCK`, session-bound, host-bound |
| Sessions | exec (stdout, escaped stderr, exit status) and interactive shells on a pty (resize, paste); flow control both ways; server-initiated rekey |
| Keystroke timing | obfuscated by default: 20 ms ticks, one-size chaff (PING or IGNORE), checked on the wire; `--no-obfuscate-keystrokes` opts out |
| Port forwarding | `-N` with `-L [127.0.0.1:]PORT:HOST:HOSTPORT`, `-D [127.0.0.1:]PORT` (SOCKS5, host names validated), `-R [localhost:]RPORT:HOST:HOSTPORT` (server binds loopback; only requested ports, each to its own destination); loopback binds only |
| Files | `pylon get USER@HOST:REMOTE LOCAL`, `pylon put LOCAL USER@HOST:REMOTE` (SFTP v3); a local file is never replaced without `--force`; server messages shown escaped; over the Pylon protocol (`--pylond FILE`) resumable with `--resume` (per-chunk hashes, the whole file's hash checked) |
| Jump hosts | `-J USER@JUMP[:PORT]` on any command: the jump host is verified under its own pins, the target under its own, end to end through a direct-tcpip channel; no agent forwarding |
| Pylon protocol (experimental) | `--pylond FILE USER@HOST` (a terminal) or `--pylond FILE -N -L/-D/-R ...`: pushes `pylond` over SSH (hash-addressed, 0500 in a 0700 `~/.cache/pylon`), bootstraps a post-quantum UDP session through the SSH channel, closes SSH; terminals keep running in a per-user session daemon (`--sessions`, `--attach`, `--ephemeral`), roam across address changes, rekey every 2 minutes; packets padded to 64 bytes; silent to unauthenticated datagrams, and under load a cookie (`mac2`) before any asymmetric work (SPEC 9.7) |
| Host trust | pinned keys (`pylon pin HOST FINGERPRINT`; re-pinning replaces the old key) or host certificates from a CA you trust for the name (`pylon ca PATTERN 'ALG BASE64'`, PATTERN a host, `*.domain` or `*`; host type, exact principal, validity window and no critical options checked); a changed key names the old pin; `pylon history [HOST]` |
| Key material | `Secret(UInt(8))` throughout; K handled in constant time, including its mpint encoding (SPEC A, I4) |
| Local shell | `pylon-local` (SPEC 13): a shell on the device that cannot reach Pylon's files, the agent, Pylon's processes or the network. Linux: an empty environment and new user, mount, pid and network namespaces with a root of its own (system directories read-only, its own home at `~/.local/share/pylon-local/home`); Android: an `isolatedProcess` service (its own UID, no permissions, no storage), not yet verified on a device. No SSH from it yet |
| Linux desktop | the app as tabs and splits (SPEC 15): a session per pane, each resized to its pane, Ctrl+Shift shortcuts never sent to the host, closing a pane ends its session. `flutter build linux` needs GTK 3 development files |

Tested against OpenSSH 9.6 (and the handshake against Dropbear 2022.83):
119 interoperability, interactive, timing, forwarding (-L/-D/-R), SFTP,
ProxyJump, Pylon protocol (terminals, re-attach, roaming, rekeying,
-L/-D/-R forwards, resumable files, cookies under load, padding),
post-quantum and hostile-server cases in `tests/interop.sh`,
known-answer tests for the key derivation in `tests/kex_test.resid`, and
a mutation fuzzer in `tests/fuzz_proxy.py`.

Next (SPEC 17): an OpenSSH 10 interop run for the hybrid (OpenSSH 9.6
here has no ML-KEM; it is checked against a reference server built on
OpenSSL's primitives, `tests/pq_server.py`), then the Android app. Open
compiler warnings: SPEC Appendix A, I6.

## Build and use

Requires the Resid toolchain (`residc`, see the Resid README).

```sh
residc cli/pylon.resid -o build/pylon
residc cli/pylond.resid -o build/pylond   # optional: the Pylon protocol server
residc cli/pylon_local.resid -o build/pylon-local   # optional: the local shell (SPEC 13)

# Pin a host: get its fingerprint out of band (its console:
# ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub), then
build/pylon pin example.org SHA256:...

# Run a command, signing with Symbolon's agent
eval "$(symbolon ssh-agent ~/.symbolon &)"   # or any session-bind capable agent
build/pylon alice@example.org uptime
```

Options: `-p PORT`, `--allow-no-strict` (per-connection exception for
servers without the Terrapin fix), `--no-obfuscate-keystrokes`, `-N -L
[127.0.0.1:]PORT:HOST:HOSTPORT`, `-D [127.0.0.1:]PORT`, `-R
[localhost:]RPORT:HOST:HOSTPORT` (each repeatable), `-J USER@JUMP[:PORT]`, `--pylond FILE` (experimental, a terminal or `-N` with `-L`/`-D`/`-R`). With no COMMAND, `pylon
USER@HOST` opens an interactive shell. Pinned keys live in
`$PYLON_HOME/known_hosts` (default `~/.config/pylon/known_hosts`).

## Tests

```sh
tests/interop.sh build/pylon      # needs sshd, ssh-keygen, ssh-agent, python3
residc test tests/kex_test.resid  # key derivation known answers
residc test tests/proto_test.resid # Pylon protocol: bootstrap, handshake, replay, padding, cookies
residc test tests/term_test.resid  # the terminal emulator core
tests/local_shell.sh build         # the local shell can't read PYLON_HOME or reach SSH_AUTH_SOCK
(cd app && flutter test)           # the app: keys, frames, tabs and splits, the local shell's backend

# Fuzzing through a mutating proxy in front of a running sshd (port 2222),
# with the host pinned under the proxy's port:
FUZZ_PORT=2299 FUZZ_EXPECT=ok tests/fuzz_proxy.py 200 2222 -- build/pylon -p {port} USER@127.0.0.1 echo ok
```

## Layout

- `core/` the SSH client core: wire types, packet ciphers, key exchange,
  host keys, transport, agent client, user authentication, sessions,
  pinned hosts.
- `cli/` the `pylon` command, `pylon-term` (the confined emulator),
  `pylon-local` (the local shell's launcher) and `pylond`.
- `app/` the Flutter app (Android, Linux desktop).
- `tests/` interoperability tests and a hostile server.

## License

MIT; see [LICENSE](LICENSE).
