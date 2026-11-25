#!/usr/bin/env bash
# The oem-key-provisioning row end to end through make: make okp-policy-check
# on a provisioning run that keeps the row (key exchange, then the import of
# the wrapped key committed with both rollback flags, the counter fuses
# configured once and the life cycle closed through the enclave, each
# irreversible step with the owner's approval) and on runs that break it.
# Runs offline on a read-only root (make integration-test, make
# integration-test-oem-key-provisioning); writes only under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

both='"request_flags":["strict","monotonic"],"ack_flags":["strict","monotonic"],"warnings":[],"counter_split":true'
kx='{"step":"key_exchange","status":"ok"}'
imp="{\"step\":\"key_import\",\"wrapped\":true,$both}"
fuse='{"step":"counter_fuse_config","status":"ok","owner_approval":"OD-test","already_configured":false}'
close='{"step":"lifecycle_close","status":"ok","from":"oem_open","to":"oem_closed","via":"enclave","owner_approval":"OD-test"}'

good="$TMP_ROOT/good.jsonl"
printf '%s\n' "$kx" "$imp" "$fuse" "$close" >"$good"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$good"
check "make okp-policy-check: a run that keeps the row passes" 0 \
	"ok 2 key_import: committed" "ok 4 lifecycle_close: ok" "okp-policy-check: OK (4 records"

t="$TMP_ROOT/kx-only.jsonl"
printf '%s\n' "$kx" >"$t"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
check "make okp-policy-check: a run that stops after the key exchange fails" nonzero \
	"FAIL end of trace: no key import committed"

t="$TMP_ROOT/order.jsonl"
printf '%s\n' "$imp" "$kx" >"$t"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
check "make okp-policy-check: the import before the key exchange fails" nonzero \
	"no successful key exchange before the import"

for flag in strict monotonic; do
	t="$TMP_ROOT/import-$flag.jsonl"
	printf '%s\n' "$kx" "{\"step\":\"key_import\",\"wrapped\":true,\"request_flags\":[\"$flag\"],\"ack_flags\":[\"$flag\"],\"warnings\":[],\"counter_split\":true}" >"$t"
	run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
	check "make okp-policy-check: an import acknowledged with $flag alone is not committed" nonzero \
		"FAIL 2 key_import: not committed"
done

t="$TMP_ROOT/fuse-twice.jsonl"
printf '%s\n' "$fuse" "$fuse" >"$t"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
check "make okp-policy-check: the counter fuses are configured once" nonzero "runs at most once"

for step in counter_fuse_config lifecycle_close; do
	t="$TMP_ROOT/$step-unapproved.jsonl"
	printf '%s\n' "{\"step\":\"$step\",\"from\":\"oem_open\",\"to\":\"oem_closed\",\"via\":\"enclave\"}" >"$t"
	run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
	check "make okp-policy-check: $step without the owner's approval fails" nonzero "no owner_approval recorded"
done

t="$TMP_ROOT/close-via.jsonl"
printf '%s\n' '{"step":"lifecycle_close","status":"ok","from":"oem_open","to":"oem_closed","via":"fuse_tool","owner_approval":"OD-test"}' >"$t"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$t"
check "make okp-policy-check: a close not through the enclave fails" nonzero "want 'enclave'"

run make -s -C "$ROOT" okp-policy-check
check "make okp-policy-check: no OKP_TRACE names the variable" nonzero "set OKP_TRACE="

# A trace path with a quote, a space and ;touch is one argument, never shell
# source: no command runs, and the checker reports the path it cannot read.
inj="$TMP_ROOT/pwn"
evil="$TMP_ROOT/a\"b c;touch $inj;x.jsonl"
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="$evil"
check "make okp-policy-check: a trace path with a quote, a space and ;touch is one argument" 2 "okp-policy-check:"
run test ! -e "$inj"
check "make okp-policy-check: the ;touch in the path ran no command" 0
run make -s -C "$ROOT" okp-policy-check OKP_TRACE="\$\$(touch $inj)"
check "make okp-policy-check: a \$(...) in the path ran no command" 2 "okp-policy-check:"
run test ! -e "$inj"
check "make okp-policy-check: the \$(touch) in the path ran no command" 0

finish
