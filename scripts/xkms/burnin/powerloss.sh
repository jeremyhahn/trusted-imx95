#!/usr/bin/env bash
# (d) Power-loss simulation: acknowledged writes survive a hard reboot.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: powerloss.sh [options] <board ssh target>

Off by default: without --hard-reboot it only reports SKIP. With it:
  1. write a set of keys and a certificate, verify it
  2. start a writer that keeps creating keys, and a few seconds in run
     `echo b > /proc/sysrq-trigger` on the board (an immediate reboot: no
     sync, no unmount, no service stop)
  3. wait for the board and xkmsd to come back
  4. every write xkmsd acknowledged before the reboot must be there with
     the same fingerprint; a miss is CRITICAL
Writes in flight at the instant of the reboot were never acknowledged and
are owed nothing. This loses the page cache, as a power cut does; it does
not test the eMMC's own write cache.

  --hard-reboot        really reboot the board
  --keys <n>           keys in the first set (default 20)
  --writer-secs <s>    seconds of writer load before the reboot (default 6)
  --cycles <c>         reboots (default 1)
EOF
	bi_common_usage
}

n=20
armed=0
secs=6
cycles=1
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--hard-reboot) armed=1; shift ;;
	--keys) n=${2:?}; shift 2 ;;
	--writer-secs) secs=${2:?}; shift 2 ;;
	--cycles) cycles=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "write $n keys and a certificate, verify"
	bi_plan "$cycles x: a background writer for ${secs}s, then 'echo b > /proc/sysrq-trigger' on the board (only with --hard-reboot; armed=$armed)"
	bi_plan "wait for the board and xkmsd; verify every acknowledged write; a loss prints CRITICAL"
	exit 0
fi

if [ "$armed" != 1 ]; then
	echo "powerloss: off by default; pass --hard-reboot to reboot the board with sysrq-b"
	echo "SUMMARY powerloss: SKIP (not armed)"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary powerloss; exit 1; }

bi_write_set base "$n" "bi-pl-$stamp-base"
bi_verify_set base

for ((c = 1; c <= cycles; c++)); do
	(
		BI_WRITE_FAIL_OK=1 BI_WRITE_CERT=0
		i=0
		while :; do
			bi_write_set "w$c" 1 "bi-pl-$stamp-w$c-$i"
			i=$((i + 1))
		done
	) >/dev/null 2>&1 &
	writer=$!
	sleep "$secs"
	bi_check "hard reboot $c (sysrq b) and return" bi_restart hard
	kill "$writer" 2>/dev/null
	wait "$writer" 2>/dev/null
	bi_verify_set base
	bi_verify_set "w$c"
done

echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary powerloss
