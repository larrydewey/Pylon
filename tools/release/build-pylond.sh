#!/usr/bin/env bash
# Builds both pylond (pylond-aarch64, pylond-x86_64) into OUTDIR with the
# pinned release toolchain, so every builder makes the same code images:
# the maintainer (ceremony.sh build), each signer (ceremony.sh check-sign)
# and the APK workflow (tools/android-core.sh) alike.
#
#   tools/release/build-pylond.sh OUTDIR
#
# The Resid compiler is RESID_HOME's (else the installed residc's), and must
# be the one toolchain.env pins. clang, lld and the aarch64 compiler-rt
# builtins come from the container image in toolchain/ (built here on first
# use; RESID_AARCH64_BUILTINS is not used). Needs docker. RESID_SIGNING_KEY,
# if set, signs the provenance trailer, which is not part of the code image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tools/release"
die() { echo "build-pylond: $*" >&2; exit 1; }

[ $# = 1 ] || die "usage: build-pylond.sh OUTDIR"
mkdir -p "$1"
out="$(cd "$1" && pwd)"
command -v docker > /dev/null || die "docker is not on PATH: release builds run in the pinned toolchain (tools/release/toolchain)"

# The compiler: RESID_HOME, else the installed residc wrapper's.
if [ -z "${RESID_HOME:-}" ]; then
    w="$(command -v residc)" || die "residc is not on PATH and RESID_HOME is not set"
    RESID_HOME="$(sed -n 's/^export RESID_HOME="\(.*\)"$/\1/p' "$(readlink -f "$w")")"
    [ -n "$RESID_HOME" ] || die "cannot tell RESID_HOME from $w: set it"
fi
RESID_HOME="$(cd "$RESID_HOME" && pwd)"
if [ -f "$RESID_HOME/bin/stage2.bin" ]; then      # installed (install.sh)
    stage2="$RESID_HOME/bin/stage2.bin"; tree="$RESID_HOME"
elif [ -f "$RESID_HOME/stage2.bin" ]; then        # a Resid checkout's build/boot
    stage2="$RESID_HOME/stage2.bin"; tree="$(cd "$RESID_HOME/../.." && pwd)"
else
    die "no stage2.bin in $RESID_HOME"
fi
. "$HERE/toolchain.env"
have="$(sha256sum "$stage2" | cut -d' ' -f1)"
[ "$have" = "$RESID_STAGE2_SHA256" ] || die "$stage2 is not the pinned compiler (sha256 $have, toolchain.env wants $RESID_STAGE2_SHA256: Resid commit $RESID_COMMIT)"

# The image, tagged by its Dockerfile, built once per machine.
img="pylon-release-toolchain:$(sha256sum "$HERE/toolchain/Dockerfile" | cut -c1-16)"
if ! docker image inspect "$img" > /dev/null 2>&1; then
    echo "build-pylond: building the toolchain image $img" >&2
    docker build -q -t "$img" "$HERE/toolchain" > /dev/null
fi

# Everything at the same absolute paths as outside, so the commands (and
# the paths a build records) are the ones a host build would use.
# The compiler caches the runtime it compiles with clang beside rt.ll, keyed
# by the runtime and the flags but not by which clang made it: a host build
# leaves its own clang's runtime there. The container gets an empty cache.
mkdir -p "$RESID_HOME/rtcache"
mounts=(-v "$ROOT:$ROOT" -v "$out:$out" -v "$tree:$tree:ro"
        --mount "type=tmpfs,dst=$RESID_HOME/rtcache,tmpfs-mode=1777")
key=""
if [ -n "${RESID_SIGNING_KEY:-}" ]; then
    key="$(readlink -f "$RESID_SIGNING_KEY")"
    mounts+=(-v "$key:$key:ro")
fi
docker run --rm --user "$(id -u):$(id -g)" --ulimit stack=-1:-1 \
    -e HOME=/tmp -e RESID_HOME="$RESID_HOME" -e RESID_AARCH64_BUILTINS=/opt/pylon-toolchain/libclang_rt.builtins-aarch64-android.a \
    -e RESID_SIGNING_KEY="$key" -e RESID_MEM_LIMIT \
    "${mounts[@]}" -w "$ROOT" "$img" \
    bash -c 'set -e; [ -n "$RESID_SIGNING_KEY" ] || unset RESID_SIGNING_KEY
             "$0" cli/pylond.resid --target aarch64 -o "$1/pylond-aarch64"
             "$0" cli/pylond.resid -o "$1/pylond-x86_64"' "$stage2" "$out"
