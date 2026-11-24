#!/usr/bin/env bash
# shellcheck disable=SC2012 # ls | wc -l counts the backup directories we named
# Tests of scripts/xkms/: the deploy script against a fake board (a temp root
# reached through a stub ssh on PATH, with a fake systemctl, ss and xkmsd), and
# every burn-in script's --help and --dry-run. No board, no network, no keys:
# the data here is throwaway text made in a temp directory.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
deploy=$here/scripts/xkms/xkmsd-deploy.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

FAILS=0
pass() { echo "ok   $1"; }
fail() {
	echo "FAIL $1: $2"
	FAILS=$((FAILS + 1))
}
ok() { # ok <name> <command...>: the command succeeds
	local name=$1
	shift
	if "$@"; then pass "$name"; else fail "$name" "$*"; fi
}

# --- the fake board ----------------------------------------------------------
fakebin=$tmp/fakebin
mkdir -p "$fakebin"
cat >"$fakebin/ssh" <<'EOF'
#!/bin/sh
# Stub ssh: drop the -o options and the target, run the command locally.
echo "ssh $*" >>"${FAKE_SSH_LOG:-/dev/null}"
while [ "$1" = -o ]; do shift 2; done
shift
for t in ${FAKE_TOOLS:-}; do PATH=$FAKE_OPT/$t:$PATH; done
export PATH
exec sh -c "$*"
EOF
cat >"$fakebin/systemctl" <<'EOF'
#!/bin/bash
R=$XKMS_FAKE_ROOT
st=$R/run/state
bin=$R/usr/local/bin/xkmsd
body=$(cat "$bin")
case $1 in
cat) [ -f "$R/etc/systemd/xkmsd.service" ] ;;
is-active) [ "$(cat "$st")" = active ] ;;
stop) echo inactive >"$st"; rm -rf "$R/proc/4242"; echo '  sl  local_address' >"$R/proc/net/tcp" ;;
start)
	case $body in *FAILSTART*) echo inactive >"$st"; exit 1 ;; esac
	case $body in *CORRUPT*)
		echo garbage >"$R/var/lib/xkms/db"
		echo junk >"$R/var/lib/xkms/newfile"
		;;
	esac
	echo active >"$st"
	case $body in *NOLISTEN*) ;; *)
		# the /proc view of a daemon listening on 8443 (0x20FB), plus a
		# connected socket on port 80 that is not a listener (state 01)
		mkdir -p "$R/proc/net" "$R/proc/4242/fd"
		printf '%s\n' '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode' \
			'   0: 00000000:20FB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0 0' \
			'   1: 0100007F:0050 0100007F:9999 01 00000000:00000000 00:00000000 00000000     0        0 12346 1 0 0' >"$R/proc/net/tcp"
		printf '%s\n' '  sl  local_address rem_address   st' >"$R/proc/net/tcp6"
		ln -sfn 'socket:[12345]' "$R/proc/4242/fd/3"
		;;
	esac
	;;
show) if [ "$(cat "$st")" = active ]; then echo 4242; else echo 0; fi ;;
esac
EOF
# ss and netstat exist only when FAKE_TOOLS names them (default: neither, as on
# the board's ss-less image; a stub that exits 127 makes the probe fall through).
export FAKE_OPT=$tmp/opt
for tool in ss netstat; do
	mkdir -p "$FAKE_OPT/$tool"
	cat >"$FAKE_OPT/$tool/$tool" <<'EOF'
#!/bin/bash
R=$XKMS_FAKE_ROOT
tool=${0##*/}
case " ${FAKE_TOOLS:-} " in *" $tool "*) ;; *) exit 127 ;; esac
body=$(cat "$R/usr/local/bin/xkmsd")
[ "$(cat "$R/run/state")" = active ] || exit 0
case $body in *NOLISTEN*) exit 0 ;; esac
if [ "$tool" = ss ]; then
	echo 'LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:* users:(("xkmsd",pid=4242,fd=3))'
else
	echo 'tcp 0 0 0.0.0.0:8443 0.0.0.0:* LISTEN 4242/xkmsd'
fi
EOF
	chmod +x "$FAKE_OPT/$tool/$tool"
done
chmod +x "$fakebin"/*
# The board has neither: the PATH is the fake bin plus symlinks to every host
# tool except ss and netstat, so a host ss never shows through.
mkdir -p "$tmp/hosttools"
IFS=: read -ra pdirs <<<"$PATH"
for d in "${pdirs[@]}"; do
	for f in "$d"/*; do
		[ -x "$f" ] && [ -f "$f" ] || continue
		case ${f##*/} in ss | netstat) continue ;; esac
		[ -e "$tmp/hosttools/${f##*/}" ] || ln -s "$f" "$tmp/hosttools/${f##*/}"
	done
done
export PATH=$fakebin:$tmp/hosttools

mkbin() { # mkbin <file> <commit> [marker...]: a fake xkmsd
	local f=$1 c=$2
	shift 2
	printf '#!/bin/sh\necho "  Git Commit: %s"\n# %s\n' "$c" "$*" >"$f"
	chmod 755 "$f"
}

mkbuild() { # mkbuild <dir> <commit> [marker...]
	local d=$1 c=$2 h
	shift 2
	mkdir -p "$d"
	mkbin "$d/xkmsd" "$c" "$@"
	h=$(sha256sum "$d/xkmsd" | cut -d' ' -f1)
	printf 'go-xkms-commit: %s\nsha256: %s  xkmsd\n' "$c" "$h" >"$d/manifest.txt"
}

mkboard() { # mkboard <root>: the old build, a config, keys and storage
	local r=$1
	mkdir -p "$r/usr/local/bin" "$r/etc/xkms" "$r/etc/systemd" "$r/var/lib/xkms/keys" "$r/run" "$r/proc/net"
	echo '  sl  local_address' >"$r/proc/net/tcp" # a Linux board always has it
	mkbin "$r/usr/local/bin/xkmsd" OLDCOMMIT
	echo "listen: fake" >"$r/etc/xkms/xkmsd.yaml"
	echo SECRETMATERIAL-0001 >"$r/var/lib/xkms/keys/k1"
	head -c 4096 /dev/urandom >"$r/var/lib/xkms/db"
	touch "$r/etc/systemd/xkmsd.service"
	echo active >"$r/run/state"
}

restored() { # restored <root> <snap>
	cmp -s "$1/usr/local/bin/xkmsd" "$2/xkmsd" || return 1
	diff -r "$1/etc/xkms" "$2/etc-xkms" >/dev/null || return 1
	diff -r "$1/var/lib/xkms" "$2/var-lib-xkms" >/dev/null || return 1
}
snap() {
	rm -rf "$2"
	mkdir -p "$2"
	cp -a "$1/usr/local/bin/xkmsd" "$2/xkmsd"
	cp -a "$1/etc/xkms" "$2/etc-xkms"
	cp -a "$1/var/lib/xkms" "$2/var-lib-xkms"
}

export XKMS_HEALTH_WAIT=2 XKMS_SETTLE=1 XKMS_MIN_FREE_KB=0 XKMS_SSH_OPTS="-o BatchMode=yes"
unset XKMS_STAMP XKMS_KEEP

D() { # D <log> args... : run the deploy script, set RC, keep the output in <log>
	local log=$1
	shift
	set +e
	"$deploy" "$@" >"$log" 2>&1
	RC=$?
	set -e
}
out_has() { case $(cat "$1") in *"$2"*) return 0 ;; *) return 1 ;; esac; }
out_lacks() { ! out_has "$@"; }

# --- usage and dry-run -------------------------------------------------------
D "$tmp/u.log" --help
ok "deploy --help exits 0" [ "$RC" = 0 ]
ok "deploy --help names --rollback" out_has "$tmp/u.log" "--rollback"
export FAKE_SSH_LOG=$tmp/ssh.log
: >"$FAKE_SSH_LOG"
mkbuild "$tmp/b-new" NEWCOMMIT
XKMS_STAMP=20260101T000000Z D "$tmp/dry.log" --dry-run board.invalid "$tmp/b-new"
ok "deploy --dry-run exits 0" [ "$RC" = 0 ]
ok "deploy --dry-run prints a plan" out_has "$tmp/dry.log" "plan:"
ok "deploy --dry-run never calls ssh" [ ! -s "$FAKE_SSH_LOG" ]
D "$tmp/bad.log" onlyone
ok "deploy with one argument is a usage error" [ "$RC" = 2 ]

# --- success path ------------------------------------------------------------
R=$tmp/boardA
mkboard "$R"
export XKMS_FAKE_ROOT=$R
snap "$R" "$tmp/snapA"
XKMS_STAMP=20260101T000001Z D "$tmp/ok.log" board.invalid "$tmp/b-new"
ok "success: exit 0" [ "$RC" = 0 ]
ok "success: new binary installed" cmp -s "$tmp/b-new/xkmsd" "$R/usr/local/bin/xkmsd"
ok "success: unit active" [ "$(cat "$R/run/state")" = active ]
ok "success: backup has a SHA256SUMS list" [ -s "$R/var/backups/xkms/20260101T000001Z/SHA256SUMS" ]
ok "success: backup holds the old binary byte for byte" cmp -s "$R/var/backups/xkms/20260101T000001Z/xkmsd" "$tmp/snapA/xkmsd"
ok "success: backup holds the old data" diff -r "$R/var/backups/xkms/20260101T000001Z/var-lib-xkms" "$tmp/snapA/var-lib-xkms"
ok "success: no staged binary left" [ ! -e "$R/usr/local/bin/.xkmsd.new" ]
ok "success: secrets are not printed" out_lacks "$tmp/ok.log" SECRETMATERIAL
ok "success: backup dir is private" [ "$(stat -c %a "$R/var/backups/xkms")" = 700 ]

# --- the listener probe: ss, netstat, or /proc/net/tcp only ----------------------
ok "default fake board has no ss" bash -c '! type ss >/dev/null 2>&1'
ok "default fake board has no netstat" bash -c '! type netstat >/dev/null 2>&1'
for probe in "ss" "netstat"; do
	R=$tmp/board-$probe
	mkboard "$R"
	export XKMS_FAKE_ROOT=$R
	FAKE_TOOLS=$probe XKMS_STAMP=20260101T000010Z D "$tmp/probe-$probe.log" board.invalid "$tmp/b-new"
	ok "probe $probe: deploy succeeds" [ "$RC" = 0 ]
done
R=$tmp/board-proc-port
mkboard "$R"
export XKMS_FAKE_ROOT=$R
XKMS_PORT=8443 XKMS_STAMP=20260101T000011Z D "$tmp/probe-port.log" board.invalid "$tmp/b-new"
ok "probe /proc only: listener on the port is found" [ "$RC" = 0 ]
R=$tmp/board-proc-noport
mkboard "$R"
export XKMS_FAKE_ROOT=$R
XKMS_PORT=9999 XKMS_HEALTH_WAIT=1 XKMS_STAMP=20260101T000012Z D "$tmp/probe-noport.log" board.invalid "$tmp/b-new"
ok "probe /proc only: no 0A line for the port fails the deploy" [ "$RC" != 0 ]

# --- health check failure rolls back, byte for byte ---------------------------
for mode in "NOLISTEN" "CORRUPT NOLISTEN" "FAILSTART" "CORRUPT FAILSTART"; do
	R=$tmp/boardB
	rm -rf "$R"
	mkboard "$R"
	export XKMS_FAKE_ROOT=$R
	snap "$R" "$tmp/snapB"
	# shellcheck disable=SC2086 # $mode is a list of marker words
	mkbuild "$tmp/b-bad" BADCOMMIT $mode
	XKMS_STAMP=20260101T000002Z D "$tmp/bad.log" board.invalid "$tmp/b-bad"
	ok "$mode: exit nonzero" [ "$RC" != 0 ]
	ok "$mode: says why" out_has "$tmp/bad.log" "FAILED"
	ok "$mode: old binary, config and data restored byte for byte" restored "$R" "$tmp/snapB"
	ok "$mode: nothing the new build wrote survives" [ ! -e "$R/var/lib/xkms/newfile" ]
	ok "$mode: old build running again" [ "$(cat "$R/run/state")" = active ]
done

# --- staging refusals leave the board alone -----------------------------------
R=$tmp/boardC
mkboard "$R"
export XKMS_FAKE_ROOT=$R
snap "$R" "$tmp/snapC"
mkbuild "$tmp/b-liar" LIARCOMMIT
printf '#!/bin/sh\necho "  Git Commit: SOMETHINGELSE"\n' >"$tmp/b-liar/xkmsd"
D "$tmp/liar.log" board.invalid "$tmp/b-liar"
ok "a build that does not match its manifest is refused" [ "$RC" != 0 ]
ok "refused build: board untouched" restored "$R" "$tmp/snapC"
mkbuild "$tmp/b-lie2" WANTED
mkbin "$tmp/b-lie2/xkmsd" OTHER
printf 'go-xkms-commit: WANTED\nsha256: %s  xkmsd\n' "$(sha256sum "$tmp/b-lie2/xkmsd" | cut -d' ' -f1)" >"$tmp/b-lie2/manifest.txt"
D "$tmp/lie2.log" board.invalid "$tmp/b-lie2"
ok "a binary whose --version does not name the commit is refused" [ "$RC" != 0 ]
ok "version-mismatch: board untouched and running" restored "$R" "$tmp/snapC"
ok "version-mismatch: unit still active" [ "$(cat "$R/run/state")" = active ]
ok "version-mismatch: staged file removed" [ ! -e "$R/usr/local/bin/.xkmsd.new" ]

# --- --rollback --------------------------------------------------------------
R=$tmp/boardD
mkboard "$R"
export XKMS_FAKE_ROOT=$R
snap "$R" "$tmp/snapD"
XKMS_STAMP=20260101T000003Z D "$tmp/d1.log" board.invalid "$tmp/b-new"
ok "rollback setup: deployed" [ "$RC" = 0 ]
echo "written after the deploy" >"$R/var/lib/xkms/later"
D "$tmp/rb.log" --rollback 20260101T000003Z board.invalid
ok "--rollback exits 0" [ "$RC" = 0 ]
ok "--rollback restores binary, config and data" restored "$R" "$tmp/snapD"
ok "--rollback drops data written after the backup" [ ! -e "$R/var/lib/xkms/later" ]
ok "--rollback leaves the unit active" [ "$(cat "$R/run/state")" = active ]
D "$tmp/rb2.log" --rollback 20250101T000000Z board.invalid
ok "--rollback of a missing backup fails and says so" [ "$RC" != 0 ]
ok "--rollback of a missing backup leaves the board" restored "$R" "$tmp/snapD"
mkdir -p "$tmp/tamper"
cp -a "$R/var/backups/xkms/20260101T000003Z" "$tmp/tamper/keep"
echo tampered >>"$R/var/backups/xkms/20260101T000003Z/var-lib-xkms/db"
D "$tmp/rb3.log" --rollback 20260101T000003Z board.invalid
ok "--rollback refuses a backup that fails its SHA256SUMS" [ "$RC" != 0 ]
ok "--rollback of a tampered backup leaves live data alone" restored "$R" "$tmp/snapD"
D "$tmp/rb4.log" --rollback ../etc board.invalid
ok "--rollback rejects a stamp that is a path" [ "$RC" != 0 ]
D "$tmp/dry2.log" --rollback 20260101T000003Z --dry-run board.invalid
ok "--rollback --dry-run prints a plan" out_has "$tmp/dry2.log" "plan:"

# --- pruning -----------------------------------------------------------------
R=$tmp/boardE
mkboard "$R"
export XKMS_FAKE_ROOT=$R
for i in 1 2 3 4 5 6 7; do
	XKMS_STAMP=2026010${i}T000000Z D "$tmp/p$i.log" board.invalid "$tmp/b-new"
done
ok "prune: default keeps the newest 5" [ "$(ls "$R/var/backups/xkms" | wc -l)" = 5 ]
ok "prune: the oldest are gone" [ ! -e "$R/var/backups/xkms/20260101T000000Z" ]
ok "prune: the second oldest is gone" [ ! -e "$R/var/backups/xkms/20260102T000000Z" ]
ok "prune: the newest remains" [ -d "$R/var/backups/xkms/20260107T000000Z" ]
XKMS_KEEP=2 XKMS_STAMP=20260108T000000Z D "$tmp/p8.log" board.invalid "$tmp/b-new"
ok "prune: XKMS_KEEP=2 keeps 2" [ "$(ls "$R/var/backups/xkms" | wc -l)" = 2 ]

# --- burn-in scripts: --help and --dry-run ------------------------------------
for s in "$here"/scripts/xkms/burnin/*.sh; do
	[ -e "$s" ] || continue
	n=$(basename "$s")
	[ "$n" = lib.sh ] && continue
	set +e
	"$s" --help >"$tmp/h.log" 2>&1
	rc=$?
	set -e
	ok "burn-in $n --help exits 0" [ "$rc" = 0 ]
	ok "burn-in $n --help prints usage" out_has "$tmp/h.log" "usage:"
	: >"$FAKE_SSH_LOG"
	set +e
	"$s" --dry-run board.invalid >"$tmp/dr.log" 2>&1
	rc=$?
	set -e
	ok "burn-in $n --dry-run exits 0" [ "$rc" = 0 ]
	ok "burn-in $n --dry-run prints a plan" out_has "$tmp/dr.log" "plan:"
	ok "burn-in $n --dry-run never calls ssh" [ ! -s "$FAKE_SSH_LOG" ]
done

if [ "$FAILS" -ne 0 ]; then
	echo "$FAILS failed"
	exit 1
fi
echo "all passed"
