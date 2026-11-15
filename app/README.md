# Pylon app (Flutter)

The interface over the Resid core. It holds no keys, makes no connections
and parses no host output itself:

- per terminal, `pylon --app` (the connection: SSH or the Pylon protocol,
  keys from the agent at `SSH_AUTH_SOCK`, Symbolon's) and `pylon-term`
  (the emulator, which confines itself before reading a byte; SPEC 12);
- the app relays bytes between them and draws the screens `pylon-term`
  sends (`lib/term/screen.dart`), encodes keys (`lib/term/keys.dart`) and
  asks before pasting lines into a program that did not ask for a paste,
  or before a host writes to the clipboard (OSC 52);
- pins, CAs and the pin history are the core's (`pylon pin`, `pylon ca`,
  `pylon pins`); the host list is `$PYLON_HOME/app_hosts.json`.

No third-party Dart packages. JetBrains Mono is bundled (OFL,
`assets/fonts/JetBrainsMono-OFL.txt`).

## Run

```sh
# the core
residc ../cli/pylon.resid -o ../build/pylon
residc ../cli/pylon_term.resid -o ../build/pylon-term
residc ../cli/pylond.resid -o ../build/pylond
# pylond goes to a host only as a signed, logged release (SPEC 8.2;
# pylond.release and pylond.proof beside it); a local build opts out:
PYLON_BIN_DIR=$PWD/../build flutter run -d linux --dart-define=PYLON_UNVERIFIED_PYLOND=true

# the interface alone (demo data, says so on every screen)
flutter build web && python3 -m http.server -d build/web
```

## Tests

`flutter test` (keys, paste rules, frames, screens, exit status);
`tests/interop.sh` runs `test/process_backend_test.dart` against a real
sshd: a terminal from keys to screens and back, a resize, the exit status.

## Status

Linux desktop and web (preview) build here. Android needs the Android
SDK, and the core built with `residc --target aarch64-linux-android`
bundled as executables in the APK's native library directory.
