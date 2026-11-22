#!/usr/bin/env bash
# Offline structure test for docs/hsm-self-defence/a55-signals-survey.md (issue #26).
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOC_REL=docs/hsm-self-defence/a55-signals-survey.md
TAMPER_REL=docs/hsm-self-defence/tamper-survey.md

# Each checker takes the survey path and prints problems, one per line.
c_headings() {
	local h
	for h in "## Scope" "## Sources" "## Findings" "## What is still missing" \
		"## Questions for the owner" \
		"## Proposed SPEC changes (proposed, pending owner approval)"; do
		# Scope is a paragraph in the file; accept it as a heading or a line start.
		if [ "$h" = "## Scope" ]; then
			grep -q '^\(## \)\?Scope' "$1" || echo "missing Scope"
		else
			grep -qxF "$h" "$1" || echo "missing heading $h"
		fi
	done
}

c_sources() {
	grep -q '^| Id | Source | Version surveyed | URL | Reached |$' "$1" || echo "no Reached column"
	local bad
	bad=$(grep -E '^\| S[0-9]+ \|' "$1" | grep -viE '\| *(\*\*)?(yes|no)\b[^|]*(\*\*)?[^|]*\|$' || true)
	[ -z "$bad" ] || echo "source rows not ending in yes or no: $bad"
}

c_status() {
	awk '/^### F[0-9]+\./ { if (open) print "no Status in " h; open=1; h=$0; next }
	     /^## / { if (open) print "no Status in " h; open=0; next }
	     /^Status:/ { open=0 }
	     END { if (open) print "no Status in " h }' "$1"
}

c_ids() {
	local id fb
	fb=$(awk '/^## Findings/{f=1;next} /^## /{f=0} f' "$1" | grep -o '\bS[0-9]\+\b' | sort -u)
	for id in $fb; do
		grep -qE "^\| $id \|" "$1" || echo "source $id not in table"
	done
}

c_words() {
	grep -qi 'provisional' "$1" || echo "no provisional"
	grep -q '^>' "$1" && echo "quoted block"
	grep -qi 'closes' "$1" && echo "claims Closes"
	local q r
	q=$(grep -cE '^[0-9]+\. \*\*' "$1")
	r=$(grep -c '^   Recommendation:' "$1")
	[ "$q" -gt 0 ] && [ "$q" = "$r" ] || echo "questions $q, recommendations $r"
}

run_all() {
	{ c_headings "$1"; c_sources "$1"; c_status "$1"; c_ids "$1"; c_words "$1"; } 2>&1
}

DOC="$ROOT/$DOC_REL"
if [ -f "$DOC" ]; then pass "survey exists"; else fail "survey exists"; finish; fi

OUT=$(run_all "$DOC")
if [ -z "$OUT" ]; then pass "survey structure"; else fail "survey structure: $OUT"; fi

if grep -q 'a55-signals-survey.md' "$ROOT/$TAMPER_REL"; then
	pass "tamper-survey links the A55 survey"
else
	fail "tamper-survey links the A55 survey"
fi

# Negative: drop the first Status line, the checker must fail.
TMPD=$(mktemp -d)
awk '/^Status: (confirmed|not confirmed)/ && !d { d=1; next } { print }' "$DOC" >"$TMPD/neg.md"
NEG=$(c_status "$TMPD/neg.md")
if [ -n "$NEG" ]; then pass "negative: missing Status detected"; else fail "negative: missing Status detected"; fi
rm -rf "$TMPD"

# ---- Block 2: docs/hsm-self-defence/a55-self-defence-design.md (issue #26) ----
DESIGN_REL=docs/hsm-self-defence/a55-self-defence-design.md
SURVEY_DIR=docs/hsm-self-defence

d_headings() {
	local h
	grep -q '^\(## \)\?Scope' "$1" || echo "missing Scope"
	for h in "## Principle: the A55 is a witness" "## Inputs the A55 can use" \
		"## What the A55 cannot do" "## What the SM and M7 carry" \
		"## Response ladder (provisional)" "## Provisional defaults" \
		"## Board validation list" "## Questions for the owner" \
		"## Proposed SPEC changes (proposed, pending owner approval)"; do
		grep -qxF "$h" "$1" || echo "missing heading $h"
	done
}

d_words() {
	grep -qi 'provisional' "$1" || echo "no provisional"
	grep -q '^>' "$1" && echo "quoted block"
	grep -qi 'closes' "$1" && echo "claims Closes"
	local q r
	q=$(grep -cE '^[0-9]+\. \*\*' "$1")
	r=$(grep -c '^   Recommendation:' "$1")
	[ "$q" -gt 0 ] && [ "$q" = "$r" ] || echo "questions $q, recommendations $r"
}

# Every finding id must carry a survey prefix and resolve to a heading there.
d_ids() {
	local pre n file all pref
	all=$(grep -oE '\bF[0-9]+\b' "$1" | wc -l)
	pref=$(grep -oE '\b(a55|tamper|fault-sca) F[0-9]+\b' "$1" | wc -l)
	[ "$all" = "$pref" ] || echo "finding ids without a survey prefix: $all ids, $pref prefixed"
	grep -oE '\b(a55|tamper|fault-sca) F[0-9]+\b' "$1" | sort -u | while read -r pre n; do
		case "$pre" in
		a55) file=a55-signals-survey.md ;;
		tamper) file=tamper-survey.md ;;
		*) file=fault-sca-survey.md ;;
		esac
		grep -q "^### $n\\." "$ROOT/$SURVEY_DIR/$file" || echo "$pre $n not a heading in $file"
	done
}

d_links() {
	local t dir
	dir=$(dirname "$1")
	grep -oE '\]\([^)]+\)' "$1" | sed 's/^](//; s/)$//; s/#.*//' | sort -u | while read -r t; do
		case "$t" in "" | http*) continue ;; esac
		[ -e "$dir/$t" ] || echo "broken link $t"
	done
}

d_private() {
	grep -qE '/home/|\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' "$1" && echo "host, IP or /home path"
}

d_all() {
	{ d_headings "$1"; d_words "$1"; d_ids "$1"; d_links "$1"; d_private "$1"; } 2>&1
}

DESIGN="$ROOT/$DESIGN_REL"
if [ -f "$DESIGN" ]; then pass "design note exists"; else fail "design note exists"; finish; fi

OUT=$(d_all "$DESIGN")
if [ -z "$OUT" ]; then pass "design note structure"; else fail "design note structure: $OUT"; fi

if grep -q 'a55-self-defence-design.md' "$ROOT/$DOC_REL"; then
	pass "A55 survey links the design note"
else
	fail "A55 survey links the design note"
fi

# Negative: drop the first Recommendation line on a temp copy, the checker must fail.
TMPD=$(mktemp -d)
awk '/^   Recommendation:/ && !d { d=1; next } { print }' "$DESIGN" >"$TMPD/neg.md"
NEG=$(d_words "$TMPD/neg.md")
if [ -n "$NEG" ]; then pass "negative: missing Recommendation detected"; else fail "negative: missing Recommendation detected"; fi
rm -rf "$TMPD"

finish
