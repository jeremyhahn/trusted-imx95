#!/usr/bin/env bash
# On-target check of xkmsd.service on a booted platform image (docs/platform-image/
# xkmsd.md, "The on-target check"). It runs over ssh against a board that runs
# the image; the host is XKMSD_TARGET_HOST (an ssh destination, no default), and
# the ssh user must be root: the last step stops the unit and remounts the state
# partition. Nothing here boots, builds or flashes anything, and nothing runs
# without the host.
#
# It fails closed. Each of these must hold, or the script prints a FAIL line and
# exits non-zero:
#   1. xkmsd.service is active and running, as the xkmsd user, with the sandbox
#      of the unit (the effective properties of `systemctl show`);
#   2. the main process is that user as the kernel sees it (/proc/<pid>/status:
#      its uid and gid, no capability, no_new_privs, a seccomp filter);
#   3. /var/lib/xkms is the persistent xkms-state mount of the image layout
#      (ext4, labelled, read-write, nosuid,nodev,noexec) owned by xkmsd;
#   4. the daemon refuses to start when that mount is read-only. This step
#      changes the board for a moment (stop, remount read-only, start, remount
#      read-write, start) and runs only when the three before it passed.
#
# XKMSD_TARGET_SSH_OPTS: extra ssh options (for example "-i key -p 2222").
set -u

state=/var/lib/xkms
nfail=0

ok() { printf 'ok   %s\n' "$*"; }
bad() {
	printf 'FAIL: %s\n' "$*"
	nfail=$((nfail + 1))
}

host=${XKMSD_TARGET_HOST:-}
case $host in
'' | -* | *[[:space:]]*)
	echo "xkmsd-target-check: set XKMSD_TARGET_HOST to the ssh destination of a booted image (not an option, no spaces)" >&2
	exit 2
	;;
esac
sshopts=()
if [ -n "${XKMSD_TARGET_SSH_OPTS:-}" ]; then read -r -a sshopts <<<"$XKMSD_TARGET_SSH_OPTS"; fi

# rssh SCRIPT: run SCRIPT in `sh -s` on the target; prints its output, returns
# its status (255 when ssh itself fails).
rssh() {
	printf '%s\n' "$1" | ssh -o BatchMode=yes -o ConnectTimeout=15 ${sshopts[@]+"${sshopts[@]}"} -- "$host" sh -s
}

declare -A P=()
# load TEXT: the KEY=VALUE lines of TEXT in P (the first of a repeated key wins).
load() {
	local l
	P=()
	while IFS= read -r l; do
		case $l in
		*=*) [ -n "${P[${l%%=*}]+x}" ] || P[${l%%=*}]=${l#*=} ;;
		esac
	done <<<"$1"
}
# is KEY VALUE: KEY is set to VALUE (an unset key is never equal).
is() { [ -n "${P[$1]+x}" ] && [ "${P[$1]}" = "$2" ]; }
# shown VALUE: VALUE for a message, '' when empty.
shown() { if [ -n "$1" ]; then printf '%s' "$1"; else printf "''"; fi; }

# --- 1. The unit and its sandbox ---------------------------------------------
unit_props="ActiveState SubState MainPID User Group NoNewPrivileges PrivateTmp ProtectSystem ProtectHome ProtectProc \
ProtectKernelTunables ProtectKernelModules ProtectKernelLogs ProtectClock ProtectControlGroups RestrictNamespaces \
RestrictRealtime RestrictSUIDSGID LockPersonality CapabilityBoundingSet UMask"
pargs=''
for p in $unit_props; do pargs="$pargs -p $p"; done
out=$(rssh "systemctl show xkmsd.service$pargs")
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
	bad "cannot read the properties of xkmsd.service over ssh (status $rc)"
	echo "xkmsd-target-check: 1 check failed" >&2
	exit 1
fi
load "$out"
if is ActiveState active; then ok "xkmsd.service is active"; else bad "xkmsd.service is not active (ActiveState is '${P[ActiveState]:-}')"; fi
if is SubState running; then :; else bad "xkmsd.service SubState is '${P[SubState]:-}', not running"; fi
pid=${P[MainPID]:-}
if [[ $pid =~ ^[1-9][0-9]*$ ]]; then :; else
	bad "xkmsd.service has no main process (MainPID is $(shown "$pid"))"
	pid=
fi
if is User xkmsd; then :; else bad "xkmsd.service User is '${P[User]:-}', not xkmsd"; fi
if is Group xkmsd; then :; else bad "xkmsd.service Group is '${P[Group]:-}', not xkmsd"; fi
sandbox_bad=0
for kv in NoNewPrivileges=yes PrivateTmp=yes ProtectSystem=strict ProtectHome=yes ProtectProc=invisible \
	ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes ProtectClock=yes \
	ProtectControlGroups=yes RestrictNamespaces=yes RestrictRealtime=yes RestrictSUIDSGID=yes \
	LockPersonality=yes CapabilityBoundingSet= UMask=0077; do
	if ! is "${kv%%=*}" "${kv#*=}"; then
		bad "xkmsd.service sandbox: ${kv%%=*} is '${P[${kv%%=*}]:-}', want '${kv#*=}'"
		sandbox_bad=1
	fi
done
[ "$sandbox_bad" = 1 ] || ok "xkmsd.service sandbox properties are in effect"

# --- 2. The main process as the kernel sees it ------------------------------
ids=$(rssh "id -u xkmsd; id -g xkmsd")
uid='' gid=''
{ IFS= read -r uid; IFS= read -r gid; } <<<"$ids"
if ! [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]]; then
	bad "the image has no xkmsd user"
	uid='' gid=''
elif [ "$uid" = 0 ]; then
	bad "the xkmsd user has uid 0"
	uid=''
fi
declare -A S=()
if [ -n "$pid" ]; then
	st=$(rssh "cat /proc/$pid/status")
	while IFS=: read -r k v; do
		[ -n "$k" ] || continue
		v=${v#"${v%%[![:space:]]*}"}
		S[$k]=$v
	done <<<"$st"
fi
# idfields KEY WANT: the four ids of KEY all equal WANT.
idfields() {
	local -a f
	read -r -a f <<<"${S[$1]:-}"
	if [ "${#f[@]}" = 4 ] && [ -n "$2" ] && [ "${f[0]}" = "$2" ] && [ "${f[1]}" = "$2" ] && [ "${f[2]}" = "$2" ] && [ "${f[3]}" = "$2" ]; then
		return 0
	fi
	bad "the main process $1 is $(shown "${f[*]:-}"), not the xkmsd user's ${2:-unknown}"
	return 1
}
proc_bad=0
if [ -n "$pid" ]; then
	idfields Uid "$uid" || proc_bad=1
	idfields Gid "$gid" || proc_bad=1
	for c in CapInh CapPrm CapEff CapBnd CapAmb; do
		if [[ ${S[$c]:-} =~ ^0+$ ]]; then :; else
			bad "the main process $c is $(shown "${S[$c]:-}"), want no capability"
			proc_bad=1
		fi
	done
	if [ "${S[NoNewPrivs]:-}" = 1 ]; then :; else
		bad "the main process NoNewPrivs is $(shown "${S[NoNewPrivs]:-}"), want 1"
		proc_bad=1
	fi
	if [ "${S[Seccomp]:-}" = 2 ]; then :; else
		bad "the main process Seccomp is $(shown "${S[Seccomp]:-}"), want 2 (a filter)"
		proc_bad=1
	fi
else
	proc_bad=1
fi
[ "$proc_bad" = 1 ] || ok "the main process runs as xkmsd under the unit's sandbox (uid $uid, no capability, no_new_privs, seccomp filter)"

# --- 3. The state directory is the persistent state mount -------------------
mnt=$(rssh "findmnt -n -P -o TARGET,FSTYPE,LABEL,OPTIONS -M $state")
mrc=$?
state_bad=0
if [ "$mrc" -ne 0 ] || [ -z "$mnt" ]; then
	bad "$state is not a mount point"
	state_bad=1
else
	fstype='' label='' opts=''
	[[ $mnt =~ FSTYPE=\"([^\"]*)\" ]] && fstype=${BASH_REMATCH[1]}
	[[ $mnt =~ LABEL=\"([^\"]*)\" ]] && label=${BASH_REMATCH[1]}
	[[ $mnt =~ OPTIONS=\"([^\"]*)\" ]] && opts=${BASH_REMATCH[1]}
	if [ "$fstype" != ext4 ]; then
		bad "$state is a $(shown "$fstype") mount, not ext4"
		state_bad=1
	fi
	if [ "$label" != xkms-state ]; then
		bad "$state is not the xkms-state partition (label $(shown "$label"))"
		state_bad=1
	fi
	o=",$opts,"
	case $o in *,rw,*) ;; *)
		bad "$state is mounted read-only (options $(shown "$opts"))"
		state_bad=1
		;;
	esac
	for want in nosuid nodev noexec; do
		case $o in *,"$want",*) ;; *)
			bad "$state is mounted without $want (options $(shown "$opts"))"
			state_bad=1
			;;
		esac
	done
fi
mu=$(rssh "systemctl show var-lib-xkms.mount -p ActiveState -p What -p Where")
load "$mu"
if is ActiveState active; then :; else
	bad "var-lib-xkms.mount is not active (ActiveState is '${P[ActiveState]:-}')"
	state_bad=1
fi
if is What /dev/disk/by-label/xkms-state; then :; else
	bad "var-lib-xkms.mount What is '${P[What]:-}', not /dev/disk/by-label/xkms-state"
	state_bad=1
fi
if is Where "$state"; then :; else
	bad "var-lib-xkms.mount Where is '${P[Where]:-}', not $state"
	state_bad=1
fi
sv=$(rssh "stat -c '%u %g %a' $state")
su='' sg='' sm=''
read -r su sg sm <<<"$sv"
if [ -n "$uid" ] && [ -n "$gid" ] && [ "$su $sg $sm" = "$uid $gid 750" ]; then :; else
	bad "$state is owned by $(shown "$su"):$(shown "$sg") mode $(shown "$sm"), want ${uid:-?}:${gid:-?} mode 750"
	state_bad=1
fi
[ "$state_bad" = 1 ] || ok "$state is the persistent xkms-state mount (ext4, read-write, nosuid,nodev,noexec, owned by xkmsd, mode 750)"

# --- 4. The daemon refuses to start on a read-only state mount ---------------
if [ "$nfail" -ne 0 ]; then
	bad "the read-only start check did not run: an earlier check failed"
else
	ro=$(rssh "m=$state
restore() {
	mount -o remount,rw \"\$m\" && echo RESTORE_RW=ok || echo RESTORE_RW=fail
	systemctl reset-failed xkmsd.service
	systemctl start xkmsd.service && echo RESTORE_START=ok || echo RESTORE_START=fail
}
trap restore EXIT
systemctl stop xkmsd.service && echo STOP=ok || { echo STOP=fail; exit 0; }
mount -o remount,ro \"\$m\" && echo REMOUNT_RO=ok || { echo REMOUNT_RO=fail; exit 0; }
echo \"RO_OPTS=\$(findmnt -n -o OPTIONS -M \"\$m\")\"
systemctl start xkmsd.service >/dev/null 2>&1 && echo START_RC=0 || echo START_RC=\$?
echo \"START_STATE=\$(systemctl show -p ActiveState --value xkmsd.service)\"")
	load "$ro"
	ro_bad=0
	is_ro=0
	case ",${P[RO_OPTS]:-}," in *,ro,*) is_ro=1 ;; esac
	if is STOP fail; then
		bad "xkmsd.service did not stop before the read-only check"
		ro_bad=1
	elif ! is REMOUNT_RO ok; then
		bad "the state mount could not be remounted read-only"
		ro_bad=1
	elif [ "$is_ro" != 1 ]; then
		bad "the state mount is not read-only after the remount (options $(shown "${P[RO_OPTS]:-}"))"
		ro_bad=1
	else
		if ! is START_RC 0 && [ -n "${P[START_RC]:-}" ]; then :; else
			bad "xkmsd.service started on a read-only state mount (start status $(shown "${P[START_RC]:-}"))"
			ro_bad=1
		fi
		if is START_STATE active || [ -z "${P[START_STATE]:-}" ]; then
			bad "xkmsd.service is active on a read-only state mount (state $(shown "${P[START_STATE]:-}"))"
			ro_bad=1
		fi
	fi
	if ! is RESTORE_RW ok; then
		bad "the state mount was not remounted read-write: restore it by hand on the board"
		ro_bad=1
	fi
	if ! is RESTORE_START ok; then
		bad "xkmsd.service did not start again after the read-only check"
		ro_bad=1
	fi
	[ "$ro_bad" = 1 ] || ok "xkmsd refuses to start on a read-only state mount"
fi

if [ "$nfail" -ne 0 ]; then
	echo "xkmsd-target-check: $nfail check(s) failed" >&2
	exit 1
fi
echo "xkmsd-target-check: all passed"
