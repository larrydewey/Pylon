#!/usr/bin/env bash
# Interoperability tests of the pylon CLI against OpenSSH's sshd (SPEC 16).
#
# Starts an unprivileged-port sshd on 127.0.0.1 with fresh keys for every
# case, restricted to one cipher / host key / user key at a time, and
# checks both what must work and what must be refused.
#
#   tests/interop.sh [path/to/pylon]
#
# Needs: sshd, ssh-keygen, ssh-agent, ssh-add (OpenSSH >= 9.6).
set -uo pipefail

PYLON="$(cd "$(dirname "${1:-build/pylon}")" && pwd)/$(basename "${1:-build/pylon}")"
HOSTILE="$(cd "$(dirname "$0")" && pwd)/hostile_server.py"
SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
WORK="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
PASS=0
FAIL=0
trap 'kill $(cat "$WORK"/sshd.pid 2>/dev/null) 2>/dev/null; kill $SSH_AGENT_PID 2>/dev/null; rm -rf "$WORK"' EXIT

cd "$WORK"
for t in ed25519 ecdsa rsa; do
    ssh-keygen -q -t $t -N '' -f host_$t
    ssh-keygen -q -t $t -N '' -f user_$t
done
ssh-keygen -q -t ed25519 -N '' -f host_other
cat user_*.pub > authorized_keys
chmod 600 authorized_keys
mkdir -p /run/sshd 2>/dev/null || true
export PYLON_HOME="$WORK/pylon"
USER_NAME="$(id -un)"

start_sshd() {   # extra sshd options...
    kill "$(cat sshd.pid 2>/dev/null)" 2>/dev/null; sleep 0.3
    cat > sshd_config <<EOF
Port $PORT
ListenAddress 127.0.0.1
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
StrictModes no
UsePAM no
LogLevel DEBUG1
EOF
    printf '%s\n' "$@" >> sshd_config
    "$SSHD" -f sshd_config -E "$WORK/sshd.log" || { echo "sshd failed to start"; exit 1; }
    sleep 0.5
}

fp() { ssh-keygen -lf "$1" | cut -d' ' -f2; }

check() {   # name expected-exit expected-output-substring command...
    local name="$1" want="$2" grepfor="$3"; shift 3
    local out; out="$("$@" 2>&1)"; local got=$?
    if [ "$got" = "$want" ] && { [ -z "$grepfor" ] || grep -q -- "$grepfor" <<<"$out"; }; then
        PASS=$((PASS + 1)); echo "ok   $name"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $name (exit $got, want $want)"; sed 's/^/     | /' <<<"$out"
    fi
}

eval "$(ssh-agent -a "$WORK/agent.sock")" > /dev/null

# --- host trust ------------------------------------------------------------
start_sshd "HostKey $WORK/host_ed25519"
ssh-add -q user_ed25519
check "unpinned host is refused before auth"  1 "does not trust a key on first use" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
check "pin refuses a wrong fingerprint"        1 "NOT pinned" \
    "$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_other.pub)"
check "pin accepts the out-of-band fingerprint" 0 "pinned" \
    "$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_ed25519.pub)"
check "exec, stdout and exit status"           7 "hello" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" 'echo hello; exit 7'
check "used publickey-hostbound"               0 "" \
    grep -q "method publickey-hostbound-v00@openssh.com" sshd.log

# --- host key change ---------------------------------------------------------
start_sshd "HostKey $WORK/host_other"
check "changed host key is refused"            1 "HOST KEY HAS CHANGED" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true

# --- ciphers -----------------------------------------------------------------
for c in chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com; do
    start_sshd "HostKey $WORK/host_ed25519" "Ciphers $c"
    check "cipher $c"                          0 "x$c" \
        "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" "echo x$c"
done
start_sshd "HostKey $WORK/host_ed25519" "Ciphers aes256-ctr" "MACs hmac-sha2-256-etm@openssh.com"
check "non-AEAD cipher is refused"             1 "no common AEAD cipher" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true

# --- key exchange ------------------------------------------------------------
start_sshd "HostKey $WORK/host_ed25519" "KexAlgorithms diffie-hellman-group14-sha256"
check "finite-field DH is refused"             1 "no common key exchange" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true

# --- host key types ----------------------------------------------------------
for t in ecdsa rsa; do
    start_sshd "HostKey $WORK/host_$t"
    "$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_$t.pub)" > /dev/null
    check "host key $t"                        0 "host-$t" \
        "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" "echo host-$t"
done

# --- user key types ----------------------------------------------------------
start_sshd "HostKey $WORK/host_ed25519"
for t in ecdsa rsa; do
    ssh-add -q -D; ssh-add -q user_$t
    check "user key $t"                        0 "user-$t" \
        "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" "echo user-$t"
done
check "rsa user key signs with rsa-sha2-512"   0 "" \
    grep -q "pkalg rsa-sha2-512" sshd.log

# --- large output (window adjust, many packets) ------------------------------
ssh-add -q -D; ssh-add -q user_ed25519
check "4 MiB of output"                        0 "4194304" \
    bash -c "'$PYLON' -p $PORT '$USER_NAME@127.0.0.1' 'head -c 4194304 /dev/zero' | wc -c"

# --- interactive shell on a pty -----------------------------------------------
check "interactive shell: type, resize, paste, exit status" 0 "interactive ok" \
    python3 "$(dirname "$HOSTILE")/pty_drive.py" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1"
check "interactive without a terminal is refused" 2 "needs a terminal" \
    bash -c "'$PYLON' -p $PORT '$USER_NAME@127.0.0.1' < /dev/null"

# --- keystroke timing on the wire (SPEC 5) -------------------------------------
# A recording proxy on another port, pinned with the same key.
TPORT=$((PORT + 2))
grep "^127.0.0.1:$PORT " "$PYLON_HOME/known_hosts" | sed "s/^127.0.0.1:$PORT /127.0.0.1:$TPORT /" >> "$PYLON_HOME/known_hosts"
TIMING="$(dirname "$HOSTILE")/timing_check.py"
check "keystrokes: fixed 20 ms ticks, one size, chaff" 0 "timing obfuscated" \
    python3 "$TIMING" $PORT $TPORT -- "$PYLON" -p {port} "$USER_NAME@127.0.0.1"
check "keystrokes: opting out shows plain timing" 0 "plain timing as expected" \
    python3 "$TIMING" --expect-plain $PORT $TPORT -- "$PYLON" --no-obfuscate-keystrokes -p {port} "$USER_NAME@127.0.0.1"

# --- local port forwarding ----------------------------------------------------
mkdir -p www && head -c 5242880 /dev/urandom > www/big.bin && echo forwarded-ok > www/small.txt
WPORT=$((PORT + 3)); LPORT=$((PORT + 4))
( cd www && exec python3 -m http.server $WPORT --bind 127.0.0.1 ) > /dev/null 2>&1 & WEB=$!
"$PYLON" -p $PORT -N -L $LPORT:127.0.0.1:$WPORT "$USER_NAME@127.0.0.1" 2> fwd.log & FWD=$!
for _ in $(seq 50); do grep -q forwarding fwd.log && break; sleep 0.1; done
check "forward: a small file through -L"       0 "forwarded-ok" \
    curl -s "http://127.0.0.1:$LPORT/small.txt"
check "forward: 5 MiB intact (flow control)"  0 "$(sha256sum www/big.bin | cut -d' ' -f1)" \
    bash -c "curl -s http://127.0.0.1:$LPORT/big.bin | sha256sum"
check "forward: four connections at once"      0 "4 of 4" \
    bash -c "for i in 1 2 3 4; do curl -s http://127.0.0.1:$LPORT/small.txt > c\$i.out & done; wait; echo \"\$(cat c?.out | grep -c forwarded-ok) of 4\""
kill $FWD $WEB 2>/dev/null; wait $FWD $WEB 2>/dev/null
check "forward: refuses a non-loopback bind"   2 "only loopback" \
    "$PYLON" -p $PORT -N -L 0.0.0.0:$LPORT:127.0.0.1:$WPORT "$USER_NAME@127.0.0.1"

# --- an agent with no acceptable key -----------------------------------------
ssh-add -q -D; ssh-keygen -q -t ed25519 -N '' -f stranger; ssh-add -q stranger
check "unknown user key fails cleanly"         1 "accepted none" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true

# --- hostile servers (refused before any key exchange completes) -------------
hostile() {   # scenario expected-substring
    local hp=$((PORT + 1))
    python3 "$HOSTILE" $hp "$1" & local pid=$!
    sleep 0.4
    check "hostile: $1"                        1 "$2" \
        "$PYLON" pin -p $hp 127.0.0.1 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
}
hostile no-strict    "strict key exchange"
hostile ignore-first "first packet is not KEXINIT"
hostile huge-length  "malformed packet"
hostile long-banner  "banner line is too long"
hostile ssh1         "does not speak SSH 2.0"
hostile bad-padding  "malformed packet"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
