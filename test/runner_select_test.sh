#!/usr/bin/env bash
# ci.yml's preflight step `Balanced runner pool (ruling 1137)` (ci-template
# v1.54, #159), run by the template's own tests, copied unchanged to
# test/testdata/runner-select-tests.py. That script reads ci.yml from the
# parent of its own directory, so it runs here on a copy laid out that way.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lay="$TMP_ROOT/runner-select"
mkdir -p "$lay/testdata"
cp "$ROOT/.github/workflows/ci.yml" "$lay/ci.yml"
cp "$ROOT/test/testdata/runner-select-tests.py" "$lay/testdata/"

run python3 -I "$lay/testdata/runner-select-tests.py"
check "runner-select: the balanced runner pool step passes the template's tests" 0

finish
