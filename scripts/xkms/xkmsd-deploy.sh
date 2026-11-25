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

r_fs() { df -Pk "$1" | tail -n 1 | tr -s ' ' | cut -d' ' -f6; } # r_fs <path>: its mount point

r_free() { df -Pk "$1" | tail -n 1 | tr -s ' ' | cut -d' ' -f4; } # r_free <path>: KiB free there

r_mounts() { # every mount point on the board, one per line
	if command -v findmnt >/dev/null 2>&1; then
		findmnt -rn -o TARGET
	else
		local _a _b _c _d mp _e
		while read -r _a _b _c _d mp _e; do printf '%s\n' "$mp"; done </proc/self/mountinfo
	fi
}

r_mounted() { # r_mounted <path>...: prints each mount point at or under a path; fails if none
	local m p hit=1
	while IFS= read -r m; do
		for p in "$@"; do
			case $m in "$p" | "$p"/*)
				echo "$m"
				hit=0
				break
				;;
			esac
		done
	done < <(r_mounts)
	return "$hit"
}

r_mountcheck() { # r_mountcheck <who>: refuse when a path a rollback swaps is or holds a mount point
	local m
	# The mount table holds resolved paths, so each path is checked as given
	# and resolved.
	m=$(r_mounted "$BIN" "$ETC" "$VAR" "$(r_real "$BIN")" "$(r_real "$ETC")" "$(r_real "$VAR")") || return 0
	echo "$1: ${m//$'\n'/, } is a mount point at or under $BIN, $ETC or $VAR. A rollback replaces those whole and cannot replace a mount point; move the state off the mount (or unmount it) first. xkmsd was not stopped."
	return 1
}

r_real() { # r_real <path>: the path with every symlink resolved, or as given when that fails
	readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

r_links() { # r_links <path>...: prints each symlink that is a path, a directory above it (below $R) or inside it; fails if none
	local p q hit=1
	for p in "$@"; do
		q=$p
		while [ -n "$q" ] && [ "$q" != "$R" ]; do
			if [ -L "$q" ]; then
				echo "$q"
				hit=0
			fi
			q=${q%/*}
		done
		if [ -d "$p" ] && [ ! -L "$p" ]; then
			while IFS= read -r q; do
				echo "$q"
				hit=0
			done < <(find "$p" -type l)
		fi
	done
	return "$hit"
}

r_linkcheck() { # r_linkcheck <who>: refuse when a path a rollback swaps is, sits under or holds a symlink
	local l
	l=$(r_links "$BIN" "$ETC" "$VAR") || return 0
	echo "$1: ${l//$'\n'/, } is a symlink at, above or inside $BIN, $ETC or $VAR. The backup would copy the link and not what it points to, and a rollback would put back only the link; replace it with the real file or directory first. xkmsd was not stopped."
	return 1
}

r_stop() { # r_stop <who>: stop the unit, then prove nothing of it still runs
	local p c
	systemctl stop "$UNIT" || { echo "$1: systemctl stop $UNIT failed"; return 1; }
	if systemctl is-active --quiet "$UNIT"; then
		echo "$1: $UNIT still active after stop"
		return 1
	fi
	p=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
	[ "${p:-0}" = 0 ] || { echo "$1: $UNIT still has MainPID $p after stop"; return 1; }
	for p in "$R"/proc/[0-9]*/comm; do
		[ -r "$p" ] || continue
		read -r c <"$p" 2>/dev/null || continue
		[ "$c" != xkmsd ] || { echo "$1: an xkmsd process (pid $(basename "${p%/comm}")) still runs after stop"; return 1; }
	done
}

r_preflight() { # r_preflight <new binary KiB>
	r_init
	command -v systemctl >/dev/null || { echo "board: no systemctl"; return 1; }
	type ss >/dev/null 2>&1 || type netstat >/dev/null 2>&1 || [ -r "$R/proc/net/tcp" ] ||
		{ echo "board: none of ss, netstat or /proc/net/tcp, cannot check the listener"; return 1; }
	systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "board: unit $UNIT does not exist"; return 1; }
	[ -x "$BIN" ] || { echo "board: $BIN is missing"; return 1; }
	[ -d "$ETC" ] || { echo "board: $ETC is missing"; return 1; }
	[ -d "$VAR" ] || { echo "board: $VAR is missing"; return 1; }
	r_linkcheck "board: refusing to deploy" || return 1
	r_mountcheck "board: refusing to deploy" || return 1
	mkdir -p "$BK" && chmod 700 "$BK" || { echo "board: cannot create $BK"; return 1; }
	# What each filesystem must hold at once: the backup copy in $BK; the staged
	# binary beside $BIN; and the copy of each tree that a rollback makes beside
	# the live one before it swaps them (the live tree still exists then).
	local kb ke kv reqs fs want f k
	kb=$(du -sk "$BIN" | cut -f1) ke=$(du -sk "$ETC" | cut -f1) kv=$(du -sk "$VAR" | cut -f1)
	reqs="$(r_fs "$BK") $((kb + ke + kv))
$(r_fs "$BIN") $(($1 + kb))
$(r_fs "$ETC") $ke
$(r_fs "$VAR") $kv"
	for fs in $(printf '%s\n' "$reqs" | cut -d' ' -f1 | LC_ALL=C sort -u); do
		want=0
		while read -r f k; do [ "$f" != "$fs" ] || want=$((want + k)); done <<<"$reqs"
		free=$(r_free "$fs")
		[ "${free:-0}" -ge $((want + MINKB)) ] || {
			echo "board: $free KiB free on $fs, need $((want + MINKB)) KiB (backup, staged binary and the copies a rollback makes)"
			return 1
		}
		echo "board: $fs has $free KiB free, $want KiB reserved for backup, install and rollback"
	done
	echo "board: preflight ok"
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

r_unstage() { r_init; rm -f "$NEWBIN" || { echo "board: cannot remove the staged $NEWBIN"; return 1; }; }

r_backup() { # r_backup <stamp>: with xkmsd stopped
	r_init
	d="$BK/$1"
	[ ! -e "$d" ] || { echo "board: backup $d already exists"; return 1; }
	if systemctl is-active --quiet "$UNIT"; then was=active; else was=inactive; fi
	"$BIN" --version >"$BK/.version.$$" 2>&1 || true
	r_stop board || { rm -f "$BK/.version.$$"; return 1; }
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
	local d="$BK/$1" t done_="" u
	[ -d "$d" ] || { echo "restore: no backup $d"; return 1; }
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) || { echo "restore: backup $d fails its SHA256SUMS; touching nothing"; return 1; }
	# The swap below renames $ETC, $VAR and $BIN; a mount point cannot be
	# renamed, and rm -rf would empty it and then fail. Refuse before stopping.
	r_mountcheck "restore: refusing; live tree untouched, the backup is in $d" || return 1
	# A symlink in the live tree would be swapped as a link; one in the
	# backup (made before deploys refused them) would be restored as one.
	r_linkcheck "restore: refusing; live tree untouched, the backup is in $d" || return 1
	t=$(find "$d" -type l)
	[ -z "$t" ] || { echo "restore: backup $d holds symlinks (${t//$'\n'/, }), not the data they point to; touching nothing"; return 1; }
	rm -rf "$ETC.restore" "$VAR.restore" "$BIN.restore" "$ETC.old" "$VAR.old" "$BIN.old" || {
		echo "restore: cannot clear leftovers beside $ETC, $VAR or $BIN; live tree untouched; the backup is in $d"
		return 1
	}
	# Never replace live state under a running daemon: it would write into the
	# restored tree or keep stale handles. Stop it and prove it is gone first.
	r_stop restore || { echo "restore: refusing to touch $ETC, $VAR or $BIN while xkmsd may run; live tree untouched"; return 1; }
	cp -a "$d/etc-xkms" "$ETC.restore" && cp -a "$d/var-lib-xkms" "$VAR.restore" &&
		cp -a "$d/xkmsd" "$BIN.restore" || {
		rm -rf "$ETC.restore" "$VAR.restore" "$BIN.restore"
		echo "restore: copy from $d failed (disk?); live data untouched; the backup is in $d"
		return 1
	}
	# The swap: each live item is renamed aside before its restored copy takes
	# its place, so nothing live is deleted until the restored tree verifies,
	# and a failed step puts back what was already swapped.
	for t in "$ETC" "$VAR" "$BIN"; do
		if mv "$t" "$t.old"; then
			if mv "$t.restore" "$t"; then
				done_="$t $done_"
				continue
			fi
			mv "$t.old" "$t" || echo "restore: cannot put $t.old back as $t"
		fi
		echo "restore: swapping $t failed; the backup is in $d"
		for u in $done_; do
			mv "$u" "$u.restore" && mv "$u.old" "$u" || echo "restore: cannot put $u.old back as $u"
		done
		echo "restore: stopped with xkmsd stopped; the backup $d is intact"
		return 1
	done
	if [ "$(r_treesum "$ETC")" = "$(r_treesum "$d/etc-xkms")" ] &&
		[ "$(r_treesum "$VAR")" = "$(r_treesum "$d/var-lib-xkms")" ] &&
		[ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$(sha256sum "$d/xkmsd" | cut -d' ' -f1)" ]; then
		echo "restore: $d restored, hashes match"
	else
		echo "restore: restored tree does not match $d; the replaced state is in $ETC.old, $VAR.old and $BIN.old; the backup is in $d"
		return 1
	fi
	rm -rf "$ETC.old" "$VAR.old" "$BIN.old" || {
		echo "restore: restored and verified, but cannot remove $ETC.old, $VAR.old or $BIN.old; xkmsd left stopped; the backup is in $d"
		return 1
	}
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
		declare -f r_init r_sums r_treesum r_fs r_free r_mounts r_mounted r_mountcheck r_real r_links r_linkcheck r_stop r_preflight r_stage r_unstage r_backup r_install r_start \
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
	board unstage >/dev/null 2>&1 || echo "xkmsd-deploy: could not remove the staged binary; restoring anyway" >&2
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
