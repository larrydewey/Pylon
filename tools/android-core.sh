#!/usr/bin/env bash
# Builds the Resid core for Android and puts it where the APK packs it:
#   app/android/app/src/main/jniLibs/arm64-v8a/libpylon.so       (connection)
#   app/android/app/src/main/jniLibs/arm64-v8a/libpylon_term.so  (emulator)
#   app/assets/pylond/pylond-x86_64, pylond-aarch64               (for servers)
# Needs residc and AArch64 compiler-rt builtins (Resid's
# tools/aarch64-builtins.sh, or RESID_AARCH64_BUILTINS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/android"
LIBS="$ROOT/app/android/app/src/main/jniLibs/arm64-v8a"
ASSETS="$ROOT/app/assets/pylond"
mkdir -p "$OUT" "$LIBS" "$ASSETS"
residc "$ROOT/cli/pylon.resid" --target aarch64-linux-android -o "$OUT/pylon"
residc "$ROOT/cli/pylon_term.resid" --target aarch64-linux-android -o "$OUT/pylon_term"
residc "$ROOT/cli/pylond.resid" --target aarch64 -o "$OUT/pylond-aarch64"
residc "$ROOT/cli/pylond.resid" -o "$OUT/pylond-x86_64"
cp "$OUT/pylon" "$LIBS/libpylon.so"
cp "$OUT/pylon_term" "$LIBS/libpylon_term.so"
cp "$OUT/pylond-aarch64" "$OUT/pylond-x86_64" "$ASSETS/"
echo "core for Android: $LIBS, $ASSETS"
