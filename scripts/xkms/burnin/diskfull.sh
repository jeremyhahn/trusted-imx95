#!/usr/bin/env bash
# (e) Disk full: xkmsd refuses writes cleanly and loses nothing it had acknowledged.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: diskfull.sh [options] <board ssh target>

  1. write a baseline set of keys, verify it
  2. on the board, fill the filesystem of the state directory with one
     filler file, leaving --margin-kib to xkmsd. The blocks reserved for
     root are reported; when xkmsd runs as root it can use them, so the
     filler covers them too
  3. write keys until xkmsd reports no space (an error matching
     --nospace-re). FAIL when --max-writes writes or --max-kib KiB of the
     filesystem go by first: the disk was never seen full
  4. --attempts more writes while full: each refused or acknowledged, none
     cut off by the 30 s timeout (a hang); xkmsd still running; the
     baseline readable
A create that exits 0 is acknowledged and owed however long it took; one
that took --slow-secs or more is a warning (SLOW), never a lost write.
  5. remove the filler (always, on exit too); every write acknowledged
     before the disk was full is still readable and new writes work;
     restart xkmsd; verify the baseline and every acknowledged write
A lost or changed acknowledged write is CRITICAL. The filler is one file,
.burnin-filler, in the state directory, created with fallocate.

  --state-dir <dir>   state directory on the board (default /var/lib/xkms)
  --margin-kib <k>    space left to xkmsd (default 256)
  --max-writes <n>    writes allowed to fill it (default 5000)
  --max-kib <k>       KiB they may take from the filesystem (default 4 x margin)
  --nospace-re <ere>  what xkmsctl says when xkmsd is out of space,
                      case-insensitive (default 'no space|ENOSPC|disk full|out of space')
  --attempts <n>      writes tried once full (default 5)
  --slow-secs <s>     a create answered after this long is SLOW (default 25)
  --keys <n>          baseline keys (default 20)
EOF
	bi_common_usage
}

dir=/var/lib/xkms
margin=256
max_writes=5000
max_kib=""
nospace_re='no space|ENOSPC|disk full|out of space'
attempts=5
slow_secs=25
n=20
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--state-dir) dir=${2:?}; shift 2 ;;
	--margin-kib) margin=${2:?}; shift 2 ;;
	--max-writes) max_writes=${2:?}; shift 2 ;;
	--max-kib) max_kib=${2:?}; shift 2 ;;
	--nospace-re) nospace_re=${2:?}; shift 2 ;;
	--attempts) attempts=${2:?}; shift 2 ;;
	--slow-secs) slow_secs=${2:?}; shift 2 ;;
	--keys) n=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done
case $dir in /* ) ;; *) bi_die "--state-dir must be absolute" ;; esac
case $dir in *[!A-Za-z0-9/_.-]*) bi_die "--state-dir has odd characters" ;; esac
max_kib=${max_kib:-$((4 * margin))}
for v in "$margin" "$max_writes" "$max_kib" "$attempts" "$slow_secs" "$n"; do
	case $v in '' | *[!0-9]*) bi_die "numeric option expected, got '$v'" ;; esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "write $n baseline keys and a certificate; verify"
	bi_plan "on the board: report the blocks reserved for root and xkmsd's user; fallocate $dir/.burnin-filler to leave $margin KiB to xkmsd"
	bi_plan "write until xkmsd reports no space, at most $max_writes writes or $max_kib KiB; FAIL if it never does"
	bi_plan "$attempts writes while full: refused or acknowledged promptly; xkmsd stays active; baseline readable"
	bi_plan "remove the filler (also on exit); verify every write acknowledged before; new writes work; restart xkmsd; verify all"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
filler="$BI_ROOT$dir/.burnin-filler" # BI_ROOT is empty on a board
freed=0
free_disk() {
	bi_board "rm -f '$filler'" >/dev/null 2>&1 && freed=1
}
trap free_disk EXIT

bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary diskfull; exit 1; }
bi_write_set base "$n" "bi-df-$stamp-base"
bi_verify_set base

# df_kib: "<size> <used> <available>" in KiB for the state directory's filesystem
df_kib() {
	bi_board "df -Pk '$BI_ROOT$dir' | tail -n 1 | tr -s ' ' | cut -d' ' -f2-4"
}
read -r size used avail <<<"$(df_kib)"
for v in "${size:-}" "${used:-}" "${avail:-}"; do
	case $v in '' | *[!0-9]*) bi_fail "cannot read the space of $dir"; bi_summary diskfull; exit 1 ;; esac
done
reserved=$((size - used - avail))
[ "$reserved" -ge 0 ] || reserved=0
user=$(bi_board "systemctl show -p User --value $BI_UNIT") || user=""
if [ -z "$user" ] || [ "$user" = root ]; then
	xroot=1
	echo "xkmsd runs as root: it can use the $reserved KiB reserved for root, so the filler covers them"
else
	xroot=0
	echo "xkmsd runs as $user: the $reserved KiB reserved for root are not its to use"
fi
room() { # the KiB xkmsd can still use
	local s u a
	read -r s u a <<<"$(df_kib)"
	case "${s:-}${u:-}${a:-}" in '' | *[!0-9]*) return 1 ;; esac
	if [ "$xroot" = 1 ]; then echo $((s - u)); else echo "$a"; fi
}
room0=$(room) || room0=""
fill=$((${room0:-0} - margin))
[ "$fill" -gt 0 ] || { bi_fail "only ${room0:-?} KiB free for xkmsd, not more than the margin $margin"; bi_summary diskfull; exit 1; }
bi_check "fill $dir's filesystem ($fill KiB, $margin KiB left to xkmsd)" bi_board "fallocate -l ${fill}K '$filler'"
room0=$(room) || room0=""

# try_write <ledger> <id>: one create; sets $res to ack, nospace, refused or
# hung (cut off by the 30 s timeout, so unknown), $msg to xkmsctl's first line
# and $secs to how long it took. The try line comes first, so a create never
# answered stays unknown. A create that exits 0 is acked whatever its latency:
# it is owed from then on, and slowness is reported apart (SLOW), not as loss.
try_write() {
	local L start out rc
	L=$(bi_ledger "$1")
	echo "try|$2||||" >>"$L"
	start=$SECONDS
	out=$(BI_CTL_TIMEOUT=30 bi_ctl key generate "$2" --key-type symmetric --algorithm aes-256-gcm --key-size 256 2>&1)
	rc=$?
	secs=$((SECONDS - start))
	msg=${out%%$'\n'*}
	if [ "$rc" = 0 ]; then
		res=ack # from now it is owed
		bi_ack "$L" "$2"
		# a key-bound proof, so the verify detects replaced key material
		bi_prove "$L" "$2" || bi_fail "create $2 was acknowledged but no key-bound proof could be made: its durability cannot be checked"
		j=$(bi_ctl -o json key get "$2" 2>/dev/null) && echo "meta|$2|$(printf '%s' "$j" | bi_sha)|||" >>"$L"
	elif [ "$rc" = 124 ]; then
		res=hung
	elif printf '%s\n' "$out" | grep -Eqi -- "$nospace_re"; then
		res=nospace
	else
		res=refused
	fi
	if [ "$res" != hung ] && [ "$secs" -ge "$slow_secs" ]; then
		slow=$((slow + 1))
		echo "SLOW: create $2 took ${secs}s to answer ($res); counted as $res, not lost"
	fi
}
count() { # count <res>: tally one result
	case $1 in ack) acked=$((acked + 1)) ;; hung) hung=$((hung + 1)) ;; refused) other=$((other + 1)) ;; esac
}

acked=0 hung=0 other=0 slow=0 i=0 full=0 bound=""
while :; do
	if [ "$i" -ge "$max_writes" ]; then bound="$max_writes writes"; break; fi
	if [ $((i % 25)) -eq 0 ] && [ -n "$room0" ] && r=$(room) && [ $((room0 - r)) -gt "$max_kib" ]; then
		bound="$i writes taking $((room0 - r)) KiB"
		break
	fi
	try_write full "bi-df-$stamp-full-$i"
	i=$((i + 1))
	if [ "$res" = nospace ]; then
		full=1
		echo "xkmsd reported no space at write $i: $msg"
		break
	fi
	count "$res"
done
echo "until full: $acked acknowledged, $other refused for another reason, $hung hung, $slow slow (${slow_secs}s or more)"
if [ "$full" = 1 ]; then
	bi_check "xkmsd reported no space (bound $max_writes writes, $max_kib KiB)" true
	nospace=0
	for ((k = 0; k < attempts; k++)); do
		try_write full "bi-df-$stamp-fullx-$k"
		[ "$res" != nospace ] || nospace=$((nospace + 1))
		count "$res"
	done
	echo "while full: $attempts more writes, $nospace refused for no space"
else
	bi_fail "the disk was never full: $bound went by without xkmsd reporting no space (check --nospace-re, --margin-kib, the reserved blocks)"
fi
bi_check "no write hung while filling the disk" [ "$hung" -eq 0 ]
bi_check "xkmsd still active while full" bi_board "systemctl is-active --quiet $BI_UNIT"
bi_verify_set base

free_disk
bi_check "filler removed" [ "$freed" -eq 1 ]
has_ack() { grep -q '^ack|' "$(bi_ledger "$1")" 2>/dev/null; }
# recovery: what xkmsd acknowledged before the disk was full is still there
if has_ack full; then bi_verify_set full; else echo "no write was acknowledged before the disk was full"; fi
n_after=0
for ((i = 0; i < 5; i++)); do
	try_write after "bi-df-$stamp-after-$i"
	[ "$res" != ack ] || n_after=$((n_after + 1))
done
bi_check "writes work again once space is free (5 of 5)" [ "$n_after" -eq 5 ]
bi_check "graceful restart" bi_restart graceful
bi_verify_set base
! has_ack full || bi_verify_set full
! has_ack after || bi_verify_set after

[ "$slow" -eq 0 ] || echo "WARNING: $slow create(s) answered after ${slow_secs}s or more (SLOW above); each is acked and verified like the rest"
echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary diskfull