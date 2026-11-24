#!/usr/bin/env bash
# The oem-key-provisioning row's text and its detail agree: docs/SPEC.md keeps
# every requirement the row states, and docs/oem-key-provisioning/
# architecture.md names the policy check and its integration target, marks the
# fuse write and the life-cycle close irreversible and owner-approved, and
# keeps both open questions.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEC="$ROOT/docs/SPEC.md"
ARCH="$ROOT/docs/oem-key-provisioning/architecture.md"

row=""
while IFS= read -r line; do
	[[ "$line" == "| oem-key-provisioning |"* ]] && row=$line
done <"$SPEC"
expect "SPEC.md has the oem-key-provisioning row" test -n "$row"

for want in \
	"key exchange, then the import of the wrapped key" \
	"(AN14861 §2, §5.2, §5.3; RM00284 §3.20, §3.2.6.3)" \
	"from OEM open to OEM closed through the enclave (RM00284 §3.23)" \
	"monotonic counter fuses are configured once (RM00284 §3.24)" \
	"IMX95RM and the i.MX 95 Security Reference Manual, both missing" \
	"When the life cycle is closed, and where provisioning runs, are open questions for the owner" \
	"(oem-key-provisioning/architecture.md)"; do
	expect "SPEC row states: $want" test "${row/"$want"/}" != "$row"
done

arch=$(<"$ARCH")
arch=${arch//$'\n'/ } # the file wraps its lines; a phrase may span two
for want in \
	"scripts/okp-policy-check.py" "make integration-test-oem-key-provisioning" \
	"only after a \`key_exchange\` that succeeded earlier in the same run" \
	"acknowledged both the strict-operation flag and the monotonic-counter flag" \
	"each carry a recorded owner approval and run at most once" \
	"Irreversible. Needs the owner's explicit approval before it is run on any device." \
	"When the life cycle is closed: the owner's" "Where provisioning runs: the owner's"; do
	expect "architecture.md states: $want" test "${arch/"$want"/}" != "$arch"
done

finish
