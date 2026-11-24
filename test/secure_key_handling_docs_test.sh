#!/usr/bin/env bash
# The secure-key-handling row's text and its detail agree: docs/SPEC.md keeps
# every requirement the row states, and docs/secure-key-handling/
# architecture.md states the two-flag rule of owner decision 241 as a rule,
# not as a pending proposal, names the policy check, records owner ruling 1234
# (the Cortex-A55 Linux side calls the HSM API) and the open SE051 question.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEC="$ROOT/docs/SPEC.md"
ARCH="$ROOT/docs/secure-key-handling/architecture.md"

row=""
while IFS= read -r line; do
	[[ "$line" == "| secure-key-handling |"* ]] && row=$line
done <"$SPEC"
expect "SPEC.md has the secure-key-handling row" test -n "$row"

for want in \
	"never leave it in the clear" "(RM00284 §2.4, §3.2)" \
	"both the strict-operation flag and the monotonic-counter flag" \
	"acknowledged with only one of them is not rollback-protected" "owner decision 241" \
	"RM00284 §3.4, §3.8, §3.12" "Generic Crypto APIs are not available on the i.MX 95 (RM00284 §3.45)" \
	"The Cortex-A55 Linux side calls the HSM API (owner ruling 1234); the Cortex-M7 does not." \
	"SE051" "U28, on I2C2 at 0x48" "J4 control header" \
	"(secure-key-handling/architecture.md)"; do
	expect "SPEC row states: $want" test "${row/"$want"/}" != "$row"
done

arch=$(<"$ARCH")
arch=${arch//$'\n'/ } # the file wraps its lines; a phrase may span two
for want in \
	"acknowledges both the strict-operation flag and the monotonic-counter flag for that operation" \
	"only one of them is not rollback-protected (RM00284 §2.4.2; owner decision 241)" \
	"scripts/skh-policy-check.py" "make integration-test-secure-key-handling" \
	"1. Closed: the Cortex-A55 Linux side calls the HSM API (owner ruling 1234)." \
	"2. Does the SE051 hold any key, and what is its role beside the enclave?" \
	"(RM00284 §3.45)"; do
	expect "architecture.md states: $want" test "${arch/"$want"/}" != "$arch"
done
expect "architecture.md no longer proposes decision 241 as pending" \
	test "${arch/"Proposed SPEC change, pending owner approval"/}" == "$arch"

finish
