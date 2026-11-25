#!/usr/bin/env bash
# The rescue initramfs's command handler and the restore driver, against fakes:
# the handler runs on plain files (RESCUE_DEV_DIR and RESCUE_SYS_DIR, which the
# real boot never sets); restore.sh runs against a stub ssh and a local fake
# rescue listener that runs the real handler per connection. All data is
# generated here. Nothing touches a board or a device.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
init=$root/scripts/board-rescue/init
restore=$root/scripts/board-rescue/restore.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/board-rescue-test.XXXXXX")
listener_pid="" proxy_pid=""
cleanup() {
	[ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null
	[ -z "$proxy_pid" ] || kill "$proxy_pid" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT

FAILS=0
pass() { echo "ok   $1"; }
fail() {
	echo "FAIL $1: ${2:-}"
	FAILS=$((FAILS + 1))
}
ok() { # ok <name> <command...>
	local name=$1
	shift
	if "$@"; then pass "$name"; else fail "$name" "$*"; fi
}
has() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1" "$2"; }
sha() { local h; h=$(sha256sum "$1") && echo "${h%% *}"; }
shabytes() { local h; h=$(head -c "$2" "$1" | sha256sum) && echo "${h%% *}"; }

# --- fixtures ---------------------------------------------------------------
dev=$tmp/dev
sys=$tmp/sys
mkdir -p "$dev" "$sys/block/mmcblk0boot0" "$sys/block/mmcblk0boot1" "$tmp/bk" "$tmp/fakebin"
echo 1 >"$sys/block/mmcblk0boot0/force_ro"
echo 1 >"$sys/block/mmcblk0boot1/force_ro"
size0=3145728 # 3 MiB, so dd's 4M block is a short block
sizeb=65536
dump0=$tmp/dump0 dumpb0=$tmp/dumpb0 dumpb1=$tmp/dumpb1
head -c "$size0" /dev/urandom >"$dump0"
head -c "$sizeb" /dev/urandom >"$dumpb0"
head -c "$sizeb" /dev/urandom >"$dumpb1"
reset_devs() {
	head -c "$size0" /dev/urandom >"$dev/mmcblk0"
	head -c "$sizeb" /dev/urandom >"$dev/mmcblk0boot0"
	head -c "$sizeb" /dev/urandom >"$dev/mmcblk0boot1"
	echo 1 >"$sys/block/mmcblk0boot0/force_ro"
	echo 1 >"$sys/block/mmcblk0boot1/force_ro"
}
reset_devs
# The board's session key, as the rescue system reads it from /rescue.key.
bkey=$tmp/board.key
head -c 32 /dev/urandom | sha256sum | { read -r h _; echo "$h"; } >"$bkey"

# A fake rescue listener: the real handler per connection, like init's serve.
cat >"$tmp/listener.py" <<'EOS'
import os, socket, subprocess, sys
init, portfile = sys.argv[1:3]
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(portfile, "w") as f:
    f.write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    p = subprocess.Popen(["sh", init, "--handle"], stdin=c.fileno(), stdout=c.fileno())
    p.wait()
    c.close()
EOS
# A client of the rescue protocol: client.py <port> <key file> <line>
# [payload file] [mode]. It sends the payload in authenticated chunks (init's
# header) and prints the reply, or "BADMAC <reply>" when the reply's MAC is
# wrong, or a line that is not a reply as it came. The modes:
#   auth          the protocol as restore.sh speaks it
#   noauth        the bare command line
#   othernonce    the command MAC made with a nonce the board did not send
#   subst=<k>     chunk <k> keeps its MAC but one of its bytes is altered
#   cut=<k>       chunk <k> has its line and MAC but only half its bytes
#   record=<file> also saves the chunk stream it sent to <file>
#   replay=<file> sends the chunk stream saved by record (another session's)
cat >"$tmp/client.py" <<'EOS'
import hashlib, socket, sys, threading
port, keyfile, line = sys.argv[1:4]
payload = sys.argv[4] if len(sys.argv) > 4 else ""
mode, _, arg = (sys.argv[5] if len(sys.argv) > 5 else "auth").partition("=")
CHUNK = 1 << 20
key = open(keyfile).read().strip()
def sha(b):
    return hashlib.sha256(b).hexdigest()
s = socket.create_connection(("127.0.0.1", int(port)), timeout=30)
f = s.makefile("rb")
first = f.readline().decode()
w = first.split()
if len(w) != 2 or w[0] != "nonce":
    sys.stdout.write(first + f.read().decode(errors="replace"))
    sys.exit(0)
nonce = "0" * 64 if mode == "othernonce" else w[1]
mac = sha(f"{key}:{nonce}:{line}".encode())
msg = line if mode == "noauth" else f"auth {mac} {line}"
data = open(payload, "rb").read() if payload else b""
words = line.split()
total = int(words[2]) if len(words) > 2 and words[2].isdigit() else len(data)
stream = []
if mode == "replay":
    stream.append(open(arg, "rb").read())
else:
    off = k = 0
    while off < total and off < len(data):
        part = data[off:off + min(CHUNK, total - off)]
        cm = sha(f"{key}:{nonce}:c:{k + 1}:{k}:{total}:{len(part)}:".encode() + part)
        head = f"chunk {k} {cm}\n".encode()
        if mode == "cut" and k == int(arg):
            stream.append(head + part[:len(part) // 2])
            break
        if mode == "subst" and k == int(arg):
            i = len(part) // 2
            part = part[:i] + bytes([part[i] ^ 0xFF]) + part[i + 1:]
        stream.append(head + part)
        off += len(part)
        k += 1
if mode == "record":
    with open(arg, "wb") as r:
        r.write(b"".join(stream))
# The reply is read while the payload is still being sent: a board that
# refuses a write answers and closes at once, and the reset its close sends
# for the unread payload would discard a reply read only afterwards.
reply = []
def reader():
    try:
        while True:
            b = f.read1(65536)
            if not b:
                break
            reply.append(b)
    except OSError:
        pass
t = threading.Thread(target=reader)
t.start()
try:
    s.sendall(msg.encode() + b"\n")
    for b in stream:
        s.sendall(b)
    s.shutdown(socket.SHUT_WR)
except OSError:
    pass
t.join()
out = []
for l in b"".join(reply).decode(errors="replace").splitlines():
    p = l.split(" ", 2)
    if len(p) == 3 and p[0] == "reply":
        good = p[1] == sha(f"{key}:{w[1]}:b:1:{len(p[2])}:{p[2]}".encode())
        out.append(p[2] if good else "BADMAC " + p[2])
    else:
        out.append(l)
sys.stdout.write("\n".join(out) + "\n")
EOS
# An on-path attacker between restore.sh and the board, without the key:
# proxy.py <port file> <board port> <mode> <state file>. It relays both ways;
# "record" saves the board's last reply line to <state file>; "forge" and
# "replay" alter a byte of every chunk stream that passes and hand the client
# a bare "OK" (forge) or the reply line recorded from an earlier connection
# (replay) in place of the board's reply.
cat >"$tmp/proxy.py" <<'EOS'
import socket, sys, threading
portfile, bport, mode, state = sys.argv[1:5]
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(portfile, "w") as f:
    f.write(str(s.getsockname()[1]))
def up(c, b):
    n = 0
    try:
        while True:
            d = c.recv(65536)
            if not d:
                break
            if mode != "record" and n <= 200000 < n + len(d):
                i = 200000 - n
                d = d[:i] + bytes([d[i] ^ 0xFF]) + d[i + 1:]
            n += len(d)
            b.sendall(d)
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass
def down(c, b):
    bf = b.makefile("rb")
    try:
        c.sendall(bf.readline())
        r = bf.readline()
        if mode == "record":
            with open(state, "wb") as o:
                o.write(r)
        elif mode == "forge":
            r = b"OK\n"
        elif mode == "replay":
            r = open(state, "rb").read()
        c.sendall(r)
        c.shutdown(socket.SHUT_WR)
    except OSError:
        pass
while True:
    c, _ = s.accept()
    b = socket.create_connection(("127.0.0.1", int(bport)))
    ts = [threading.Thread(target=up, args=(c, b)), threading.Thread(target=down, args=(c, b))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    c.close()
    b.close()
EOS
# A client that never lets go: hold.py <port> <out> [<key file> <line>]
# takes the nonce and goes quiet, or with a key and line authenticates, sends
# a chunk line and 1000 bytes of the chunk and goes quiet. It writes the nonce line to <out>
# once connected, then "dropped after N s" when the board closes, or "held"
# when it gave up after 40 s.
cat >"$tmp/hold.py" <<'EOS'
import hashlib, socket, sys, time
port, out = sys.argv[1:3]
s = socket.create_connection(("127.0.0.1", int(port)), timeout=40)
t0 = time.monotonic()
f = s.makefile("rb")
first = f.readline().decode()
if len(sys.argv) > 4:
    key = open(sys.argv[3]).read().strip()
    line = sys.argv[4]
    nonce = first.split()[1]
    mac = hashlib.sha256(f"{key}:{nonce}:{line}".encode()).hexdigest()
    s.sendall(f"auth {mac} {line}\nchunk 0 {'0' * 64}\n".encode() + b"\0" * 1000)
with open(out, "w") as o:
    o.write(first)
    o.flush()
    try:
        f.read()
        o.write("dropped after %d s\n" % (time.monotonic() - t0))
    except OSError:
        o.write("held\n")
EOS
mkdir -p "$tmp/ram"
RESCUE_AUTH_SECS=2 RESCUE_LIFE_SECS=8 RESCUE_DEV_DIR=$dev RESCUE_SYS_DIR=$sys RESCUE_KEY_FILE=$bkey RESCUE_TMP_DIR=$tmp/ram python3 -I "$tmp/listener.py" "$init" "$tmp/port" 2>"$tmp/listener.err" &
listener_pid=$!
n=0
while [ ! -s "$tmp/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -s "$tmp/port" ] || { echo "FAIL listener did not start"; cat "$tmp/listener.err"; exit 1; }
port=$(<"$tmp/port")
# rq <line> [payload file] [mode] [key file]: one request to the fake rescue.
rq() { python3 -I "$tmp/client.py" "$port" "${4:-$bkey}" "$1" "${2:-}" "${3:-auth}"; }
payload=$tmp/payload

# --- the handler ------------------------------------------------------------
want=$(shabytes "$dev/mmcblk0" 100000)
out=$(rq "hash mmcblk0 100000")
ok "hash prints the SHA-256 of the first bytes" test "$out" = "$want"
before=$(sha "$dev/mmcblk0")
rq "hash mmcblk0 100000" >/dev/null
ok "hash leaves the device unchanged" test "$(sha "$dev/mmcblk0")" = "$before"
out=$(rq "hash mmcblk0 99999999999")
ok "hash past the device size is refused" has "$out" "ERR"

want=$(sha "$dump0")
out=$(rq "write mmcblk0 $size0 $want" "$dump0")
ok "write then OK" test "$out" = OK
ok "the device holds the stream" test "$(sha "$dev/mmcblk0")" = "$want"
ok "the device keeps its size" test "$(wc -c <"$dev/mmcblk0")" -eq "$size0"

reset_devs
want=$(sha "$dump0")
bad=$tmp/bad
{ head -c 1000 "$dump0"; printf 'X'; tail -c +1002 "$dump0"; } >"$bad"
out=$(rq "write mmcblk0 $size0 $want" "$bad")
ok "a corrupted stream gives MISMATCH" has "$out" "MISMATCH"
ok "the MISMATCH names the hash read back" has "$out" "$(sha "$dev/mmcblk0")"

reset_devs
before=$(sha "$dev/mmcblk0")
head -c 5000 "$dump0" >"$payload"
out=$(rq "write mmcblk0 $size0 $want" "$payload")
ok "a short stream is refused" test "$out" = "ERR write aborted: chunk 0: stream cut short at 5000 of 1048576 bytes"
ok "a short stream writes nothing" test "$(sha "$dev/mmcblk0")" = "$before"

# --- chunk authentication -------------------------------------------------------
# The payload goes in 1 MiB chunks, each under its own MAC; size0 is 3 chunks.
# An on-path attacker who relays the nonce and the command line cannot make
# the board write a byte the key holder did not send.
mib=1048576
logcount() { # logcount <text>: how many lines of the handler's log have it
	local n=0 l
	while IFS= read -r l; do has "$l" "$1" && n=$((n + 1)); done <"$tmp/listener.err"
	echo "$n"
}
# same_range <file a> <file b> <from> <count>: the two files agree there.
same_range() { cmp -s <(tail -c +"$(($3 + 1))" "$1" | head -c "$4") <(tail -c +"$(($3 + 1))" "$2" | head -c "$4"); }
reset_devs
cp "$dev/mmcblk0" "$tmp/mmc.before"
out=$(rq "write mmcblk0 $size0 $want" "$dump0" subst=1)
ok "a substituted chunk is refused" test "$out" = "ERR write aborted: chunk 1: bad MAC"
ok "the chunk before it was written" same_range "$dev/mmcblk0" "$dump0" 0 "$mib"
ok "no byte of the substituted chunk or after it was written" same_range "$dev/mmcblk0" "$tmp/mmc.before" "$mib" "$((size0 - mib))"
ok "the refusal is logged" test "$(logcount "write mmcblk0 aborted: chunk 1: bad MAC")" -eq 1
reset_devs
before=$(sha "$dev/mmcblk0")
out=$(rq "write mmcblk0 $size0 $want" "$dump0" subst=0)
ok "a substituted first chunk writes nothing" test "$out$(sha "$dev/mmcblk0")" = "ERR write aborted: chunk 0: bad MAC$before"
reset_devs
cp "$dev/mmcblk0" "$tmp/mmc.before"
out=$(rq "write mmcblk0 $size0 $want" "$dump0" cut=2)
ok "a chunk cut short is refused" test "$out" = "ERR write aborted: chunk 2: stream cut short at 524288 of 1048576 bytes"
ok "the cut chunk was not written" same_range "$dev/mmcblk0" "$tmp/mmc.before" "$((2 * mib))" "$mib"
reset_devs
cp "$dev/mmcblk0" "$tmp/mmc.before"
head -c "$((2 * mib))" "$dump0" >"$payload"
out=$(rq "write mmcblk0 $size0 $want" "$payload")
ok "a stream that stops at a chunk boundary is refused" test "$out" = "ERR write aborted: chunk 2: no chunk line"
ok "nothing past the stop was written" same_range "$dev/mmcblk0" "$tmp/mmc.before" "$((2 * mib))" "$mib"
reset_devs
out=$(rq "write mmcblk0 $size0 $want" "$dump0" record="$tmp/session1.chunks")
ok "a recorded session writes OK" test "$out" = OK
reset_devs
before=$(sha "$dev/mmcblk0")
out=$(rq "write mmcblk0 $size0 $want" "" replay="$tmp/session1.chunks")
ok "chunks replayed from an earlier session are refused" test "$out" = "ERR write aborted: chunk 0: bad MAC"
ok "the replayed chunks wrote nothing" test "$(sha "$dev/mmcblk0")" = "$before"
ok "no chunk is left in RAM" test -z "$(ls -A "$tmp/ram")"

wantb=$(sha "$dumpb0")
out=$(rq "write mmcblk0boot0 $sizeb $wantb" "$dumpb0")
ok "a boot partition writes OK" test "$out" = OK
ok "force_ro is restored after the boot write" test "$(<"$sys/block/mmcblk0boot0/force_ro")" = 1
ok "the other boot partition's force_ro is untouched" test "$(<"$sys/block/mmcblk0boot1/force_ro")" = 1

reset_devs
echo "decoy" >"$dev/mmcblk0p1"
echo "decoy" >"$dev/sda"
before=$(sha "$dev/mmcblk0")
echo 0123456789 >"$payload"
for name in sda mmcblk0p1 mmcblk1 ../dev/mmcblk0 mmcblk0boot2 "mmcblk0;x"; do
	out=$(rq "write $name 10 $want" "$payload")
	ok "write to $name is refused" has "$out" "ERR refused"
	out=$(rq "hash $name 10")
	ok "hash of $name is refused" has "$out" "ERR refused"
done
ok "the refused writes changed nothing" test "$(sha "$dev/mmcblk0")" = "$before"
ok "decoys untouched" test "$(<"$dev/sda")" = decoy
out=$(rq "frobnicate")
ok "an unknown command is refused" has "$out" "ERR"
out=$(rq "write mmcblk0 10 nothex")
ok "a bad sha256 is refused" has "$out" "ERR"
out=$(rq "write mmcblk0 abc $want")
ok "a bad byte count is refused" has "$out" "ERR"
out=$(rq "reboot")
ok "reboot answers OK (and does not reboot the test host)" test "$out" = OK

# --- authentication -----------------------------------------------------------
# No host without the session key reaches hash, write or reboot.
reboots() { logcount "reboot (test: not rebooting)"; }
reboots0=$(reboots)
reset_devs
before=$(sha "$dev/mmcblk0")
beforeb=$(sha "$dev/mmcblk0boot0")
head -c 64 /dev/urandom | sha256sum | { read -r h _; echo "$h"; } >"$tmp/wrong.key"
for mode in noauth othernonce wrongkey; do
	kf=$bkey m=$mode
	[ "$mode" != wrongkey ] || { kf=$tmp/wrong.key m=auth; }
	out=$(rq "write mmcblk0 $size0 $(sha "$dump0")" "$dump0" "$m" "$kf")
	ok "$mode: write is refused" test "$out" = "ERR auth refused"
	out=$(rq "write mmcblk0boot0 $sizeb $(sha "$dumpb0")" "$dumpb0" "$m" "$kf")
	ok "$mode: boot partition write is refused" test "$out" = "ERR auth refused"
	out=$(rq "hash mmcblk0 100000" "" "$m" "$kf")
	ok "$mode: hash is refused" test "$out" = "ERR auth refused"
	out=$(rq "reboot" "" "$m" "$kf")
	ok "$mode: reboot is refused" test "$out" = "ERR auth refused"
done
ok "the refused requests wrote nothing" test "$(sha "$dev/mmcblk0")$(sha "$dev/mmcblk0boot0")" = "$before$beforeb"
ok "boot partitions stayed locked" test "$(<"$sys/block/mmcblk0boot0/force_ro")" = 1
ok "the handler logged the refusals" has "$(<"$tmp/listener.err")" "refused"
ok "no refused reboot reached the reboot step" test "$(reboots)" -eq "$reboots0"
mv "$bkey" "$bkey.off"
out=$(rq "hash mmcblk0 100000" "" auth "$bkey.off")
ok "without a session key on the board every command is refused" test "$out" = "ERR no session key"
mv "$bkey.off" "$bkey"
ok "the session key never reaches the handler's log" lacks "$(<"$tmp/listener.err")" "$(<"$bkey")"

# --- deadlines ---------------------------------------------------------------
# There is one listener. A client that takes the nonce and goes quiet is
# dropped after RESCUE_AUTH_SECS (2 s here), and the next client is served;
# an authenticated one that stalls mid-write is dropped after
# RESCUE_LIFE_SECS (8 s here), with the processes of its write.
# hold_then_serve <name> [<key file> <line>]
hold_then_serve() {
	local name=$1 n=0 hp want out
	shift
	rm -f "$tmp/hold.out"
	python3 -I "$tmp/hold.py" "$port" "$tmp/hold.out" "$@" &
	hp=$!
	while [ ! -s "$tmp/hold.out" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
	want=$(shabytes "$dev/mmcblk0" 100000)
	out=$(rq "hash mmcblk0 100000" 2>&1)
	wait "$hp"
	ok "$name: the board dropped the holding client" has "$(<"$tmp/hold.out")" "dropped after"
	ok "$name: the next client was served" test "$out" = "$want"
}
hold_then_serve "idle client"
ok "idle client: the drop is logged" test "$(logcount "no auth line after 2 s: dropping the connection")" -eq 1
hold_then_serve "stalled write" "$bkey" "write mmcblk0 $size0 $(sha "$dump0")"
ok "stalled write: the drop is logged" test "$(logcount "command still running after 8 s: dropping the connection")" -eq 1
# shellcheck disable=SC2016 # init's text, not this shell's $port
ok "serve runs the handler per accepted connection (nc -e)" has "$(<"$init")" 'nc -l -p "$port" -e /bin/rescue-handle'
ok "the initramfs ships bin/rescue-handle" has "$(<"$root/scripts/board-rescue/build-initramfs.sh")" 'entries["bin/rescue-handle"]'

# --- restore.sh -------------------------------------------------------------
# A zstd that only copies: the fake dumps are plain bytes.
# shellcheck disable=SC2016 # the fake's own variables
printf '#!/bin/sh\nfor a; do f=$a; done\nexec cat "$f"\n' >"$tmp/fakebin/zstd"
# A stub ssh: records the remote command and answers like a board. The
# session-key script runs for real, with the board's /tmp mapped to
# FAKE_TMP; the key it appends to the initramfs is then read back out of the
# cpio (cpio.py) into the file the fake rescue reads, as the kernel would
# unpack it into /rescue.key.
cat >"$tmp/fakebin/ssh" <<'EOS'
#!/usr/bin/env bash
# stub ssh: ssh [-o X]... <target> <command>
while [ "${1:-}" = -o ]; do shift 2; done
shift # the target
log=$FAKE_SSH_LOG
echo "ssh: $*" >>"$log"
case $* in
"sh -s")
	cat >/dev/null
	echo "bytes=${FAKE_BOARD_BYTES}"
	echo "gw=192.0.2.1"
	echo "if=eth9"
	echo "ip=127.0.0.1/8"
	;;
"cat >/tmp/rescue.cpio.gz") cat >"$FAKE_UPLOAD" ;;
"sh -s -- rescue-key")
	script=$(cat)
	sh -c "${script//\/tmp\//$FAKE_TMP/}" || exit 1
	python3 -I "$FAKE_CPIO_PY" "$FAKE_TMP/rescue-initrd.img" "$FAKE_UPLOAD" "$FAKE_BOARD_KEY" >&2 || exit 1
	;;
"sha256sum /tmp/rescue.cpio.gz")
	h=$(sha256sum "$FAKE_UPLOAD")
	echo "${h%% *}  /tmp/rescue.cpio.gz"
	;;
kexec\ -l*) ;;
*kexec\ -e*) ;;
true) ;;
*"/proc/cmdline"*) echo "/dev/mmcblk0p2" ;;
*) echo "stub ssh: unexpected command $*" >&2; exit 99 ;;
esac
EOS
chmod +x "$tmp/fakebin/zstd" "$tmp/fakebin/ssh"
# cpio.py <initrd> <uploaded initramfs> <out>: the initrd must be the upload,
# zero padding to a 4-byte boundary, then one newc archive with rescue.key
# (mode 0100400) and the trailer; writes the key file's content to <out>.
cat >"$tmp/cpio.py" <<'EOS'
import sys
initrd, orig, out = sys.argv[1:4]
data = open(initrd, "rb").read()
base = open(orig, "rb").read()
if not data.startswith(base):
    sys.exit("the initrd does not start with the uploaded initramfs")
off = len(base)
while off < len(data) and data[off] == 0:
    off += 1
if off % 4:
    sys.exit("the appended cpio is not 4-byte aligned")
files = {}
while True:
    h = data[off:off + 110]
    if h[:6] != b"070701":
        sys.exit("bad newc magic at %d" % off)
    f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
    mode, size, ns = f[1], f[6], f[11]
    name = data[off + 110:off + 110 + ns - 1].decode()
    if data[off + 110 + ns - 1] != 0:
        sys.exit("name not NUL-terminated")
    off = (off + 110 + ns + 3) & ~3
    body = data[off:off + size]
    off = (off + size + 3) & ~3
    if name == "TRAILER!!!":
        break
    files[name] = (mode, body)
if off != len(data):
    sys.exit("bytes after the trailer")
mode, body = files.get("rescue.key", (None, b""))
if mode != 0o100400 or len(body.strip()) != 64:
    sys.exit("no rescue.key of mode 0400 with a 64-hex key")
with open(out, "wb") as o:
    o.write(body)
EOS
mkdir -p "$tmp/cpio" "$tmp/board-tmp"
printf 'fake initramfs\n' >"$tmp/rescue.cpio.gz"
{
	echo "# fake backup"
	echo "mmcblk0 mmcblk0.img.zst $size0 $(sha "$dump0")"
	echo "mmcblk0boot0 mmcblk0boot0.img.zst $sizeb $(sha "$dumpb0")"
	echo "mmcblk0boot1 mmcblk0boot1.img.zst $sizeb $(sha "$dumpb1")"
} >"$tmp/bk/manifest.txt"
cp "$dump0" "$tmp/bk/mmcblk0.img.zst"
cp "$dumpb0" "$tmp/bk/mmcblk0boot0.img.zst"
cp "$dumpb1" "$tmp/bk/mmcblk0boot1.img.zst"

export FAKE_SSH_LOG=$tmp/ssh.log FAKE_BOARD_BYTES=$size0
export FAKE_TMP=$tmp/board-tmp FAKE_UPLOAD=$tmp/board-tmp/rescue.cpio.gz
export FAKE_CPIO_PY=$tmp/cpio.py FAKE_BOARD_KEY=$bkey
export RESCUE_PORT=$port RESTORE_WAIT=10 RESTORE_SETTLE=0
skey=$tmp/bk/rescue-session.key
run_restore() { PATH="$tmp/fakebin:$PATH" bash "$restore" "$@" >"$tmp/out" 2>&1; RC=$?; OUT=$(<"$tmp/out"); }

# verify-only against devices that hold the backup
cp "$dump0" "$dev/mmcblk0"
cp "$dumpb0" "$dev/mmcblk0boot0"
cp "$dumpb1" "$dev/mmcblk0boot1"
before=$(sha "$dev/mmcblk0")
: >"$FAKE_SSH_LOG"
run_restore board "$tmp/bk" --verify-only --cpio "$tmp/rescue.cpio.gz"
ok "verify-only on matching devices exits 0" test "$RC" -eq 0
ok "verify-only reports MATCH for all three" test "$(echo "$OUT" | while read -r _ _ c _; do [ "$c" = MATCH ] && echo x; done | wc -l)" -eq 3
ok "verify-only wrote nothing" test "$(sha "$dev/mmcblk0")" = "$before"
log=$(<"$FAKE_SSH_LOG")
ok "kexec loads the board's own kernel with the initramfs and the address" has "$log" "kexec -l /boot/Image --initrd=/tmp/rescue-initrd.img --append='console=ttyLP0,115200 rescue.ip=127.0.0.1/8 rescue.port=$RESCUE_PORT rescue.gw=192.0.2.1 rescue.if=eth9'"
ok "kexec -e follows stopping xkmsd and a sync" has "$log" "systemctl stop xkmsd; sync; sleep 1; kexec -e"
ok "the initramfs was uploaded intact" test "$(sha "$FAKE_UPLOAD")" = "$(sha "$tmp/rescue.cpio.gz")"
ok "the board's root device is reported" has "$OUT" "board root device: /dev/mmcblk0p2"
ok "the session key step ran on the board before the kexec" has "$log" "ssh: sh -s -- rescue-key"
ok "the initrd carries the board's session key (cpio.py checked it)" test -s "$bkey"
ok "the session key file is deleted once the board is back" test ! -e "$skey"

# verify-only against devices that differ
reset_devs
run_restore board "$tmp/bk" --verify-only --cpio "$tmp/rescue.cpio.gz"
ok "verify-only on differing devices exits nonzero" test "$RC" -ne 0
ok "verify-only names the difference" has "$OUT" "mmcblk0 DIFFERS"

# the write flow
reset_devs
: >"$FAKE_SSH_LOG"
run_restore board "$tmp/bk" --cpio "$tmp/rescue.cpio.gz"
ok "write flow exits 0" test "$RC" -eq 0
ok "mmcblk0 holds the backup" test "$(sha "$dev/mmcblk0")" = "$(sha "$dump0")"
ok "mmcblk0boot0 holds the backup" test "$(sha "$dev/mmcblk0boot0")" = "$(sha "$dumpb0")"
ok "mmcblk0boot1 holds the backup" test "$(sha "$dev/mmcblk0boot1")" = "$(sha "$dumpb1")"
ok "each write reported OK" test "$(echo "$OUT" | while read -r _ _ c _; do [ "$c" = OK ] && echo x; done | wc -l)" -eq 3
ok "boot partitions are read-only again" test "$(<"$sys/block/mmcblk0boot0/force_ro")$(<"$sys/block/mmcblk0boot1/force_ro")" = 11
ok "the output carries no key material" lacks "$OUT" "BEGIN"

# a corrupted dump is caught
reset_devs
cp "$tmp/bk/mmcblk0.img.zst" "$tmp/good0"
cp "$bad" "$tmp/bk/mmcblk0.img.zst"
run_restore board "$tmp/bk" --cpio "$tmp/rescue.cpio.gz"
ok "a corrupted dump fails the restore" test "$RC" -ne 0
ok "the failure says MISMATCH" has "$OUT" "MISMATCH"
cp "$tmp/good0" "$tmp/bk/mmcblk0.img.zst"
ok "the failure keeps the session key for a retry" test "$(<"$skey")" = "$(<"$bkey")"
ok "the session key file is mode 0600" test "$(stat -c %a "$skey")" = 600
k=$(<"$bkey")
ok "the session key is not in the output" lacks "$OUT" "$k"
ok "the session key is not on any ssh command line" lacks "$(<"$FAKE_SSH_LOG")" "$k"
ok "the session key is not in the rescue's log" lacks "$(<"$tmp/listener.err")" "$k"

# a retry with another session's key is refused and writes nothing
reset_devs
before=$(sha "$dev/mmcblk0")
cp "$skey" "$tmp/skey.good"
cp "$tmp/wrong.key" "$skey"
badmac0=$(logcount "bad MAC: refused")
run_restore board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
ok "a stale session key fails the retry" test "$RC" -ne 0
ok "the board refused the stale key" test "$(logcount "bad MAC: refused")" -gt "$badmac0"
ok "the stale-key retry wrote nothing" test "$(sha "$dev/mmcblk0")" = "$before"
rm -f "$skey"
run_restore board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
ok "a retry without the session key file is refused" has "$OUT" "no session key"
cp "$tmp/skey.good" "$skey"

# a retry against a board already in the rescue system
reset_devs
: >"$FAKE_SSH_LOG"
run_restore board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
ok "--no-kexec restores without kexec" test "$RC" -eq 0
ok "--no-kexec deletes the session key at the end" test ! -e "$skey"
ok "--no-kexec ran no kexec" lacks "$(<"$FAKE_SSH_LOG")" kexec
ok "--no-kexec result verifies" test "$(sha "$dev/mmcblk0")" = "$(sha "$dump0")"

# an on-path attacker between restore.sh and the board (proxy.py), without
# the key: it alters a chunk and hands restore.sh an OK of its own
# with_proxy <mode> <restore arguments...>: run_restore through proxy.py.
with_proxy() {
	local mode=$1 n=0
	shift
	rm -f "$tmp/pport"
	python3 -I "$tmp/proxy.py" "$tmp/pport" "$port" "$mode" "$tmp/proxy.state" 2>>"$tmp/proxy.err" &
	proxy_pid=$!
	while [ ! -s "$tmp/pport" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
	RESCUE_PORT=$(<"$tmp/pport") run_restore "$@"
	kill "$proxy_pid" 2>/dev/null
	wait "$proxy_pid" 2>/dev/null
	proxy_pid=""
}
cp "$tmp/skey.good" "$skey"
reset_devs
with_proxy record board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
ok "a restore through a relaying proxy verifies" test "$RC" -eq 0
ok "the proxy holds an authenticated OK of that session" has "$(<"$tmp/proxy.state")" "reply "
for mode in forge replay; do
	cp "$tmp/skey.good" "$skey"
	reset_devs
	cp "$dev/mmcblk0" "$tmp/mmc.before"
	with_proxy "$mode" board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
	ok "$mode: the attacker's OK fails the restore" test "$RC" -ne 0
	ok "$mode: restore.sh refused the reply" has "$OUT" "mmcblk0 UNAUTHENTICATED"
	ok "$mode: the board wrote nothing of the altered chunk" cmp -s "$dev/mmcblk0" "$tmp/mmc.before"
done
rm -f "$skey"

# refusals
: >"$FAKE_SSH_LOG"
FAKE_BOARD_BYTES=1234 run_restore board "$tmp/bk" --cpio "$tmp/rescue.cpio.gz"
ok "a size mismatch refuses" test "$RC" -ne 0
ok "a size mismatch kexecs nothing" lacks "$(<"$FAKE_SSH_LOG")" kexec
cp "$tmp/bk/manifest.txt" "$tmp/bk/manifest.bad"
echo "mmcblk0p1 x.zst 10 $(sha "$dump0")" >>"$tmp/bk/manifest.bad"
run_restore board "$tmp/bk" --manifest "$tmp/bk/manifest.bad" --cpio "$tmp/rescue.cpio.gz"
ok "a manifest naming another device is refused" has "$OUT" "does not write"
run_restore board
ok "missing arguments exit 2" test "$RC" -eq 2

if [ "$FAILS" -ne 0 ]; then
	echo "board_rescue_test: $FAILS failed"
	exit 1
fi
echo "board_rescue_test: all passed"
