#!/usr/bin/env bash
# (f) Concurrency: parallel clients doing conflicting operations on the same keys.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: concurrency.sh [options] <board ssh target>

Runs --clients parallel xkmsctl processes against the same key ids, for
--rounds rounds. Each round:
  1. all clients generate the same new key id at once: at most one may be
     acknowledged, and the key must exist afterwards
  2. all clients sign with it at once: every signature must verify
  3. all clients delete it at once: the key must be gone afterwards, and
     no client may be told it was deleted while it still exists
Then every key written by a client with a unique id (acknowledged) is
verified from the ledger. A lost or changed acknowledged write is CRITICAL.
More than one acknowledged create of one id is a FAIL (a lost update).

  --clients <n>   parallel clients (default 8)
  --rounds <n>    rounds (default 10)
EOF
	bi_common_usage
}

clients=8
rounds=10
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--clients) clients=${2:?}; shift 2 ;;
	--rounds) rounds=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done
for v in "$clients" "$rounds"; do
	case $v in '' | *[!0-9]*) bi_die "numeric option expected, got '$v'" ;; esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "$rounds rounds of $clients clients on one key id: simultaneous create (at most one acknowledged), sign (all verify), delete (key gone)"
	bi_plan "each client also writes keys with unique ids; every acknowledged one is verified at the end"
	bi_plan "a lost or changed acknowledged write prints CRITICAL; two acknowledged creates of one id is a FAIL"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary concurrency; exit 1; }

L=$(bi_ledger uniq)
: >"$L"
for ((r = 1; r <= rounds; r++)); do
	id="bi-cc-$stamp-shared-$r"
	rm -f "$BI_WORK"/cc.*
	for ((c = 1; c <= clients; c++)); do
		(
			if bi_ctl key generate "$id" --key-algorithm ecdsa --curve P-256 --key-type signing >/dev/null 2>&1; then echo ok >"$BI_WORK/cc.create.$c"; fi
			# unique id: owed once acknowledged
			u="bi-cc-$stamp-u-$r-$c"
			if bi_ctl key generate "$u" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1; then
				bi_ack "$BI_WORK/cc.uniq.$c" "$u"
				j=$(bi_ctl -o json key get "$u" 2>/dev/null) && echo "meta|$u|$(printf '%s' "$j" | bi_sha)|||" >>"$BI_WORK/cc.uniq.$c"
			fi
		) &
	done
	wait
	cat "$BI_WORK"/cc.uniq.* >>"$L" 2>/dev/null
	made=$(find "$BI_WORK" -maxdepth 1 -name 'cc.create.*' | wc -l)
	bi_check "round $r: at most one create of $id acknowledged ($made)" [ "$made" -le 1 ]
	bi_check "round $r: $id exists after the race" bi_ctl key get "$id"

	rm -f "$BI_WORK"/cc.*sign.*
	for ((c = 1; c <= clients; c++)); do
		(
			# a failed request or an answer without a signature is a failure too:
			# the parent needs one verified signature from every client
			j=$(bi_ctl -o json key sign "$id" "cc-$r-$c" 2>/dev/null) || { touch "$BI_WORK/cc.failsign.$c"; exit 0; }
			s=$(bi_jget "$j" signature) && [ -n "$s" ] || { touch "$BI_WORK/cc.failsign.$c"; exit 0; }
			if bi_ctl key verify "$id" "cc-$r-$c" "$s" >/dev/null 2>&1; then
				touch "$BI_WORK/cc.oksign.$c"
			else
				touch "$BI_WORK/cc.badsign.$c"
			fi
		) &
	done
	wait
	failed=$(find "$BI_WORK" -maxdepth 1 -name 'cc.failsign.*' | wc -l)
	bad=$(find "$BI_WORK" -maxdepth 1 -name 'cc.badsign.*' | wc -l)
	good=$(find "$BI_WORK" -maxdepth 1 -name 'cc.oksign.*' | wc -l)
	bi_check "round $r: every concurrent sign request answered with a signature ($failed failed)" [ "$failed" -eq 0 ]
	bi_check "round $r: every concurrent signature verifies ($bad do not)" [ "$bad" -eq 0 ]
	bi_check "round $r: one verified signature per client ($good of $clients)" [ "$good" -eq "$clients" ]

	rm -f "$BI_WORK"/cc.del.*
	for ((c = 1; c <= clients; c++)); do
		(bi_ctl key delete "$id" >/dev/null 2>&1 && echo ok >"$BI_WORK/cc.del.$c") &
	done
	wait
	dels=$(find "$BI_WORK" -maxdepth 1 -name 'cc.del.*' | wc -l)
	bi_check "round $r: $id gone after concurrent deletes ($dels acknowledged)" bash -c '! "$@" >/dev/null 2>&1' _ "$BI_CTL" "${BI_CTL_ARGS[@]}" ${BI_SERVER:+--server "$BI_SERVER"} key get "$id"
	bi_check "round $r: at least one delete acknowledged" [ "$dels" -ge 1 ]
done

if [ -s "$L" ]; then bi_verify_set uniq; else bi_fail "no unique-id write was acknowledged"; fi
bi_check "xkmsd still active" bi_board "systemctl is-active --quiet $BI_UNIT"
echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary concurrency
