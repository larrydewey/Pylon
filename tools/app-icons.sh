#!/usr/bin/env bash
# Renders the legacy launcher PNGs (Android 7.x; 8 and later use the
# adaptive icon in res/mipmap-anydpi-v26) from app/branding/pylon-icon.svg.
# Needs rsvg-convert (librsvg).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/app/branding/pylon-icon.svg"
RES="$ROOT/app/android/app/src/main/res"
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    rsvg-convert -w "${d#*:}" -h "${d#*:}" "$SVG" -o "$RES/mipmap-${d%%:*}/ic_launcher.png"
done
echo "launcher icons: $RES/mipmap-*/ic_launcher.png"
