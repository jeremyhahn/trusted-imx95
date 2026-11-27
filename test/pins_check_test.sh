#!/usr/bin/env bash
# test/pins_check_test.sh: scripts/pins-check.sh passes on the real pin files
# and fails, naming the variable and the rule, on scratch copies that each
# break one rule. Offline; temp files only.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK=${PINS_CHECK_SCRIPT:-$ROOT/scripts/pins-check.sh}
PINS=$ROOT/scripts/tool-pins.sh
REQS=$ROOT/scripts/ahab/requirements.txt
PINS_TEXT=$(<"$PINS")
REQS_TEXT=$(<"$REQS")
BUILD=$ROOT/scripts/ahab/build-requirements.txt
BUILD_TEXT=$(<"$BUILD")
WFDIR=$ROOT/.github/workflows
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
check "explicit real files pass" 0 "workflow actions)"
run bash "$CHECK" "$PINS" "$REQS" "$BUILD" "$WFDIR"
check "explicit real files and workflows pass" 0 "workflow actions)"

# bad_build <name> <from> <to> <substring...>: a copy of build-requirements.txt.
bad_build() {
	local name=$1 from=$2 to=$3 f
	shift 3
	N=$((N + 1))
	f=$TMP_ROOT/build.$N
	[[ "$BUILD_TEXT" == *"$from"* ]] || { fail "$name" "fixture text '$from' not in build-requirements.txt"; return; }
	printf '%s\n' "${BUILD_TEXT/"$from"/"$to"}" >"$f"
	run bash "$CHECK" "$PINS" "$REQS" "$f"
	check "$name" 1 "$@"
}

# bad_wf <name> <workflow> <from> <to> <substring...>: a scratch copy of the
# workflows directory with <from> replaced by <to> in one file.
bad_wf() {
	local name=$1 wf=$2 from=$3 to=$4 d text
	shift 4
	N=$((N + 1))
	d=$TMP_ROOT/wf.$N
	mkdir -p "$d"
	cp "$WFDIR"/*.yml "$d"/
	text=$(<"$d/$wf")
	[[ "$text" == *"$from"* ]] || { fail "$name" "fixture text '$from' not in $wf"; return; }
	printf '%s\n' "${text/"$from"/"$to"}" >"$d/$wf"
	run bash "$CHECK" "$PINS" "$REQS" "$BUILD" "$d"
	check "$name" 1 "$@"
}

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

pk_hash=--hash=sha256:81383611a09c1bc0b08b76e0fd5829d7c6824c65b27a6aee339da133f4233ea2
bad_build "build requirement without --hash" "packaging==26.4 \\
    $pk_hash" "packaging==26.4" "build." "line 6" "rule g" "packaging"
bad_build "duplicate build requirement" "setuptools-scm==9.2.2" "packaging==26.4 \\
    $pk_hash
setuptools-scm==9.2.2" "duplicate requirement 'packaging'" "rule g"
bad_build "shared pin with another version" "packaging==26.4" "packaging==26.2" \
	"rule h" "packaging" "26.2"
bad_build "shared pin with another hash set" "$pk_hash" "${pk_hash%?}0" "rule h" "packaging" "hash set"

# The checkout pin is read from the workflow, so a bump does not break these fixtures.
sha="" tag=""
if [[ $(<"$WFDIR/signatures.yml") =~ actions/checkout@([0-9a-f]{40})\ \#\ (v[^[:space:]]+) ]]; then
	sha=${BASH_REMATCH[1]} tag=${BASH_REMATCH[2]}
fi
[[ -n "$sha" ]] || { echo "pins_check_test: signatures.yml has no 'actions/checkout@<sha> # <tag>' pin" >&2; exit 1; }
co=actions/checkout@$sha
bad_wf "action pinned to a tag" signatures.yml "$co # $tag" "actions/checkout@v6" "signatures.yml" "rule i" "40-hex"
bad_wf "action commit in uppercase hex" signatures.yml "$co" "actions/checkout@${sha^^}" "rule i"
bad_wf "action without a tag comment" signatures.yml "$co # $tag" "$co" "rule i" "no '# <tag>' comment"
bad_wf "two workflows, two checkout commits" releasability.yml "$co" \
	"actions/checkout@0000000000000000000000000000000000000001" "rule i" "actions/checkout" "is pinned to"

# doc_names <file>: the update procedure names every PINNED_TOOLS tool and the
# files and targets an update touches; each missing one is printed.
DOC=$ROOT/docs/maintenance/dependency-updates.md
doc_names() {
	local w text missing=0 tools
	[ -f "$1" ] || { echo "no such file: $1"; return 1; }
	text=$(<"$1")
	tools=$(bash -c '. "$1"; echo "$PINNED_TOOLS"' _ "$PINS")
	IFS=',' read -r -a want <<<"$tools,scripts/tool-pins.sh,scripts/ahab/requirements.txt,scripts/ahab/build-requirements.txt,make pins-check,make deps-check"
	for w in "${want[@]}"; do
		[[ "$text" == *"$w"* ]] || { echo "the procedure does not name $w"; missing=1; }
	done
	return "$missing"
}
run doc_names "$DOC"
check "update procedure names every tool, file and target" 0
if [ -f "$DOC" ]; then
	DOC_TEXT=$(<"$DOC")
	printf '%s\n' "${DOC_TEXT//TRIVY/}" >"$TMP_ROOT/doc.md"
	run doc_names "$TMP_ROOT/doc.md"
	check "procedure without TRIVY fails" 1 "does not name TRIVY"
fi

finish
