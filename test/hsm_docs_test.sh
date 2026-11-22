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

finish
