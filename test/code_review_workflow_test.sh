#!/usr/bin/env bash
# Runs the handbook template's code-review regression suites (test/testdata,
# copied unchanged from handbook commit 824e4979) against this repository's
# .github/workflows/code-review.yml. Each suite reads the gate, twin-exit,
# approval and lock-wait code out of the workflow and runs it under bash and jq
# against a fake forge; nothing reaches the network. Needs python3, jq, curl.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wf=${CODE_REVIEW_TEST_YML:-$root/.github/workflows/code-review.yml}
fail=0
n=0
for suite in "$root"/test/testdata/code-review-*-tests.py; do
	n=$((n + 1))
	echo "== $(basename "$suite")"
	if ! python3 -I "$suite" "$wf"; then
		echo "FAIL: $(basename "$suite")"
		fail=1
	fi
done
[ "$n" -gt 0 ] || { echo "FAIL: no code-review suites found"; exit 1; }
[ "$fail" -eq 0 ] && echo "code_review_workflow_test: PASS ($n suites)"
exit "$fail"
