#!/usr/bin/env bash
# test/pins_check_test.sh: scripts/pins-check.sh passes on the real pin files
# and fails, naming the variable and the rule, on scratch copies that each
# break one rule. Offline; temp files only.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK=$ROOT/scripts/pins-check.sh
PINS=$ROOT/scripts/tool-pins.sh
REQS=$ROOT/scripts/ahab/requirements.txt
PINS_TEXT=$(<"$PINS")
REQS_TEXT=$(<"$REQS")
N=0

# bad_pins <name> <from> <to> <substring...>: a copy of the pin file with the
# first <from> replaced by <to> must fail, naming each substring.
bad_pins() {
	local name=$1 from=$2 to=$3 f
	shift 3
	N=$((N + 1))
	f=$TMP_ROOT/pins.$N
	[[ "$PINS_TEXT" == *"$from"* ]] || { fail "$name" "fixture text '$from' not in the pin file"; return; }
	printf '%s\n' "${PINS_TEXT/"$from"/"$to"}" >"$f"
	run bash "$CHECK" "$f" "$REQS"
	check "$name" 1 "$@"
}

# bad_reqs <name> <from> <to> <substring...>: the same for requirements.txt.
bad_reqs() {
	local name=$1 from=$2 to=$3 f
	shift 3
	N=$((N + 1))
	f=$TMP_ROOT/reqs.$N
	[[ "$REQS_TEXT" == *"$from"* ]] || { fail "$name" "fixture text '$from' not in requirements.txt"; return; }
	printf '%s\n' "${REQS_TEXT/"$from"/"$to"}" >"$f"
	run bash "$CHECK" "$PINS" "$f"
	check "$name" 1 "$@"
}

run bash "$CHECK"
check "real files pass" 0 "pins-check: OK (4 tools,"
run bash "$CHECK" "$PINS" "$REQS"
check "explicit real files pass" 0 "requirements)"

bad_pins "URL on the old version" "download/v0.76.2/" "download/v0.76.1/" "TRIVY_URL" "rule b"
bad_pins "URL repo mismatch" "TRIVY_REPO=aquasecurity/trivy" "TRIVY_REPO=other/trivy" "TRIVY_URL" "rule b"
bad_pins "63-hex SHA256" "TRIVY_SHA256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdb" \
	"TRIVY_SHA256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fd" "TRIVY_SHA256" "rule c"
bad_pins "uppercase hex SHA256" "SHELLCHECK_SHA256=b7af" "SHELLCHECK_SHA256=B7AF" "SHELLCHECK_SHA256" "rule c"
bad_pins "uv SHA256 short" "SW_UV_SHA256=d7f4" "SW_UV_SHA256=d7" "SW_UV_SHA256" "rule c"
bad_pins "digest without sha256:" "ALPINE_DIGEST=sha256:" "ALPINE_DIGEST=" "ALPINE_DIGEST" "rule d"
bad_pins "python digest short" "SW_PYTHON_DIGEST=sha256:a5a7" "SW_PYTHON_DIGEST=sha256:" "SW_PYTHON_DIGEST" "rule d"
bad_pins "bad snapshot" "SW_DEBIAN_SNAPSHOT=20261122T000000Z" "SW_DEBIAN_SNAPSHOT=2026-11-22" "SW_DEBIAN_SNAPSHOT" "rule e"
bad_pins "PINNED_TOOLS name with no URL" "PINNED_TOOLS=SHELLCHECK,ACTIONLINT,GITLEAKS,TRIVY" \
	"PINNED_TOOLS=SHELLCHECK,ACTIONLINT,GITLEAKS,TRIVY,NOSUCH" "NOSUCH_URL" "rule a"
bad_pins "tool with a URL missing from PINNED_TOOLS" "PINNED_TOOLS=SHELLCHECK,ACTIONLINT,GITLEAKS,TRIVY" \
	"PINNED_TOOLS=SHELLCHECK,ACTIONLINT,GITLEAKS" "TRIVY_URL" "rule f"
bad_pins "tool without HOLD" "TRIVY_HOLD=" "TRIVY_X=" "TRIVY_HOLD" "rule a"

first_hash=--hash=sha256:48b70ecd719054fcb0d7e6f25a1fecc13607aac61d446e83f47d211b4ead0d61
bad_reqs "requirement without --hash" "argparse-addons==0.12.0 \\
    $first_hash" "argparse-addons==0.12.0" "argparse-addons" "--hash"
bad_reqs "requirement with >=" "asn1crypto==1.5.1" "asn1crypto>=1.5.1" "asn1crypto" "name==version"
bad_reqs "requirement with a short hash" "${first_hash}" "${first_hash%?}" "argparse-addons"
bad_reqs "duplicate requirement" "asn1crypto==1.5.1" "argparse-addons==0.12.0 \\
    $first_hash
asn1crypto==1.5.1" "duplicate requirement 'argparse-addons'"

finish
