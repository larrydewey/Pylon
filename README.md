# Pylon

A security-first remote terminal: SSH, file transfer, port forwarding and
roaming sessions, meant to replace Termius, ConnectBot, JuiceSSH and the
SSH side of Termux.

- **Strict SSH to every server.** A small modern subset (curve25519, AEAD
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
| Key exchange | `curve25519-sha256` with strict kex and ext-info |
| Host keys | `ssh-ed25519`, `ecdsa-sha2-nistp256/384`, `rsa-sha2-512/256` (RSA ≥ 2048) |
| Ciphers | `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com` |
| Authentication | agent keys over `SSH_AUTH_SOCK`, session-bound, host-bound |
| Sessions | exec with stdout, stderr (escaped) and exit status; flow control; server-initiated rekey |
| Host trust | pinned keys only (`pylon pin HOST FINGERPRINT`) |
| Key material | `Secret(UInt(8))` throughout; K handled in constant time, including its mpint encoding (SPEC A, I4) |

Tested against OpenSSH 9.6 (and the handshake against Dropbear 2022.83):
24 interoperability and hostile-server cases in `tests/interop.sh`,
known-answer tests for the key derivation in `tests/kex_test.resid`, and
a mutation fuzzer in `tests/fuzz_proxy.py`.

Next (SPEC 17): interactive shells (needs a non-blocking stdin read in the
Resid runtime), the hybrid post-quantum key exchanges (needs ML-KEM in
Resid's standard library), then the Android app. Open compiler warning:
SPEC Appendix A, I4.

## Build and use

Requires the Resid toolchain (`residc`, see the Resid README).

```sh
residc cli/pylon.resid -o build/pylon

# Pin a host: get its fingerprint out of band (its console:
# ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub), then
build/pylon pin example.org SHA256:...

# Run a command, signing with Symbolon's agent
eval "$(symbolon ssh-agent ~/.symbolon &)"   # or any session-bind capable agent
build/pylon alice@example.org uptime
```

Options: `-p PORT`, `--allow-no-strict` (per-connection exception for
servers without the Terrapin fix). Pinned keys live in
`$PYLON_HOME/known_hosts` (default `~/.config/pylon/known_hosts`).

## Tests

```sh
tests/interop.sh build/pylon      # needs sshd, ssh-keygen, ssh-agent, python3
residc test tests/kex_test.resid  # key derivation known answers

# Fuzzing through a mutating proxy in front of a running sshd (port 2222),
# with the host pinned under the proxy's port:
FUZZ_PORT=2299 FUZZ_EXPECT=ok tests/fuzz_proxy.py 200 2222 -- build/pylon -p {port} USER@127.0.0.1 echo ok
```

## Layout

- `core/` the SSH client core: wire types, packet ciphers, key exchange,
  host keys, transport, agent client, user authentication, sessions,
  pinned hosts.
- `cli/` the `pylon` command.
- `tests/` interoperability tests and a hostile server.

## License

MIT; see [LICENSE](LICENSE).
