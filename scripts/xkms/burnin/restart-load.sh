#!/usr/bin/env bash
# (g) Restart under load: restart and kill xkmsd while clients write; nothing acknowledged is lost.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: restart-load.sh [options] <board ssh target>

Starts --writers background clients that create keys and record a key in
their ledger only after xkmsd acknowledged it. While they run, the board
restarts xkmsd --cycles times, alternating graceful restart and kill -9.
Writes that fail during a restart are expected and owed nothing. Afterwards:
  - xkmsd must answer again after each restart
  - every acknowledged write must be present and unchanged (else CRITICAL)
  - at least one write must have been acknowledged

  --writers <n>   background writers (default 4)
  --cycles <n>    restarts (default 6)
  --gap-secs <s>  seconds of load between restarts (default 5)
EOF
	bi_common_usage
}

writers=4
cycles=6
gap=5
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--writers) writers=${2:?}; shift 2 ;;
	--cycles) cycles=${2:?}; shift 2 ;;
	--gap-secs) gap=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done
for v in "$writers" "$cycles" "$gap"; do
	case $v in '' | *[!0-9]*) bi_die "numeric option expected, got '$v'" ;; esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "$writers writers create keys (and sign) in a loop; each acknowledged write goes in a ledger"
	bi_plan "$cycles times, ${gap}s apart: restart xkmsd on the board, alternating graceful and kill -9; wait until it answers"
	bi_plan "stop the writers; verify every acknowledged write; a loss or change prints CRITICAL"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary restart-load; exit 1; }

pids=()
for ((w = 1; w <= writers; w++)); do
	(
		BI_WRITE_FAIL_OK=1 BI_WRITE_CERT=0
		i=0
		while :; do
			bi_write_set "w$w" 1 "bi-rl-$stamp-w$w-$i"
			i=$((i + 1))
		done
	) >/dev/null 2>&1 &
	pids+=($!)
done

for ((c = 1; c <= cycles; c++)); do
	sleep "$gap"
	if [ $((c % 2)) -eq 1 ]; then mode=graceful; else mode=kill9; fi
	bi_check "restart $c ($mode) under load, xkmsd answers again" bi_restart "$mode"
done
sleep "$gap"
kill "${pids[@]}" 2>/dev/null
wait "${pids[@]}" 2>/dev/null

acked=0
for ((w = 1; w <= writers; w++)); do
	L=$(bi_ledger "w$w")
	[ -s "$L" ] || continue
	acked=$((acked + $(grep -c '^meta|' "$L")))
	bi_verify_set "w$w"
done
echo "acknowledged writes recorded: $acked"
bi_check "at least one write was acknowledged" [ "$acked" -gt 0 ]
echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary restart-load
