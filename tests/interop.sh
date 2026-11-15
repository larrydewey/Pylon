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

# The seccomp mode of the process holding the listening socket on 127.0.0.1:$1.
listener_seccomp() {
    local hex ino p; hex=$(printf '%04X' "$1")
    ino=$(awk -v a="0100007F:$hex" '$2 == a && $4 == "0A" { print $10 }' /proc/net/tcp | head -1)
    [ -n "$ino" ] || return 1
    for p in /proc/[0-9]*; do
        if ls -l "$p/fd" 2>/dev/null | grep -q "socket:\[$ino\]"; then grep '^Seccomp:' "$p/status"; return 0; fi
    done
    return 1
}

check() {   # name expected-exit expected-output-substring command...
    local name="$1" want="$2" grepfor="$3"; shift 3
    # ONLY=REGEX runs just the matching checks (pinning always runs).
    if [ -n "${ONLY:-}" ] && ! grep -qE -- "$ONLY|pin accepts" <<<"$name"; then return 0; fi
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
check "the refusal names the old pin and its date" 1 "Pinned: $(fp host_ed25519.pub) on $(date -u +%Y-%m-%d)" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
check "re-pinning replaces the old key"         0 "pinned" \
    "$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_other.pub)"
check "the new key works"                       0 "after-repin" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" "echo after-repin"
start_sshd "HostKey $WORK/host_ed25519"
check "the replaced key is no longer trusted"   1 "HOST KEY HAS CHANGED" \
    "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
check "pin history records the change"         0 "re-pinned 127.0.0.1:$PORT $(fp host_other.pub) replacing $(fp host_ed25519.pub)" \
    "$PYLON" history 127.0.0.1:$PORT
check "pin history records refusals"           0 "refused 127.0.0.1:$PORT $(fp host_other.pub)" \
    "$PYLON" history 127.0.0.1:$PORT
"$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_ed25519.pub)" > /dev/null

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
start_sshd "HostKey $WORK/host_ed25519"
"$PYLON" pin -p $PORT 127.0.0.1 "$(fp host_ed25519.pub)" > /dev/null

# --- host certificates (SPEC 6.1.1), with no pins at all ----------------------
ssh-keygen -q -t ed25519 -N '' -f host_ca; ssh-keygen -q -t ed25519 -N '' -f other_ca
for v in good wrongname expired untrusted; do cp host_ecdsa host_cert_$v; cp host_ecdsa.pub host_cert_$v.pub; done
ssh-keygen -q -s host_ca -I good -h -n 127.0.0.1 -V -5m:+1h host_cert_good.pub
ssh-keygen -q -s host_ca -I wrong -h -n other.example -V -5m:+1h host_cert_wrongname.pub
ssh-keygen -q -s host_ca -I old -h -n 127.0.0.1 -V -2h:-1h host_cert_expired.pub
ssh-keygen -q -s other_ca -I other -h -n 127.0.0.1 -V -5m:+1h host_cert_untrusted.pub
CAH="$WORK/ca_home"; mkdir -p "$CAH"
start_sshd "HostKey $WORK/host_cert_good" "HostCertificate $WORK/host_cert_good-cert.pub"
check "certificate: refused while no CA is trusted" 1 "does not trust a key on first use" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
check "certificate: a CA for another domain does not count" 0 "trusting" \
    env PYLON_HOME="$CAH" "$PYLON" ca '*.example.org' "$(cat host_ca.pub)"
check "certificate: still refused" 1 "does not trust a key on first use" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
check "certificate: trust the CA for this host" 0 "trusting" \
    env PYLON_HOME="$CAH" "$PYLON" ca 127.0.0.1 "$(cat host_ca.pub)"
check "certificate: accepted without a pin" 0 "via-cert" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" "echo via-cert"
start_sshd "HostKey $WORK/host_cert_wrongname" "HostCertificate $WORK/host_cert_wrongname-cert.pub"
check "certificate: for another name is refused" 1 "not for 127.0.0.1" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
start_sshd "HostKey $WORK/host_cert_expired" "HostCertificate $WORK/host_cert_expired-cert.pub"
check "certificate: expired is refused" 1 "expired" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
start_sshd "HostKey $WORK/host_cert_untrusted" "HostCertificate $WORK/host_cert_untrusted-cert.pub"
check "certificate: from an untrusted CA is refused" 1 "CA you do not trust" \
    env PYLON_HOME="$CAH" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1" true
start_sshd "HostKey $WORK/host_ed25519"

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
check "app mode: a session over framed pipes" 0 "app ok" \
    python3 "$(dirname "$HOSTILE")/app_drive.py" "$PYLON" -p $PORT "$USER_NAME@127.0.0.1"
check "app mode: the agent reached through the app (Android's path)" 0 "agent through the app" \
    python3 "$(dirname "$HOSTILE")/app_drive.py" --bridge-agent "$PYLON" -p $PORT "$USER_NAME@127.0.0.1"
check "app mode: the emulator process (confined)" 0 "term process ok" \
    python3 "$(dirname "$HOSTILE")/term_proc.py" "$(dirname "$PYLON")/pylon-term"
FLUTTER="${FLUTTER:-$(command -v flutter || echo /home/user/tools/flutter/bin/flutter)}"
if [ -x "$FLUTTER" ] && [ -d "$(dirname "$HOSTILE")/../app" ]; then
    check "app: the Flutter app's process backend, end to end" 0 "All tests passed" \
        env PYLON_BIN_DIR="$(cd "$(dirname "$PYLON")" && pwd)" PYLON_TEST_TARGET="$USER_NAME@127.0.0.1" PYLON_TEST_PORT=$PORT \
        bash -c "cd '$(dirname "$HOSTILE")/../app' && '$FLUTTER' test test/process_backend_test.dart 2>&1"
else
    echo "skip app backend test (no flutter)"
fi
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
s.sendto(bytes([1, 0, 0, 0]) + os.urandom(1280), ('127.0.0.1', $PPORT))
s.sendto(os.urandom(64), ('127.0.0.1', $PPORT))
try:
    s.recvfrom(4096); print('replied')
except socket.timeout:
    print('no reply')"
    kill $PP 2>/dev/null; wait $PP 2>/dev/null
    # SOCKS5 (-D) over the Pylon protocol: the handshake runs in the client,
    # pylond connects (and resolves names).
    DP=$((PORT + 13))
    "$PYLON" -p $PORT -N -D $DP --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pd.log & PD=$!
    for _ in $(seq 100); do grep -q "SOCKS5" pd.log && break; sleep 0.2; done
    check "pylon protocol: SOCKS5 (-D), a host name resolved by pylond" 0 "pylon-proto-ok" \
        curl -s -m 10 --socks5-hostname "127.0.0.1:$DP" "http://localhost:$W2/small.txt"
    check "pylon protocol: SOCKS5 (-D), 3 MB intact" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "curl -s -m 60 --socks5 127.0.0.1:$DP http://127.0.0.1:$W2/big.bin | sha256sum"
    check "pylon protocol: SOCKS5 (-D), a closed port is refused (reply 5)" 7 "" \
        curl -s -m 10 --socks5 "127.0.0.1:$DP" "http://127.0.0.1:1/"
    check "pylon protocol: SOCKS5 (-D), a name with odd bytes is refused" 97 "" \
        curl -s -m 10 --socks5-hostname "127.0.0.1:$DP" "http://a_b.example:$W2/"
    kill $PD 2>/dev/null; wait $PD 2>/dev/null
    # Remote forwarding (-R) over the Pylon protocol: pylond (confined)
    # listens on its loopback, the client connects here.
    RP=$((PORT + 14))
    "$PYLON" -p $PORT -N -R $RP:127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pR.log & PRR=$!
    for _ in $(seq 100); do grep -q "from here" pR.log && break; sleep 0.2; done
    check "pylon protocol: -R, the server's port reaches here" 0 "pylon-proto-ok" \
        curl -s -m 10 "http://127.0.0.1:$RP/small.txt"
    check "pylon protocol: -R, 3 MB intact" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "curl -s -m 60 http://127.0.0.1:$RP/big.bin | sha256sum"
    check "pylon protocol: -R, pylond bound loopback only" 0 "" \
        bash -c "P=\$(printf '%04X' $RP); grep -q \" 0100007F:\$P 00000000:0000 0A\" /proc/net/tcp && ! grep -q \" 00000000:\$P 00000000:0000 0A\" /proc/net/tcp"
    check "pylon protocol: -R, the port is held by the confined daemon" 0 "Seccomp:	2" listener_seccomp $RP
    kill $PRR 2>/dev/null; wait $PRR 2>/dev/null
    "$PYLON" -p $PORT -N -R $RP:127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pR2.log & PRR=$!
    for _ in $(seq 100); do grep -q "from here" pR2.log && break; sleep 0.2; done
    check "pylon protocol: -R, a new client takes the port over" 0 "pylon-proto-ok" \
        curl -s -m 10 "http://127.0.0.1:$RP/small.txt"
    kill $PRR 2>/dev/null; wait $PRR 2>/dev/null
    # Files over the Pylon protocol: resumable get and put (pylond's
    # Landlock keeps it beneath \$HOME, so the remote side lives there).
    HD="pylon-interop-$PORT"; mkdir -p "$HOME/$HD"; head -c 3000000 /dev/urandom > pf.bin
    PFSUM="$(sha256sum pf.bin | cut -d' ' -f1)"
    check "pylon protocol: put 3 MB (a path under \$HOME)" 0 "3000000 bytes" \
        "$PYLON" put -p $PORT --pylond "$PYLOND" pf.bin "$USER_NAME@127.0.0.1:$HD/pf.bin"
    check "pylon protocol: pylond wrote the same bytes" 0 "$PFSUM" sha256sum "$HOME/$HD/pf.bin"
    check "pylon protocol: get it back intact" 0 "$PFSUM" \
        bash -c "'$PYLON' get -p $PORT --pylond '$PYLOND' '$USER_NAME@127.0.0.1:$HD/pf.bin' pg.bin 2>/dev/null && sha256sum pg.bin"
    check "pylon protocol: get refuses to replace a local file" 1 "or --resume to continue it" \
        "$PYLON" get -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1:$HD/pf.bin" pg.bin
    check "pylon protocol: an interrupted get" 1 "stopped" \
        env PYLON_TEST_STOP_AFTER=1000000 "$PYLON" get -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1:$HD/pf.bin" pi.bin
    check "pylon protocol: get --resume continues where it stopped" 0 "resumed at 983040" \
        "$PYLON" get -p $PORT --pylond "$PYLOND" --resume "$USER_NAME@127.0.0.1:$HD/pf.bin" pi.bin
    check "pylon protocol: the resumed get is intact" 0 "$PFSUM" sha256sum pi.bin
    check "pylon protocol: an interrupted put" 1 "stopped" \
        env PYLON_TEST_STOP_AFTER=1000000 "$PYLON" put -p $PORT --pylond "$PYLOND" pf.bin "$USER_NAME@127.0.0.1:$HD/pp.bin"
    check "pylon protocol: put --resume continues where it stopped" 0 "resumed at" \
        "$PYLON" put -p $PORT --pylond "$PYLOND" --resume pf.bin "$USER_NAME@127.0.0.1:$HD/pp.bin"
    check "pylon protocol: the resumed put is intact" 0 "$PFSUM" sha256sum "$HOME/$HD/pp.bin"
    check "pylon protocol: a missing remote file" 1 "no such file" \
        "$PYLON" get -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1:$HD/nope" nope.bin
    check "pylon protocol: a remote name with escape bytes is refused" 2 "printable ASCII" \
        "$PYLON" get -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1:$HD/$(printf '\033[31mred')" red2.bin
    check "pylon protocol: a put outside \$HOME is refused (Landlock)" 1 "cannot write the file" \
        "$PYLON" put -p $PORT --pylond "$PYLOND" pf.bin "$USER_NAME@127.0.0.1:$WORK/outside.bin"
    rm -rf "$HOME/$HD"
    # Roaming: the client moves to a new UDP socket mid-transfer.
    PYLON_TEST_REBIND_AFTER=300 "$PYLON" -p $PORT -N -L $L3:127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pr.log & PR=$!
    for _ in $(seq 100); do grep -q "forwarding" pr.log && break; sleep 0.2; done
    check "pylon protocol: roaming mid-transfer, 3 MB intact" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "curl -s -m 60 http://127.0.0.1:$L3/big.bin | sha256sum"
    check "pylon protocol: the client did change sockets" 0 "moved to a new UDP socket" cat pr.log
    # Rekeying every second during a transfer (the test hook; 2 minutes otherwise).
    PYLON_TEST_REKEY_SECS=1 "$PYLON" -p $PORT -N -L $((PORT + 12)):127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pk.log & PK=$!
    for _ in $(seq 100); do grep -q "forwarding" pk.log && break; sleep 0.2; done
    check "pylon protocol: rekeying mid-transfer, 3 MB intact" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "sleep 2.5; curl -s -m 60 --limit-rate 600k http://127.0.0.1:$((PORT + 12))/big.bin | sha256sum"
    check "pylon protocol: the keys did change" 0 "" bash -c "test \$(grep -c 'new session keys' pk.log) -ge 3"
    kill $PK 2>/dev/null; wait $PK 2>/dev/null
    kill $PR $WEB2 2>/dev/null; wait $PR $WEB2 2>/dev/null
    check "pylon protocol: a terminal (type, resize, paste, exit status)" 0 "interactive ok" \
        python3 "$(dirname "$HOSTILE")/pty_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: a terminal that roams mid-session" 0 "interactive ok" \
        env PYLON_TEST_REBIND_AFTER=60 python3 "$(dirname "$HOSTILE")/pty_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: re-attach from a new client (screen and shell kept)" 0 "reattach ok" \
        python3 "$(dirname "$HOSTILE")/attach_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    # One daemon for every client: the confined daemon, its terminal
    # broker, and the original process waiting on the daemon.
    check "pylon protocol: one session daemon serves every client" 0 "3" \
        bash -c "pgrep -fc 'pylond-.* serve'"
    check "pylond: confined (seccomp filter, no new privileges)" 0 "NoNewPrivs:	1 Seccomp:	2" \
        bash -c "for p in \$(pgrep -f 'pylond-[0-9a-f]* serve'); do grep -hE '^(NoNewPrivs|Seccomp):' /proc/\$p/status | tr '\\n' ' '; echo; done; true"
    check "pylon protocol: app mode over the Pylon protocol" 0 "app ok" \
        python3 "$(dirname "$HOSTILE")/app_drive.py" "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1"
    check "pylon protocol: --pylond with a COMMAND is refused" 2 "not a COMMAND" \
        "$PYLON" -p $PORT --pylond "$PYLOND" "$USER_NAME@127.0.0.1" true
    # Under load pylond answers an init with a cookie and does no
    # asymmetric work until the init comes back with mac2 (a fresh daemon
    # started with the test hook that keeps it always under load).
    pkill -f "pylond-.* serve" 2>/dev/null; sleep 0.5
    ( cd www2 && exec python3 -m http.server $W2 --bind 127.0.0.1 ) > /dev/null 2>&1 & WEB2=$!
    PYLON_TEST_BUSY=1 PYLON_TEST_REKEY_SECS=1 "$PYLON" -p $PORT -N -L $((PORT + 15)):127.0.0.1:$W2 --pylond "$PYLOND" "$USER_NAME@127.0.0.1" 2> pc.log & PC=$!
    for _ in $(seq 100); do grep -q "forwarding" pc.log && break; sleep 0.2; done
    check "pylon protocol: under load, the handshake takes a cookie (mac2)" 0 "sent a cookie; retrying with mac2" cat pc.log
    check "pylon protocol: under load, 3 MB intact while rekeying" 0 "$(sha256sum www2/big.bin | cut -d' ' -f1)" \
        bash -c "sleep 2.5; curl -s -m 60 --limit-rate 600k http://127.0.0.1:$((PORT + 15))/big.bin | sha256sum"
    check "pylon protocol: under load, rekeying with mac2" 0 "" bash -c "test \$(grep -c 'new session keys' pc.log) -ge 3"
    check "pylond: under load, still silent without mac1" 0 "no reply" \
        python3 -c "
import socket, os
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.5)
s.sendto(bytes([1, 0, 0, 0]) + os.urandom(1280), ('127.0.0.1', $(sed -n 's/.*session to 127.0.0.1:\([0-9]*\).*/\1/p' pc.log)))
try:
    s.recvfrom(4096); print('replied')
except socket.timeout:
    print('no reply')"
    check "pylon protocol: data packets padded to 64 bytes" 0 "padded" \
        python3 "$(dirname "$HOSTILE")/pad_check.py" "$(sed -n 's/.*session to 127.0.0.1:\([0-9]*\).*/\1/p' pc.log)" -- curl -s -m 10 "http://127.0.0.1:$((PORT + 15))/small.txt"
    kill $PC $WEB2 2>/dev/null; wait $PC $WEB2 2>/dev/null
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
