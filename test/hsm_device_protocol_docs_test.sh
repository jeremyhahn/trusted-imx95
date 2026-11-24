#!/usr/bin/env bash
# test/hsm_device_protocol_docs_test.sh: offline structure test for
# docs/hsm-device-protocol/on-device-transport-survey.md (issue #24).
# Host-side and provisional (ruling 195): it guards the shape and the honesty
# marks of the survey and says nothing about what the device shall do.
# Checkers take the survey path and print one problem per line.
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
	done < <(section_body "$f" '^## [1-5][.] ' '^## [^1-5]' |
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
	section_body "$f" '^## 5[.] ' '^## [^5]' | grep -qF unconfirmed ||
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

# The xkmsd-node design: no requirement words, one blockquote, no private
# address or home path, links resolve, and a design status line.
NODE="$ROOT/docs/hsm-device-protocol/xkmsd-node.md"
expect "xkmsd-node.md exists" test -f "$NODE"
for c in c_words c_links; do
	out=$("$c" "$NODE")
	if [ -z "$out" ]; then pass "$c on xkmsd-node.md"; else fail "$c on xkmsd-node.md" "$out"; fi
done
expect "xkmsd-node.md status names rulings 1243 and 1244" \
	grep -qE '^> \*\*Status: DESIGN, per owner rulings 1243 and 1244' "$NODE"

negative "status line dropped" c_status '/^> \*\*Status:/d'
# shellcheck disable=SC2016 # $a is a sed address, not a shell variable
negative "device shall do X" c_words '$a the device shall do X'
negative "Sources heading dropped" c_headings '/^## Sources$/d'
negative "provisional default dropped" c_questions \
	'/^1\. \*\*/s/\*Provisional default:\*//'
negative "cited source row removed" c_sources '/^| S3 |/d'

# The enclave interface trace: a record of facts read from NXP's driver and
# library sources. Same word and link checks, its own status line, and one
# citation or "unconfirmed" mark in each of its six question sections.
TRACE="$ROOT/docs/hsm-device-protocol/enclave-interface-trace.md"

c_trace_status() {
	local first
	first=$(awk 'NR > 1 && NF { print; exit }' "$1")
	[[ "$first" == '> **Status: TRACE'* ]] ||
		echo "line after the title is not the TRACE Status blockquote"
}

c_trace_sections() {
	local f=$1 q
	for q in a b c d e f; do
		section_body "$f" "^## [(]${q}[)] " '^## ' |
			grep -qE '[A-Za-z_.]+:[0-9]|unconfirmed' ||
			echo "section ($q) has neither a file:line citation nor an unconfirmed mark"
	done
}

expect "enclave-interface-trace.md exists" test -f "$TRACE"
for c in c_words c_links c_trace_status c_trace_sections; do
	out=$("$c" "$TRACE")
	if [ -z "$out" ]; then pass "$c on enclave-interface-trace.md"; else fail "$c on enclave-interface-trace.md" "$out"; fi
done

negative_trace() {
	local name=$1 c=$2 copy
	copy=$(mktemp "$TMP_ROOT/trace.XXXXXX") || { fail "negative: $name" "mktemp failed"; return; }
	LC_ALL=C sed -e "$3" "$TRACE" >"$copy"
	if cmp -s "$TRACE" "$copy"; then
		fail "negative: $name" "the edit changed nothing"
	elif [ -n "$("$c" "$copy")" ]; then
		pass "negative: $name"
	else
		fail "negative: $name" "$c did not detect it"
	fi
}

# Each Sources row of the trace carries a 40-hex commit and a URL; every
# "unconfirmed" mark is followed by a reason (3 or more words) on its line or the next.
c_trace_sources() {
	awk '
		/^## Sources/ { s = 1; next }
		/^## / { s = 0 }
		s && /^\| [0-9]+ \|/ {
			n++
			if ($0 !~ /[0-9a-f]{40}/) print "Sources row " $2 " has no 40-hex commit"
			if ($0 !~ /https:\/\/[^ |]+/) print "Sources row " $2 " has no URL"
		}
		END { if (n == 0) print "no Sources rows found" }
	' "$1"
}

c_trace_unconfirmed() {
	awk '
		{ line[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) {
				if (!match(tolower(line[i]), /unconfirmed/)) continue
				rest = substr(line[i], RSTART + RLENGTH)
				w = split(rest, a, /[^A-Za-z0-9]+/) - 1
				if (w < 3 && i < NR) { w += split(line[i + 1], b, /[^A-Za-z0-9]+/) - 1 }
				if (w < 3) print "line " i ": unconfirmed without a reason"
			}
		}
	' "$1"
}

for c in c_trace_sources c_trace_unconfirmed; do
	out=$("$c" "$TRACE")
	if [ -z "$out" ]; then pass "$c on enclave-interface-trace.md"; else fail "$c on enclave-interface-trace.md" "$out"; fi
done
negative_trace "trace source row without its commit" c_trace_sources '/^| 1 /s/[0-9a-f]\{40\}/none/'
negative_trace "trace status line dropped" c_trace_status '/^> \*\*Status:/d'
negative_trace "trace section (c) emptied" c_trace_sections '/^## [(]c[)] /,/^## [(]d[)] /{/^## /!d;}'

# The requirement table of xkmsd-node.md: header, R1..Rn in order, an exact Status
# vocabulary, and a ruling number in the Source cell of every decided row.
trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

c_reqs() {
	local f=$1 hdr line id status src n=0 re='ruling[s]? [0-9]+'
	hdr=$(awk '/^## 3[.] /{s=1;next} /^## /{s=0} s && /^[|] #/{print; exit}' "$f")
	[ "$hdr" = '| # | Requirement | Status | Source |' ] ||
		echo "the section 3 table header is not '| # | Requirement | Status | Source |'"
	while IFS= read -r line; do
		n=$((n + 1))
		IFS='|' read -r _ id _ status src _ <<<"$line"
		id=$(trim "$id")
		status=$(trim "$status")
		src=$(trim "$src")
		[ "$id" = "R$n" ] || echo "row $n is $id: a gap or a duplicate"
		case "$status" in
		decided)
			[[ "$src" =~ $re ]] || echo "$id is decided but its Source names no ruling number"
			;;
		'proposed, pending owner approval') ;;
		*) echo "$id has the Status '$status'" ;;
		esac
	done < <(awk '/^## 3[.] /{s=1;next} /^## /{s=0} s && /^[|] R[0-9]+ /{print}' "$f")
	[ "$n" -gt 0 ] || echo "no R rows found"
}

out=$(c_reqs "$NODE")
if [ -z "$out" ]; then pass "c_reqs on xkmsd-node.md"; else fail "c_reqs on xkmsd-node.md" "$out"; fi

negative_file() {
	local name=$1 c=$2 src=$3 copy
	copy=$(mktemp "$TMP_ROOT/neg2.XXXXXX") || { fail "negative: $name" "mktemp failed"; return; }
	LC_ALL=C sed -e "$4" "$src" >"$copy"
	if cmp -s "$src" "$copy"; then
		fail "negative: $name" "the edit changed nothing"
	elif [ -n "$("$c" "$copy")" ]; then
		pass "negative: $name"
	else
		fail "negative: $name" "$c did not detect it"
	fi
}
negative_file "R5 status changed to decided" c_reqs "$NODE" '/^| R5 /s/proposed, pending owner approval/decided/'
negative_file "R7 row deleted" c_reqs "$NODE" '/^| R7 /d'
negative_file "R1 source names no ruling" c_reqs "$NODE" '/^| R1 /s/rulings 1243, 1244/SPEC row platform-image/'

SEAM="$ROOT/docs/hsm-device-protocol/local-seam-trace.md"
expect "local-seam-trace.md exists" test -f "$SEAM"
for c in c_words c_links c_trace_status; do
	out=$("$c" "$SEAM")
	if [ -z "$out" ]; then pass "$c on local-seam-trace.md"; else fail "$c on local-seam-trace.md" "$out"; fi
done
negative_file "local-seam trace status line dropped" c_trace_status "$SEAM" '/^> \*\*Status:/d'

# The "Open vendor checks" section: one row (V1..V4) for each of the four cells
# the trace leaves unconfirmed (message length, reset handling, session flag,
# sequence-control file); each row has seven filled columns, a repository URL,
# a tag or a 40-hex commit, a requirement id and an action.
c_vendor_checks() {
	awk -F'|' '
		/^## Open vendor checks/ { in_s = 1; next }
		/^## / { in_s = 0 }
		in_s && /^\| V[0-9]+ / {
			n++
			id = $2; gsub(/ /, "", id); seen[id] = 1
			if (NF != 9) { print id ": want 7 columns"; next }
			for (i = 2; i <= 8; i++) { c = $i; gsub(/^ +| +$/, "", c); if (c == "") print id ": empty column " i - 1 }
			if ($5 !~ /https:\/\/github\.com\//) print id ": no repository URL"
			if ($6 !~ /lf-6\.18\.37-2\.1\.0|[0-9a-f]{40}/) print id ": no tag or commit"
			if ($4 !~ /R(3|4|11)/) print id ": no requirement id"
			if ($8 !~ /read at the tag|ask NXP/) print id ": no action"
		}
		END {
			if (n != 4) print "want 4 rows, have " n + 0
			for (k = 1; k <= 4; k++) if (!(("V" k) in seen)) print "row V" k " missing"
		}
	' "$1"
}
expect "vendor checks section present" grep -q '^## Open vendor checks' "$TRACE"
out=$(c_vendor_checks "$TRACE")
if [ -z "$out" ]; then pass "c_vendor_checks on enclave-interface-trace.md"; else fail "c_vendor_checks on enclave-interface-trace.md" "$out"; fi
negative_file "vendor check row without its action" c_vendor_checks "$TRACE" '/^| V2 /s/| read at the tag and cite file:line, or ask NXP |$/| |/'
negative_file "vendor check row deleted" c_vendor_checks "$TRACE" '/^| V4 /d'

finish
