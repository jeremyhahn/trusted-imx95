#!/usr/bin/env bash
# Structure test of docs/platform-image/emmc-layout.md (provisional, pending the
# owner's answer on #14): required headings, the "proposed, pending owner
# approval" status, a source cell in every region table row, no closing keyword.
# A scratch copy with a heading removed must fail.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

doc=$ROOT/docs/platform-image/emmc-layout.md

# check_doc FILE: prints one line per problem.
check_doc() {
	local f=$1 h l in_regions=0 cells last
	for h in "## Scope" "## Sources" "## Regions" "### boot0 (hardware boot partition 1)" \
		"### boot1 (hardware boot partition 2)" "### RPMB" "### User area" \
		"## What is still missing" "## Questions for the owner" "## Board steps outside this lane"; do
		grep -qxF "$h" "$f" || echo "missing heading $h"
	done
	grep -qi 'proposed, pending owner approval' "$f" || echo "missing status 'proposed, pending owner approval'"
	if grep -Eqi '\b(closes|fixes|resolves) +#[0-9]' "$f"; then echo "closing keyword present"; fi
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in
		'## Regions') in_regions=1 ;;
		'## '*) in_regions=0 ;;
		esac
		[ "$in_regions" -eq 1 ] || continue
		case $l in '|'*) ;; *) continue ;; esac
		case $l in '|--'*) continue ;; esac
		[[ $l == '| What |'* ]] && continue
		# The last cell is the source: non-empty.
		last=${l%|}
		last=${last##*|}
		cells=${last//[[:space:]]/}
		[ -n "$cells" ] || echo "region row without a source cell: $l"
	done <"$f"
}

run check_doc "$doc"
expect "the eMMC layout doc has no structure problem" test -z "$OUT"

# Every region has at least one table row with a source.
for r in boot0 boot1 RPMB "User area"; do
	expect "region $r has a table" grep -q "^### .*$r" "$doc"
done

scratch=$TMP_ROOT/scratch.md
cp "$doc" "$scratch"
rm -f "$scratch.n"
while IFS= read -r l || [ -n "$l" ]; do
	[ "$l" = "## Questions for the owner" ] || printf '%s\n' "$l" >>"$scratch.n"
done <"$scratch"
run check_doc "$scratch.n"
expect "a scratch copy without the Questions heading is reported" test "${OUT##*missing heading ## Questions for the owner*}" != "$OUT"

printf '%s\n' '| a thing | 0 | someone | |' >"$TMP_ROOT/row.md"
{ echo "## Regions"; cat "$TMP_ROOT/row.md"; } >"$TMP_ROOT/row2.md"
run check_doc "$TMP_ROOT/row2.md"
expect "a region row with an empty source cell is reported" test "${OUT##*region row without a source cell*}" != "$OUT"

finish
