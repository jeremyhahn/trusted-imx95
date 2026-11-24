#!/usr/bin/env bash
# test/pins_drift_check_test.sh: scripts/pins-drift-check.sh passes on the real
# tree and, on scratch trees, fails naming file, line and the pin when a doc or
# script restates a python or alpine version that moved. Offline; temp files.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK=$ROOT/scripts/pins-drift-check.sh
PINS=$ROOT/scripts/tool-pins.sh

run bash "$CHECK"
check "real tree passes" 0 "pins-drift-check: OK"

# tree <name>: a scratch root with docs/, scripts/ and test/ directories.
N=0
tree() {
	N=$((N + 1))
	T=$TMP_ROOT/tree.$N
	mkdir -p "$T/docs/a" "$T/scripts" "$T/test"
}

tree
printf 'intro\nbase python:3.13-slim-bookworm and alpine:3.24 and alpine:3.24.4\n' >"$T/docs/a/ok.md"
run bash "$CHECK" "$PINS" "$T"
check "agreeing restatements pass" 0 "OK (3 restated pins in 1 files)"

tree
printf 'intro\nbase image\nuse python:3.12-slim-bookworm here\n' >"$T/docs/a/stale.md"
run bash "$CHECK" "$PINS" "$T"
check "stale python in a doc" 1 "docs/a/stale.md:3" "SW_PYTHON_VERSION is 3.13" "python:3.12-slim"

tree
printf '#!/bin/sh\nFROM=alpine:3.20\n' >"$T/scripts/x.sh"
run bash "$CHECK" "$PINS" "$T"
check "stale alpine in a script" 1 "scripts/x.sh:2" "ALPINE_VERSION is 3.24.4" "alpine:3.20"

tree
printf 'a alpine:3.19 b alpine:3.24 c python:3.11-slim\n' >"$T/test/y_test.sh"
run bash "$CHECK" "$PINS" "$T"
check "two stale pins on one line" 1 "test/y_test.sh:1" "alpine:3.19" "python:3.11-slim" "2 stale"

tree
for f in scripts/tool-pins.sh test/pins_check_test.sh test/ci_scripts_test.sh test/integration/make_targets_test.sh; do
	mkdir -p "$T/${f%/*}"
	printf 'python:3.9-slim alpine:3.0.0\n' >"$T/$f"
done
run bash "$CHECK" "$PINS" "$T"
check "excluded files are not flagged" 0 "OK (0 restated pins in 0 files)"

run bash "$CHECK" "$TMP_ROOT/none.sh"
check "missing pin file" 1 "no such file"
run bash "$CHECK" "$PINS" "$TMP_ROOT/nodir"
check "missing root" 1 "no such directory"

# A moved pin makes a formerly agreeing doc fail.
tree
printf 'python:3.13-slim-bookworm\n' >"$T/docs/a/ok.md"
printf '%s\n' "$(<"$PINS")" >"$TMP_ROOT/pins.moved"
printf 'SW_PYTHON_VERSION=3.14\n' >>"$TMP_ROOT/pins.moved"
run bash "$CHECK" "$TMP_ROOT/pins.moved" "$T"
check "a moved SW_PYTHON_VERSION flags the doc" 1 "docs/a/ok.md:1" "SW_PYTHON_VERSION is 3.14"

finish
