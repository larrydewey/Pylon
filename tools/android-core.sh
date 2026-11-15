#!/usr/bin/env bash
# Builds the Resid core for Android and puts it where the APK packs it:
#   app/android/app/src/main/jniLibs/arm64-v8a/libpylon.so       (connection)
#   app/android/app/src/main/jniLibs/arm64-v8a/libpylon_term.so  (emulator)
#   app/assets/pylond/pylond-x86_64, pylond-aarch64               (for servers)
#   app/assets/pylond/pylond.release, pylond.proof                (SPEC 8.2)
# Needs residc and AArch64 compiler-rt builtins (Resid's
# tools/aarch64-builtins.sh, or RESID_AARCH64_BUILTINS).
#
# PYLOND_RELEASE_DIR: a signed, logged pylond release (pylond-x86_64,
# pylond-aarch64, pylond.release, pylond.proof, made with tools/release).
# Its builds are the ones packed, after this build of the same source is
# checked to have the same code images (reproducibility, SPEC 8.2). Without
# it the pylond builds made here are packed unsigned, and the app's pylon
# refuses to push them (a developer build may opt out at build time:
# flutter build --dart-define=PYLON_UNVERIFIED_PYLOND=true).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBS="$ROOT/app/android/app/src/main/jniLibs/arm64-v8a"
ASSETS="$ROOT/app/assets/pylond"
# Relative paths from the root: the provenance trailer records the output
# path, so every checkout builds the same bytes with the same key.
cd "$ROOT"
OUT=build/android
mkdir -p "$OUT" "$LIBS" "$ASSETS"
residc cli/pylon.resid --target aarch64-linux-android -o "$OUT/pylon"
residc cli/pylon_term.resid --target aarch64-linux-android -o "$OUT/pylon_term"
residc cli/pylond.resid --target aarch64 -o "$OUT/pylond-aarch64"
residc cli/pylond.resid -o "$OUT/pylond-x86_64"
cp "$OUT/pylon" "$LIBS/libpylon.so"
cp "$OUT/pylon_term" "$LIBS/libpylon_term.so"
rm -f "$ASSETS"/pylond-* "$ASSETS"/pylond.release "$ASSETS"/pylond.proof
if [ -n "${PYLOND_RELEASE_DIR:-}" ]; then
    residc tools/release/release.resid -o "$OUT/pylon-release"
    for arch in aarch64 x86_64; do
        want=$(awk -v a="$arch" '$1 == "pylond" && $2 == a { print $4 }' "$PYLOND_RELEASE_DIR/pylond.release")
        got=$("$OUT/pylon-release" code-hash "$OUT/pylond-$arch")
        rel=$("$OUT/pylon-release" code-hash "$PYLOND_RELEASE_DIR/pylond-$arch")
        if [ -z "$want" ] || [ "$got" != "$want" ] || [ "$rel" != "$want" ]; then
            echo "pylond-$arch: this build's code image ($got) is not the release's ($want, its file $rel)" >&2
            exit 1
        fi
    done
    cp "$PYLOND_RELEASE_DIR"/pylond-aarch64 "$PYLOND_RELEASE_DIR"/pylond-x86_64 \
       "$PYLOND_RELEASE_DIR"/pylond.release "$PYLOND_RELEASE_DIR"/pylond.proof "$ASSETS/"
    echo "pylond: the release in $PYLOND_RELEASE_DIR (reproduced)"
else
    cp "$OUT/pylond-aarch64" "$OUT/pylond-x86_64" "$ASSETS/"
    echo "pylond: unsigned builds (no PYLOND_RELEASE_DIR)"
fi
echo "core for Android: $LIBS, $ASSETS"
