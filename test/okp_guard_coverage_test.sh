#!/usr/bin/env bash
# Derives the life-cycle guard's coverage from the surveys (ruling 1234). Every
# backticked or fenced token in a survey that names a fuse, life-cycle, lock,
# commit, flash or enclave-library spelling must be either flagged by the guard's own
# scan (test/no_lifecycle_close_test.sh, PATTERNS and scan_file) or listed below as
# read-only or as not a command. A token in neither set fails and names the survey,
# line and token. Reads files only: a token is text fed to the scan, never run.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
OKP_DIR=${OKP_DOCS_DIR:-$ROOT/docs/oem-key-provisioning}
LC_DIR=${LC_DOCS_DIR:-$ROOT/docs/device-lifecycle}
GUARD=$ROOT/test/no_lifecycle_close_test.sh

# Tokens that are read-only or have no life-cycle or fuse effect. glob|reason|survey.
# The glob is matched against the whole token, case-sensitively.
SAFE=(
	'get-info|read-only enclave report|fuse-map-survey.md'
	'nxpele get-info|read-only enclave report|fuse-map-survey.md'
	'nxpele get-events|read-only enclave event log|key-ceremony-survey.md'
	'nxpele --help|usage text only|key-ceremony-survey.md'
	'nxpele read-common-fuse|read-only fuse read|key-ceremony-survey.md'
	'read-common-fuse|read-only fuse read|key-ceremony-survey.md'
	'read-shadow-fuse|read-only shadow-fuse read|key-ceremony-survey.md'
	'nxpele export-nxp-prod-ka-puk|exports a public key|key-ceremony-survey.md'
	'nxpele export-nxp-prod-ka-puk --help|usage text only|public-flow-survey.md'
	'el2go get-families -c provision-device|lists device families, no write|public-flow-survey.md'
	'ahab_status|read-only U-Boot status command|fuse-map-survey.md'
	'fuse read|read-only U-Boot fuse read|fuse-map-survey.md'
	'fuse sense|read-only U-Boot fuse read|fuse-map-survey.md'
	'display_life_cycle|read-only U-Boot life-cycle display|fuse-map-survey.md'
	'hsm_import_key|key-store import, no fuse or life-cycle effect|provisioning-failure-survey.md'
	'hsm_get_key_attr|read-only key attribute query|provisioning-failure-survey.md'
	'hsm_dev_getinfo|read-only device information query|provisioning-records-survey.md'
	'hsm_key_lifecycle_t|a key attribute type, not the device life cycle|provisioning-failure-survey.md'
)

# Tokens skipped as not a command. glob|reason, matched like SAFE.
IGNORE=(
	'*/*|a file or source path'
	'*.[ch]|a source or header file name'
	'*.rst|a document file name'
	'*.json|a data file name'
	'*.py|a source file name'
	'[A-Z]*[A-Z0-9_*]|an upper-case constant, fuse-field or environment name'
	'LOCK_CFG[a-z]|a lock-configuration fuse field name with a placeholder'
	'fuse[0-9N]*|a fuse word name'
	'fuse_version|a fuse field name'
	'ele_api_mapping_table|a data table name'
	'uuu_[0-9]*|a release file name'
	'device-lifecycle|this repository feature name'
	'hsm-device-lifecycle|this repository feature name'
	'nxpele|a bare tool name with no subcommand'
	'blhost|a bare tool name with no subcommand'
	'sdphost|a bare tool name with no subcommand'
	'el2go|a bare tool name with no subcommand'
	'ahab_\*|a family glob; each member is checked where it is named'
)

KW='fuse|lifecycle|life-cycle|life_cycle|lc_|close|lock|commit|forward|signed-message|flash|erase|efuse'
PRE='^(nxpele|nxpfuses|blhost|sdphost|sdpshost|uuu|fastboot|el2go|ahab_|ele_|hsm_)'

# load_guard <text>: define PATTERNS, Q and scan_file from the guard's text up to its
# first test line. The guard's fixtures are not run.
load_guard() {
	eval "$1"
}
guard_head() {
	local l out=""
	while IFS= read -r l || [ -n "$l" ]; do
		[ "$l" = "fails=0" ] && break
		out+="$l"$'\n'
	done <"$GUARD"
	printf '%s' "$out"
}

# tokens <file>: print "<line>\t<token>" for each candidate token.
tokens() {
	local f=$1 n=0 fence=0 line rest t
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		if [[ $line =~ ^[[:space:]]*\`\`\` ]]; then
			fence=$((1 - fence))
			continue
		fi
		local toks=()
		if ((fence)); then
			toks+=("$line")
		else
			rest=$line
			while [[ $rest =~ \`([^\`]+)\` ]]; do
				toks+=("${BASH_REMATCH[1]}")
				rest=${rest#*"${BASH_REMATCH[0]}"}
			done
		fi
		for t in "${toks[@]}"; do
			t=${t#"${t%%[![:space:]]*}"}
			t=${t%"${t##*[![:space:]]}"}
			[ -n "$t" ] || continue
			# A comment line in a fenced block is not a command.
			[[ $t == \#* ]] && continue
			if [[ ${t,,} =~ $KW || ${t,,} =~ $PRE ]]; then
				printf '%s\t%s\n' "$n" "$t"
			fi
		done
	done <"$f"
}

# in_table <token> <table name>: rc 0 when a row's glob matches the whole token.
in_table() {
	local t=$1 row glob
	local -n tbl=$2
	for row in "${tbl[@]}"; do
		glob=${row%%|*}
		# shellcheck disable=SC2053
		if [[ $t == $glob ]]; then return 0; fi
	done
	return 1
}

# flagged <token>: rc 0 when the guard's scan flags the token as a command, alone or
# as a subcommand of nxpele (a bare subcommand word such as commit).
flagged() {
	local t=$1 re tmp
	re=$(
		IFS='|'
		echo "${PATTERNS[*]}"
	)
	tmp=$SCRATCH/token.sh
	printf '%s\n' "$t" >"$tmp"
	if scan_file "$tmp" token.sh "$re" >/dev/null; then :; else return 0; fi
	printf '%s\n' "nxpele -p x $t" >"$tmp"
	if scan_file "$tmp" token.sh "$re" >/dev/null; then return 1; else return 0; fi
}

# check <okp dir> <lifecycle dir>: report each uncovered token, rc 1 if any.
check() {
	local okp=$1 lc=$2 f n t rc=0
	for f in "$okp"/*-survey.md "$lc"/decommission-survey.md; do
		[ -f "$f" ] || continue
		while IFS=$'\t' read -r n t; do
			if flagged "$t"; then continue; fi
			if in_table "$t" SAFE; then continue; fi
			if in_table "$t" IGNORE; then continue; fi
			echo "${f##*/}:$n: $t"
			rc=1
		done < <(tokens "$f")
	done
	return $rc
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
GUARD_TEXT=$(guard_head)
load_guard "$GUARD_TEXT"

# Every table row has a reason and, for SAFE, a survey file that exists.
rows_ok=1
for row in "${SAFE[@]}"; do
	IFS='|' read -r _ r s <<<"$row"
	if [ -z "$r" ] || { [ ! -f "$OKP_DIR/$s" ] && [ ! -f "$LC_DIR/$s" ]; }; then
		rows_ok=0
		echo "bad SAFE row: $row"
	fi
done
for row in "${IGNORE[@]}"; do
	[ -n "${row#*|}" ] || {
		rows_ok=0
		echo "bad IGNORE row: $row"
	}
done
if [ "$rows_ok" -eq 1 ]; then pass "every read-only and ignore row has a reason and an existing survey"
else fail "a SAFE or IGNORE row lacks a reason or names a missing survey"; fi

if OUT=$(check "$OKP_DIR" "$LC_DIR"); then
	pass "every survey token is flagged by the guard, read-only or not a command"
else
	fail "survey tokens the guard neither flags nor lists" "$OUT"
fi

# Scratch copies of the surveys.
copy_docs() {
	mkdir -p "$1/okp" "$1/lc"
	cp "$OKP_DIR"/*-survey.md "$1/okp/"
	cp "$LC_DIR/decommission-survey.md" "$1/lc/"
}

# A made-up life-cycle verb named in backticks fails and is named.
S1=$SCRATCH/f1
copy_docs "$S1"
printf '%s\n' "The station runs \`hsm_lc_poke\` to move on." >>"$S1/okp/key-ceremony-survey.md"
if OUT=$(check "$S1/okp" "$S1/lc"); then
	fail "a made-up life-cycle verb in a survey was not caught"
elif [[ $OUT == *"key-ceremony-survey.md:"*": hsm_lc_poke"* ]]; then
	pass "a made-up life-cycle verb fails and names survey, line and token"
else
	fail "a made-up verb failed without naming survey, line and token" "$OUT"
fi

# A new read-only spelling that is not in the table fails too.
S2=$SCRATCH/f2
copy_docs "$S2"
printf '%s\n' "Read it with \`nxpele read-quux-fuse\`." >>"$S2/lc/decommission-survey.md"
if OUT=$(check "$S2/okp" "$S2/lc"); then
	fail "a new read-only spelling outside the table was not caught"
elif [[ $OUT == *"decommission-survey.md:"*": nxpele read-quux-fuse"* ]]; then
	pass "a new read-only spelling outside the table fails and is named"
else
	fail "a new spelling failed without naming survey, line and token" "$OUT"
fi

# A fenced line is a token as well.
S3=$SCRATCH/f3
copy_docs "$S3"
printf '%s\n' '```' 'nxpele -p x quux-fuse-all' '```' >>"$S3/okp/provisioning-host-survey.md"
if OUT=$(check "$S3/okp" "$S3/lc"); then
	fail "a fenced command outside the table was not caught"
else
	pass "a fenced command outside the table fails"
fi

# The guard without its hsm_lc_update patterns misses the survey line that names it.
MUT=
while IFS= read -r l; do
	case "$l" in
	*"hsm[-_ ]?lc"* | *"lc[-_ ]?update"*) continue ;;
	esac
	MUT+="$l"$'\n'
done <<<"$GUARD_TEXT"
if OUT=$(
	load_guard "$MUT"
	check "$OKP_DIR" "$LC_DIR"
); then
	fail "dropping the hsm_lc_update patterns did not fail the check"
elif [[ $OUT == *"decommission-survey.md:"*"hsm_lc_update"* || $OUT == *"survey.md:"*"hsm_lc_update"* ]]; then
	pass "a guard without the hsm_lc_update patterns fails on the survey line naming it"
else
	fail "the mutated guard failed without naming hsm_lc_update" "$OUT"
fi

finish
