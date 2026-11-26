#!/usr/bin/env bash
# SPEC rows and ROADMAP entries agree: every row of the Features table of
# docs/SPEC.md has exactly one top-level "- **<row>**" entry in ROADMAP.md, and
# every such entry has a SPEC row. Each broken case runs on a scratch copy under
# TMP_ROOT; the clone is never edited.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

# check_rows SPEC ROADMAP: prints one line per problem, nothing when the files
# agree. A SPEC without a Features table, or a ROADMAP without entries, is a
# problem too, so an empty read never passes.
check_rows() {
	local spec=$1 roadmap=$2 l name in_feat=0 rows=() entries=() r e n
	declare -A seen=() in_spec=() count=()
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in
		'## Features') in_feat=1 ;;
		'## '*) in_feat=0 ;;
		esac
		[ "$in_feat" -eq 1 ] || continue
		case $l in '| '*) ;; *) continue ;; esac
		name=${l#'| '}
		name=${name%%' |'*}
		[ "$name" = Feature ] && continue
		rows+=("$name")
		in_spec[$name]=1
	done <"$spec"
	if [ "${#rows[@]}" -eq 0 ]; then
		echo "no Features table in SPEC"
	fi
	while IFS= read -r l || [ -n "$l" ]; do
		if [[ $l =~ ^-\ \*\*([^*]+)\*\* ]]; then
			entries+=("${BASH_REMATCH[1]}")
			count[${BASH_REMATCH[1]}]=$((${count[${BASH_REMATCH[1]}]:-0} + 1))
		fi
	done <"$roadmap"
	if [ "${#entries[@]}" -eq 0 ]; then
		echo "no entries in ROADMAP"
	fi
	for r in "${rows[@]}"; do
		[ -n "${count[$r]:-}" ] || echo "missing in ROADMAP: $r"
	done
	for e in "${entries[@]}"; do
		[ -z "${seen[$e]:-}" ] || continue
		seen[$e]=1
		[ -n "${in_spec[$e]:-}" ] || echo "not in SPEC: $e"
		n=${count[$e]}
		[ "$n" -le 1 ] || echo "duplicate in ROADMAP: $e"
	done
}

# drop_line FILE OUT PREFIX: copies FILE to OUT without the lines that start
# with PREFIX.
drop_line() {
	local l
	: >"$2"
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in "$3"*) continue ;; esac
		printf '%s\n' "$l" >>"$2"
	done <"$1"
}

# pick_line FILE PREFIX: prints the first line of FILE that starts with PREFIX.
pick_line() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in "$2"*)
			printf '%s\n' "$l"
			return 0
			;;
		esac
	done <"$1"
	return 1
}

# --- cases ---
spec=$ROOT/docs/SPEC.md
roadmap=$ROOT/ROADMAP.md

run check_rows "$spec" "$roadmap"
expect "the real SPEC and ROADMAP agree (no output)" test -z "$OUT"
[ -z "$OUT" ] || printf '%s\n' "$OUT"

# The table is read: a known row is among those found.
expect "the real files carry the xkms-board row and entry" test -n "$(pick_line "$spec" '| xkms-board |')" -a -n "$(pick_line "$roadmap" '- **xkms-board**')"

drop_line "$roadmap" "$TMP_ROOT/no-xkms.md" '- **xkms-board**'
run check_rows "$spec" "$TMP_ROOT/no-xkms.md"
expect "a ROADMAP without the xkms-board line is reported" test "$OUT" = "missing in ROADMAP: xkms-board"

cp "$roadmap" "$TMP_ROOT/extra.md"
printf '%s\n' '- **no-such-row** — x' >>"$TMP_ROOT/extra.md"
run check_rows "$spec" "$TMP_ROOT/extra.md"
expect "an entry without a SPEC row is reported" test "$OUT" = "not in SPEC: no-such-row"

cp "$roadmap" "$TMP_ROOT/dup.md"
pick_line "$roadmap" '- **maintenance**' >>"$TMP_ROOT/dup.md"
run check_rows "$spec" "$TMP_ROOT/dup.md"
expect "an entry listed twice is reported" test "$OUT" = "duplicate in ROADMAP: maintenance"

drop_line "$spec" "$TMP_ROOT/spec-short.md" '| hsm-self-defence |'
run check_rows "$TMP_ROOT/spec-short.md" "$roadmap"
expect "a SPEC table that lost a row reports its entry" test "$OUT" = "not in SPEC: hsm-self-defence"

drop_line "$spec" "$TMP_ROOT/spec-nofeat.md" '## Features'
run check_rows "$TMP_ROOT/spec-nofeat.md" "$roadmap"
expect "a SPEC without a Features table is reported" test "${OUT%%$'\n'*}" = "no Features table in SPEC"

: >"$TMP_ROOT/empty.md"
run check_rows "$spec" "$TMP_ROOT/empty.md"
expect "a ROADMAP without entries is reported" test "${OUT%%$'\n'*}" = "no entries in ROADMAP"

finish
