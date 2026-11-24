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
  `pylon pins`); the host list is `$PYLON_HOME/app_hosts.json`;
- getting into a server (`lib/ui/access_help.dart`): a host that refuses
  every key gets a card with the keys to add and the `pylon authorize`
  command; Authorize a key (`pylon authorize --app`, agent requests framed
  as for a terminal) adds keys or a CA from a device that can log in;
  Share pin shows a host's pins as a `pylon-hostkey/1` QR code, which
  another device scans (Android: Camera2 and ZXing, `QrScanner.kt`) or
  pastes into `pylon pin`, which still checks the key the host presents;
- the local shell (SPEC 13) is `pylon-local` in place of `pylon --app`
  (Linux: namespaces, a root of its own; Android: `LocalShellService`, an
  isolated process running `libpylon_local.so`), drawn by `pylon-term`
  like any session, in purple;
- on a desktop, tabs and splits (`lib/desktop/`, SPEC 15): Ctrl+Shift+T
  new tab, Ctrl+Shift+L local shell, Ctrl+Shift+E / Ctrl+Shift+O split
  right / down, Ctrl+Shift+W close pane, Ctrl+Shift+arrows focus,
  Ctrl+PageUp/PageDown tabs, Ctrl+Shift+V paste, Ctrl+Shift+K commands.
  `PYLON_LAYOUT=phone` gives the phone layout.

One third-party Dart package, `qr` (BSD-3-Clause), draws the Share pin
code. JetBrains Mono is bundled (OFL, `assets/fonts/JetBrainsMono-OFL.txt`).
On Android, ZXing's core library (Apache-2.0) decodes scanned codes; its
license and notice are in `android/app/src/main/assets/third_party/zxing`,
and in the APK under `assets/third_party/zxing/`.

## Run

```sh
# the core
residc ../cli/pylon.resid -o ../build/pylon
residc ../cli/pylon_term.resid -o ../build/pylon-term
residc ../cli/pylond.resid -o ../build/pylond
residc ../cli/pylon_local.resid -o ../build/pylon-local
# pylond goes to a host only as a signed, logged release (SPEC 8.2;
# pylond.release and pylond.proof beside it); a local build opts out:
PYLON_BIN_DIR=$PWD/../build flutter run -d linux --dart-define=PYLON_UNVERIFIED_PYLOND=true

# the interface alone (demo data, says so on every screen)
flutter build web && python3 -m http.server -d build/web
```

## Tests

`flutter test` (keys, paste rules, frames, screens, exit status, the
tab and split model, the desktop layout's shortcuts, focus and resizes,
the local shell's backend against stub processes; with
`PYLON_LOCAL_TEST_BIN=../build`, the real `pylon-local` and `pylon-term`);
`tests/interop.sh` runs `test/process_backend_test.dart` against a real
sshd: a terminal from keys to screens and back, a resize, the exit status.

## Status

Web (preview) builds here; `flutter build linux` needs the GTK 3
development files (`libgtk-3-dev`), which this machine lacks. The app
needs Android 10 (API 29) or later: each terminal's emulator runs in an
isolated process of its own (`bindIsolatedService`, SPEC 12), which
older versions cannot do. Android needs the Android
SDK, and the core built with `residc --target aarch64-linux-android`
bundled as executables in the APK's native library directory.
