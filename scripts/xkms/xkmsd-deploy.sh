#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2153,SC2012,SC2029 # the r_* functions run on the board: their variables come from the header board() sends; the client-side expansion in the upload is intended
# Deploy an xkmsd build to the board with a backup, a health check and an
# automatic rollback.
#
#   scripts/xkms/xkmsd-deploy.sh [--dry-run] <ssh target> <build dir>
#   scripts/xkms/xkmsd-deploy.sh --rollback <stamp> [--dry-run] <ssh target>
#
# Runs from a host that can ssh to the board as root. The board-side steps
# are the r_* functions below: they are sent over ssh on stdin, so nothing
# needs installing on the board. They print paths, hashes and reasons only:
# no configuration, key or unseal material is ever read out or printed.
#
# Environment (all optional):
#   XKMS_SSH_OPTS     extra ssh options (default: BatchMode, ConnectTimeout=10)
#   XKMS_KEEP         backups to keep (default 5)
#   XKMS_HEALTH_WAIT  seconds to wait for the unit and its listener (30)
#   XKMS_SETTLE       seconds the unit must stay up after the check (3)
#   XKMS_MIN_FREE_KB  free space to leave after the backup, in KiB (51200)
#   XKMS_PORT         TCP port the listener must be on (any port if unset); the
#                     board needs one of ss, netstat or /proc/net/tcp
#   XKMS_STAMP        backup name (default: the UTC time now); tests set it
#   XKMS_FAKE_ROOT    prefix for every board path; tests only, empty on a board
set -uo pipefail

usage() {
	cat <<'EOF'
usage: xkmsd-deploy.sh [--dry-run] <ssh target> <build dir>
       xkmsd-deploy.sh --rollback <stamp> [--dry-run] <ssh target>

Install build/xkms/<commit>/xkmsd on the board:
  1. preflight: board reachable, unit exists, enough disk
  2. upload the binary beside the old one; check its hash and --version
  3. stop xkmsd; back up /usr/local/bin/xkmsd, /etc/xkms and /var/lib/xkms
     to /var/backups/xkms/<UTC stamp>/ with a SHA256SUMS list
  4. install the new binary and start the unit
  5. health check: unit active, a listener owned by the daemon, the version
     names the build's go-xkms commit, and the unit stays up
  6. on any failure restore the backup, restart, and exit nonzero
The newest 5 backups are kept. xkmsd has no config validate mode: the config
is checked by the start itself, and a bad one fails step 5.

  --rollback <stamp>  restore that backup and restart; no build dir needed
  --dry-run           print the plan; contact nothing
EOF
}

die() {
	echo "xkmsd-deploy: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Board side. Sent over ssh; keep to POSIX tools a board has.
# ---------------------------------------------------------------------------

r_init() {
	BIN="$R/usr/local/bin/xkmsd"
	NEWBIN="$R/usr/local/bin/.xkmsd.new"
	ETC="$R/etc/xkms"
	VAR="$R/var/lib/xkms"
	BK="$R/var/backups/xkms"
	umask 077
}

r_sums() { # r_sums <dir>: the per-file SHA-256 list of a tree, sorted by path
	(cd "$1" && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2)
}

r_treesum() { r_sums "$1" | sha256sum | cut -d' ' -f1; }

r_preflight() { # r_preflight <new binary KiB>
	r_init
	command -v systemctl >/dev/null || { echo "board: no systemctl"; return 1; }
	type ss >/dev/null 2>&1 || type netstat >/dev/null 2>&1 || [ -r "$R/proc/net/tcp" ] ||
		{ echo "board: none of ss, netstat or /proc/net/tcp, cannot check the listener"; return 1; }
	systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "board: unit $UNIT does not exist"; return 1; }
	[ -x "$BIN" ] || { echo "board: $BIN is missing"; return 1; }
	[ -d "$ETC" ] || { echo "board: $ETC is missing"; return 1; }
	[ -d "$VAR" ] || { echo "board: $VAR is missing"; return 1; }
	mkdir -p "$BK" && chmod 700 "$BK" || { echo "board: cannot create $BK"; return 1; }
	need=$1
	for n in $(du -sk "$BIN" "$ETC" "$VAR" | cut -f1); do need=$((need + n)); done
	free=$(df -Pk "$BK" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)
	[ "${free:-0}" -ge $((need + MINKB)) ] || {
		echo "board: $free KiB free in $BK, need $((need + MINKB)) KiB"
		return 1
	}
	echo "board: preflight ok ($free KiB free, $need KiB to back up and install)"
}

r_stage() { # r_stage <sha256> <go-xkms commit>: the uploaded binary is what we meant
	r_init
	got=$(sha256sum "$NEWBIN" | cut -d' ' -f1)
	[ "$got" = "$1" ] || { rm -f "$NEWBIN"; echo "board: upload hash $got, expected $1"; return 1; }
	chmod 755 "$NEWBIN"
	v=$("$NEWBIN" --version 2>&1) || { rm -f "$NEWBIN"; echo "board: the new binary does not run here"; return 1; }
	case $v in
	*"$2"*) ;;
	*) rm -f "$NEWBIN"; echo "board: the new binary's version does not name $2"; return 1 ;;
	esac
	echo "board: staged $NEWBIN sha256 $got"
}

r_unstage() { r_init; rm -f "$NEWBIN"; }

r_backup() { # r_backup <stamp>: with xkmsd stopped
	r_init
	d="$BK/$1"
	[ ! -e "$d" ] || { echo "board: backup $d already exists"; return 1; }
	if systemctl is-active --quiet "$UNIT"; then was=active; else was=inactive; fi
	"$BIN" --version >"$BK/.version.$$" 2>&1 || true
	systemctl stop "$UNIT" || { echo "board: cannot stop $UNIT"; rm -f "$BK/.version.$$"; return 1; }
	if systemctl is-active --quiet "$UNIT"; then
		echo "board: $UNIT still active after stop"
		rm -f "$BK/.version.$$"
		return 1
	fi
	mkdir "$d" && cp -a "$BIN" "$d/xkmsd" && cp -a "$ETC" "$d/etc-xkms" &&
		cp -a "$VAR" "$d/var-lib-xkms" || {
		echo "board: backup copy failed (disk?)"
		rm -rf "$d" "$BK/.version.$$"
		return 1
	}
	mv "$BK/.version.$$" "$d/VERSION"
	echo "$was" >"$d/WAS_ACTIVE"
	{
		(cd "$d" && sha256sum xkmsd)
		(cd "$d" && find etc-xkms var-lib-xkms -type f -exec sha256sum {} + | LC_ALL=C sort -k2)
	} >"$d/SHA256SUMS"
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) || {
		echo "board: backup does not verify"
		rm -rf "$d"
		return 1
	}
	echo "board: backup $d ($(wc -l <"$d/SHA256SUMS") files, list $d/SHA256SUMS)"
}

r_install() {
	r_init
	mv -f "$NEWBIN" "$BIN" || { echo "board: cannot install $BIN"; return 1; }
	echo "board: installed $BIN sha256 $(sha256sum "$BIN" | cut -d' ' -f1)"
}

r_start() { systemctl start "$UNIT" || { echo "board: systemctl start $UNIT failed"; return 1; }; }

r_listening() { # r_listening <pid>: a LISTEN socket owned by pid (on port $PORT when set)
	local p=$1 line t la st ino f hp
	if type ss >/dev/null 2>&1; then
		while read -r line; do
			[[ $line == *"pid=$p,"* ]] || continue
			[ -z "${PORT:-}" ] || [[ $line == *":$PORT "* ]] || continue
			return 0
		done < <(ss -ltnp 2>/dev/null)
	fi
	if type netstat >/dev/null 2>&1; then
		while read -r line; do
			[[ $line == *" $p/"* ]] || continue
			[ -z "${PORT:-}" ] || [[ $line == *":$PORT "* ]] || continue
			return 0
		done < <(netstat -ltnp 2>/dev/null)
	fi
	hp=""
	[ -z "${PORT:-}" ] || hp=$(printf '%04X' "$PORT")
	for t in tcp tcp6; do
		[ -r "$R/proc/net/$t" ] || continue
		while read -r _ la _ st _ _ _ _ _ ino _; do
			[ "$st" = 0A ] || continue
			[ -z "$hp" ] || [ "${la##*:}" = "$hp" ] || continue
			for f in "$R/proc/$p/fd/"*; do
				[ "$(readlink "$f" 2>/dev/null)" = "socket:[$ino]" ] && return 0
			done
		done <"$R/proc/net/$t"
	done
	return 1
}

r_health() { # r_health [<go-xkms commit>]
	r_init
	i=0
	pid=0
	while [ "$i" -lt "$WAIT" ]; do
		if systemctl is-active --quiet "$UNIT"; then
			pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
			if [ "${pid:-0}" != 0 ]; then
				r_listening "$pid" && break
			fi
		fi
		pid=0
		i=$((i + 1))
		sleep 1
	done
	if [ "$pid" = 0 ]; then
		systemctl is-active --quiet "$UNIT" || { echo "health: $UNIT is not active"; return 1; }
		echo "health: $UNIT is active but no listener of its own after ${WAIT}s"
		return 1
	fi
	echo "health: $UNIT active, listener owned by pid $pid"
	if [ -n "${1:-}" ]; then
		v=$("$BIN" --version 2>&1)
		case $v in
		*"$1"*) echo "health: version names $1" ;;
		*) echo "health: installed binary does not report $1"; return 1 ;;
		esac
	fi
	sleep "$SETTLE"
	systemctl is-active --quiet "$UNIT" || { echo "health: $UNIT died within ${SETTLE}s"; return 1; }
	[ "$(systemctl show -p MainPID --value "$UNIT")" = "$pid" ] || {
		echo "health: $UNIT restarted within ${SETTLE}s (crash loop)"
		return 1
	}
	echo "health: ok"
}

r_restore() { # r_restore <stamp>
	r_init
	d="$BK/$1"
	[ -d "$d" ] || { echo "restore: no backup $d"; return 1; }
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) || { echo "restore: backup $d fails its SHA256SUMS; touching nothing"; return 1; }
	systemctl stop "$UNIT" || true
	rm -rf "$ETC.restore" "$VAR.restore" "$BIN.restore"
	cp -a "$d/etc-xkms" "$ETC.restore" && cp -a "$d/var-lib-xkms" "$VAR.restore" &&
		cp -a "$d/xkmsd" "$BIN.restore" || {
		rm -rf "$ETC.restore" "$VAR.restore" "$BIN.restore"
		echo "restore: copy from $d failed (disk?); live data untouched"
		return 1
	}
	rm -rf "$ETC" "$VAR"
	mv "$ETC.restore" "$ETC" && mv "$VAR.restore" "$VAR" && mv -f "$BIN.restore" "$BIN" ||
		{ echo "restore: swap failed; the backup $d is intact"; return 1; }
	if [ "$(r_treesum "$ETC")" = "$(r_treesum "$d/etc-xkms")" ] &&
		[ "$(r_treesum "$VAR")" = "$(r_treesum "$d/var-lib-xkms")" ] &&
		[ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$(sha256sum "$d/xkmsd" | cut -d' ' -f1)" ]; then
		echo "restore: $d restored, hashes match"
	else
		echo "restore: restored tree does not match $d"
		return 1
	fi
	if [ "$(cat "$d/WAS_ACTIVE")" = active ]; then
		systemctl start "$UNIT" || { echo "restore: restart failed"; return 1; }
	else
		echo "restore: $UNIT was not active at backup time; left stopped"
	fi
}

r_backup_commit() { # the go-xkms commit the backed-up binary reported, if any
	r_init
	while IFS= read -r l; do
		case $l in
		*"Git Commit:"*)
			l=${l#*Git Commit:}
			echo "${l# }"
			return 0
			;;
		esac
	done <"$BK/$1/VERSION" 2>/dev/null
	return 0
}

r_prune() {
	r_init
	n=0
	for s in $(ls -1 "$BK" 2>/dev/null | LC_ALL=C sort -r); do
		case $s in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
		*) continue ;;
		esac
		n=$((n + 1))
		if [ "$n" -gt "$KEEP" ]; then
			rm -rf "${BK:?}/$s"
			echo "board: pruned backup $s"
		fi
	done
}

# ---------------------------------------------------------------------------
# Host side.
# ---------------------------------------------------------------------------

dry=0
rollback=""
pos=()
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	--dry-run) dry=1 ;;
	--rollback)
		[ $# -ge 2 ] || die "--rollback needs a stamp"
		rollback=$2
		shift
		;;
	-*) die "unknown option $1" ;;
	*) pos+=("$1") ;;
	esac
	shift
done

if [ -n "$rollback" ]; then
	[ ${#pos[@]} -eq 1 ] || { usage >&2; exit 2; }
else
	[ ${#pos[@]} -eq 2 ] || { usage >&2; exit 2; }
	builddir=${pos[1]}
fi
target=${pos[0]}
case $target in -* | *[[:space:]]*) die "bad ssh target" ;; esac

stamp=${XKMS_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
case $stamp in
[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
*) die "stamp must look like 20261124T120000Z" ;;
esac
[ -z "$rollback" ] || stamp=$rollback
case $rollback in "" | [0-9]*T*Z) ;; *) die "bad stamp" ;; esac

keep=${XKMS_KEEP:-5}
wait_s=${XKMS_HEALTH_WAIT:-30}
settle=${XKMS_SETTLE:-3}
minkb=${XKMS_MIN_FREE_KB:-51200}
fake=${XKMS_FAKE_ROOT:-}
for v in "$keep" "$wait_s" "$settle" "$minkb"; do
	case $v in '' | *[!0-9]*) die "numeric option expected, got '$v'" ;; esac
done

if [ "$dry" = 1 ]; then
	if [ -n "$rollback" ]; then
		echo "plan: ssh $target: verify backup $stamp, stop xkmsd, restore binary, /etc/xkms and /var/lib/xkms, start, health check"
	else
		echo "plan: read $builddir/manifest.txt; check $builddir/xkmsd against its SHA-256"
		echo "plan: ssh $target: preflight (unit, disk), upload the binary, check its hash and --version"
		echo "plan: ssh $target: stop xkmsd, back up to /var/backups/xkms/$stamp/, install, start"
		echo "plan: health check: unit active, listener, version names the commit, stays up ${settle}s"
		echo "plan: on failure restore /var/backups/xkms/$stamp and restart; keep the newest $keep backups"
	fi
	exit 0
fi

# shellcheck disable=SC2206 # word splitting of the option string is intended
ssh_opts=(${XKMS_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10})

# board <action> [arg...]: run r_<action> on the board with the shared header.
board() {
	local action=$1 args=""
	shift
	[ $# -eq 0 ] || args=$(printf '%q ' "$@")
	{
		printf 'R=%q; UNIT=xkmsd; KEEP=%q; WAIT=%q; SETTLE=%q; MINKB=%q; PORT=%q\n' "$fake" "$keep" "$wait_s" "$settle" "$minkb" "${XKMS_PORT:-}"
		declare -f r_init r_sums r_treesum r_preflight r_stage r_unstage r_backup r_install r_start \
			r_listening r_health r_restore r_backup_commit r_prune
		echo "r_$action $args"
	} | ssh "${ssh_opts[@]}" "$target" "bash -s"
}

if [ -n "$rollback" ]; then
	echo "xkmsd-deploy: rolling back to $stamp"
	board restore "$stamp" || die "rollback to $stamp failed; the backup is in /var/backups/xkms/$stamp"
	want=$(board backup_commit "$stamp")
	board health "$want" || die "rolled back to $stamp but the health check failed"
	echo "xkmsd-deploy: rolled back to $stamp, healthy"
	exit 0
fi

[ -f "$builddir/manifest.txt" ] && [ -f "$builddir/xkmsd" ] || die "$builddir has no manifest.txt and xkmsd"
commit=""
want_sha=""
while IFS= read -r l; do
	case $l in
	"go-xkms-commit: "*) commit=${l#go-xkms-commit: } ;;
	"sha256: "*"  xkmsd") want_sha=${l#sha256: }; want_sha=${want_sha%%  *} ;;
	esac
done <"$builddir/manifest.txt"
[ -n "$commit" ] && [ -n "$want_sha" ] || die "manifest.txt lacks the commit or the xkmsd hash"
have_sha=$(sha256sum "$builddir/xkmsd" | cut -d' ' -f1)
[ "$have_sha" = "$want_sha" ] || die "$builddir/xkmsd does not match its manifest hash"
kib=$(($(wc -c <"$builddir/xkmsd") / 1024 + 1))
echo "xkmsd-deploy: go-xkms $commit, xkmsd sha256 $have_sha"

board preflight "$kib" || die "preflight failed"

if ! ssh "${ssh_opts[@]}" "$target" "umask 077; cat > '$fake/usr/local/bin/.xkmsd.new'" <"$builddir/xkmsd"; then
	board unstage
	die "upload failed"
fi
board stage "$have_sha" "$commit" || die "staging failed; the board still runs the old binary"

# From here the daemon is stopped: every failure restores.
rollback_now() {
	echo "xkmsd-deploy: FAILED: $1; restoring backup $stamp" >&2
	board unstage >/dev/null 2>&1
	if board restore "$stamp"; then
		board health "$(board backup_commit "$stamp")" || echo "xkmsd-deploy: restored, but the old build is unhealthy too" >&2
		echo "xkmsd-deploy: restored the previous state from $stamp" >&2
	else
		echo "xkmsd-deploy: RESTORE FAILED: the backup is in /var/backups/xkms/$stamp; do not delete it" >&2
	fi
	exit 1
}

board backup "$stamp" || {
	board start >/dev/null 2>&1
	die "backup failed; nothing was installed"
}
board install || rollback_now "install failed"
board start || rollback_now "start failed"
board health "$commit" || rollback_now "health check failed"
board prune
echo "xkmsd-deploy: deployed go-xkms $commit; backup $stamp"
