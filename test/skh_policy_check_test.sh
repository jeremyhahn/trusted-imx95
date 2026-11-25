#!/usr/bin/env bash
# scripts/skh-policy-check.py: the secure-key-handling row of docs/SPEC.md as
# a fail-closed check of a trace of enclave operations. Each vector is one
# record; the two-flag rule (RM00284 §2.4.2, owner decision 241) is checked
# flag by flag, so a record with one flag alone fails.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHK="$ROOT/scripts/skh-policy-check.py"

# vec <name> <record...>: write the records, one per line, to $TMP_ROOT/<name>.jsonl.
vec() {
	local name=$1
	shift
	printf '%s\n' "$@" >"$TMP_ROOT/$name.jsonl"
}

both='"request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[],"counter_split":true'

vec good \
	'{"op":"key_generate","api":"hsm","generated_in":"enclave"}' \
	"{\"op\":\"key_update\",\"api\":\"hsm\",$both}" \
	"{\"op\":\"key_delete\",\"api\":\"hsm\",$both}" \
	'{"op":"sign","api":"hsm"}' \
	'{"op":"data_storage","api":"hsm"}' \
	'{"op":"attest","api":"hsm"}'
run python3 "$CHK" "$TMP_ROOT/good.jsonl"
check "a trace that keeps the row passes, updates and deletions rollback-protected" 0 \
	"ok 2 key_update: rollback-protected" "ok 3 key_delete: rollback-protected" "ok 4 sign: ok" \
	"skh-policy-check: OK (6 records"

for op in key_update key_delete; do
	vec "$op-strict-only" "{\"op\":\"$op\",\"api\":\"hsm\",\"request_flags\":[\"strict\"],\"ack_flags\":[\"strict\"],\"warnings\":[],\"counter_split\":true}"
	run python3 "$CHK" "$TMP_ROOT/$op-strict-only.jsonl"
	check "$op with the strict-operation flag alone is not rollback-protected" 1 \
		"FAIL 1 $op: not rollback-protected" "monotonic flag not sent"

	vec "$op-counter-only" "{\"op\":\"$op\",\"api\":\"hsm\",\"request_flags\":[\"monotonic\"],\"ack_flags\":[\"monotonic\"],\"warnings\":[],\"counter_split\":true}"
	run python3 "$CHK" "$TMP_ROOT/$op-counter-only.jsonl"
	check "$op with the monotonic-counter flag alone is not rollback-protected" 1 \
		"FAIL 1 $op: not rollback-protected" "strict flag not sent"

	vec "$op-half-acked" "{\"op\":\"$op\",\"api\":\"hsm\",\"request_flags\":[\"strict\",\"monotonic\"],\"ack_flags\":[\"strict\"],\"warnings\":[],\"counter_split\":true}"
	run python3 "$CHK" "$TMP_ROOT/$op-half-acked.jsonl"
	check "$op with both flags sent and one acknowledged is not rollback-protected" 1 \
		"FAIL 1 $op: not rollback-protected" "monotonic flag not acknowledged"
done

vec counter-warning '{"op":"key_update","api":"hsm","request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":["HSM_KEY_STORE_COUNTER"],"counter_split":true}'
run python3 "$CHK" "$TMP_ROOT/counter-warning.jsonl"
check "a counter warning makes an acknowledged update not rollback-protected" 1 \
	"not rollback-protected" "enclave warning HSM_KEY_STORE_COUNTER"

vec no-split '{"op":"key_delete","api":"hsm","request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[]}'
run python3 "$CHK" "$TMP_ROOT/no-split.jsonl"
check "no counter split configured: not rollback-protected" 1 "counter split not configured"

vec generic '{"op":"sign","api":"generic-crypto"}'
run python3 "$CHK" "$TMP_ROOT/generic.jsonl"
check "the Generic Crypto APIs are refused" 1 "FAIL 1 sign: refused" "is not the HSM API"

vec unknown-op '{"op":"key_export","api":"hsm"}'
run python3 "$CHK" "$TMP_ROOT/unknown-op.jsonl"
check "an op the row does not use fails closed" 1 "op 'key_export' is not an HSM API service"

vec clear-key '{"op":"sign","api":"hsm","plaintext_key":"00"}'
run python3 "$CHK" "$TMP_ROOT/clear-key.jsonl"
check "a key in the clear fails" 1 "key material in the clear"

vec host-gen '{"op":"key_generate","api":"hsm","generated_in":"host"}'
run python3 "$CHK" "$TMP_ROOT/host-gen.jsonl"
check "a key generated outside the enclave fails" 1 "key not generated in the enclave"

vec mixed '{"op":"sign","api":"hsm"}' '{"op":"key_update","api":"hsm","request_flags":["strict"],"ack_flags":["strict"],"counter_split":true}'
run python3 "$CHK" "$TMP_ROOT/mixed.jsonl"
check "one bad record fails the trace and is counted" 1 "ok 1 sign: ok" "1 of 2 records break"

vec bad-json '{"op":'
run python3 "$CHK" "$TMP_ROOT/bad-json.jsonl"
check "a record that is not JSON stops the check" 2 "bad-json.jsonl:1:"

vec bad-flags '{"op":"key_update","api":"hsm","request_flags":"strict"}'
run python3 "$CHK" "$TMP_ROOT/bad-flags.jsonl"
check "flags that are not a list stop the check" 2 "request_flags must be a list of strings"

vec not-object '[1]'
run python3 "$CHK" "$TMP_ROOT/not-object.jsonl"
check "a record that is not an object stops the check" 2 "a record must be a JSON object"

: >"$TMP_ROOT/empty.jsonl"
run python3 "$CHK" "$TMP_ROOT/empty.jsonl"
check "an empty trace stops the check" 2 "no record"

run python3 "$CHK" "$TMP_ROOT/missing.jsonl"
check "a missing trace stops the check" 2 "skh-policy-check:"

run python3 "$CHK"
check "no argument prints the usage" 2 "usage: skh-policy-check.py"

finish
