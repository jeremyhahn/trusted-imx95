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
echo "$*" >>"$R/run/systemctl.log"
st=$R/run/state
bin=$R/usr/local/bin/xkmsd
body=$(cat "$bin")
# run/pid, when present, is the MainPID, and each start or restart changes it
# unless run/samepid exists; run/restartfail and run/killfail fail those verbs
bump() { [ ! -e "$R/run/pid" ] || [ -e "$R/run/samepid" ] || echo $(($(cat "$R/run/pid") + 1)) >"$R/run/pid"; }
case $1 in
restart)
	[ ! -e "$R/run/restartfail" ] || exit 1
	bump
	echo active >"$st"
	;;
kill)
	[ ! -e "$R/run/killfail" ] || exit 1
	echo inactive >"$st"
	;;
cat) [ -f "$R/etc/systemd/xkmsd.service" ] ;;
is-active) [ "$(cat "$st")" = active ] ;;
stop)
	# run/stopfail: the stop fails and the unit stays up; run/linger: the unit
	# goes inactive but an xkmsd process survives it
	[ ! -e "$R/run/stopfail" ] || exit 1
	echo inactive >"$st"
	[ -e "$R/run/linger" ] || rm -rf "$R/proc/4242"
	echo '  sl  local_address' >"$R/proc/net/tcp"
	;;
start)
	case $body in *FAILSTART*) echo inactive >"$st"; exit 1 ;; esac
	case $body in *CORRUPT*)
		echo garbage >"$R/var/lib/xkms/db"
		echo junk >"$R/var/lib/xkms/newfile"
		;;
	esac
	echo active >"$st"
	bump
	mkdir -p "$R/proc/4242"
	echo xkmsd >"$R/proc/4242/comm"
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
show) if [ "$2 $3" = "-p User" ]; then echo "${FAKE_UNIT_USER:-}"
	elif [ "$(cat "$st")" = active ]; then cat "$R/run/pid" 2>/dev/null || echo 4242; else echo 0; fi ;;
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
cat >"$fakebin/df" <<'EOF'
#!/bin/bash
# Stub df: the host's df, unless FAKE_DF_FREE names the KiB free on one
# filesystem mounted at / that holds every board path; FAKE_DF_RESERVED adds
# KiB reserved for root (in the size, neither used nor available).
[ -n "${FAKE_DF_FREE:-}" ] || exec "${0%/*}/../hosttools/df" "$@"
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "fake $((FAKE_DF_FREE + ${FAKE_DF_RESERVED:-0})) 0 $FAKE_DF_FREE 0% /"
EOF
cat >"$fakebin/xkmsctl" <<'EOF'
#!/bin/bash
# Stub xkmsctl: keys are files in $FAKE_KMS. FAKE_CTL_FAIL lists the verbs
# that fail (generate, encrypt, sign, get, list, verify); "badsig" makes sign
# answer without a signature.
k=$FAKE_KMS
a=()
while [ $# -gt 0 ]; do case $1 in -o | --server) shift 2 ;; *) a+=("$1"); shift ;; esac; done
set -- "${a[@]}"
[ "$1" = key ] || exit 2
v=$2 id=${3:-}
case " ${FAKE_CTL_FAIL:-} " in *" $v "*) echo "error: $v failed" >&2; exit 1 ;; esac
case $v in
generate)
	# FAKE_CTL_NOSPACE_AFTER: while the burn-in filler exists, creates past
	# that many fail with ENOSPC's message
	if [ -n "${FAKE_CTL_NOSPACE_AFTER:-}" ] && [ -e "$XKMS_FAKE_ROOT/var/lib/xkms/.burnin-filler" ]; then
		c=$(($(cat "$k/.full" 2>/dev/null || echo 0) + 1))
		echo "$c" >"$k/.full"
		[ "$c" -le "$FAKE_CTL_NOSPACE_AFTER" ] || { echo "error: write $k/$id: no space left on device" >&2; exit 1; }
	fi
	(set -o noclobber; : >"$k/$id") 2>/dev/null || exit 1 # one create of an id wins
	# FAKE_CTL_PIDS records this process; FAKE_CTL_SLOW delays the answer after
	# the create succeeded; FAKE_CTL_ACKED lists each id as it is answered
	[ -z "${FAKE_CTL_PIDS:-}" ] || echo "$$" >>"$FAKE_CTL_PIDS"
	# (only for ids matching the glob FAKE_CTL_SLOW_MATCH when it is set)
	# shellcheck disable=SC2254 # the glob is meant
	[ -z "${FAKE_CTL_SLOW:-}" ] || case $id in ${FAKE_CTL_SLOW_MATCH:-*}) sleep "$FAKE_CTL_SLOW" ;; esac
	[ -z "${FAKE_CTL_ACKED:-}" ] || echo "$id" >>"$FAKE_CTL_ACKED"
	;;
list) ls "$k" ;;
get)
	# a missing key is answered with xkmsctl's not-found error (exit 1)
	# (FAKE_CTL_MISSING_ERR: any other error text instead, as a dead server gives)
	[ -e "$k/$id" ] || { echo "error: ${FAKE_CTL_MISSING_ERR:-key $id not found}" >&2; exit 1; }
	echo "{\"id\":\"$id\"}"
	;;
delete)
	# FAKE_CTL_KEEP: the delete is acknowledged but the key stays
	[ -e "$k/$id" ] || exit 1
	[ -n "${FAKE_CTL_KEEP:-}" ] || rm -f "$k/$id"
	;;
encrypt) [ -e "$k/$id" ] && echo "{\"ciphertext\":\"c-$4\",\"nonce\":\"n\",\"tag\":\"t\"}" ;;
decrypt) [ -e "$k/$id" ] && echo "${4#c-}" ;;
sign)
	[ -e "$k/$id" ] || exit 1
	case " ${FAKE_CTL_FAIL:-} " in *" badsig "*) echo '{"error":"none"}' ;; *) echo "{\"signature\":\"s-$id-$4\"}" ;; esac
	;;
verify) [ -e "$k/$id" ] && [ "$5" = "s-$id-$4" ] ;;
*) exit 2 ;;
esac
EOF
cat >"$fakebin/findmnt" <<'EOF'
#!/bin/bash
# Stub findmnt -rn -o TARGET: / plus the paths in FAKE_MOUNTS.
echo /
for m in ${FAKE_MOUNTS:-}; do echo "$m"; done
EOF
# Stub mv and rm: fail, touching nothing, when an argument matches the glob in
# FAKE_MV_FAIL or FAKE_RM_FAIL; otherwise the host's tool.
for tool in mv rm; do
	cat >"$fakebin/$tool" <<'EOF'
#!/bin/bash
tool=${0##*/}
var=FAKE_${tool^^}_FAIL
pat=${!var:-}
if [ -n "$pat" ]; then
	for a; do
		# shellcheck disable=SC2053 # $pat is a glob on purpose
		[[ $a != $pat ]] || { echo "$tool: stub failure on $a" >&2; exit 1; }
	done
fi
exec "${0%/*}/../hosttools/$tool" "$@"
EOF
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

# --- rollback never replaces live state under a running xkmsd ------------------
# stopfail: systemctl stop fails and the unit stays active; linger: the unit
# goes inactive but an xkmsd process survives
for how in stopfail linger; do
	R=$tmp/boardS-$how
	mkboard "$R"
	export XKMS_FAKE_ROOT=$R
	XKMS_STAMP=20260101T000004Z D "$tmp/s-$how.log" board.invalid "$tmp/b-new"
	ok "$how setup: deployed" [ "$RC" = 0 ]
	echo "written after the deploy" >"$R/var/lib/xkms/later"
	touch "$R/run/$how"
	snap "$R" "$tmp/snapS"
	D "$tmp/rs-$how.log" --rollback 20260101T000004Z board.invalid
	ok "$how: --rollback refuses" [ "$RC" != 0 ]
	ok "$how: --rollback says it left the live tree" out_has "$tmp/rs-$how.log" "live tree untouched"
	ok "$how: binary, config and state byte-identical" restored "$R" "$tmp/snapS"
	ok "$how: no restore copies left behind" [ ! -e "$R/var/lib/xkms.restore" ]
done
R=$tmp/boardS-deploy
mkboard "$R"
export XKMS_FAKE_ROOT=$R
touch "$R/run/stopfail"
snap "$R" "$tmp/snapS"
XKMS_STAMP=20260101T000004Z D "$tmp/s-deploy.log" board.invalid "$tmp/b-new"
ok "stopfail: deploy refuses" [ "$RC" != 0 ]
ok "stopfail: deploy leaves the board byte-identical" restored "$R" "$tmp/snapS"
ok "stopfail: deploy leaves the unit active" [ "$(cat "$R/run/state")" = active ]

# --- mount points: refused before xkmsd is stopped ------------------------------
# A rollback renames the state directories; a mount point (or one inside them)
# cannot be swapped, so deploy and --rollback refuse before stopping anything.
for mnt in var/lib/xkms etc/xkms/tls usr/local/bin/xkmsd; do
	R=$tmp/boardM
	rm -rf "$R"
	mkboard "$R"
	export XKMS_FAKE_ROOT=$R
	snap "$R" "$tmp/snapM"
	FAKE_MOUNTS="$R/$mnt" XKMS_STAMP=20260101T000007Z D "$tmp/m.log" board.invalid "$tmp/b-new"
	ok "mount $mnt: deploy refuses" [ "$RC" != 0 ]
	ok "mount $mnt: says which mount point" out_has "$tmp/m.log" "$R/$mnt is a mount point"
	ok "mount $mnt: xkmsd was never stopped" out_lacks "$R/run/systemctl.log" stop
	ok "mount $mnt: unit still active" [ "$(cat "$R/run/state")" = active ]
	ok "mount $mnt: board untouched" restored "$R" "$tmp/snapM"
	ok "mount $mnt: no backup made" [ ! -e "$R/var/backups/xkms/20260101T000007Z" ]
done
R=$tmp/boardM2
mkboard "$R"
export XKMS_FAKE_ROOT=$R
XKMS_STAMP=20260101T000008Z D "$tmp/m2.log" board.invalid "$tmp/b-new"
ok "mounted rollback setup: deployed" [ "$RC" = 0 ]
echo "written after the deploy" >"$R/var/lib/xkms/later"
snap "$R" "$tmp/snapM2"
: >"$R/run/systemctl.log"
FAKE_MOUNTS="$R/var/lib/xkms" D "$tmp/m2r.log" --rollback 20260101T000008Z board.invalid
ok "mounted state: --rollback refuses" [ "$RC" != 0 ]
ok "mounted state: --rollback says why" out_has "$tmp/m2r.log" "$R/var/lib/xkms is a mount point"
ok "mounted state: --rollback never stopped xkmsd" out_lacks "$R/run/systemctl.log" stop
ok "mounted state: live state byte-identical" restored "$R" "$tmp/snapM2"
ok "mounted state: the backup still verifies" bash -c "cd '$R/var/backups/xkms/20260101T000008Z' && sha256sum -c --quiet SHA256SUMS"
# The mount table holds resolved paths: a mount is found when the path to
# the board's root goes through a symlink too.
rm -rf "$tmp/boardM3" "$tmp/boardM3l"
mkboard "$tmp/boardM3"
ln -s boardM3 "$tmp/boardM3l"
R=$tmp/boardM3l
export XKMS_FAKE_ROOT=$R
FAKE_MOUNTS="$tmp/boardM3/var/lib/xkms" XKMS_STAMP=20260101T000009Z D "$tmp/m3.log" board.invalid "$tmp/b-new"
ok "mount seen through a linked root: deploy refuses" [ "$RC" != 0 ]
ok "mount seen through a linked root: says which mount point" out_has "$tmp/m3.log" "$tmp/boardM3/var/lib/xkms is a mount point"
ok "mount seen through a linked root: xkmsd was never stopped" out_lacks "$R/run/systemctl.log" stop

# --- symlinks: refused before xkmsd is stopped ----------------------------------
# The backup copies a link as a link, so a rollback would put back the link
# and not the state it points to. A state path that is a symlink, sits under
# one or holds one is refused before anything is stopped.
# linkboard <case>: a fresh board in $R with the symlink of <case>
linkboard() {
	R=$tmp/boardL
	rm -rf "$R"
	mkboard "$R"
	export XKMS_FAKE_ROOT=$R
	case $1 in
	var-is-link)
		mv "$R/var/lib/xkms" "$R/data-xkms"
		ln -s "$R/data-xkms" "$R/var/lib/xkms"
		;;
	parent-is-link)
		mv "$R/var/lib" "$R/var/lib.real"
		ln -s lib.real "$R/var/lib"
		;;
	link-inside)
		echo "outside the tree" >"$R/elsewhere"
		ln -s "$R/elsewhere" "$R/etc/xkms/linked"
		;;
	bin-is-link)
		mv "$R/usr/local/bin/xkmsd" "$R/usr/local/bin/xkmsd.real"
		ln -s "$R/usr/local/bin/xkmsd.real" "$R/usr/local/bin/xkmsd"
		;;
	esac
}
for c in var-is-link parent-is-link link-inside bin-is-link; do
	linkboard "$c"
	snap "$R" "$tmp/snapL"
	XKMS_STAMP=20260101T000010Z D "$tmp/l.log" board.invalid "$tmp/b-new"
	ok "$c: deploy refuses" [ "$RC" != 0 ]
	ok "$c: says it is a symlink" out_has "$tmp/l.log" "is a symlink at, above or inside"
	ok "$c: xkmsd was never stopped" out_lacks "$R/run/systemctl.log" stop
	ok "$c: board untouched" restored "$R" "$tmp/snapL"
	ok "$c: no backup made" [ ! -e "$R/var/backups/xkms/20260101T000010Z" ]
done
# A rollback refuses a live tree that became a link, and a backup that
# holds one (as an older deploy could make).
linkboard none
XKMS_STAMP=20260101T000011Z D "$tmp/l2.log" board.invalid "$tmp/b-new"
ok "linked rollback setup: deployed" [ "$RC" = 0 ]
mv "$R/var/lib/xkms" "$R/data-xkms"
ln -s "$R/data-xkms" "$R/var/lib/xkms"
snap "$R" "$tmp/snapL2"
: >"$R/run/systemctl.log"
D "$tmp/l2r.log" --rollback 20260101T000011Z board.invalid
ok "linked live state: --rollback refuses" [ "$RC" != 0 ]
ok "linked live state: --rollback says why" out_has "$tmp/l2r.log" "$R/var/lib/xkms is a symlink"
ok "linked live state: --rollback never stopped xkmsd" out_lacks "$R/run/systemctl.log" stop
ok "linked live state: board untouched" restored "$R" "$tmp/snapL2"
linkboard none
XKMS_STAMP=20260101T000012Z D "$tmp/l3.log" board.invalid "$tmp/b-new"
ok "linked backup setup: deployed" [ "$RC" = 0 ]
ln -s /nonexistent "$R/var/backups/xkms/20260101T000012Z/etc-xkms/linked"
snap "$R" "$tmp/snapL3"
: >"$R/run/systemctl.log"
D "$tmp/l3r.log" --rollback 20260101T000012Z board.invalid
ok "linked backup: --rollback refuses" [ "$RC" != 0 ]
ok "linked backup: --rollback says why" out_has "$tmp/l3r.log" "holds symlinks"
ok "linked backup: --rollback never stopped xkmsd" out_lacks "$R/run/systemctl.log" stop
ok "linked backup: board untouched" restored "$R" "$tmp/snapL3"

# --- a failing mv or rm stops the restore with the backup intact ---------------
R=$tmp/boardV
mkboard "$R"
export XKMS_FAKE_ROOT=$R
XKMS_STAMP=20260101T000009Z D "$tmp/v.log" board.invalid "$tmp/b-new"
ok "mv/rm failure setup: deployed" [ "$RC" = 0 ]
bk=$R/var/backups/xkms/20260101T000009Z
echo "written after the deploy" >"$R/var/lib/xkms/later"
snap "$R" "$tmp/snapV"
FAKE_MV_FAIL="$R/var/lib/xkms.old" D "$tmp/vmv.log" --rollback 20260101T000009Z board.invalid
ok "mv failure: --rollback exits nonzero" [ "$RC" != 0 ]
ok "mv failure: says the swap failed" out_has "$tmp/vmv.log" "swapping $R/var/lib/xkms failed"
ok "mv failure: names the backup" out_has "$tmp/vmv.log" "the backup $bk is intact"
ok "mv failure: the backup still verifies" bash -c "cd '$bk' && sha256sum -c --quiet SHA256SUMS"
ok "mv failure: the half-done swap is put back" restored "$R" "$tmp/snapV"
FAKE_RM_FAIL="$R/var/lib/xkms.old" D "$tmp/vrm.log" --rollback 20260101T000009Z board.invalid
ok "rm failure: --rollback exits nonzero" [ "$RC" != 0 ]
ok "rm failure: names the backup" out_has "$tmp/vrm.log" "the backup is in $bk"
ok "rm failure: the backup still verifies" bash -c "cd '$bk' && sha256sum -c --quiet SHA256SUMS"
ok "rm failure: live state byte-identical" restored "$R" "$tmp/snapV"
FAKE_RM_FAIL="$R/etc/xkms.old" D "$tmp/vrm2.log" --rollback 20260101T000009Z board.invalid
ok "late rm failure: --rollback exits nonzero" [ "$RC" != 0 ]
R=$tmp/boardV2
mkboard "$R"
export XKMS_FAKE_ROOT=$R
mkbuild "$tmp/b-fs" FSCOMMIT FAILSTART
FAKE_MV_FAIL="$R/var/lib/xkms.old" XKMS_STAMP=20260101T000010Z D "$tmp/v2.log" board.invalid "$tmp/b-fs"
ok "deploy, failing mv in rollback: exits nonzero" [ "$RC" != 0 ]
ok "deploy, failing mv in rollback: says where the backup is" out_has "$tmp/v2.log" "RESTORE FAILED: the backup is in /var/backups/xkms/20260101T000010Z"
ok "deploy, failing mv in rollback: the backup still verifies" bash -c "cd '$R/var/backups/xkms/20260101T000010Z' && sha256sum -c --quiet SHA256SUMS"
ok "deploy, failing mv in rollback: the state is still there" [ -s "$R/var/lib/xkms/keys/k1" ]

# --- preflight reserves room for the copies a rollback makes -------------------
R=$tmp/boardF
mkboard "$R"
head -c 4194304 /dev/urandom >"$R/var/lib/xkms/big"
export XKMS_FAKE_ROOT=$R
snap "$R" "$tmp/snapF"
live=0
for n in $(du -sk "$R/usr/local/bin/xkmsd" "$R/etc/xkms" "$R/var/lib/xkms" | cut -f1); do live=$((live + n)); done
# room for one backup and the staged binary, not for a rollback's copies too
FAKE_DF_FREE=$((live + 64)) XKMS_STAMP=20260101T000005Z D "$tmp/df.log" board.invalid "$tmp/b-new"
ok "room for one backup only: preflight refuses" [ "$RC" != 0 ]
ok "room for one backup only: says why" out_has "$tmp/df.log" "copies a rollback makes"
ok "room for one backup only: board untouched" restored "$R" "$tmp/snapF"
ok "room for one backup only: no backup made" [ ! -e "$R/var/backups/xkms/20260101T000005Z" ]
FAKE_DF_FREE=$((2 * live + 64)) XKMS_STAMP=20260101T000006Z D "$tmp/df2.log" board.invalid "$tmp/b-new"
ok "room for backup and rollback: deploy succeeds" [ "$RC" = 0 ]

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

# --- burn-in lib against the fake xkmsctl --------------------------------------
lib=$here/scripts/xkms/burnin/lib.sh
LB() { # LB <log> <code>: run <code> with lib.sh sourced, against the fake xkmsctl; set RC
	rm -rf "$tmp/kms" "$tmp/bi"
	mkdir -p "$tmp/kms" "$tmp/bi"
	set +e
	FAKE_KMS=$tmp/kms XKMS_CTL=xkmsctl XKMS_WORK=$tmp/bi XKMS_BOARD=board.invalid BI_WRITE_CERT=0 \
		bash -c 'source "$1"; eval "$2"' _ "$lib" "$2" >"$1" 2>&1
	RC=$?
	set -e
}
# generate is acknowledged, every follow-up call fails, and refused writes are
# notes only (BI_WRITE_FAIL_OK=1): the ids must still be owed
# shellcheck disable=SC2016 # the code runs in LB's shell, with lib.sh sourced
ackset='BI_WRITE_FAIL_OK=1; export FAKE_CTL_FAIL="encrypt sign get"; bi_write_set s 2 bi-x; unset FAKE_CTL_FAIL; cat "$(bi_ledger s)"'
LB "$tmp/l1.log" "$ackset; bi_verify_set s; bi_summary t"
ok "acknowledged create, failed follow-up: the id is in the ledger" out_has "$tmp/l1.log" "ack|bi-x-0|"
ok "acknowledged create, failed follow-up: so is the signing key" out_has "$tmp/l1.log" "ack|bi-x-1|"
ok "acknowledged create, failed follow-up: verify passes while the keys exist" [ "$RC" = 0 ]
LB "$tmp/l2.log" "$ackset; rm -f \"\$FAKE_KMS/bi-x-0\"; bi_verify_set s; bi_summary t"
ok "acknowledged key missing: verify FAILs" [ "$RC" != 0 ]
ok "acknowledged key missing: CRITICAL names it" out_has "$tmp/l2.log" "CRITICAL: acknowledged key bi-x-0 does not exist"

# --- bi_restart proves the restart happened ------------------------------------
R=$tmp/boardR
mkboard "$R"
echo 100 >"$R/run/pid"
mkdir -p "$R/proc/sys/kernel/random"
echo boot-0001 >"$R/proc/sys/kernel/random/boot_id"
export XKMS_FAKE_ROOT=$R XKMS_KILL_WAIT=0 XKMS_REBOOT_WAIT=0
RS() { # RS <log> <mode> [<fake-board flag>]: one bi_restart, RC from bi_summary
	rm -f "$R/run/restartfail" "$R/run/killfail" "$R/run/samepid"
	[ -z "${3:-}" ] || touch "$R/run/$3"
	echo active >"$R/run/state"
	LB "$1" "bi_check restart bi_restart $2; bi_summary t"
}
for mode in graceful kill9; do
	RS "$tmp/r-$mode.log" "$mode"
	ok "$mode restart with a new MainPID passes" [ "$RC" = 0 ]
	RS "$tmp/r-$mode-same.log" "$mode" samepid
	ok "$mode restart with an unchanged MainPID FAILs" [ "$RC" != 0 ]
	ok "$mode restart with an unchanged MainPID says so" out_has "$tmp/r-$mode-same.log" "MainPID is still"
done
RS "$tmp/r-gfail.log" graceful restartfail
ok "a failed systemctl restart FAILs" [ "$RC" != 0 ]
ok "a failed systemctl restart says so" out_has "$tmp/r-gfail.log" "systemctl restart xkmsd failed"
RS "$tmp/r-kfail.log" kill9 killfail
ok "a failed systemctl kill FAILs" [ "$RC" != 0 ]
# the fake board never reboots: sysrq writes land in the temp root, and the
# boot_id stays the same
# boot_id stays the same. Never run it against a lib.sh that would write the
# host's own /proc/sysrq-trigger.
if [ -n "$XKMS_FAKE_ROOT" ] && grep -q 'BI_ROOT/proc/sysrq-trigger' "$lib"; then
	RS "$tmp/r-hard.log" hard
	ok "a hard reboot with an unchanged boot_id FAILs" [ "$RC" != 0 ]
	ok "a hard reboot with an unchanged boot_id says so" out_has "$tmp/r-hard.log" "boot_id is still boot-0001"
	ok "the sysrq trigger went to the fake root" [ "$(cat "$R/proc/sysrq-trigger")" = b ]
else
	fail "hard reboot" "lib.sh does not keep sysrq inside XKMS_FAKE_ROOT; not run"
fi
unset XKMS_KILL_WAIT XKMS_REBOOT_WAIT

# --- concurrency.sh counts failed signs ----------------------------------------
CC() { # CC <log> [<FAKE_CTL_FAIL>]: concurrency.sh, 3 clients, 1 round; set RC
	rm -rf "$tmp/kms" "$tmp/bi"
	mkdir -p "$tmp/kms" "$tmp/bi"
	echo active >"$R/run/state"
	set +e
	FAKE_CTL_FAIL=${2:-} FAKE_KMS=$tmp/kms XKMS_CTL=xkmsctl XKMS_WORK=$tmp/bi \
		"$here/scripts/xkms/burnin/concurrency.sh" --clients 3 --rounds 1 board.invalid >"$1" 2>&1
	RC=$?
	set -e
}
CC "$tmp/cc-ok.log"
ok "concurrency: all signs verify, PASS" [ "$RC" = 0 ]
CC "$tmp/cc-fail.log" sign
ok "concurrency: every sign request fails, FAIL" [ "$RC" != 0 ]
ok "concurrency: the failed signs are counted" out_has "$tmp/cc-fail.log" "(3 failed)"
CC "$tmp/cc-bad.log" badsig
ok "concurrency: answers without a signature, FAIL" [ "$RC" != 0 ]
ok "concurrency: no client verified" out_has "$tmp/cc-bad.log" "(0 of 3)"
# the delete check needs xkmsctl's own not-found answer: an error is no proof
gone_check_failed() { # the delete check of a log has a FAIL line (its "acknowledged)" is followed by a colon)
	case $(cat "$1") in *"FAIL round 1: bi-cc-"*"gone after concurrent deletes ("*" acknowledged): "*) return 0 ;; *) return 1 ;; esac
}
ok "concurrency: a real not-found passes the delete check" out_has "$tmp/cc-ok.log" "gone after concurrent deletes ("
gone_check_not_failed() { ! gone_check_failed "$1"; }
ok "concurrency: the not-found delete check does not fail" gone_check_not_failed "$tmp/cc-ok.log"
FAKE_CTL_MISSING_ERR="dial tcp 192.0.2.1:8443: connect: connection refused" CC "$tmp/cc-conn.log"
ok "concurrency: a connection error on the delete read, FAIL" [ "$RC" != 0 ]
ok "concurrency: the delete check is the one that fails" gone_check_failed "$tmp/cc-conn.log"
ok "concurrency: the connection error text is reported" out_has "$tmp/cc-conn.log" "connection refused"
FAKE_CTL_KEEP=1 CC "$tmp/cc-keep.log"
ok "concurrency: a key still present after the deletes, FAIL" [ "$RC" != 0 ]
ok "concurrency: the still-present key is named" out_has "$tmp/cc-keep.log" "still exists"

# --- xkmsd-build.sh pins its toolchain and its environment -----------------------
# A stub go reports the release in $gobin/release and records the environment
# it is built in; the go-xkms repository is a local one-commit repository.
gobin=$tmp/gobin
mkdir -p "$gobin"
cat >"$gobin/go" <<EOF
#!/bin/bash
case \$1 in
version) echo "go version \$(cat "$gobin/release") linux/amd64" ;;
build)
	env | LC_ALL=C sort >>"$gobin/build.env"
	while [ \$# -gt 0 ]; do case \$1 in -o) printf 'stub binary\n' >"\$2"; shift ;; esac; shift; done
	;;
*) exit 2 ;;
esac
EOF
chmod +x "$gobin/go"
gx=$tmp/go-xkms
mkdir -p "$gx"
git -C "$gx" init -q
echo 0.1.0 >"$gx/VERSION"
git -C "$gx" add VERSION
GIT_AUTHOR_DATE=2026-01-02T03:04:05Z GIT_COMMITTER_DATE=2026-01-02T03:04:05Z \
	git -C "$gx" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init
gxc=$(git -C "$gx" rev-parse HEAD)
BLD() { # BLD <log> <outdir> <go release> [VAR=value...]: build the fake commit with the stub go; set RC
	local log=$1 out=$2
	echo "$3" >"$gobin/release"
	shift 3
	: >"$gobin/build.env"
	set +e
	env "$@" PATH="$gobin:$PATH" XKMS_REPO="$gx" XKMS_SRC="$tmp/gosrc" XKMS_OUT="$out" \
		"$here/scripts/xkms/xkmsd-build.sh" "$gxc" >"$log" 2>&1
	RC=$?
	set -e
}
pin=$(while read -r l; do case $l in go_pin=*) echo "${l#go_pin=}"; break ;; esac; done <"$here/scripts/xkms/xkmsd-build.sh")
ok "build: the script names one pinned release" [ -n "$pin" ]
BLD "$tmp/bld-old.log" "$tmp/bld-old" go1.0.1
ok "build: a go that is not the pinned release is refused" [ "$RC" != 0 ]
ok "build: the refusal names the pin and the go found" out_has "$tmp/bld-old.log" "pinned to $pin, found: go version go1.0.1"
ok "build: refused before any build ran" [ ! -s "$gobin/build.env" ]
ok "build: refused before anything was written" [ ! -e "$tmp/bld-old/$gxc" ]
BLD "$tmp/bld-1.log" "$tmp/bld-1" "$pin" GOFLAGS=-mod=mod GOEXPERIMENT=boringcrypto GOAMD64=v3 GOARM64=v9.0 CGO_ENABLED=1 GOTOOLCHAIN=auto
ok "build: the pinned release builds" [ "$RC" = 0 ]
ok "build: the build ran" [ -s "$gobin/build.env" ]
ok "build: the caller's GOFLAGS did not reach the build" out_lacks "$gobin/build.env" "mod=mod"
ok "build: the caller's GOEXPERIMENT did not reach the build" out_lacks "$gobin/build.env" "boringcrypto"
ok "build: GOFLAGS is empty" out_has "$gobin/build.env" $'\nGOFLAGS=\n'
ok "build: GOEXPERIMENT is empty" out_has "$gobin/build.env" $'\nGOEXPERIMENT=\n'
ok "build: GOTOOLCHAIN=local whatever the caller set" out_has "$gobin/build.env" "GOTOOLCHAIN=local"
ok "build: CGO_ENABLED=0 whatever the caller set" out_has "$gobin/build.env" "CGO_ENABLED=0"
ok "build: GOAMD64 is the default" out_has "$gobin/build.env" $'\nGOAMD64=v1\n'
ok "build: GOARM64 is the default" out_has "$gobin/build.env" $'\nGOARM64=v8.0\n'
ok "build: GOPATH is fixed, outside the source tree" out_has "$gobin/build.env" "GOPATH=$here/build/go-xkms/gopath"
ok "build: GOCACHE is fixed, outside the source tree" out_has "$gobin/build.env" "GOCACHE=$here/build/go-xkms/gocache"
ok "build: the manifest records the pin" out_has "$tmp/bld-1/$gxc/manifest.txt" "go-pinned: $pin"
ok "build: the manifest records GOTOOLCHAIN=local" out_has "$tmp/bld-1/$gxc/manifest.txt" "GOTOOLCHAIN=local"
ok "build: the manifest records the clean GOFLAGS" out_has "$tmp/bld-1/$gxc/manifest.txt" "GOFLAGS= GOEXPERIMENT="
ok "build: the manifest holds no host path" out_lacks "$tmp/bld-1/$gxc/manifest.txt" "$here"
BLD "$tmp/bld-2.log" "$tmp/bld-2" "$pin"
ok "build: a second build of the commit succeeds" [ "$RC" = 0 ]
# The records must carry the pin and the environment, not merely agree: two
# records that both lack them are identical too.
same_pinned_records() {
	local m1=$tmp/bld-1/$gxc/manifest.txt m2=$tmp/bld-2/$gxc/manifest.txt m
	for m in "$m1" "$m2"; do
		out_has "$m" "go-pinned: $pin" || { echo "$m: no go-pinned line"; return 1; }
		out_has "$m" "go-version: go version $pin " || { echo "$m: no go-version line"; return 1; }
		out_has "$m" "env: " || { echo "$m: no env line"; return 1; }
		out_has "$m" "GOTOOLCHAIN=local" || { echo "$m: no GOTOOLCHAIN=local"; return 1; }
		out_has "$m" "GOFLAGS= GOEXPERIMENT=" || { echo "$m: no clean GOFLAGS/GOEXPERIMENT"; return 1; }
	done
	cmp -s "$m1" "$m2"
}
ok "build: two builds of one commit give identical records that carry the pin and the environment" same_pinned_records

# --- burn-in writers drain at a stop -------------------------------------------
# Every create takes FAKE_CTL_SLOW seconds to be answered after it succeeded,
# and restart-load.sh stops its writers about 2s in: each is mid-request then.
# A writer killed there would leave an answered create out of its ledger.
RL() { # RL <log> [<VAR=value>...]: restart-load.sh, 2 writers, 1 restart; set RC
	rm -rf "$tmp/kms" "$tmp/bi"
	mkdir -p "$tmp/kms" "$tmp/bi"
	: >"$tmp/ctl-acked"
	echo active >"$R/run/state"
	set +e
	env "${@:2}" FAKE_KMS="$tmp/kms" FAKE_CTL_ACKED="$tmp/ctl-acked" XKMS_CTL=xkmsctl XKMS_WORK="$tmp/bi" XKMS_KILL_WAIT=0 \
		"$here/scripts/xkms/burnin/restart-load.sh" --writers 2 --cycles 1 --gap-secs 1 board.invalid >"$1" 2>&1
	RC=$?
	set -e
	sleep 4 # a killed writer's xkmsctl would answer now, into no ledger
}
all_answered_in_ledger() { # every create xkmsctl answered is acknowledged in a ledger
	local id n=0
	while read -r id; do
		n=$((n + 1))
		grep -qxF "ack|$id||||" "$tmp"/bi/ledger.w* || { echo "answered but not in a ledger: $id"; return 1; }
	done <"$tmp/ctl-acked"
	[ "$n" -gt 0 ]
}
RL "$tmp/rl-drain.log" FAKE_CTL_SLOW=3
ok "drain: restart-load passes with a slow xkmsctl" [ "$RC" = 0 ]
ok "drain: every answered create is in a ledger" all_answered_in_ledger
ok "drain: no writer had to be killed" out_lacks "$tmp/rl-drain.log" "killing its process group"
# a writer stuck past the bounded wait is killed with its process group; its
# request is unknown, not lost
: >"$tmp/ctl-pids"
export FAKE_CTL_PIDS=$tmp/ctl-pids
# shellcheck disable=SC2016 # the code runs in LB's shell, with lib.sh sourced
LB "$tmp/hk.log" 'bi_write_set w1 1 bi-pre; export FAKE_CTL_SLOW=30; bi_spawn_writer w1 bi-hk; sleep 1; bi_stop_writers 1; bi_verify_set w1; bi_summary t'
unset FAKE_CTL_PIDS
pid_dead() { # <pid>: gone, or a zombie (killed, not yet reaped by init: kill -0 still answers)
	local s
	[ -r "/proc/$1/stat" ] || return 0
	{ read -r s <"/proc/$1/stat"; } 2>/dev/null || return 0
	s=${s##*) }
	case ${s%% *} in Z | X) return 0 ;; *) return 1 ;; esac
}
ctl_gone() { # every stub xkmsctl recorded in ctl-pids is dead, within a bounded wait
	local p t=0 alive
	[ -s "$tmp/ctl-pids" ] || return 1
	# The group kill is signalled before bi_stop_writers returns, but the
	# processes die and are reaped asynchronously: wait for the condition,
	# at most 10s, not for a fixed time.
	while [ "$t" -lt 100 ]; do
		alive=0
		while read -r p; do pid_dead "$p" || alive=1; done <"$tmp/ctl-pids"
		[ "$alive" = 0 ] && return 0
		t=$((t + 1))
		sleep 0.1
	done
	return 1
}
ok "hard kill: the stuck xkmsctl went with its writer's process group" ctl_gone
ok "hard kill: the writer is killed after the bounded wait" out_has "$tmp/hk.log" "killing its process group"
ok "hard kill: the in-flight create is unknown" out_has "$tmp/hk.log" "1 create(s) never acknowledged"
ok "hard kill: nothing is reported lost" out_lacks "$tmp/hk.log" CRITICAL
ok "hard kill: verify passes" [ "$RC" = 0 ]

# --- diskfull.sh must see the disk full ----------------------------------------
# The fake board's filesystem has 1000 KiB free; the filler goes in its
# state directory, and the stub xkmsctl reports no space after N creates
# (and has no certificates: BI_WRITE_CERT=0).
DF() { # DF <log> [<VAR=value>...]: diskfull.sh on the fake board; set RC
	rm -rf "$tmp/kms" "$tmp/bi"
	mkdir -p "$tmp/kms" "$tmp/bi"
	echo active >"$R/run/state"
	set +e
	env FAKE_DF_FREE=1000 "${@:2}" FAKE_KMS="$tmp/kms" XKMS_CTL=xkmsctl XKMS_WORK="$tmp/bi" BI_WRITE_CERT=0 \
		"$here/scripts/xkms/burnin/diskfull.sh" --keys 2 --max-writes 30 --attempts 2 board.invalid >"$1" 2>&1
	RC=$?
	set -e
}
DF "$tmp/df-ok.log" FAKE_CTL_NOSPACE_AFTER=4
ok "diskfull: no space after 4 writes passes" [ "$RC" = 0 ]
ok "diskfull: the no-space write is named" out_has "$tmp/df-ok.log" "xkmsd reported no space at write 5"
ok "diskfull: the writes before it are verified" out_has "$tmp/df-ok.log" "PASS verify full: 8 ledger entries intact"
ok "diskfull: writes work again" out_has "$tmp/df-ok.log" "PASS writes work again once space is free (5 of 5)"
ok "diskfull: the filler is gone" [ ! -e "$R/var/lib/xkms/.burnin-filler" ]
DF "$tmp/df-never.log"
ok "diskfull: a daemon never out of space FAILs" [ "$RC" != 0 ]
ok "diskfull: says the disk was never full" out_has "$tmp/df-never.log" "the disk was never full: 30 writes went by"
ok "diskfull: the filler is gone after a FAIL" [ ! -e "$R/var/lib/xkms/.burnin-filler" ]
DF "$tmp/df-root.log" FAKE_CTL_NOSPACE_AFTER=1 FAKE_DF_RESERVED=500 FAKE_UNIT_USER=root
ok "diskfull: a root xkmsd gets the reserved blocks filled too" out_has "$tmp/df-root.log" "(1244 KiB, 256 KiB left to xkmsd)"
ok "diskfull: the reserved blocks are reported" out_has "$tmp/df-root.log" "it can use the 500 KiB reserved for root"
DF "$tmp/df-user.log" FAKE_CTL_NOSPACE_AFTER=1 FAKE_DF_RESERVED=500 FAKE_UNIT_USER=xkms
ok "diskfull: a non-root xkmsd leaves the reserved blocks" out_has "$tmp/df-user.log" "(744 KiB, 256 KiB left to xkmsd)"
ok "diskfull: and says so" out_has "$tmp/df-user.log" "the 500 KiB reserved for root are not its to use"
# A create that succeeds but answers after 26 s (under the 30 s timeout) is
# owed like any other: it must be acked in the ledger and verified, and is
# reported as SLOW, not as hung or lost.
DF "$tmp/df-slow.log" FAKE_CTL_NOSPACE_AFTER=4 FAKE_CTL_SLOW=26 'FAKE_CTL_SLOW_MATCH=*-full-1'
slow_id=$(cd "$tmp/kms" && echo bi-df-*-full-1)
ok "diskfull slow: passes" [ "$RC" = 0 ]
ok "diskfull slow: the slow create is acked in the ledger" out_has "$tmp/bi/ledger.full" "ack|$slow_id|"
ok "diskfull slow: reported as SLOW" out_has "$tmp/df-slow.log" "SLOW: create $slow_id took"
ok "diskfull slow: not counted as hung" out_has "$tmp/df-slow.log" "0 hung, 1 slow"
ok "diskfull slow: every acked write verified" out_has "$tmp/df-slow.log" "PASS verify full: 8 ledger entries intact"

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
