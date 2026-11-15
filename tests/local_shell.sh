#!/usr/bin/env bash
# The local shell on Linux (SPEC 13, G8). pylon-local's shell cannot read
# PYLON_HOME, cannot connect to SSH_AUTH_SOCK, cannot see Pylon's
# processes and has no network: checked with bash and with dash, as the
# current user and (when run as root) as nobody (tests/local_drive.py).
# Then, when flutter is found, the app's backend runs the real pylon-local
# through the real pylon-term (app/test/local_shell_test.dart).
#
#   tests/local_shell.sh [BUILD_DIR]
#
# Needs python3, unshare(1) and a kernel that allows unprivileged user
# namespaces. Builds pylon-local and pylon-term with residc into BUILD_DIR
# (default build/) when they are not there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(cd "${1:-$ROOT/build}" 2>/dev/null && pwd || { mkdir -p "$ROOT/build" && echo "$ROOT/build"; })"
[ -x "$BIN/pylon-local" ] || residc "$ROOT/cli/pylon_local.resid" -o "$BIN/pylon-local" > /dev/null
for sh in /bin/bash /bin/sh; do
    [ -x "$sh" ] || continue
    echo "shell $sh:"
    TEST_SHELL="$sh" python3 "$ROOT/tests/local_drive.py" "$BIN/pylon-local"
done
FLUTTER="${FLUTTER:-$(command -v flutter || echo /home/user/tools/flutter/bin/flutter)}"
if [ -x "$FLUTTER" ]; then
    [ -x "$BIN/pylon-term" ] || residc "$ROOT/cli/pylon_term.resid" -o "$BIN/pylon-term" > /dev/null
    (cd "$ROOT/app" && PYLON_LOCAL_TEST_BIN="$BIN" "$FLUTTER" test test/local_shell_test.dart --plain-name 'the real pylon-local')
else
    echo "skip the app's end-to-end local shell test (no flutter)"
fi
