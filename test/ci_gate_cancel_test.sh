#!/usr/bin/env bash
# ci.yml's CI Gate job-level `if:` (v1.53, #159), evaluated from the real file
# by test/testdata/ci-gate-cancel-tests.py. The script reads ci.yml from the
# parent of its own directory, so it runs here on a copy laid out that way.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lay="$TMP_ROOT/ci-gate-cancel"
mkdir -p "$lay/testdata"
cp "$ROOT/.github/workflows/ci.yml" "$lay/ci.yml"
cp "$ROOT/test/testdata/ci-gate-cancel-tests.py" "$lay/testdata/"

run python3 -I "$lay/testdata/ci-gate-cancel-tests.py"
check "ci-gate: the job condition passes the cancellation cases" 0

finish
