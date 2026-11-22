#!/usr/bin/env bash
# The template's helper scripts (ci-template v1.54, #159), run by the
# template's own tests, copied unchanged to test/testdata/. The tests find the
# scripts and ci.yml beside their own testdata/ directory, so they run on a
# copy laid out that way.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lay="$TMP_ROOT/ci-helpers"
mkdir -p "$lay/testdata"
cp "$ROOT/.github/workflows/ci.yml" "$lay/ci.yml"
cp "$ROOT/scripts/ci-mask-lan.sh" "$ROOT/scripts/ci-image-history.sh" \
  "$ROOT/scripts/ci-image-cache.sh" "$lay/"
cp "$ROOT/test/testdata/ci-mask-lan-tests.py" \
  "$ROOT/test/testdata/ci-image-history-tests.py" "$lay/testdata/"

run python3 -I "$lay/testdata/ci-mask-lan-tests.py"
check "ci-mask-lan: the template's tests pass" 0
# The ci-image-history wiring cases parse ci.yml with PyYAML, which the
# toolchain image does not carry; without it they are skipped, named here.
if python3 -I -c 'import yaml' 2>/dev/null; then
  run python3 -I "$lay/testdata/ci-image-history-tests.py"
  check "ci-image-history: the template's tests pass" 0
else
  echo "SKIP ci-image-history: PyYAML is not installed"
fi

finish
