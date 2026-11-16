#!/usr/bin/env bash
# Pylon's DNSSEC validator against live DNS (SPEC 6.4), compared name by
# name with an independent validator: the validating resolver's verdict. Needs real DNS on port
# 53 (the CI job "dnssec-live"; the build sandbox has none).
#
#   tests/dnssec_live.sh path/to/pylon [RESOLVER]
#
# For every name below, `pylon sshfp` and the validating resolver (its
# status and AD flag) must agree on the outcome (secure with records, secure without records, insecure, bogus),
# and for secure records on the SHA-256 fingerprints themselves. Pylon may
# answer "indeterminate" only where SPEC 6.4 lists a limit (an alias, a
# wildcard, RSA zone keys under 2048 bits); that is reported, not failed.
# At least one name must reach each outcome, or the list needs updating.
set -uo pipefail
PYLON="$1"
RES="${2:-1.1.1.1}"
export PYLON_DNS="$RES"

# Names: hosts expected to publish SSHFP in signed zones; signed zones
# without SSHFP; unsigned zones; deliberately broken signed zones. Several
# per outcome: zones change, and many (all of .org) still sign with RSA
# keys under 2048 bits, which Pylon reports as indeterminate (SPEC 6.4).
NAMES=(
  nic.cz www.nic.cz gitlab.nic.cz nlnetlabs.nl open.nlnetlabs.nl
  people.debian.org freefall.freebsd.org
  example.com cloudflare.com
  github.com amazon.com
  rhybar.cz sigfail.verteiltesysteme.net dnssec-failed.org
)

# The validating resolver's own verdict, read from the header, not from a
# tool's wording: SERVFAIL is bogus, the AD flag secure, an answer without
# it unsigned. (A resolver also says SERVFAIL when it cannot reach a zone:
# a bogus verdict from it is rechecked with checking disabled, and only a
# zone that then answers counts as bogus.)
resolver_outcome() {   # name -> secure-records | secure-none | insecure | bogus | error
    local out st; out="$(dig @"$RES" +dnssec +tries=2 +time=5 SSHFP "$1" 2>&1)"
    st="$(sed -n 's/.*status: \([A-Z]*\),.*/\1/p' <<<"$out" | head -1)"
    if [ "$st" = SERVFAIL ]; then
        local cd; cd="$(dig @"$RES" +dnssec +cd +tries=2 +time=5 SSHFP "$1" 2>&1 | sed -n 's/.*status: \([A-Z]*\),.*/\1/p' | head -1)"
        if [ "$cd" = NOERROR ] || [ "$cd" = NXDOMAIN ]; then echo bogus; else echo error; fi
        return
    fi
    [ "$st" = NOERROR ] || [ "$st" = NXDOMAIN ] || { echo error; return; }
    if grep -q "^;; flags:[^;]* ad[ ;]" <<<"$out"; then
        if grep -qE "^[^;].*[[:space:]]IN[[:space:]]+SSHFP[[:space:]]" <<<"$out"; then echo secure-records; else echo secure-none; fi
    else
        echo insecure
    fi
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
    d="$(resolver_outcome "$n")"
    pout="$("$PYLON" sshfp "$n" 2>&1)"
    p="$(pylon_outcome "$(head -1 <<<"$pout")")"
    if [ "$d" = error ]; then
        echo "skip $n: the resolver gave no verdict"; continue
    fi
    if [ "$p" = indeterminate ]; then
        LIMIT=$((LIMIT + 1)); echo "limit $n: resolver $d, pylon: $(head -1 <<<"$pout")"; continue
    fi
    if [ "$p" != "$d" ]; then
        FAIL=$((FAIL + 1)); echo "FAIL $n: resolver $d, pylon $p"; sed 's/^/     | /' <<<"$pout"; continue
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
