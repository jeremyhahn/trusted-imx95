#!/usr/bin/env bash
# The secure-key-handling row end to end through make: make skh-policy-check
# on a trace that keeps the row (keys generated in the enclave, signing, data
# storage and attestation through the HSM API, an update and a deletion with
# both rollback flags acknowledged) and on traces that break it. Runs offline
# on a read-only root (make integration-test, make
# integration-test-secure-key-handling); writes only under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

both='"request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[],"counter_split":true'
good="$TMP_ROOT/good.jsonl"
printf '%s\n' \
	'{"op":"key_generate","api":"hsm","generated_in":"enclave"}' \
	'{"op":"sign","api":"hsm"}' \
	'{"op":"data_storage","api":"hsm"}' \
	'{"op":"attest","api":"hsm"}' \
	"{\"op\":\"key_update\",\"api\":\"hsm\",$both}" \
	"{\"op\":\"key_delete\",\"api\":\"hsm\",$both}" >"$good"

run make -s -C "$ROOT" skh-policy-check SKH_TRACE="$good"
check "make skh-policy-check: a run that keeps the row passes" 0 \
	"ok 5 key_update: rollback-protected" "ok 6 key_delete: rollback-protected" "skh-policy-check: OK (6 records"

# One flag alone, either flag, for an update and for a deletion: never protected.
for op in key_update key_delete; do
	for flag in strict monotonic; do
		t="$TMP_ROOT/$op-$flag.jsonl"
		printf '%s\n' "{\"op\":\"$op\",\"api\":\"hsm\",\"request_flags\":[\"$flag\"],\"ack_flags\":[\"$flag\"],\"warnings\":[],\"counter_split\":true}" >"$t"
		run make -s -C "$ROOT" skh-policy-check SKH_TRACE="$t"
		check "make skh-policy-check: $op acknowledged with $flag alone is not rollback-protected" nonzero \
			"FAIL 1 $op: not rollback-protected"
	done
done

t="$TMP_ROOT/generic.jsonl"
printf '%s\n' '{"op":"attest","api":"generic-crypto"}' >"$t"
run make -s -C "$ROOT" skh-policy-check SKH_TRACE="$t"
check "make skh-policy-check: the Generic Crypto APIs are refused" nonzero "is not the HSM API"

t="$TMP_ROOT/clear.jsonl"
printf '%s\n' '{"op":"key_generate","api":"hsm","generated_in":"enclave","plaintext_key":"00"}' >"$t"
run make -s -C "$ROOT" skh-policy-check SKH_TRACE="$t"
check "make skh-policy-check: a key leaving the enclave in the clear fails" nonzero "key material in the clear"

run make -s -C "$ROOT" skh-policy-check
check "make skh-policy-check: no SKH_TRACE names the variable" nonzero "set SKH_TRACE="

finish
