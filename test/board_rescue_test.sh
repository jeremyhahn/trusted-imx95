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
listener_pid=""
cleanup() {
	[ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null
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
# [payload file] [auth|noauth|othernonce]. "noauth" sends the bare command
# line; "othernonce" makes the MAC with a nonce the board did not send.
cat >"$tmp/client.py" <<'EOS'
import hashlib, socket, sys, threading
port, keyfile, line = sys.argv[1:4]
payload = sys.argv[4] if len(sys.argv) > 4 else ""
mode = sys.argv[5] if len(sys.argv) > 5 else "auth"
key = open(keyfile).read().strip()
s = socket.create_connection(("127.0.0.1", int(port)), timeout=30)
f = s.makefile("rb")
first = f.readline().decode()
w = first.split()
if len(w) != 2 or w[0] != "nonce":
    sys.stdout.write(first + f.read().decode(errors="replace"))
    sys.exit(0)
nonce = "0" * 64 if mode == "othernonce" else w[1]
mac = hashlib.sha256(f"{key}:{nonce}:{line}".encode()).hexdigest()
msg = line if mode == "noauth" else f"auth {mac} {line}"
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
    if payload:
        with open(payload, "rb") as p:
            s.sendall(p.read())
    s.shutdown(socket.SHUT_WR)
except OSError:
    pass
t.join()
sys.stdout.write(b"".join(reply).decode(errors="replace"))
EOS
RESCUE_DEV_DIR=$dev RESCUE_SYS_DIR=$sys RESCUE_KEY_FILE=$bkey python3 -I "$tmp/listener.py" "$init" "$tmp/port" 2>"$tmp/listener.err" &
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
head -c 5000 "$dump0" >"$payload"
out=$(rq "write mmcblk0 $size0 $want" "$payload")
ok "a short stream gives MISMATCH" has "$out" "MISMATCH"

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
logcount() { # logcount <text>: how many lines of the handler's log have it
	local n=0 l
	while IFS= read -r l; do has "$l" "$1" && n=$((n + 1)); done <"$tmp/listener.err"
	echo "$n"
}
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
