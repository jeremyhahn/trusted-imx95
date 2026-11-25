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

# count_owner_questions FILE: lines that start an owner question held outside the surveys.
count_owner_questions() {
	grep -c '^Owner question, proposed, pending owner approval' "$1" || true
}

# check_readme FILE [ARCH]: prints the problems found, one per line; empty means clean.
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
	# the issue-closing keyword with an issue number; "closes" alone is prose (life cycle)
	if grep -qiE '(closes|fixes|resolves):? +#[0-9]' "$f"; then echo "contains closes"; fi
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
	for t in $SURVEYS ../ftpm/README.md architecture.md evidence-bundle.md decommission-runbook.md; do
		grep -qF "]($t" "$f" || echo "no link to $t"
	done
	local rows want=0 s
	rows=$(grep -cE '^\| [A-G][0-9]+ \|' "$f" || true)
	for s in $SURVEYS; do
		want=$((want + $(count_questions "$DIR/$s" '^## .*[Qq]uestions for the owner')))
	done
	want=$((want + $(count_questions "$DIR/../ftpm/README.md" '^## Open questions for the owner')))
	want=$((want + $(count_owner_questions "${2:-$DIR/architecture.md}")))
	[ "$rows" -eq "$want" ] || echo "question rows $rows, sources $want"
	grep -E '^\| G1 \|' "$f" | grep -F '](architecture.md#where-the-life-cycle-closes)' >/dev/null || echo "G1 row does not link architecture.md#where-the-life-cycle-closes"
	grep -E '^\| [A-G][0-9]+ \|' "$f" | grep -vE '\]\([^)]*\.md#[^)]+\)' >/dev/null && echo "a row has no anchored source link"
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
neg "G1 row deleted" '/^\| G1 \|/d'
neg "G1 source link to a missing anchor" '/^\| G1 \|/s/#where-the-life-cycle-closes/#no-such-anchor/'
# a second owner question in architecture.md that the README does not list
tmpa=$(mktemp "$TMP_ROOT/arch.XXXXXX")
cp "$DIR/architecture.md" "$tmpa"
printf '\nOwner question, proposed, pending owner approval: a second question.\n' >>"$tmpa"
out=$(check_readme "$README" "$tmpa")
if printf '%s' "$out" | grep -qF 'question rows 31, sources 32'; then pass "negative: a second architecture.md owner question"; else fail "negative: a second owner question was not caught" "$out"; fi

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

# check_runbook FILE: decommission-runbook.md. Same link rules as the pages, plus the
# proposed status, the section headings, every step label, no life-cycle imperative,
# no closing keyword, no /home path.
RUNBOOK_HEADINGS=(
	"## Scope and defaults"
	"## Order of steps"
	"## Board-side wipe"
	"## Control-plane steps"
	"## Not in this runbook"
	"## Evidence of completion"
)
check_runbook() {
	local f=$1 h n
	[ -f "$f" ] || { echo "missing runbook"; return; }
	check_page "$f"
	grep -E '^> \*\*Status:' "$f" | grep -qF 'PROPOSED' || echo "status line lacks PROPOSED"
	grep -E '^> \*\*Status:' "$f" | grep -qF 'pending owner approval' || echo "status line lacks pending owner approval"
	for h in "${RUNBOOK_HEADINGS[@]}"; do
		grep -qxF "$h" "$f" || echo "missing heading: $h"
	done
	for n in 1 2 3 4 5 6a 6b 6c 7; do
		grep -qE "^\| $n \|" "$f" || echo "missing step $n"
	done
	# a step row (table row starting with a step number) must not move the life cycle
	if grep -E '^\| [0-9][abc]? \|' "$f" | grep -qiE 'life[ -]cycle'; then echo "life cycle in a step row"; fi
	grep -qF 'verb: none yet' -i "$f" || echo "no 'verb: none yet'"
	grep -qE '/home/' "$f" && echo "contains a /home path"
	return 0
}

problems=$(check_runbook "$DIR/decommission-runbook.md")
if [ -z "$problems" ]; then
	pass "decommission-runbook.md passes every check"
else
	fail "decommission-runbook.md checks" "$problems"
fi

neg_runbook() { # name sed-expression
	local tmp out
	tmp=$(mktemp "$TMP_ROOT/runbook.XXXXXX")
	sed -E "$2" "$DIR/decommission-runbook.md" >"$tmp"
	out=$(check_runbook "$tmp")
	if [ -n "$out" ]; then pass "negative: $1"; else fail "negative: $1 was not caught"; fi
}
neg_runbook "runbook status line removed" '/^> \*\*Status:/d'
neg_runbook "runbook 6b label removed" '/^\| 6b \|/d'
neg_runbook "runbook closing keyword" 's/^## Scope and defaults$/Closes #177\n&/'
neg_runbook "runbook life cycle in a step" 's/^(\| 3 \|.*) \|/\1 life cycle |/'

# the README link to the runbook, and that the file is really needed
if grep -qF '](decommission-runbook.md' "$README"; then pass "README links the runbook"; else fail "README links the runbook"; fi
neg "README link to the runbook removed" 's|\(decommission-runbook\.md\)|(no-such-file.md)|g'

# --- where the life cycle closes (ruling 1234, second half) ---------------------------
# Removable block. The deny list is one array: tokens that must not appear on a
# non-comment line of any file under scripts/device-lifecycle/ (ruling 1234: the life
# cycle closes only at the provisioning station, never from this folder; ruling 1244:
# no RPMB). Comment lines (first non-blank character #) may name them.
DENY_TOKENS=(nvm_write fuse lifecycle life-cycle ahab_ spsdk nxpele rpmb /dev/mmcblk)

# check_closing ARCH README SCRIPTDIR: prints the problems found; empty means clean.
check_closing() {
	local arch=$1 readme=$2 sdir=$3 re f
	grep -qxF '## Where the life cycle closes' "$arch" || echo "architecture.md lacks the heading"
	awk '/^## Where the life cycle closes$/ {on=1; next} /^## / {on=0} on' "$arch" | grep -q '1234' \
		|| echo "the section does not cite ruling 1234"
	grep -qF 'where the life cycle closes' "$readme" || echo "README row lacks the cell text"
	re=$(IFS='|'; printf '%s' "${DENY_TOKENS[*]}")
	while IFS= read -r f; do
		if grep -vE '^[[:space:]]*#' "$f" | grep -qiE "$re"; then
			echo "deny-list token in non-comment line of ${f#"$sdir"/}"
		fi
	done < <(find "$sdir" -type f | sort)
}

SDIR="$ROOT/scripts/device-lifecycle"
problems=$(check_closing "$DIR/architecture.md" "$README" "$SDIR")
if [ -z "$problems" ]; then pass "life-cycle boundary checks"; else fail "life-cycle boundary checks" "$problems"; fi

# negatives on copies under mktemp
tmpd=$(mktemp -d "$TMP_ROOT/closing.XXXXXX")
cp -r "$SDIR" "$tmpd/scripts"
printf 'nxpele --burn\n' >>"$tmpd/scripts/collect-evidence.sh"
out=$(check_closing "$DIR/architecture.md" "$README" "$tmpd/scripts")
if [ -n "$out" ]; then pass "negative: a non-comment nxpele line in a script"; else fail "negative: a non-comment nxpele line was not caught"; fi
mkdir "$tmpd/okdir"
printf '# nxpele is named only in a comment\n' >"$tmpd/okdir/ok.sh"
out=$(check_closing "$DIR/architecture.md" "$README" "$tmpd/okdir")
if [ -z "$out" ]; then pass "a comment line may name a token"; else fail "a comment line may name a token" "$out"; fi
sed -E '/^## Where the life cycle closes$/d' "$DIR/architecture.md" >"$tmpd/arch.md"
out=$(check_closing "$tmpd/arch.md" "$README" "$SDIR")
if [ -n "$out" ]; then pass "negative: architecture.md without the heading"; else fail "negative: heading removal was not caught"; fi
sed -E 's/, and where the life cycle closes//' "$README" >"$tmpd/readme.md"
out=$(check_closing "$DIR/architecture.md" "$tmpd/readme.md" "$SDIR")
if [ -n "$out" ]; then pass "negative: README without the cell text"; else fail "negative: README cell removal was not caught"; fi
# runbook absent from a copy of the docs: the check reports it
out=$(check_runbook "$TMP_ROOT/absent-runbook.md")
if [ -n "$out" ]; then pass "negative: runbook file missing"; else fail "negative: runbook file missing was not caught"; fi

finish
