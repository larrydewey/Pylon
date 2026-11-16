#!/usr/bin/env bash
# One command for a whole Pylon release (tools/release/CEREMONY.md):
#
#   tools/release/release.sh VERSION [--keys DIR] [--notes FILE] [--yes] [--no-push] [--no-wait]
#
# From a clean master that matches origin, on the release machine:
#   1. the app's version becomes VERSION (its version code one higher), committed;
#   2. both pylond are built with the pinned toolchain, and the unsigned
#      manifest written (release/VERSION/, counter one above the log's);
#   3. pylond is rebuilt independently and compared, then the manifest is
#      signed with every release key in DIR (at least the quorum);
#   4. the release is appended to a copy of the log, the head signed, the
#      proof written, and everything verified against the keys this commit
#      pins, before anything leaves the machine;
#   5. master, the pylond-log branch and the tag vVERSION are pushed, the
#      GitHub release is created with the four pylond files and published;
#   6. the APK workflow's run for it is followed until the APK is attached
#      (--no-wait skips this).
#
# DIR (or $PYLON_RELEASE_KEYS) holds the private keys: rel*.key (release
# keys) and one log*.key (the log key). Nothing is pushed until step 5, and
# a run that stopped can be started again: finished steps are recognized
# and skipped. --no-push stops before step 5, to look at release/VERSION
# first; the same command without it then publishes.
#
# Needs: docker, gh (logged in), git with push access, the Resid compiler
# tools/release/toolchain.env pins (residc), python3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

VERSION=""; KEYS="${PYLON_RELEASE_KEYS:-}"; NOTES=""; YES=0; WAIT=1; PUSH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --keys) KEYS="${2:?--keys DIR}"; shift 2 ;;
        --notes) NOTES="${2:?--notes FILE}"; shift 2 ;;
        --yes) YES=1; shift ;;
        --no-wait) WAIT=0; shift ;;
        --no-push) PUSH=0; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) [ -z "$VERSION" ] || die "one VERSION"; VERSION="$1"; shift ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh VERSION (as 0.1.4) [--keys DIR] [--notes FILE] [--yes] [--no-push] [--no-wait]"
TAG="v$VERSION"
REL="release/$VERSION"
TOOL=build/pylon-release
export CEREMONY_QUIET=1

# ── checks: nothing is changed before all of them pass ───────────────────
step "checks"
[ -n "$KEYS" ] || die "no keys: give --keys DIR or set PYLON_RELEASE_KEYS (CEREMONY.md, 'The release machine')"
[ -d "$KEYS" ] || die "no key directory $KEYS (is the drive mounted?)"
KEYS="$(cd "$KEYS" && pwd)"
case "$KEYS/" in "$ROOT"/*) die "the keys are inside the repository ($KEYS): move them out" ;; esac
mapfile -t RELKEYS < <(find "$KEYS" -maxdepth 1 -name 'rel*.key' | sort)
mapfile -t LOGKEYS < <(find "$KEYS" -maxdepth 1 -name 'log*.key' | sort)
[ "${#RELKEYS[@]}" -ge 2 ] || die "$KEYS holds ${#RELKEYS[@]} release key(s) (rel*.key); a release needs at least 2"
[ "${#LOGKEYS[@]}" -eq 1 ] || die "$KEYS holds ${#LOGKEYS[@]} log keys (log*.key); exactly one is needed"
for k in "${RELKEYS[@]}" "${LOGKEYS[@]}"; do
    m="$(stat -c %a "$k")"
    [ "$m" = 600 ] || [ "$m" = 400 ] || die "$k is readable by others (mode $m): chmod 600 it"
done
for c in docker gh git python3 residc; do command -v "$c" > /dev/null || die "$c is not on PATH"; done
REPO=""
if [ "$PUSH" = 1 ]; then
    gh auth status > /dev/null 2>&1 || die "gh is not logged in (gh auth login)"
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || die "gh cannot tell which GitHub repository origin is"
fi
[ "$(git branch --show-current)" = master ] || die "not on master"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes: commit or stash them first"
git fetch -q origin master pylond-log --tags || die "cannot fetch from origin"
LOCAL="$(git rev-parse HEAD)"; REMOTE="$(git rev-parse origin/master)"
BUMP_DONE=0
grep -q "^version: $VERSION+" app/pubspec.yaml && BUMP_DONE=1
if [ "$BUMP_DONE" = 1 ]; then
    # A re-run: the bump may be committed here and not pushed yet.
    git merge-base --is-ancestor "$REMOTE" "$LOCAL" || die "master and origin/master have diverged"
else
    [ "$LOCAL" = "$REMOTE" ] || die "master is not origin/master: pull or push first"
fi
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$LOCAL" ] || die "$TAG already exists, on another commit"
fi
docker info > /dev/null 2>&1 || die "docker is not running"
bash tools/release/build-pylond.sh --check || die "the Resid compiler is not the one this commit's releases are built with"

# The log: the pylond-log branch's worktree, made when there is none.
LOGWT="$(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/pylond-log$/{print w}')"
if [ -z "$LOGWT" ]; then
    LOGWT="$ROOT/build/pylond-log"
    git worktree add -q "$LOGWT" pylond-log
fi
[ -z "$(git -C "$LOGWT" status --porcelain)" ] || die "the log worktree $LOGWT has uncommitted changes"
git -C "$LOGWT" merge -q --ff-only origin/pylond-log || die "the pylond-log branch in $LOGWT cannot fast-forward to origin's"
LOG="$LOGWT/log"
TOP=0
for e in "$LOG"/entries/*.release; do
    [ -f "$e" ] || continue
    c="$(sed -n 's/^counter //p' "$e")"
    [ "$c" -gt "$TOP" ] && TOP="$c"
done
# This version already in the log (a re-run after step 4) keeps its counter.
COUNTER=$((TOP + 1))
for e in "$LOG"/entries/*.release; do
    [ -f "$e" ] && grep -qx "version $VERSION" "$e" && COUNTER="$(sed -n 's/^counter //p' "$e")"
done

PREV="$(git tag -l 'v*' --sort=-v:refname | grep -vx "$TAG" | head -1)"
echo "release $TAG: pylond $VERSION, release counter $COUNTER (the log's highest is $TOP)"
echo "  from master $(git rev-parse --short HEAD), previous release ${PREV:-none}"
echo "  release keys: ${RELKEYS[*]##*/}; log key: ${LOGKEYS[0]##*/} (from $KEYS)"
echo "  log: $LOG"
if [ "$YES" != 1 ]; then
    read -r -p "Go ahead? [y/N] " a
    [ "$a" = y ] || [ "$a" = Y ] || die "stopped"
fi

# ── 1. the app's version ─────────────────────────────────────────────────
step "1. the app's version"
if [ "$BUMP_DONE" = 1 ]; then
    echo "app/pubspec.yaml already says $VERSION"
else
    code="$(sed -n 's/^version: [0-9.]*+\([0-9]*\)$/\1/p' app/pubspec.yaml)"
    [ -n "$code" ] || die "cannot read the version code from app/pubspec.yaml"
    sed -i "s/^version: .*/version: $VERSION+$((code + 1))/" app/pubspec.yaml
    git commit -q -m "Pylon $VERSION" -m "App version $VERSION (version code $((code + 1)))." -- app/pubspec.yaml
    echo "version: $VERSION+$((code + 1)), committed"
fi

# ── 2-3. build, check, sign ──────────────────────────────────────────────
step "2. pylond, built with the pinned toolchain"
if [ -f "$REL/pylond.release" ] && [ -f "$REL/BUILDINFO" ]; then
    [ "$(sed -n 's/^pylon commit //p' "$REL/BUILDINFO")" = "$(git rev-parse HEAD)" ] \
        || die "$REL was built from another commit: remove it (rm -rf $REL) and run again"
    echo "$REL is built"
else
    rm -rf "$REL"
    bash tools/release/ceremony.sh build "$VERSION" "$COUNTER"
fi

step "3. an independent rebuild, then the release keys' signatures"
sigs() { grep -c '^sig ' "$REL/pylond.release" || true; }
if [ "$(sigs)" -ge "${#RELKEYS[@]}" ]; then
    echo "signed $(sigs) times"
else
    # check-sign rebuilds pylond and signs only if the code images match;
    # one rebuild covers every key on this machine.
    bash tools/release/ceremony.sh check-sign "$REL" "${RELKEYS[0]}"
    for k in "${RELKEYS[@]:1}"; do "$TOOL" sign "$REL/pylond.release" "$k" > /dev/null; echo "signed with ${k##*/}"; done
fi

# ── 4. the log, in a copy until it verifies ──────────────────────────────
step "4. the log entry, the signed head, the proof"
ROOTS="$(mktemp)"
bash tools/release/ceremony.sh pinned-roots > "$ROOTS"
if [ -f "$REL/pylond.proof" ] && "$TOOL" verify "$ROOTS" "$REL" "$REL/pylond.proof" > /dev/null 2>&1; then
    echo "$REL/pylond.proof verifies"
else
    STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
    cp -a "$LOG" "$STAGE/log"
    bash tools/release/ceremony.sh publish "$REL" "$STAGE/log" "${LOGKEYS[0]}"
    rm -rf "$LOG" && cp -a "$STAGE/log" "$LOG"
fi
rm -f "$ROOTS"
if [ -n "$(git -C "$LOGWT" status --porcelain)" ]; then
    git -C "$LOGWT" add log
    git -C "$LOGWT" commit -q -m "pylond $VERSION (release $COUNTER)"
    echo "log committed on pylond-log"
fi

if [ "$PUSH" != 1 ]; then
    echo
    echo "Ready, nothing pushed (--no-push): $REL holds the signed, logged release,"
    echo "master the version commit and $LOGWT the log commit. Publish with the"
    echo "same command without --no-push."
    exit 0
fi

# ── 5. out: master, the log, the tag, the release ────────────────────────
step "5. push and publish"
git push -q origin master
git -C "$LOGWT" push -q origin pylond-log
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null || git tag -a "$TAG" -m "Pylon $VERSION"
git push -q origin "$TAG"
NOTEFILE="$(mktemp)"
if [ -n "$NOTES" ]; then cp "$NOTES" "$NOTEFILE"; else
    {
        echo "Pylon $VERSION, with pylond $VERSION (release $COUNTER): signed by $(sigs) release keys and logged."
        echo
        echo "Changes since ${PREV:-the start}:"
        echo
        git log --no-merges --format='- %s' ${PREV:+"$PREV"..}"$TAG" | grep -v "^- Pylon $VERSION\$"
        echo
        echo "The Android APK (pylon-$TAG.apk) and SHA256SUMS are attached by CI once the build finishes."
    } > "$NOTEFILE"
fi
ASSETS=("$REL/pylond-x86_64" "$REL/pylond-aarch64" "$REL/pylond.release" "$REL/pylond.proof")
if gh release view "$TAG" -R "$REPO" > /dev/null 2>&1; then
    gh release upload "$TAG" "${ASSETS[@]}" --clobber -R "$REPO"
else
    # A draft first: the APK workflow runs on publishing and needs the files there.
    gh release create "$TAG" --draft --verify-tag --title "Pylon $VERSION" --notes-file "$NOTEFILE" -R "$REPO" "${ASSETS[@]}" > /dev/null
fi
rm -f "$NOTEFILE"
gh release edit "$TAG" --draft=false --latest -R "$REPO" > /dev/null
URL="$(gh release view "$TAG" -R "$REPO" --json url --jq .url)"
echo "published: $URL"

# ── 6. the APK ───────────────────────────────────────────────────────────
[ "$WAIT" = 1 ] || { echo "not waiting for the APK build (--no-wait)"; exit 0; }
step "6. the APK build"
RUN=""
for _ in $(seq 30); do
    RUN="$(gh run list -R "$REPO" --workflow apk.yml --event release --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    [ -n "$RUN" ] && break
    sleep 10
done
[ -n "$RUN" ] || die "no APK workflow run for $TAG appeared; look at the Actions tab"
echo "following https://github.com/$REPO/actions/runs/$RUN"
if gh run watch "$RUN" -R "$REPO" --exit-status --interval 30 > /dev/null; then
    echo "done: $URL"
    gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' | sed 's/^/  /'
else
    die "the APK build failed: gh run view $RUN --log-failed"
fi
