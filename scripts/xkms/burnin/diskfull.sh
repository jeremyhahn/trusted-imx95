#!/usr/bin/env bash
# (e) Disk full: xkmsd refuses writes cleanly and loses nothing it had acknowledged.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: diskfull.sh [options] <board ssh target>

  1. write a baseline set of keys, verify it
  2. on the board, fill the filesystem of the state directory with one
     filler file, leaving --margin-kib free
  3. keep writing: each write must either be acknowledged or fail cleanly and
     promptly (no hang, no crash); reads of the baseline must still work
  4. xkmsd must still be running; every write acknowledged while full is
     kept in the ledger
  5. remove the filler (always, on exit too); new writes must work again;
     restart xkmsd; verify the baseline and every acknowledged write
A lost or changed acknowledged write is CRITICAL. The filler is one file,
.burnin-filler, in the state directory, created with fallocate.

  --state-dir <dir>   state directory on the board (default /var/lib/xkms)
  --margin-kib <k>    free space to leave (default 256)
  --attempts <n>      writes tried while full (default 20)
  --keys <n>          baseline keys (default 20)
EOF
	bi_common_usage
}

dir=/var/lib/xkms
margin=256
attempts=20
n=20
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--state-dir) dir=${2:?}; shift 2 ;;
	--margin-kib) margin=${2:?}; shift 2 ;;
	--attempts) attempts=${2:?}; shift 2 ;;
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

if [ "$BI_DRY" = 1 ]; then
	bi_plan "write $n baseline keys and a certificate; verify"
	bi_plan "on the board: fallocate $dir/.burnin-filler to leave $margin KiB free on that filesystem"
	bi_plan "$attempts writes while full: acknowledged or a prompt clean error; xkmsd stays active; baseline readable"
	bi_plan "remove the filler (also on exit); writes work again; restart xkmsd; verify baseline and every acknowledged write"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
filler="$dir/.burnin-filler"
freed=0
free_disk() {
	bi_board "rm -f '$filler'" >/dev/null 2>&1 && freed=1
}
trap free_disk EXIT

bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary diskfull; exit 1; }
bi_write_set base "$n" "bi-df-$stamp-base"
bi_verify_set base

avail=$(bi_board "df -Pk '$dir' | tail -n 1 | tr -s ' ' | cut -d' ' -f4") || avail=""
case $avail in '' | *[!0-9]*) bi_fail "cannot read free space of $dir"; bi_summary diskfull; exit 1 ;; esac
fill=$((avail - margin))
[ "$fill" -gt 0 ] || { bi_fail "only $avail KiB free, less than the margin $margin"; bi_summary diskfull; exit 1; }
bi_check "fill $dir's filesystem ($fill KiB, $margin KiB left)" bi_board "fallocate -l ${fill}K '$filler'"

BI_WRITE_FAIL_OK=1
refused=0
hung=0
for ((i = 0; i < attempts; i++)); do
	start=$SECONDS
	BI_CTL_TIMEOUT=30 bi_ctl key generate "bi-df-$stamp-full-$i" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1
	rc=$?
	took=$((SECONDS - start))
	if [ "$rc" = 124 ] || [ "$took" -ge 25 ]; then
		hung=$((hung + 1))
	elif [ "$rc" -ne 0 ]; then
		refused=$((refused + 1))
	else
		# acknowledged: from now it is owed
		BI_REFUSED=0
		j=$(bi_ctl -o json key get "bi-df-$stamp-full-$i" 2>/dev/null) && echo "meta|bi-df-$stamp-full-$i|$(printf '%s' "$j" | bi_sha)|||" >>"$(bi_ledger full)"
	fi
done
BI_WRITE_FAIL_OK=0
echo "while full: $refused writes refused, $hung hung, $((attempts - refused - hung)) acknowledged"
bi_check "no write hung while the disk was full" [ "$hung" -eq 0 ]
bi_check "xkmsd still active while full" bi_board "systemctl is-active --quiet $BI_UNIT"
bi_verify_set base

free_disk
bi_check "filler removed" [ "$freed" -eq 1 ]
n_after=0
for ((i = 0; i < 5; i++)); do
	if bi_ctl key generate "bi-df-$stamp-after-$i" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1; then n_after=$((n_after + 1)); fi
done
bi_check "writes work again once space is free (5 of 5)" [ "$n_after" -eq 5 ]
bi_check "graceful restart" bi_restart graceful
bi_verify_set base
[ ! -s "$(bi_ledger full)" ] || bi_verify_set full

echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary diskfull
