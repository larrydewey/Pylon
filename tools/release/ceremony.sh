#!/usr/bin/env bash
# The pylond release ceremony (SPEC 8.2.1), around pylon-release. Read
# tools/release/CEREMONY.md first; each step says on whose machine it runs.
#
#   ceremony.sh keygen NAME                       a key holder, offline: NAME.key, NAME.pub
#   ceremony.sh roots K REL.pub... --log K LOG.pub...
#                                                 the maintainer, once: pins the public keys
#                                                 in core/release_roots.resid
#   ceremony.sh build VERSION COUNTER             the maintainer, per release: both pylond
#                                                 builds and the unsigned manifest in
#                                                 release/VERSION/
#   ceremony.sh check-sign DIR NAME.key           each signer: rebuilds pylond from this
#                                                 checkout, signs only if the code images
#                                                 are the manifest's
#   ceremony.sh publish DIR LOGDIR LOG.key        the log key holder: appends to the log,
#                                                 signs the tree head, writes the proof and
#                                                 verifies the release against the pinned roots
#
# Private keys stay where keygen made them: never in this repository, never
# in CI, never on the machine that builds the APK.
set -euo pipefail
CALLER="$PWD"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL=build/pylon-release

# Paths given on the command line are the caller's (its working directory),
# made absolute before the script moves to the repository root.
abs() { case "$1" in /*) echo "$1" ;; *) echo "$CALLER/$1" ;; esac; }
cd "$ROOT"

die() { echo "ceremony: $*" >&2; exit 1; }

tool() {   # builds pylon-release from this checkout when it is missing or older
    if [ ! -x "$TOOL" ] || [ tools/release/release.resid -nt "$TOOL" ] || [ core/release.resid -nt "$TOOL" ]; then
        mkdir -p build
        residc tools/release/release.resid -o "$TOOL" > /dev/null
    fi
}

# Built exactly as tools/android-core.sh builds them (paths relative to the
# root): the code images are what every builder must reproduce.
build_pylond() {   # OUTDIR
    : "${RESID_AARCH64_BUILTINS:?the aarch64 build needs RESID_AARCH64_BUILTINS (Resid tools/aarch64-builtins.sh finds one in an Android NDK)}"
    local o="$1"; mkdir -p "$o"
    residc cli/pylond.resid --target aarch64 -o "$o/pylond-aarch64" > /dev/null
    residc cli/pylond.resid -o "$o/pylond-x86_64" > /dev/null
}

compiler_id() {   # the compiler the code images depend on
    local w; w="$(command -v residc)" || die "residc is not on PATH"
    local s; s="$(dirname "$(readlink -f "$w")")/stage2.bin"
    if [ -f "$s" ]; then sha256sum "$s" | cut -d' ' -f1; else echo "unknown ($w)"; fi
}

case "${1:-}" in
keygen)
    [ $# = 2 ] || die "usage: ceremony.sh keygen NAME"
    case "$2" in */*) die "NAME is a name, not a path: run keygen in the directory that keeps the key" ;; esac
    tool
    # In the caller's directory, never the repository's: the key must not
    # land in a checkout.
    case "$CALLER/" in "$ROOT"/*) die "run keygen outside the repository (an offline directory)" ;; esac
    umask 077
    (cd "$CALLER" && "$ROOT/$TOOL" keygen "$2")
    echo
    echo "Keep $2.key offline and backed up (it is the whole private key, hex)."
    echo "Send only $2.pub to the maintainer, and confirm its key id with them"
    echo "over a second channel (in person, or a call)."
    ;;

roots)
    shift
    tool
    args=()
    for a in "$@"; do case "$a" in *.pub) args+=("$(abs "$a")") ;; *) args+=("$a") ;; esac; done
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    "$ROOT/$TOOL" roots "$tmp" "${args[@]}"
    mkdir -p build/ceremony
    cp "$tmp" build/ceremony/roots
    python3 - "$tmp" core/release_roots.resid <<'EOF'
import sys
roots = open(sys.argv[1]).read()
src = open(sys.argv[2]).read()
head = src[:src.index("pub Str pinned_roots()")]
head = head.replace("Empty until the first release ceremony: until\n// then no pylond verifies against this build, and pylon refuses to push\n// one unless told to trust other roots (--pylond-roots FILE) or none\n// (--pylond-unverified), both developer options that say so.",
                    "Pinned at a release ceremony (tools/release/CEREMONY.md).")
lit = roots.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
open(sys.argv[2], "w").write(head + 'pub Str pinned_roots() { return "' + lit + '"; }\n')
EOF
    echo "Pinned in core/release_roots.resid (and build/ceremony/roots):"
    sed 's/^/  /' build/ceremony/roots
    echo
    echo "Check every key id against what its holder read out, then commit"
    echo "core/release_roots.resid. Releases built from then on trust these keys."
    ;;

build)
    [ $# = 3 ] || die "usage: ceremony.sh build VERSION COUNTER"
    v="$2"; c="$3"; d="$ROOT/release/$v"
    [ ! -e "$d" ] || die "$d exists"
    git diff --quiet HEAD -- cli core || die "uncommitted changes in cli/ or core/: build from a commit"
    tool
    build_pylond "$d"
    "$ROOT/$TOOL" manifest "$v" "$c" "$d" "$d/pylond.release"
    {
        echo "pylon commit $(git rev-parse HEAD)"
        echo "compiler stage2.bin sha256 $(compiler_id)"
    } > "$d/BUILDINFO"
    echo "Built $d:"; ls -1 "$d" | sed 's/^/  /'
    echo
    echo "Each signer now runs, on their own machine, at commit $(git rev-parse --short HEAD)"
    echo "and with the same compiler (BUILDINFO):"
    echo "  tools/release/ceremony.sh check-sign $d NAME.key"
    echo "passing $d/pylond.release around (signatures are appended to it)."
    ;;

check-sign)
    [ $# = 3 ] || die "usage: ceremony.sh check-sign DIR NAME.key"
    d="$(abs "$2")"; key="$(abs "$3")"
    [ -f "$d/pylond.release" ] || die "no $d/pylond.release"
    tool
    if [ -f "$d/BUILDINFO" ]; then
        want_c="$(sed -n 's/^pylon commit //p' "$d/BUILDINFO")"
        [ "$want_c" = "$(git rev-parse HEAD)" ] || die "this checkout is $(git rev-parse --short HEAD), the release was built from ${want_c:0:12}: check that out first"
        want_s="$(sed -n 's/^compiler stage2.bin sha256 //p' "$d/BUILDINFO")"
        [ "$want_s" = "$(compiler_id)" ] || echo "ceremony: warning: a different compiler than the release's (BUILDINFO); the code images will likely differ" >&2
    fi
    own="$(mktemp -d)"; trap 'rm -rf "$own"' EXIT
    echo "Rebuilding pylond independently..."
    build_pylond "$own"
    for arch in aarch64 x86_64; do
        want="$(awk -v a="$arch" '$1 == "pylond" && $2 == a { print $4 }' "$d/pylond.release")"
        mine="$("$ROOT/$TOOL" code-hash "$own/pylond-$arch")"
        theirs="$("$ROOT/$TOOL" code-hash "$d/pylond-$arch")"
        echo "  $arch: manifest $want"
        echo "  $arch: my build $mine"
        [ -n "$want" ] && [ "$mine" = "$want" ] && [ "$theirs" = "$want" ] || die "pylond-$arch is not what this checkout builds: NOT signing"
    done
    "$ROOT/$TOOL" sign "$d/pylond.release" "$key"
    echo "Signed. Pass $d/pylond.release on to the next signer, or to the log key holder."
    ;;

publish)
    [ $# = 4 ] || die "usage: ceremony.sh publish DIR LOGDIR LOG.key"
    d="$(abs "$2")"; log="$(abs "$3")"; key="$(abs "$4")"
    tool
    mkdir -p "$log"
    "$ROOT/$TOOL" log-append "$log" "$d/pylond.release"
    "$ROOT/$TOOL" sign "$log/head" "$key"
    "$ROOT/$TOOL" proof "$log" "$d/pylond.release" "$d/pylond.proof"
    roots="build/ceremony/roots"
    if [ ! -f "$roots" ]; then
        python3 -c "import re,sys; s=open('core/release_roots.resid').read(); m=re.search(r'pinned_roots\(\) \{ return \"(.*)\"; \}', s); sys.stdout.write(m.group(1).encode().decode('unicode_escape') if m else '')" > "$d/.roots"
        roots="$d/.roots"
    fi
    [ -s "$roots" ] || die "no roots pinned in core/release_roots.resid: run the roots step first"
    "$ROOT/$TOOL" verify "$roots" "$d" "$d/pylond.proof"
    rm -f "$d/.roots"
    echo
    echo "Verified against the pinned roots. Attach to the GitHub release (as a"
    echo "draft, before publishing it, so the APK build finds them):"
    for f in pylond-x86_64 pylond-aarch64 pylond.release pylond.proof; do echo "  $d/$f"; done
    echo "and commit $log to the pylond-log branch (append-only)."
    ;;

*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
