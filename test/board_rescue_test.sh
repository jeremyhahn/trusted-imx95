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
handle() { RESCUE_DEV_DIR=$dev RESCUE_SYS_DIR=$sys sh "$init" --handle 2>"$tmp/handler.err"; }

# --- the handler ------------------------------------------------------------
want=$(shabytes "$dev/mmcblk0" 100000)
out=$(echo "hash mmcblk0 100000" | handle)
ok "hash prints the SHA-256 of the first bytes" test "$out" = "$want"
before=$(sha "$dev/mmcblk0")
echo "hash mmcblk0 100000" | handle >/dev/null
ok "hash leaves the device unchanged" test "$(sha "$dev/mmcblk0")" = "$before"
out=$(echo "hash mmcblk0 99999999999" | handle)
ok "hash past the device size is refused" has "$out" "ERR"

want=$(sha "$dump0")
out=$({ echo "write mmcblk0 $size0 $want"; cat "$dump0"; } | handle)
ok "write then OK" test "$out" = OK
ok "the device holds the stream" test "$(sha "$dev/mmcblk0")" = "$want"
ok "the device keeps its size" test "$(wc -c <"$dev/mmcblk0")" -eq "$size0"

reset_devs
want=$(sha "$dump0")
bad=$tmp/bad
{ head -c 1000 "$dump0"; printf 'X'; tail -c +1002 "$dump0"; } >"$bad"
out=$({ echo "write mmcblk0 $size0 $want"; cat "$bad"; } | handle)
ok "a corrupted stream gives MISMATCH" has "$out" "MISMATCH"
ok "the MISMATCH names the hash read back" has "$out" "$(sha "$dev/mmcblk0")"

reset_devs
out=$({ echo "write mmcblk0 $size0 $want"; head -c 5000 "$dump0"; } | handle)
ok "a short stream gives MISMATCH" has "$out" "MISMATCH"

wantb=$(sha "$dumpb0")
out=$({ echo "write mmcblk0boot0 $sizeb $wantb"; cat "$dumpb0"; } | handle)
ok "a boot partition writes OK" test "$out" = OK
ok "force_ro is restored after the boot write" test "$(<"$sys/block/mmcblk0boot0/force_ro")" = 1
ok "the other boot partition's force_ro is untouched" test "$(<"$sys/block/mmcblk0boot1/force_ro")" = 1

reset_devs
echo "decoy" >"$dev/mmcblk0p1"
echo "decoy" >"$dev/sda"
before=$(sha "$dev/mmcblk0")
for name in sda mmcblk0p1 mmcblk1 ../dev/mmcblk0 mmcblk0boot2 "mmcblk0;x"; do
	out=$({ echo "write $name 10 $want"; echo 0123456789; } | handle)
	ok "write to $name is refused" has "$out" "ERR refused"
	out=$(echo "hash $name 10" | handle)
	ok "hash of $name is refused" has "$out" "ERR refused"
done
ok "the refused writes changed nothing" test "$(sha "$dev/mmcblk0")" = "$before"
ok "decoys untouched" test "$(<"$dev/sda")" = decoy
out=$(echo "frobnicate" | handle)
ok "an unknown command is refused" has "$out" "ERR"
out=$(echo "write mmcblk0 10 nothex" | handle)
ok "a bad sha256 is refused" has "$out" "ERR"
out=$(echo "write mmcblk0 abc $want" | handle)
ok "a bad byte count is refused" has "$out" "ERR"
out=$(echo "reboot" | handle)
ok "reboot answers OK (and does not reboot the test host)" test "$out" = OK

# --- restore.sh -------------------------------------------------------------
# A zstd that only copies: the fake dumps are plain bytes.
# shellcheck disable=SC2016 # the fake's own variables
printf '#!/bin/sh\nfor a; do f=$a; done\nexec cat "$f"\n' >"$tmp/fakebin/zstd"
# A stub ssh: records the remote command and answers like a board.
cat >"$tmp/fakebin/ssh" <<'EOS'
#!/bin/sh
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
mkdir -p "$tmp/cpio"
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

RESCUE_DEV_DIR=$dev RESCUE_SYS_DIR=$sys python3 -I "$tmp/listener.py" "$init" "$tmp/port" 2>"$tmp/listener.err" &
listener_pid=$!
n=0
while [ ! -s "$tmp/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -s "$tmp/port" ] || { echo "FAIL listener did not start"; cat "$tmp/listener.err"; exit 1; }

export FAKE_SSH_LOG=$tmp/ssh.log FAKE_UPLOAD=$tmp/uploaded FAKE_BOARD_BYTES=$size0
export RESCUE_PORT RESTORE_WAIT=10 RESTORE_SETTLE=0
RESCUE_PORT=$(<"$tmp/port")
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
ok "kexec loads the board's own kernel with the initramfs and the address" has "$log" "kexec -l /boot/Image --initrd=/tmp/rescue.cpio.gz --append='console=ttyLP0,115200 rescue.ip=127.0.0.1/8 rescue.port=$RESCUE_PORT rescue.gw=192.0.2.1 rescue.if=eth9'"
ok "kexec -e follows stopping xkmsd and a sync" has "$log" "systemctl stop xkmsd; sync; sleep 1; kexec -e"
ok "the initramfs was uploaded intact" test "$(sha "$tmp/uploaded")" = "$(sha "$tmp/rescue.cpio.gz")"
ok "the board's root device is reported" has "$OUT" "board root device: /dev/mmcblk0p2"

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

# a retry against a board already in the rescue system
reset_devs
: >"$FAKE_SSH_LOG"
run_restore board "$tmp/bk" --no-kexec --ip 127.0.0.1/8
ok "--no-kexec restores without kexec" test "$RC" -eq 0
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
