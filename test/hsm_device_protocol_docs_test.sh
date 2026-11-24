#!/usr/bin/env bash
# Offline structure test for docs/hsm-device-protocol/on-device-transport-survey.md; checkers take the survey path and print one problem per line.
set -uo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SURVEY="$ROOT/docs/hsm-device-protocol/on-device-transport-survey.md"

# section_body <file> <awk-start-regex> <awk-stop-regex>: lines from the first
# heading matching start up to (not including) the next "## " heading that
# matches stop.
section_body() {
	awk -v start="$2" -v stop="$3" '
		/^## / { if (on && $0 ~ stop) on = 0; if ($0 ~ start) on = 1 }
		on { print }
	' "$1"
}

c_headings() {
	local f=$1 h
	for h in \
		"## Question" \
		"## 1. A55 Linux to the enclave" \
		"## 2. A55 Linux to the Cortex-M7" \
		"## 3. A55 normal world to OP-TEE" \
		"## 4. A local-socket front for a daemon" \
		"## 5. Properties that matter to a later network protocol" \
		"## What this survey does not decide" \
		"## Sources" \
		"## Questions for the owner"; do
		grep -qxF -- "$h" "$f" || echo "missing heading: $h"
	done
}

c_status() {
	local f=$1 first s
	first=$(awk 'NR > 1 && NF { print; exit }' "$f")
	[[ "$first" == '> **Status: SURVEY, PROVISIONAL'* ]] ||
		echo "line after the title is not the Status blockquote"
	for s in "ruling 195" "item 160" "go-xkms #1521"; do
		grep -qF -- "$s" "$f" || echo "missing text: $s"
	done
}

c_sources() {
	local f=$1 id row
	grep -qxF '| # | Title | Version surveyed | URL |' "$f" ||
		echo "missing Sources table header"
	while read -r id; do
		grep -q "^| $id |" "$f" || echo "cited $id has no Sources row"
	done < <(section_body "$f" '^## [1-5]\. ' '^## [^1-5]' |
		grep -oE '\bS[0-9]+\b' | sort -u)
	while read -r row; do
		awk -F'|' '{ c = $(NF - 1); gsub(/^ +| +$/, "", c);
			if (c !~ /^https:\/\//) exit 1 }' <<<"$row" ||
			echo "Sources row without https URL: ${row%% |*}"
	done < <(grep -E '^\| S[0-9]+ \|' "$f")
}

c_unconfirmed() {
	local f=$1
	grep -qF unconfirmed "$f" || echo "no unconfirmed mark in the file"
	grep -qE '^#+ Sources not reached' "$f" ||
		echo "missing 'Sources not reached' heading"
	section_body "$f" '^## 5\. ' '^## [^5]' | grep -qF unconfirmed ||
		echo "section 5 has no unconfirmed cell"
}

c_questions() {
	local f=$1 q d
	q=$(section_body "$f" '^## Questions for the owner' '^## [^Q]' |
		grep -cE '^[0-9]+\. \*\*')
	d=$(section_body "$f" '^## Questions for the owner' '^## [^Q]' |
		grep -E '^[0-9]+\. \*\*' | grep -ciF 'Provisional default')
	[ "$q" -gt 0 ] || echo "no numbered questions"
	[ "$q" -eq "$d" ] || echo "questions $q, provisional defaults $d"
}

c_words() {
	local f=$1 n
	grep -niwE 'shall|must' "$f" | sed 's/^/requirement word, line /' |
		cut -c1-60
	grep -nE 'Closes|Fixes' "$f" | cut -c1-60 | sed 's/^/closing word, line /'
	n=$(awk '/^>/ { if (!q) n++; q = 1; next } { q = 0 } END { print n + 0 }' "$f")
	[ "$n" -eq 1 ] || echo "blockquote runs: $n, want 1"
	grep -nE '(^|[^0-9.])(10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)' "$f" |
		cut -c1-60 | sed 's/^/private IP, line /'
	grep -n '/home/' "$f" | cut -c1-60 | sed 's/^/home path, line /'
}

c_links() {
	local f=$1 dir t
	dir=$(dirname "$f")
	while read -r t; do
		[ -e "$dir/$t" ] || echo "broken link: $t"
	done < <(grep -oE '\]\([^)]+\)' "$f" | sed -e 's/^](//' -e 's/)$//' \
		-e 's/#.*//' | grep -E '^\.\./|\.md$' | grep -v '^https\?:' | sort -u)
}

CHECKERS=(c_headings c_status c_sources c_unconfirmed c_questions c_words c_links)

# run_all <file>: every checker; prints the problems, returns 1 if any.
run_all() {
	local c out rc=0
	for c in "${CHECKERS[@]}"; do
		out=$("$c" "$1")
		if [ -n "$out" ]; then
			echo "$c: $out"
			rc=1
		fi
	done
	return $rc
}

# checker_ok <checker>: pass when the checker prints no problem on the survey.
checker_ok() {
	local out
	out=$("$1" "$SURVEY")
	if [ -z "$out" ]; then pass "$1"; else fail "$1" "$out"; fi
}

# negative <name> <checker> <sed-expr>: the checker must report a problem on
# a copy of the survey edited by the sed expression.
negative() {
	local name=$1 c=$2 copy
	# A fresh temp copy per case, edited with POSIX sed only (no GNU "0,/re/"
	# address, no empty-regex reuse), so the result does not depend on the
	# sed flavour or on an earlier case.
	copy=$(mktemp "$TMP_ROOT/neg.XXXXXX") || { fail "negative: $name" "mktemp failed"; return; }
	LC_ALL=C sed -e "$3" "$SURVEY" >"$copy"
	if cmp -s "$SURVEY" "$copy"; then
		fail "negative: $name" "the edit changed nothing"
	elif [ -n "$("$c" "$copy")" ]; then
		pass "negative: $name"
	else
		fail "negative: $name" "$c did not detect it"
	fi
}

expect "survey exists" test -f "$SURVEY"

for c in "${CHECKERS[@]}"; do checker_ok "$c"; done

run run_all "$SURVEY"
check "run_all on the survey" 0

negative "status line dropped" c_status '/^> \*\*Status:/d'
# shellcheck disable=SC2016 # $a is a sed address, not a shell variable
negative "device shall do X" c_words '$a the device shall do X'
negative "Sources heading dropped" c_headings '/^## Sources$/d'
negative "provisional default dropped" c_questions \
	'/^1\. \*\*/s/\*Provisional default:\*//'
negative "cited source row removed" c_sources '/^| S3 |/d'

finish
