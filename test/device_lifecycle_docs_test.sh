#!/usr/bin/env bash
# test/device_lifecycle_docs_test.sh: offline checks of docs/device-lifecycle/README.md,
# the feature folder index: headings, status line, links and anchors, and that the
# consolidated question rows match the questions in the four surveys and ftpm.
# Negatives run on copies under mktemp; nothing is written under the repo.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIR="$ROOT/docs/device-lifecycle"
README="$DIR/README.md"
SURVEYS="attestation-survey.md enrollment-survey.md decommission-survey.md evidence-binding-survey.md"
HEADINGS=(
	"## Purpose"
	"## Documents"
	"## How the pieces fit"
	"## Open questions for the owner, consolidated"
	"## What is blocked on what"
	"## Proposed SPEC changes (proposed, pending owner approval)"
)

# slug: a GitHub heading slug (lowercase, keep letters digits space - _, spaces to -).
slug() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

# anchor_exists FILE ANCHOR: some heading of FILE has that slug.
anchor_exists() {
	local line text
	while IFS= read -r line; do
		text=$(printf '%s' "$line" | sed -E 's/^#+ +//')
		[ "$(slug "$text")" = "$2" ] && return 0
	done < <(grep -E '^#+ ' "$1")
	return 1
}

# count_questions FILE HEADING_REGEX: numbered bold items in that section.
count_questions() {
	awk -v re="$2" '
		/^## / { on = ($0 ~ re) ; next }
		on && /^[0-9]+\. \*\*/ { n++ }
		END { print n + 0 }' "$1"
}

# check_readme FILE: prints the problems found, one per line; empty means clean.
# Relative links resolve against $DIR, where the README lives.
check_readme() {
	local f=$1 h link target anchor
	[ -f "$f" ] || { echo "missing README"; return; }
	for h in "${HEADINGS[@]}"; do
		grep -qxF "$h" "$f" || echo "missing heading: $h"
	done
	grep -qiE '^> \*\*Status:.*provisional' "$f" || echo "status line lacks provisional"
	grep -qi 'ruling 927' "$f" || echo "no ruling 927"
	grep -qF '#25' "$f" || echo "no #25"
	grep -E '^> \*\*Status:' "$f" | grep -qF '#177' || echo "status line lacks #177"
	if grep -qi 'closes' "$f"; then echo "contains closes"; fi
	while IFS= read -r link; do
		target=${link%%#*}
		anchor=""
		[ "$target" = "$link" ] || anchor=${link#*#}
		[ -n "$target" ] || continue
		if [ ! -f "$DIR/$target" ]; then
			echo "dead link: $link"
		elif [ -n "$anchor" ] && ! anchor_exists "$DIR/$target" "$anchor"; then
			echo "dead anchor: $link"
		fi
	done < <(grep -oE '\]\([^)#][^)]*\)' "$f" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^[a-z]+://' | sort -u)
	for t in $SURVEYS ../ftpm/README.md architecture.md evidence-bundle.md; do
		grep -qF "]($t" "$f" || echo "no link to $t"
	done
	local rows want=0 s
	rows=$(grep -cE '^\| [A-F][0-9]+ \|' "$f" || true)
	for s in $SURVEYS; do
		want=$((want + $(count_questions "$DIR/$s" '^## .*[Qq]uestions for the owner')))
	done
	want=$((want + $(count_questions "$DIR/../ftpm/README.md" '^## Open questions for the owner')))
	[ "$rows" -eq "$want" ] || echo "question rows $rows, sources $want"
	grep -E '^\| [A-F][0-9]+ \|' "$f" | grep -vqE '\]\([^)]*\.md#[^)]+\)' && echo "a row has no anchored source link"
	return 0
}

problems=$(check_readme "$README")
if [ -z "$problems" ]; then
	pass "README passes every check"
else
	fail "README checks" "$problems"
fi

# the slug function, positive and negative
if [ "$(slug '12. Questions for the owner')" = "12-questions-for-the-owner" ]; then pass "slug of a numbered heading"; else fail "slug of a numbered heading"; fi
if anchor_exists "$DIR/enrollment-survey.md" "12-questions-for-the-owner"; then pass "anchor found"; else fail "anchor found"; fi
if anchor_exists "$DIR/enrollment-survey.md" "no-such-heading"; then fail "absent anchor accepted"; else pass "absent anchor rejected"; fi

# negatives: each broken copy must be reported
neg() { # name sed-expression
	local tmp out
	tmp=$(mktemp "$TMP_ROOT/readme.XXXXXX")
	sed -E "$2" "$README" >"$tmp"
	out=$(check_readme "$tmp")
	if [ -n "$out" ]; then pass "negative: $1"; else fail "negative: $1 was not caught"; fi
}
neg "dropped heading" '/^## What is blocked on what$/d'
neg "dead relative link" 's|\(attestation-survey\.md\)|(no-such-file.md)|'
neg "dropped question row" '/^\| B3 \|/d'
neg "no architecture.md link" '/architecture\.md/d'
neg "status line without #177" '/^> \*\*Status:/s/#177//g'

# check_page FILE: architecture.md and evidence-bundle.md. Relative links resolve against
# $DIR; a link with only an anchor resolves against FILE itself.
check_page() {
	local f=$1 link target anchor
	[ -f "$f" ] || { echo "missing page"; return; }
	grep -qE '^> \*\*Status:' "$f" || echo "no status line"
	grep -qi 'ruling 1234' "$f" || echo "no ruling 1234"
	# the issue-closing keyword; the word alone is ordinary prose (life cycle "closes")
	if grep -qiE '(closes|fixes|resolves):? +#[0-9]' "$f"; then echo "contains closes"; fi
	while IFS= read -r link; do
		target=${link%%#*}
		anchor=""
		[ "$target" = "$link" ] || anchor=${link#*#}
		if [ -z "$target" ]; then
			anchor_exists "$f" "$anchor" || echo "dead anchor: $link"
		elif [ ! -f "$DIR/$target" ]; then
			echo "dead link: $link"
		elif [ -n "$anchor" ] && ! anchor_exists "$DIR/$target" "$anchor"; then
			echo "dead anchor: $link"
		fi
	done < <(grep -oE '\]\([^)]+\)' "$f" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^[a-z]+://' | sort -u)
}

for page in architecture.md evidence-bundle.md; do
	problems=$(check_page "$DIR/$page")
	if [ -z "$problems" ]; then
		pass "$page passes every check"
	else
		fail "$page checks" "$problems"
	fi
done

neg_page() { # name page sed-expression
	local tmp out
	tmp=$(mktemp "$TMP_ROOT/page.XXXXXX")
	sed -E "$3" "$DIR/$2" >"$tmp"
	out=$(check_page "$tmp")
	if [ -n "$out" ]; then pass "negative: $1"; else fail "negative: $1 was not caught"; fi
}
neg_page "dead anchor in architecture.md" architecture.md 's/#what-the-public-references-give-about-the-root/#no-such-anchor/'
neg_page "no ruling 1234 in evidence-bundle.md" evidence-bundle.md 's/[Rr]uling 1234/ruling 0000/g'
neg_page "no status line in architecture.md" architecture.md '/^> \*\*Status:/d'

finish
