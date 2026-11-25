#!/usr/bin/env bash
# test/pins_report_test.sh: scripts/pins-report.sh prints the pin inventory
# from files in the tree, follows scratch copies, and exits 1 on a missing
# file. Offline; temp files only.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT=$ROOT/scripts/pins-report.sh
PINS=$ROOT/scripts/tool-pins.sh
REQS=$ROOT/scripts/ahab/requirements.txt
BUILD=$ROOT/scripts/ahab/build-requirements.txt
WFDIR=$ROOT/.github/workflows
PINS_TEXT=$(<"$PINS")

run bash "$REPORT"
check "real files" 0 SHELLCHECK ACTIONLINT GITLEAKS TRIVY "sha256:f59abe656b69" "actions/checkout@" "requirements" "Debian snapshot"
run bash "$REPORT" "$PINS" "$REQS" "$BUILD" "$WFDIR"
check "explicit real files" 0 "== workflow actions" "signatures.yml:"

# The release tag comes from the URL, the version from the pin.
p=$TMP_ROOT/pins.new
text=${PINS_TEXT//0.76.2/0.77.0}
printf '%s\n' "$text" >"$p"
run bash "$REPORT" "$p" "$REQS" "$BUILD" "$WFDIR"
check "changed TRIVY pin shows the new version and tag" 0 "0.77.0" "v0.77.0"

# A HOLD reason is printed.
p=$TMP_ROOT/pins.hold
printf '%s\n' "${PINS_TEXT/TRIVY_HOLD=/TRIVY_HOLD=\'waiting for the db schema\'}" >"$p"
run bash "$REPORT" "$p" "$REQS" "$BUILD" "$WFDIR"
check "HOLD reason is printed" 0 "waiting for the db schema"

# An action in a scratch workflows directory: first 12 hex and the tag.
d=$TMP_ROOT/wf
mkdir -p "$d"
printf 'jobs:\n  j:\n    steps:\n      - uses: acme/tool@0123456789abcdef0123456789abcdef01234567 # v9.9.9\n      - uses: ./local\n' >"$d/x.yml"
run bash "$REPORT" "$PINS" "$REQS" "$BUILD" "$d"
check "workflow action line" 0 "acme/tool@0123456789ab # v9.9.9"
if [[ "$OUT" == *"./local"* ]]; then fail "local action is not listed"; else pass "local action is not listed"; fi

# Missing files exit 1.
run bash "$REPORT" "$TMP_ROOT/none.sh"
check "missing pin file" 1 "no such file"
run bash "$REPORT" "$PINS" "$TMP_ROOT/none.txt"
check "missing requirements file" 1 "no such file"
run bash "$REPORT" "$PINS" "$REQS" "$BUILD" "$TMP_ROOT/nodir"
check "missing workflows directory" 1 "no such directory"

finish
