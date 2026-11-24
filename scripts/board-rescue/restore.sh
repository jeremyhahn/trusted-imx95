#!/usr/bin/env bash
# Restore (or verify) the board's stock eMMC image from a backup directory by
# kexec-ing the board's own kernel with the rescue initramfs (README.md).
#
# usage: restore.sh <board ssh target> <backup dir> [--verify-only]
#                   [--ip <addr/prefix> --gw <gw>] [--if <iface>]
#                   [--manifest <file>] [--cpio <rescue.cpio.gz>] [--no-kexec]
#
# The backup dir holds the three dumps and a manifest (default manifest.txt):
#   <dev> <file> <raw bytes> <sha256 of the raw bytes>      one line per device,
# for mmcblk0, mmcblk0boot0 and mmcblk0boot1; '#' starts a comment. <file> is
# relative to the backup dir and is zstd compressed.
#
# --verify-only hashes the three devices from the rescue system and writes
# nothing. --no-kexec skips the preflight and the kexec: the board is already in
# the rescue system (a retry after a failed write); --ip is then its address.
# Without --ip the board's current address, gateway and interface are reused.
# Either way the script ends by rebooting the board into its own system.
#
# Environment: RESTORE_SSH_OPTS (default BatchMode, ConnectTimeout=10),
# RESCUE_PORT (7777), RESTORE_WAIT (seconds to wait for the rescue port and for
# ssh after the reboot, 240), RESTORE_IO_TIMEOUT (seconds per hash or write
# command, 7200).
# Prints only paths, sizes, hashes and step names; reads nothing from the board
# but its size, boot files and network setup.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)

usage() {
	echo "usage: restore.sh <board ssh target> <backup dir> [--verify-only] [--ip <addr/prefix> --gw <gw>]"
	echo "                  [--if <iface>] [--manifest <file>] [--cpio <rescue.cpio.gz>] [--no-kexec]"
	echo "see scripts/board-rescue/README.md"
}

die() {
	echo "restore: $*" >&2
	exit 1
}

step() { echo "restore: step $*"; }

verify_only=0
nokexec=0
ip=""
gw=""
ifc=""
manifest=""
cpio=$root/build/board-rescue/rescue.cpio.gz
pos=()
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--verify-only) verify_only=1 ;;
	--no-kexec) nokexec=1 ;;
	--ip) [ $# -ge 2 ] || die "--ip needs a value"; ip=$2; shift ;;
	--gw) [ $# -ge 2 ] || die "--gw needs a value"; gw=$2; shift ;;
	--if) [ $# -ge 2 ] || die "--if needs a value"; ifc=$2; shift ;;
	--manifest) [ $# -ge 2 ] || die "--manifest needs a value"; manifest=$2; shift ;;
	--cpio) [ $# -ge 2 ] || die "--cpio needs a value"; cpio=$2; shift ;;
	-*) die "unknown option $1" ;;
	*) pos+=("$1") ;;
	esac
	shift
done
[ "${#pos[@]}" -eq 2 ] || { usage >&2; exit 2; }
target=${pos[0]}
backup=${pos[1]}
[ -d "$backup" ] || die "no backup directory $backup"
[ -n "$manifest" ] || manifest=$backup/manifest.txt
[ -f "$manifest" ] || die "no manifest $manifest"
[ -z "$gw" ] || [ -n "$ip" ] || die "--gw needs --ip"
[ "$nokexec" -eq 0 ] || [ -n "$ip" ] || die "--no-kexec needs --ip (the rescue address)"
if [ -n "$ip" ]; then
	case $ip in */*) ;; *) die "--ip must be <addr>/<prefix>" ;; esac
fi
[ "$nokexec" -eq 1 ] || [ -f "$cpio" ] || die "no $cpio (run scripts/board-rescue/build-initramfs.sh)"
command -v zstd >/dev/null || die "zstd not found"
command -v sha256sum >/dev/null || die "sha256sum not found"

port=${RESCUE_PORT:-7777}
wait_s=${RESTORE_WAIT:-240}
io_s=${RESTORE_IO_TIMEOUT:-7200}
# shellcheck disable=SC2206 # word splitting of the option list is the point
ssh_opts=(${RESTORE_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10})

# shellcheck disable=SC2029 # the remote command is composed here on purpose
board() { ssh "${ssh_opts[@]}" "$target" "$@"; }

devs=(mmcblk0 mmcblk0boot0 mmcblk0boot1)
declare -A m_file m_bytes m_sha

# --- manifest ---------------------------------------------------------------
while read -r d f b s extra; do
	case $d in '' | '#'*) continue ;; esac
	[ -z "$extra" ] || die "manifest line for $d has extra fields"
	case $d in mmcblk0 | mmcblk0boot0 | mmcblk0boot1) ;; *) die "manifest names a device this tool does not write: $d" ;; esac
	case $b in '' | *[!0-9]*) die "manifest: bad byte count for $d" ;; esac
	case $s in *[!0-9a-f]* | '') die "manifest: bad sha256 for $d" ;; esac
	[ "${#s}" -eq 64 ] || die "manifest: bad sha256 for $d"
	case $f in /* | *..*) die "manifest: file for $d must be inside the backup dir" ;; esac
	m_file[$d]=$f m_bytes[$d]=$b m_sha[$d]=$s
done <"$manifest"
for d in "${devs[@]}"; do
	[ -n "${m_file[$d]:-}" ] || die "manifest lacks $d"
	[ "${m_bytes[$d]}" -gt 0 ] || die "manifest: zero size for $d"
	[ -f "$backup/${m_file[$d]}" ] || die "missing dump $backup/${m_file[$d]}"
	echo "restore: dump $d $backup/${m_file[$d]} ${m_bytes[$d]} bytes sha256 ${m_sha[$d]}"
done

# --- rescue protocol --------------------------------------------------------
rescue_host=""

# rescue_cmd <command line> [dump file]: one connection; the dump, when given,
# is streamed after the command line; prints the reply line.
rescue_cmd() {
	local line=$1 dump=${2:-} reply
	(
		exec 3<>"/dev/tcp/$rescue_host/$port" || exit 1
		printf '%s\n' "$line" >&3
		if [ -n "$dump" ]; then
			zstd -dc -- "$dump" >&3 || exit 1
		fi
		read -r -t "$io_s" reply <&3 || exit 1
		printf '%s\n' "$reply"
	)
}

wait_port() {
	local n=0
	while ! (exec 3<>"/dev/tcp/$rescue_host/$port") 2>/dev/null; do
		n=$((n + 1))
		[ "$n" -lt "$wait_s" ] || return 1
		sleep 1
	done
}

wait_ssh() {
	local n=0
	while ! board true >/dev/null 2>&1; do
		n=$((n + 1))
		[ "$n" -lt "$wait_s" ] || return 1
		sleep 1
	done
}

# --- board preflight and kexec ---------------------------------------------
if [ "$nokexec" -eq 0 ]; then
	step preflight
	pre=$(board 'sh -s' <<'EOS'
command -v kexec >/dev/null || { echo "ERR no kexec"; exit 0; }
[ -f /boot/Image ] || { echo "ERR no /boot/Image"; exit 0; }
[ -r /sys/block/mmcblk0/size ] || { echo "ERR no mmcblk0"; exit 0; }
read -r sectors </sys/block/mmcblk0/size
echo "bytes=$((sectors * 512))"
route=$(ip -4 route show default 2>/dev/null | head -n 1)
set -- $route
gw=""; dev=""
while [ $# -gt 0 ]; do
	case $1 in via) gw=$2 ;; dev) dev=$2 ;; esac
	shift
done
echo "gw=$gw"
echo "if=$dev"
[ -z "$dev" ] || echo "ip=$(ip -4 -o addr show dev "$dev" | head -n 1 | { read -r _ _ _ a _; echo "$a"; })"
EOS
	) || die "preflight ssh failed"
	b_bytes="" b_gw="" b_if="" b_ip=""
	while IFS= read -r l; do
		case $l in
		ERR*) die "board preflight: ${l#ERR }" ;;
		bytes=*) b_bytes=${l#bytes=} ;;
		gw=*) b_gw=${l#gw=} ;;
		if=*) b_if=${l#if=} ;;
		ip=*) b_ip=${l#ip=} ;;
		esac
	done <<<"$pre"
	echo "restore: board mmcblk0 $b_bytes bytes, backup ${m_bytes[mmcblk0]} bytes"
	[ "$b_bytes" = "${m_bytes[mmcblk0]}" ] || die "the board's mmcblk0 is $b_bytes bytes, the backup's is ${m_bytes[mmcblk0]}"
	if [ -z "$ip" ]; then
		[ -n "$b_ip" ] || die "cannot read the board's address; pass --ip and --gw"
		ip=$b_ip gw=$b_gw
		[ -n "$ifc" ] || ifc=$b_if
		echo "restore: reusing the board's address $ip gw ${gw:-none} on ${ifc:-eth0}"
	fi
	rescue_host=${ip%%/*}

	step upload
	want=$(sha256sum "$cpio") || die "cannot hash $cpio"
	want=${want%% *}
	board 'cat >/tmp/rescue.cpio.gz' <"$cpio" || die "upload failed"
	have=$(board 'sha256sum /tmp/rescue.cpio.gz') || die "cannot hash the upload"
	have=${have%% *}
	[ "$have" = "$want" ] || die "uploaded initramfs has SHA-256 $have, want $want"
	echo "restore: /tmp/rescue.cpio.gz $want"

	step kexec-load
	append="console=ttyLP0,115200 rescue.ip=$ip rescue.port=$port"
	[ -z "$gw" ] || append="$append rescue.gw=$gw"
	[ -z "$ifc" ] || append="$append rescue.if=$ifc"
	board "kexec -l /boot/Image --initrd=/tmp/rescue.cpio.gz --append='$append'" || die "kexec -l failed"

	step kexec-exec
	# The session dies with the old kernel, so the call is bounded and its
	# status is not an answer.
	timeout 60 ssh "${ssh_opts[@]}" "$target" 'systemctl stop xkmsd; sync; sleep 1; kexec -e' >/dev/null 2>&1 || true
else
	rescue_host=${ip%%/*}
fi

step wait-rescue
wait_port || die "the rescue port $rescue_host:$port did not open in ${wait_s}s"

# --- per device -------------------------------------------------------------
rc=0
for d in "${devs[@]}"; do
	if [ "$verify_only" -eq 1 ]; then
		step "verify $d"
		got=$(rescue_cmd "hash $d ${m_bytes[$d]}") || die "hash $d: no answer"
		if [ "$got" = "${m_sha[$d]}" ]; then
			echo "restore: $d MATCH $got"
		else
			echo "restore: $d DIFFERS board $got backup ${m_sha[$d]}"
			rc=1
		fi
	else
		step "write $d"
		got=$(rescue_cmd "write $d ${m_bytes[$d]} ${m_sha[$d]}" "$backup/${m_file[$d]}") || die "write $d: no answer"
		echo "restore: $d $got"
		[ "$got" = OK ] || die "write $d did not verify (board stays in the rescue system; retry with --no-kexec --ip $ip)"
	fi
done

if [ "$rc" -ne 0 ] && [ "$verify_only" -eq 0 ]; then
	die "a device failed"
fi

step reboot
rescue_cmd reboot >/dev/null || true
wait_ssh || die "ssh did not return in ${wait_s}s after the reboot"
step "board answers"
sleep "${RESTORE_SETTLE:-0}"
# shellcheck disable=SC2016 # expands on the board
rootdev=$(board 'for w in $(cat /proc/cmdline); do case $w in root=*) echo "${w#root=}" ;; esac; done; findmnt -n -o SOURCE / 2>/dev/null || true') || die "board does not answer after the reboot"
echo "restore: board root device: $(echo "$rootdev" | tr '\n' ' ')"
[ -n "$rootdev" ] || die "the board reported no root device"
if [ "$rc" -ne 0 ]; then
	echo "restore: verify-only: the board differs from the backup" >&2
fi
exit "$rc"
