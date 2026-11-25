#!/usr/bin/env bash
# scripts/okp-policy-check.py: the oem-key-provisioning row of docs/SPEC.md as
# a fail-closed check of the trace of one provisioning run. Each vector is one
# run; the vendor's order (key exchange, then the wrapped-key import), the
# two-flag commit of the import, and the once-only, owner-approved fuse write
# and life-cycle close are checked one by one.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHK="$ROOT/scripts/okp-policy-check.py"

# vec <name> <record...>: write the records, one per line, to $TMP_ROOT/<name>.jsonl.
vec() {
	local name=$1
	shift
	printf '%s\n' "$@" >"$TMP_ROOT/$name.jsonl"
}

both='"status":"ok","request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[],"counter_split":true'
kx='{"step":"key_exchange","status":"ok"}'
imp="{\"step\":\"key_import\",\"wrapped\":true,$both}"
fuse='{"step":"counter_fuse_config","status":"ok","owner_approval":"OD-test","already_configured":false}'
evid='{"step":"counter_fuse_evidence","configured":true,"evidence":"OD-test-readout"}'
close='{"step":"lifecycle_close","status":"ok","from":"oem_open","to":"oem_closed","via":"enclave","owner_approval":"OD-test"}'

vec good "$kx" "$imp" "$fuse" "$close"
run python3 "$CHK" "$TMP_ROOT/good.jsonl"
check "a run that keeps the row passes" 0 \
	"ok 1 key_exchange: ok" "ok 2 key_import: committed" "ok 3 counter_fuse_config: ok" \
	"ok 4 lifecycle_close: ok" "okp-policy-check: OK (4 records"

vec good-evidence "$kx" "$imp" "$evid" "$close"
run python3 "$CHK" "$TMP_ROOT/good-evidence.jsonl"
check "evidence of fuses configured before the run stands in for the write" 0 \
	"ok 3 counter_fuse_evidence: ok" "okp-policy-check: OK (4 records"

vec kx-only "$kx"
run python3 "$CHK" "$TMP_ROOT/kx-only.jsonl"
check "a trace that stops after the key exchange fails" 1 "ok 1 key_exchange: ok" \
	"FAIL end of trace: no key import committed" "no counter_fuse_config" "no life-cycle close"

vec no-import "$kx" "$fuse" "$close"
run python3 "$CHK" "$TMP_ROOT/no-import.jsonl"
check "a run with no import fails" 1 "FAIL end of trace: no key import committed"

vec no-fuse "$kx" "$imp" "$close"
run python3 "$CHK" "$TMP_ROOT/no-fuse.jsonl"
check "a run with the fuses not shown configured fails" 1 "FAIL end of trace: the counter fuses are not shown configured"

vec no-close "$kx" "$imp" "$fuse"
run python3 "$CHK" "$TMP_ROOT/no-close.jsonl"
check "a run with no life-cycle close fails" 1 "FAIL end of trace: no life-cycle close"

vec refused-import-only "$kx" "{\"step\":\"key_import\",\"wrapped\":false,$both}" "$fuse" "$close"
run python3 "$CHK" "$TMP_ROOT/refused-import-only.jsonl"
check "an import that was refused does not count as committed" 1 "FAIL end of trace: no key import committed"

nowarn='"status":"ok","request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"counter_split":true'
for w in absent null string; do
	case $w in
	absent) field= ;;
	null) field=',"warnings":null' ;;
	string) field=',"warnings":"none"' ;;
	esac
	vec "import-warnings-$w" "$kx" "{\"step\":\"key_import\",\"wrapped\":true,$nowarn$field}" "$fuse" "$close"
	run python3 "$CHK" "$TMP_ROOT/import-warnings-$w.jsonl"
	check "an import with warnings $w is not committed" 1 "FAIL 2 key_import: not committed" "warnings absent or not a list"
done

# An import whose outcome is not the string "ok" is not committed, whatever its flags say.
for st in error null absent unknown number; do
	case $st in
	error) field='"status":"error",' ;;
	null) field='"status":null,' ;;
	absent) field= ;;
	unknown) field='"status":"pending",' ;;
	number) field='"status":0,' ;;
	esac
	vec "import-status-$st" "$kx" "{\"step\":\"key_import\",$field\"wrapped\":true,\"request_flags\":[\"strict\",\"monotonic\"],\"ack_flags\":[\"strict\",\"monotonic\"],\"warnings\":[],\"counter_split\":true}" "$fuse" "$close"
	run python3 "$CHK" "$TMP_ROOT/import-status-$st.jsonl"
	check "an import with status $st is not committed" 1 "FAIL 2 key_import: not committed" \
		"import outcome: status" "FAIL end of trace: no key import committed"
done

for p in absent null true-string false-string; do
	case $p in
	absent) field= ;;
	null) field=',"already_configured":null' ;;
	true-string) field=',"already_configured":"true"' ;;
	false-string) field=',"already_configured":"false"' ;;
	esac
	vec "fuse-prior-$p" "$kx" "$imp" "{\"step\":\"counter_fuse_config\",\"status\":\"ok\",\"owner_approval\":\"OD-test\"$field}" "$close"
	run python3 "$CHK" "$TMP_ROOT/fuse-prior-$p.jsonl"
	check "a fuse write with the prior state $p fails" 1 "FAIL 3 counter_fuse_config: refused" \
		"already_configured must be present and the JSON boolean false"
done

fuse_body='"owner_approval":"OD-test","already_configured":false'
close_body='"from":"oem_open","to":"oem_closed","via":"enclave","owner_approval":"OD-test"'
for s in counter_fuse_config lifecycle_close; do
	case $s in
	counter_fuse_config) body=$fuse_body ;;
	lifecycle_close) body=$close_body ;;
	esac
	for st in absent null error unknown number list; do
		case $st in
		absent) field= ;;
		null) field='"status":null,' ;;
		error) field='"status":"error",' ;;
		unknown) field='"status":"pending",' ;;
		number) field='"status":0,' ;;
		list) field='"status":["ok"],' ;;
		esac
		rec="{\"step\":\"$s\",$field$body}"
		if [ "$s" = counter_fuse_config ]; then
			vec "$s-status-$st" "$kx" "$imp" "$rec" "$close"
		else
			vec "$s-status-$st" "$kx" "$imp" "$fuse" "$rec"
		fi
		run python3 "$CHK" "$TMP_ROOT/$s-status-$st.jsonl"
		check "$s with status $st fails and does not complete the run" 1 \
			"$s outcome: status" "FAIL end of trace"
	done
done

vec evid-bad '{"step":"counter_fuse_evidence","configured":true}'
run python3 "$CHK" "$TMP_ROOT/evid-bad.jsonl"
check "evidence without a reference fails" 1 "FAIL 1 counter_fuse_evidence" "non-empty \"evidence\""

vec evid-false '{"step":"counter_fuse_evidence","configured":false,"evidence":"x"}'
run python3 "$CHK" "$TMP_ROOT/evid-false.jsonl"
check "evidence that the fuses are not configured fails" 1 "needs \"configured\": true"

vec evid-then-write "$evid" "$fuse"
run python3 "$CHK" "$TMP_ROOT/evid-then-write.jsonl"
check "a fuse write after evidence of configured fuses fails" 1 "FAIL 2 counter_fuse_config" "already configured"

vec write-then-evid "$fuse" "$evid"
run python3 "$CHK" "$TMP_ROOT/write-then-evid.jsonl"
check "evidence after a fuse write in the same run fails" 1 "FAIL 2 counter_fuse_evidence" "no prior state to evidence"

vec import-first "$imp" "$kx"
run python3 "$CHK" "$TMP_ROOT/import-first.jsonl"
check "an import before the key exchange fails" 1 "FAIL 1 key_import" "no successful key exchange before the import"

vec failed-kx '{"step":"key_exchange","status":"error"}' "$imp"
run python3 "$CHK" "$TMP_ROOT/failed-kx.jsonl"
check "a failed key exchange does not admit the import" 1 \
	"FAIL 1 key_exchange: refused" "FAIL 2 key_import" "no successful key exchange"

vec unwrapped "$kx" "{\"step\":\"key_import\",\"wrapped\":false,$both}"
run python3 "$CHK" "$TMP_ROOT/unwrapped.jsonl"
check "an import of a key that is not wrapped fails" 1 "the imported key is not wrapped"

for flag in strict monotonic; do
	vec "import-$flag-only" "$kx" "{\"step\":\"key_import\",\"status\":\"ok\",\"wrapped\":true,\"request_flags\":[\"$flag\"],\"ack_flags\":[\"$flag\"],\"warnings\":[],\"counter_split\":true}"
	run python3 "$CHK" "$TMP_ROOT/import-$flag-only.jsonl"
	check "an import acknowledged with $flag alone is not committed" 1 "FAIL 2 key_import: not committed"
done

vec half-acked "$kx" '{"step":"key_import","status":"ok","wrapped":true,"request_flags":["strict","monotonic"],"ack_flags":["strict"],"warnings":[],"counter_split":true}'
run python3 "$CHK" "$TMP_ROOT/half-acked.jsonl"
check "both flags sent, one acknowledged: not committed" 1 "monotonic flag not acknowledged"

vec warning "$kx" '{"step":"key_import","status":"ok","wrapped":true,"request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":["HSM_KEY_STORE_COUNTER"],"counter_split":true}'
run python3 "$CHK" "$TMP_ROOT/warning.jsonl"
check "a counter warning makes the import not committed" 1 "enclave warning HSM_KEY_STORE_COUNTER"

vec no-split "$kx" '{"step":"key_import","status":"ok","wrapped":true,"request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[]}'
run python3 "$CHK" "$TMP_ROOT/no-split.jsonl"
check "no counter split: the import is not committed" 1 "counter split not configured"

vec fuse-unapproved '{"step":"counter_fuse_config"}'
run python3 "$CHK" "$TMP_ROOT/fuse-unapproved.jsonl"
check "a fuse write without the owner's approval fails" 1 "FAIL 1 counter_fuse_config: refused" "no owner_approval recorded"

vec fuse-blank '{"step":"counter_fuse_config","owner_approval":"  "}'
run python3 "$CHK" "$TMP_ROOT/fuse-blank.jsonl"
check "a blank approval is no approval" 1 "no owner_approval recorded"

vec fuse-twice "$fuse" "$fuse"
run python3 "$CHK" "$TMP_ROOT/fuse-twice.jsonl"
check "the counter fuses are configured once" 1 "ok 1 counter_fuse_config: ok" "FAIL 2 counter_fuse_config" "runs at most once"

vec fuse-again '{"step":"counter_fuse_config","owner_approval":"OD-test","already_configured":true}'
run python3 "$CHK" "$TMP_ROOT/fuse-again.jsonl"
check "fuses already configured are not configured again" 1 "already configured"

vec close-unapproved '{"step":"lifecycle_close","from":"oem_open","to":"oem_closed","via":"enclave"}'
run python3 "$CHK" "$TMP_ROOT/close-unapproved.jsonl"
check "a life-cycle close without the owner's approval fails" 1 "FAIL 1 lifecycle_close: refused" "no owner_approval recorded"

vec close-twice "$close" "$close"
run python3 "$CHK" "$TMP_ROOT/close-twice.jsonl"
check "the life cycle closes once" 1 "FAIL 2 lifecycle_close" "runs at most once"

vec close-wrong '{"step":"lifecycle_close","from":"oem_open","to":"oem_closed","via":"fuse_tool","owner_approval":"OD-test"}'
run python3 "$CHK" "$TMP_ROOT/close-wrong.jsonl"
check "a close not through the enclave fails" 1 "via 'fuse_tool', want 'enclave'"

vec close-state '{"step":"lifecycle_close","from":"oem_closed","to":"oem_closed","via":"enclave","owner_approval":"OD-test"}'
run python3 "$CHK" "$TMP_ROOT/close-state.jsonl"
check "a close that does not start from OEM open fails" 1 "from 'oem_closed', want 'oem_open'"

vec clear-key "$kx" "{\"step\":\"key_import\",\"wrapped\":true,\"plaintext_key\":\"00\",$both}"
run python3 "$CHK" "$TMP_ROOT/clear-key.jsonl"
check "a key in the clear fails" 1 "key material in the clear"

vec unknown '{"step":"key_export"}'
run python3 "$CHK" "$TMP_ROOT/unknown.jsonl"
check "a step the flow does not have fails closed" 1 "step 'key_export' is not a step of the vendor's flow"

vec bad-json '{"step":'
run python3 "$CHK" "$TMP_ROOT/bad-json.jsonl"
check "a record that is not JSON stops the check" 2 "bad-json.jsonl:1:"

vec bad-flags "$kx" '{"step":"key_import","status":"ok","wrapped":true,"request_flags":"strict"}'
run python3 "$CHK" "$TMP_ROOT/bad-flags.jsonl"
check "flags that are not a list stop the check" 2 "request_flags must be a list of strings"

vec not-object '[1]'
run python3 "$CHK" "$TMP_ROOT/not-object.jsonl"
check "a record that is not an object stops the check" 2 "a record must be a JSON object"

: >"$TMP_ROOT/empty.jsonl"
run python3 "$CHK" "$TMP_ROOT/empty.jsonl"
check "an empty trace stops the check" 2 "no record"

run python3 "$CHK" "$TMP_ROOT/missing.jsonl"
check "a missing trace stops the check" 2 "okp-policy-check:"

run python3 "$CHK"
check "no argument prints the usage" 2 "usage: okp-policy-check.py"

finish
