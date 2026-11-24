#!/usr/bin/env bash
# (b) Soak: a steady mixed load for hours, with latency percentiles, error
# counts, and the daemon's RSS and descriptor growth sampled from the board.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: soak.sh [options] <board ssh target>

Creates a few keys, then runs --workers parallel clients for the duration.
Each loops over a mix of operations on those keys: sign+verify, encrypt+
decrypt, key get, key list, and generate+delete of a throwaway key. Every
call's latency and exit status is logged. At the end it prints per operation:
count, errors, p50/p95/p99 in ms. The board is sampled every --sample-secs
for the daemon's RSS and open descriptors. A set of keys written before the
soak is verified afterwards (a loss is CRITICAL).

FAIL when: the error rate exceeds --max-error-pct, RSS grew by more than
--max-rss-growth-pct, descriptors by more than --max-fd-growth, or xkmsd
restarted (its PID changed) during the run.

  --hours <h>              duration in hours (default 1)
  --seconds <s>            duration in seconds, instead of --hours
  --workers <n>            parallel clients (default 4)
  --sample-secs <s>        board sampling interval (default 60)
  --max-error-pct <p>      default 0.5
  --max-rss-growth-pct <p> default 20
  --max-fd-growth <n>      default 20
EOF
	bi_common_usage
}

hours=1
secs=""
workers=4
sample=60
maxerr=0.5
maxrss=20
maxfd=20
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--hours) hours=${2:?}; shift 2 ;;
	--seconds) secs=${2:?}; shift 2 ;;
	--workers) workers=${2:?}; shift 2 ;;
	--sample-secs) sample=${2:?}; shift 2 ;;
	--max-error-pct) maxerr=${2:?}; shift 2 ;;
	--max-rss-growth-pct) maxrss=${2:?}; shift 2 ;;
	--max-fd-growth) maxfd=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done
for v in "$hours" "$workers" "$sample" "$maxrss" "$maxfd" "${secs:-0}"; do
	case $v in '' | *[!0-9]*) bi_die "numeric option expected, got '$v'" ;; esac
done
[ -n "$secs" ] || secs=$((hours * 3600))

if [ "$BI_DRY" = 1 ]; then
	bi_plan "write a 10-key set (verified at the end), create 4 soak keys"
	bi_plan "$workers workers for ${secs}s: sign+verify, encrypt+decrypt, get, list, generate+delete; latency and status per call"
	bi_plan "every ${sample}s ssh to the board: daemon PID, RSS KiB, open descriptors"
	bi_plan "report p50/p95/p99 and errors per operation; FAIL above ${maxerr}% errors, ${maxrss}% RSS growth, +$maxfd descriptors, or a daemon restart"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary soak; exit 1; }
bi_write_set pre 10 "bi-soak-$stamp-pre"
bi_ctl key generate "bi-soak-$stamp-sig" --key-algorithm ecdsa --curve P-256 --key-type signing >/dev/null 2>&1 || bi_fail "create soak signing key"
bi_ctl key generate "bi-soak-$stamp-aes" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1 || bi_fail "create soak aes key"

now_ms() { local t=${EPOCHREALTIME/./}; echo $((t / 1000)); }

# timed <worker> <op> <command...>: log "op ms rc"
timed() {
	local w=$1 op=$2 t0 rc
	shift 2
	t0=$(now_ms)
	"$@" >/dev/null 2>&1
	rc=$?
	echo "$op $(($(now_ms) - t0)) $rc" >>"$BI_WORK/lat.$w"
	return "$rc"
}

worker() {
	local w=$1 end=$2 i=0 j sig ct n tag
	local sk="bi-soak-$stamp-sig" ak="bi-soak-$stamp-aes"
	while [ "$SECONDS" -lt "$end" ]; do
		i=$((i + 1))
		case $((i % 5)) in
		0)
			sig=""
			j=$(bi_ctl -o json key sign "$sk" "soak-$w-$i" 2>/dev/null) && sig=$(bi_jget "$j" signature)
			timed "$w" sign bi_ctl -o json key sign "$sk" "soak-$w-$i"
			[ -z "${sig:-}" ] || timed "$w" verify bi_ctl key verify "$sk" "soak-$w-$i" "$sig"
			;;
		1)
			j=$(bi_ctl -o json key encrypt "$ak" "soak-$w-$i" 2>/dev/null) || { echo "encrypt 0 1" >>"$BI_WORK/lat.$w"; continue; }
			ct=$(bi_jget "$j" ciphertext) n=$(bi_jget "$j" nonce) tag=$(bi_jget "$j" tag)
			timed "$w" encrypt bi_ctl key encrypt "$ak" "soak-$w-$i"
			timed "$w" decrypt bi_ctl key decrypt "$ak" "$ct" --nonce "$n" --tag "$tag"
			;;
		2) timed "$w" get bi_ctl key get "$sk" ;;
		3) timed "$w" list bi_ctl key list ;;
		4)
			timed "$w" generate bi_ctl key generate "bi-soak-$stamp-t$w-$i" --key-type symmetric --algorithm aes-256-gcm --key-size 256
			timed "$w" delete bi_ctl key delete "bi-soak-$stamp-t$w-$i"
			;;
		esac
	done
}

pid0=$(bi_board "systemctl show -p MainPID --value $BI_UNIT" 2>/dev/null)
end=$((SECONDS + secs))
for ((w = 1; w <= workers; w++)); do worker "$w" "$end" & done

: >"$BI_WORK/samples"
while [ "$SECONDS" -lt "$end" ]; do
	s=$(bi_proc_sample) && echo "$(date -u +%H:%M:%S) $s" >>"$BI_WORK/samples"
	sleep "$sample"
done
wait

pid1=$(bi_board "systemctl show -p MainPID --value $BI_UNIT" 2>/dev/null)
bi_check "xkmsd did not restart during the soak (pid $pid0 -> $pid1)" [ "$pid0" = "$pid1" ]

# percentiles
total=0
errs=0
for op in sign verify encrypt decrypt get list generate delete; do
	cat "$BI_WORK"/lat.* 2>/dev/null | while read -r o ms rc; do [ "$o" = "$op" ] && echo "$ms $rc"; done >"$BI_WORK/op.$op"
	c=$(wc -l <"$BI_WORK/op.$op")
	[ "$c" -gt 0 ] || continue
	e=0
	while read -r _ rc; do [ "$rc" = 0 ] || e=$((e + 1)); done <"$BI_WORK/op.$op"
	mapfile -t v < <(cut -d' ' -f1 "$BI_WORK/op.$op" | sort -n)
	printf 'op %-9s n=%-7d errors=%-5d p50=%sms p95=%sms p99=%sms\n' "$op" "$c" "$e" \
		"${v[$((c * 50 / 100))]}" "${v[$((c * 95 / 100))]}" "${v[$((c * 99 / 100 >= c ? c - 1 : c * 99 / 100))]}"
	total=$((total + c))
	errs=$((errs + e))
done
# errors in hundredths of a percent, to stay in integers
maxerr_x100=$(printf '%s' "$maxerr" | { IFS=. read -r a b; echo $((a * 100 + ${b:-0} * 10 ** (2 - ${#b}))); } 2>/dev/null || echo 50)
if [ "$total" -gt 0 ]; then
	bi_check "error rate $errs/$total within ${maxerr}%" [ $((errs * 10000 / total)) -le "$maxerr_x100" ]
else
	bi_fail "no calls were made"
fi

# growth: first sample against the last
mapfile -t smp <"$BI_WORK/samples"
if [ "${#smp[@]}" -ge 2 ]; then
	read -r _ rss0 fd0 <<<"${smp[0]}"
	read -r _ rss1 fd1 <<<"${smp[${#smp[@]} - 1]}"
	echo "daemon: RSS ${rss0} -> ${rss1} KiB, descriptors ${fd0} -> ${fd1} over ${#smp[@]} samples ($BI_WORK/samples)"
	bi_check "RSS growth within ${maxrss}%" [ $((rss1 * 100)) -le $((rss0 * (100 + maxrss))) ]
	bi_check "descriptor growth within $maxfd" [ $((fd1 - fd0)) -le "$maxfd" ]
else
	bi_fail "fewer than two board samples"
fi

bi_verify_set pre
bi_summary soak
