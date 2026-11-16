#!/usr/bin/env bash
# Pylon's DNSSEC validator against live DNS (SPEC 6.4), compared name by
# name with an independent validator, BIND's delv. Needs real DNS on port
# 53 (the CI job "dnssec-live"; the build sandbox has none).
#
#   tests/dnssec_live.sh path/to/pylon [RESOLVER]
#
# For every name below, `pylon sshfp` and `delv SSHFP` must agree on the
# outcome (secure with records, secure without records, insecure, bogus),
# and for secure records on the SHA-256 fingerprints themselves. Pylon may
# answer "indeterminate" only where SPEC 6.4 lists a limit (an alias, a
# wildcard, RSA zone keys under 2048 bits); that is reported, not failed.
# At least one name must reach each outcome, or the list needs updating.
set -uo pipefail
PYLON="$1"
RES="${2:-1.1.1.1}"
export PYLON_DNS="$RES"

# name: hosts whose operators publish SSHFP in signed zones; signed zones
# without SSHFP; unsigned zones; and a deliberately broken signed zone.
NAMES=(
  db.debian.org people.debian.org master.debian.org
  freefall.freebsd.org
  example.com isc.org cloudflare.com ietf.org
  github.com amazon.com
  dnssec-failed.org
)

delv_outcome() {   # name -> secure-records | secure-none | insecure | bogus | error
    local out; out="$(delv @"$RES" SSHFP "$1" 2>&1)"
    if grep -q "resolution failed\|validation failed\|broken trust chain\|no valid RRSIG" <<<"$out"; then echo bogus
    elif grep -q "; negative response, fully validated" <<<"$out"; then echo secure-none
    elif grep -q "; fully validated" <<<"$out"; then echo secure-records
    elif grep -q "; unsigned answer\|; negative response, unsigned answer" <<<"$out"; then echo insecure
    else echo error; fi
}

pylon_outcome() {  # pylon sshfp's first line -> the same names, or indeterminate
    case "$1" in
        *"(only SHA-1 records"*) echo secure-records ;;
        *"does not exist)"*|"SSHFP: none for "*"(secure, DNSSEC-validated"*")") echo secure-none ;;
        "SSHFP: "*" SHA-256 record(s) for "*) echo secure-records ;;
        *": insecure ("*) echo insecure ;;
        *": BOGUS ("*) echo bogus ;;
        *"indeterminate"*) echo indeterminate ;;
        *) echo error ;;
    esac
}

norm() { tr 'A-F' 'a-f' | tr -d ' ' ; }

PASS=0; FAIL=0; LIMIT=0
declare -A SEEN
for n in "${NAMES[@]}"; do
    d="$(delv_outcome "$n")"
    pout="$("$PYLON" sshfp "$n" 2>&1)"
    p="$(pylon_outcome "$(head -1 <<<"$pout")")"
    if [ "$d" = error ]; then
        echo "skip $n: delv gave no verdict"; continue
    fi
    if [ "$p" = indeterminate ]; then
        LIMIT=$((LIMIT + 1)); echo "limit $n: delv $d, pylon: $(head -1 <<<"$pout")"; continue
    fi
    if [ "$p" != "$d" ]; then
        FAIL=$((FAIL + 1)); echo "FAIL $n: delv $d, pylon $p"; sed 's/^/     | /' <<<"$pout"; continue
    fi
    if [ "$d" = secure-records ]; then
        # The SHA-256 fingerprints themselves: dig's records against pylon's.
        # "ALG 2 HEX" both ways (dig splits the hex with spaces; norm drops them).
        want="$(dig @"$RES" +short SSHFP "$n" | awk '$2 == 2' | norm | sort)"
        got="$(tail -n +2 <<<"$pout" | awk '$2 == 2' | norm | sort)"
        if [ "$want" != "$got" ]; then
            FAIL=$((FAIL + 1)); echo "FAIL $n: SHA-256 records differ"; echo "     | dig:   $want"; echo "     | pylon: $got"; continue
        fi
    fi
    PASS=$((PASS + 1)); SEEN[$d]=1; echo "ok   $n: $d"
done

for o in secure-records secure-none insecure bogus; do
    if [ -z "${SEEN[$o]:-}" ]; then FAIL=$((FAIL + 1)); echo "FAIL no name reached $o: update the list in tests/dnssec_live.sh"; fi
done
echo
echo "$PASS agreed, $FAIL failed, $LIMIT at a documented limit"
[ "$FAIL" = 0 ]
