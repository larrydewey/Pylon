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
trap 'kill $(cat "$WORK"/sshd.pid "$WORK"/target.pid 2>/dev/null) 2>/dev/null; kill $SSH_AGENT_PID 2>/dev/null; rm -rf "$WORK"' EXIT

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
Subsystem sftp internal-sftp
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
kill $FWD 2>/dev/null; wait $FWD 2>/dev/null
# SOCKS5 (-D) and remote (-R) forwarding, against the same web server.
DPORT=$((PORT + 6)); RPORT=$((PORT + 7))
"$PYLON" -p $PORT -N -D $DPORT -R $RPORT:127.0.0.1:$WPORT "$USER_NAME@127.0.0.1" 2> fwd2.log & FWD=$!
for _ in $(seq 50); do grep -q "SOCKS5" fwd2.log && grep -q "from here" fwd2.log && break; sleep 0.1; done
check "socks: an IPv4 address through -D"      0 "forwarded-ok" \
    curl -s --socks5 "127.0.0.1:$DPORT" "http://127.0.0.1:$WPORT/small.txt"
check "socks: a host name, resolved by the server" 0 "forwarded-ok" \
    curl -s --socks5-hostname "127.0.0.1:$DPORT" "http://localhost:$WPORT/small.txt"
check "socks: 5 MiB intact"                    0 "$(sha256sum www/big.bin | cut -d' ' -f1)" \
    bash -c "curl -s --socks5 127.0.0.1:$DPORT http://127.0.0.1:$WPORT/big.bin | sha256sum"
check "socks: a name with odd bytes is refused" 97 "" \
    curl -s --socks5-hostname "127.0.0.1:$DPORT" "http://a_b.example:$WPORT/"
check "remote: the server's port reaches here" 0 "forwarded-ok" \
    curl -s "http://127.0.0.1:$RPORT/small.txt"
check "remote: the server bound loopback only" 0 "" \
    bash -c "P=\$(printf '%04X' $RPORT); grep -q \" 0100007F:\$P 00000000:0000 0A\" /proc/net/tcp && ! grep -q \" 00000000:\$P 00000000:0000 0A\" /proc/net/tcp"
kill $FWD $WEB 2>/dev/null; wait $FWD $WEB 2>/dev/null
check "remote: refuses a non-loopback bind"    2 "only loopback" \
    "$PYLON" -p $PORT -N -R 0.0.0.0:$RPORT:127.0.0.1:$WPORT "$USER_NAME@127.0.0.1"
check "forward: refuses a non-loopback bind"   2 "only loopback" \
    "$PYLON" -p $PORT -N -L 0.0.0.0:$LPORT:127.0.0.1:$WPORT "$USER_NAME@127.0.0.1"

# --- SFTP get / put -------------------------------------------------------------
head -c 3145728 /dev/urandom > up.bin; : > empty.bin
RDIR="$WORK/remote"; mkdir -p "$RDIR"
check "sftp: put 3 MiB"                        0 "3145728 bytes" \
    "$PYLON" put -p $PORT up.bin "$USER_NAME@127.0.0.1:$RDIR/up.bin"
check "sftp: the server has the same bytes"    0 "$(sha256sum up.bin | cut -d' ' -f1)" \
    sha256sum "$RDIR/up.bin"
check "sftp: get it back intact"               0 "$(sha256sum up.bin | cut -d' ' -f1)" \
    bash -c "'$PYLON' get -p $PORT '$USER_NAME@127.0.0.1:$RDIR/up.bin' down.bin 2>/dev/null && sha256sum down.bin"
check "sftp: refuses to replace a local file"  1 "not replaced" \
    "$PYLON" get -p $PORT "$USER_NAME@127.0.0.1:$RDIR/up.bin" down.bin
check "sftp: --force replaces it"              0 "3145728 bytes" \
    "$PYLON" get -p $PORT --force "$USER_NAME@127.0.0.1:$RDIR/up.bin" down.bin
check "sftp: an empty file"                    0 "0 bytes" \
    "$PYLON" put -p $PORT empty.bin "$USER_NAME@127.0.0.1:$RDIR/empty.bin"
check "sftp: a missing remote file"            1 "cannot open" \
    "$PYLON" get -p $PORT "$USER_NAME@127.0.0.1:$RDIR/nope" nope.bin
check "sftp: escape bytes in a name are shown escaped" 1 'x1b.31mred on the server' \
    "$PYLON" get -p $PORT "$USER_NAME@127.0.0.1:$RDIR/$(printf '\033[31mred')" red.bin

# --- ProxyJump ------------------------------------------------------------------
# A second sshd is the target, with its own host key; the first is the jump.
JT=$((PORT + 5))
sed -e "s/^Port .*/Port $JT/" -e "s#^PidFile .*#PidFile $WORK/target.pid#" -e "/^HostKey/d" sshd_config > target_config
echo "HostKey $WORK/host_ecdsa" >> target_config
"$SSHD" -f target_config -E "$WORK/target.log"; sleep 0.5
check "jump: an unpinned target is refused"     1 "does not trust a key on first use" \
    "$PYLON" -J "$USER_NAME@127.0.0.1:$PORT" -p $JT "$USER_NAME@127.0.0.1" true
check "jump: pin the target through the jump"   0 "pinned" \
    "$PYLON" pin -J "$USER_NAME@127.0.0.1:$PORT" -p $JT 127.0.0.1 "$(fp host_ecdsa.pub)"
check "jump: run a command on the target"       0 "via-jump" \
    "$PYLON" -J "$USER_NAME@127.0.0.1:$PORT" -p $JT "$USER_NAME@127.0.0.1" "echo via-jump"
check "jump: the target saw the jump host"      0 "" \
    grep -q "Connection from 127.0.0.1" "$WORK/target.log"
check "jump: the jump host relayed (direct-tcpip)" 0 "" \
    grep -q "direct-tcpip" sshd.log
check "jump: SFTP through the jump"             0 "3145728 bytes" \
    "$PYLON" get -J "$USER_NAME@127.0.0.1:$PORT" -p $JT "$USER_NAME@127.0.0.1:$RDIR/up.bin" viajump.bin
check "jump: nothing listening behind the jump" 1 "pylon:" \
    "$PYLON" -J "$USER_NAME@127.0.0.1:$PORT" -p 1 "$USER_NAME@127.0.0.1" true
kill "$(cat "$WORK/target.pid")" 2>/dev/null

# --- the Pylon protocol (EXPERIMENTAL): pylond, UDP, roaming --------------------
PYLOND="$(dirname "$PYLON")/pylond"
if [ -x "$PYLOND" ]; then
    mkdir -p www2 && echo pylon-proto-ok > www2/small.txt && head -c 3000000 /dev/urandom > www2/big.bin
    W2=$((PORT + 9)); L2=$((PORT + 10)); L3=$((PORT + 11))
    ( cd www2 && exec python3 -m http.server $W2 --bind 127.0.0.1 ) > /dev/null 2>&1 & WEB2=$!
    "$PYLON" -p $PORT -N -L $L2:127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pp.log & PP=$!
    for _ in $(seq 100); do grep -q "forwarding" pp.log && break; sleep 0.2; done
    PPORT=$(sed -n 's/.*session to 127.0.0.1:\([0-9]*\).*/\1/p' pp.log)
    check "pylon protocol: SSH closed after the bootstrap" 0 "SSH closed" cat pp.log
    check "pylon protocol: a file through -L"      0 "pylon-proto-ok" \
        curl -s -m 10 "http://127.0.0.1:$L2/small.txt"
    check "pylon protocol: 3 MB intact (reliable streams)" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "curl -s -m 60 http://127.0.0.1:$L2/big.bin | sha256sum"
    check "pylond: stored by hash, 0500 in a 0700 directory" 0 "500 700" \
        bash -c "stat -c %a \$HOME/.cache/pylon/pylond-* | head -1 | tr '\\n' ' '; stat -c %a \$HOME/.cache/pylon"
    check "pylond: silent to an unauthenticated datagram" 0 "no reply" \
        python3 -c "
import socket, os
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.5)
s.sendto(bytes([1, 0, 0, 0]) + os.urandom(1264), ('127.0.0.1', $PPORT))
s.sendto(os.urandom(64), ('127.0.0.1', $PPORT))
try:
    s.recvfrom(4096); print('replied')
except socket.timeout:
    print('no reply')"
    kill $PP 2>/dev/null; wait $PP 2>/dev/null
    # Roaming: the client moves to a new UDP socket mid-transfer.
    PYLON_TEST_REBIND_AFTER=300 "$PYLON" -p $PORT -N -L $L3:127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pr.log & PR=$!
    for _ in $(seq 100); do grep -q "forwarding" pr.log && break; sleep 0.2; done
    check "pylon protocol: roaming mid-transfer, 3 MB intact" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "curl -s -m 60 http://127.0.0.1:$L3/big.bin | sha256sum"
    check "pylon protocol: the client did change sockets" 0 "moved to a new UDP socket" cat pr.log
    kill $PR $WEB2 2>/dev/null; wait $PR $WEB2 2>/dev/null
    check "pylon protocol: a terminal (type, resize, paste, exit status)" 0 "interactive ok" \
        python3 "$(dirname "$HOSTILE")/pty_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: a terminal that roams mid-session" 0 "interactive ok" \
        env PYLON_TEST_REBIND_AFTER=60 python3 "$(dirname "$HOSTILE")/pty_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: re-attach from a new client (screen and shell kept)" 0 "reattach ok" \
        python3 "$(dirname "$HOSTILE")/attach_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: one session daemon serves every client" 0 "1" \
        bash -c "pgrep -fc 'pylond-.* serve'"
    check "pylon protocol: --pylond with a COMMAND is refused" 2 "not a COMMAND" \
        "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1" true
    pkill -f "pylond-.* serve" 2>/dev/null
else
    echo "skip pylon protocol (no $PYLOND)"
fi

# --- an agent with no acceptable key -----------------------------------------
ssh-add -q -D; ssh-keygen -q -t ed25519 -N '' -f stranger; ssh-add -q stranger
check "unknown user key fails cleanly"         1 "accepted none" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true

# --- post-quantum hybrid (mlkem768x25519-sha256) ------------------------------
# OpenSSH 9.6 here has no ML-KEM, so a reference server built on OpenSSL's
# primitives (pq_server.py) checks the hybrid exchange end to end.
PQPORT=$((PORT + 8)); PQSEED=0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526
PQFP=$(python3 -c "
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
import hashlib, base64, struct
pk = ed25519.Ed25519PrivateKey.from_private_bytes(bytes.fromhex('$PQSEED')).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
b = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + pk
print('SHA256:' + base64.b64encode(hashlib.sha256(b).digest()).decode().rstrip('='))")
python3 "$(dirname "$HOSTILE")/pq_server.py" $PQPORT $PQSEED ok > pq.log 2>&1 & PQ=$!
sleep 0.5
check "pq: pin verifies the hybrid exchange's signature" 0 "pinned" \
    "$PYLON" pin -p $PQPORT 127.0.0.1 "$PQFP"
check "pq: keys agree in both directions"      1 "post-quantum handshake verified" \
    "$PYLON" -p $PQPORT "$USER_NAME@127.0.0.1" true
check "pq: the server decrypted our packet"    0 "SERVER-DECRYPTED type 5: ssh-userauth" \
    cat pq.log
kill $PQ 2>/dev/null; wait $PQ 2>/dev/null
python3 "$(dirname "$HOSTILE")/pq_server.py" $PQPORT $PQSEED bad-ct > pq2.log 2>&1 & PQ=$!
sleep 0.5
check "pq: a corrupted ML-KEM ciphertext fails the signature" 1 "does not verify" \
    "$PYLON" -p $PQPORT "$USER_NAME@127.0.0.1" true
kill $PQ 2>/dev/null; wait $PQ 2>/dev/null

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
