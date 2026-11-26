#!/usr/bin/env bash
# board-ctl.sh: a drop-in for the burn-in suite's --ctl (XKMS_CTL) that runs the
# board's own xkmsctl over ssh, so the client key never leaves the board.
#
# xkmsd on the board requires mutual TLS on every transport, and the only
# client credential is xkmsd's init admin credential, readable only by the
# `xkms` user. This script names the key file by PATH on the command line of
# the board's xkmsctl and nothing else: it never cats, copies, prints or
# stores the key.
#
# Usage (as --ctl; the suite's --ctl-args come through as arguments):
#   XKMS_BOARD=<board> burnin/functional.sh --ctl scripts/xkms/burnin/board-ctl.sh <board>
#   board-ctl.sh [xkmsctl arguments...]
#
# Environment:
#   XKMS_BOARD          ssh target of the board, as root (required; the suite's
#                       positional <board> is not exported to --ctl, so set both)
#   XKMS_BOARD_CTL      xkmsctl on the board        (default /usr/local/bin/xkmsctl)
#   XKMS_BOARD_TLS_CA   CA file on the board        (default /var/lib/xkms/storage/unified-tls/cert.pem,
#                       the served certificate, which is self-signed today)
#   XKMS_BOARD_TLS_CERT client certificate          (default /var/lib/xkms/storage/admin-cert.pem)
#   XKMS_BOARD_TLS_KEY  client key, used by path    (default /var/lib/xkms/storage/admin-key.pem)
#
# xkmsctl runs as the `xkms` user (su -s /bin/sh xkms -c). The TLS flags
# --tls-ca, --tls-cert and --tls-key come first, so a flag the caller passes
# itself wins. Every argument is single-quoted for the board's shell. Exit
# status, stdout and stderr are xkmsctl's own; ssh's 255 means ssh failed.
#
# Files. The suite passes data as arguments, never on stdin or stdout, so
# stdin is /dev/null and files are the only data that must move. A call with
# no file argument is one ssh session. Otherwise a per-call directory
# /tmp/xkms-burnin.XXXXXX (mode 700, owned by xkms) is made on the board,
# inputs are uploaded into it (ssh, cat), xkmsctl runs with the board paths,
# outputs are downloaded when xkmsctl exited 0 (an output that is not there is
# skipped), and the directory is removed on every exit, including a failure or
# a signal. The file arguments are the ones the suite uses:
#   inputs   --ca-cert FILE  --ca-key FILE  --csr FILE   (also --flag=FILE)
#            cert save <id> FILE
#   outputs  --output FILE  --key-output FILE
#            key export <id> FILE
# (-o is the output format, not a file.) A positional file must directly
# follow `cert save <id>` or `key export <id>`.
#
# Signals. Every ssh runs in the background and is waited on, so TERM, INT or
# HUP act at once: the active ssh is killed and reaped, the cleanup ssh runs
# bounded (XKMS_BOARD_CLEANUP_TIMEOUT seconds, default 10), and the script
# exits 143, 130 or 129. Under bi_ctl's `timeout` that is status 124.
set -u
umask 077

board=${XKMS_BOARD:-}
ctl=${XKMS_BOARD_CTL:-/usr/local/bin/xkmsctl}
store=/var/lib/xkms/storage
tls_ca=${XKMS_BOARD_TLS_CA:-$store/unified-tls/cert.pem}
tls_cert=${XKMS_BOARD_TLS_CERT:-$store/admin-cert.pem}
tls_key=${XKMS_BOARD_TLS_KEY:-$store/admin-key.pem}

die() { echo "board-ctl: $*" >&2; exit 2; }
[ -n "$board" ] || die "set XKMS_BOARD to the board's ssh target"

# q: single-quote one word for a POSIX shell.
q() {
	local s=$1 sq="'\\''"
	printf "'%s'" "${s//\'/$sq}"
}

ssh_pid=""
rdir=""
mkf=""

# stop_ssh: kill and reap the active ssh child, if any. ssh shares this
# script's process group (no job control), so the group is left alone.
# shellcheck disable=SC2329 # runs from the traps
stop_ssh() {
	if [ -n "$ssh_pid" ]; then
		kill -KILL "$ssh_pid" 2>/dev/null
		wait "$ssh_pid" 2>/dev/null
		ssh_pid=""
	fi
}

# bssh: one ssh session, run in the background and waited on. Bash defers a
# trap while a foreground command runs, so a stalled ssh would hold off the
# TERM that `timeout` sends; `wait` returns at once and the trap runs. <&0
# keeps the caller's stdin, which a background command would lose. The
# keepalive options end a dead connection on their own.
bssh() {
	local rc
	ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 "$board" "$@" <&0 &
	ssh_pid=$!
	wait "$ssh_pid"
	rc=$?
	ssh_pid=""
	return "$rc"
}

# cleanup: runs on every exit. The ssh that removes the board's temp dir is
# bounded, so cleanup cannot hang, and a signal during it is ignored.
# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
	local rc=$?
	trap '' HUP INT TERM
	stop_ssh
	if [ -n "$rdir" ]; then
		timeout -k 2 "${XKMS_BOARD_CLEANUP_TIMEOUT:-10}" ssh -o BatchMode=yes -o ConnectTimeout=5 \
			-o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$board" "rm -rf $(q "$rdir")" \
			</dev/null >/dev/null 2>&1
	fi
	[ -z "$mkf" ] || rm -f "$mkf"
	exit "$rc"
}
trap cleanup EXIT
trap 'stop_ssh; exit 129' HUP
trap 'stop_ssh; exit 130' INT
trap 'stop_ssh; exit 143' TERM

args=("$@")
rargs=()
up_l=() up_r=() dn_l=() dn_r=()
n=0

# add_file <in|out> <local path>: records the file and prints its board path.
add_file() {
	local kind=$1 path=$2
	n=$((n + 1))
	if [ "$kind" = in ]; then
		up_l+=("$path")
		up_r+=("f$n")
	else
		dn_l+=("$path")
		dn_r+=("f$n")
	fi
	REPLY="@DIR@/f$n"
}

i=0
while [ "$i" -lt "${#args[@]}" ]; do
	a=${args[$i]}
	kind=""
	case "$a" in
	--ca-cert | --ca-key | --csr) kind=in ;;
	--output | --key-output) kind=out ;;
	--ca-cert=* | --ca-key=* | --csr=*) kind=in ;;
	--output=* | --key-output=*) kind=out ;;
	esac
	if [ -n "$kind" ]; then
		case "$a" in
		*=*)
			add_file "$kind" "${a#*=}"
			rargs+=("${a%%=*}=$REPLY")
			;;
		*)
			if [ $((i + 1)) -lt "${#args[@]}" ]; then
				add_file "$kind" "${args[$((i + 1))]}"
				rargs+=("$a" "$REPLY")
				i=$((i + 1))
			else
				rargs+=("$a")
			fi
			;;
		esac
	elif [ "$a" = -o ]; then
		rargs+=("$a")
		if [ $((i + 1)) -lt "${#args[@]}" ]; then
			rargs+=("${args[$((i + 1))]}")
			i=$((i + 1))
		fi
	elif { [ "$a" = cert ] && [ "${args[$((i + 1))]:-}" = save ]; } ||
		{ [ "$a" = key ] && [ "${args[$((i + 1))]:-}" = export ]; }; then
		# <cmd> <sub> <id> FILE
		rargs+=("$a" "${args[$((i + 1))]}")
		i=$((i + 1))
		if [ $((i + 1)) -lt "${#args[@]}" ]; then
			rargs+=("${args[$((i + 1))]}")
			i=$((i + 1))
		fi
		if [ $((i + 1)) -lt "${#args[@]}" ]; then
			f=${args[$((i + 1))]}
			case "$f" in
			-*) ;;
			*)
				if [ "${rargs[$((${#rargs[@]} - 2))]}" = save ]; then k=in; else k=out; fi
				add_file "$k" "$f"
				rargs+=("$REPLY")
				i=$((i + 1))
				;;
			esac
		fi
	else
		rargs+=("$a")
	fi
	i=$((i + 1))
done

# run_remote: xkmsctl as the xkms user, the TLS flags first. Stdin is /dev/null
# so a caller's read loop is not consumed.
run_remote() {
	local dir=$1 inner w
	inner=$(q "$ctl")
	for w in --tls-ca "$tls_ca" --tls-cert "$tls_cert" --tls-key "$tls_key"; do
		inner+=" $(q "$w")"
	done
	for w in "${rargs[@]+"${rargs[@]}"}"; do
		[ -z "$dir" ] || w=${w//@DIR@/$dir}
		inner+=" $(q "$w")"
	done
	bssh "su -s /bin/sh xkms -c $(q "$inner")" </dev/null
}

if [ "$n" -eq 0 ]; then
	run_remote ""
	exit $?
fi

# The answer goes through a local file, not $(...): a command substitution runs
# in a subshell the main shell cannot interrupt while it waits.
mkf=$(mktemp "${TMPDIR:-/tmp}/board-ctl.XXXXXX") || die "cannot make a local temp file"
# shellcheck disable=SC2016 # expands on the board
bssh 'd=$(mktemp -d /tmp/xkms-burnin.XXXXXX) && chown xkms "$d" && chmod 700 "$d" && echo "$d"' </dev/null >"$mkf" || {
	# mktemp may have succeeded before a later step failed; the name is unknown.
	echo "board-ctl: cannot make the temp dir on the board" >&2
	exit 1
}
mk=$(<"$mkf")
case "$mk" in
/tmp/xkms-burnin.?*) rdir=$mk ;;
*) die "unexpected temp dir from the board" ;;
esac
case "$rdir" in
*[!A-Za-z0-9/._-]*) rdir="" ; die "unexpected temp dir from the board" ;;
esac

for ((j = 0; j < ${#up_l[@]}; j++)); do
	# A missing local input is left absent on the board: xkmsctl reports it.
	[ -r "${up_l[$j]}" ] || continue
	bssh "umask 077; cat > $(q "$rdir/${up_r[$j]}") && chown xkms $(q "$rdir/${up_r[$j]}")" <"${up_l[$j]}" || {
		echo "board-ctl: cannot upload ${up_l[$j]}" >&2
		exit 1
	}
done

run_remote "$rdir"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

for ((j = 0; j < ${#dn_l[@]}; j++)); do
	bssh "[ -e $(q "$rdir/${dn_r[$j]}") ] || exit 3; cat $(q "$rdir/${dn_r[$j]}")" </dev/null >"${dn_l[$j]}"
	drc=$?
	if [ "$drc" -eq 3 ]; then
		rm -f "${dn_l[$j]}"
	elif [ "$drc" -ne 0 ]; then
		rm -f "${dn_l[$j]}"
		echo "board-ctl: cannot download ${dn_l[$j]}" >&2
		exit 1
	fi
done
exit 0
