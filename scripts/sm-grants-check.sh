#!/usr/bin/env bash
# sm-grants-check.sh <patched cfg> <allowlist> | --print <cfg>: the M7 LM's normalised grants must equal system-manager/m7-grants.txt (UNLISTED or STALE otherwise).
set -euo pipefail

die() {
	echo "sm-grants-check: $*" >&2
	exit 1
}

# grants <cfg>: the normalised grant lines of the M7 LM block, sorted.
grants() {
	local l acc="" in=0 seen=0 out=() bs=$'\\'
	[ -r "$1" ] && [ -f "$1" ] || die "cannot read ${1##*/}"
	while IFS= read -r l || [ -n "$l" ]; do
		l=${l%%#*}
		if [[ $l =~ ^LM[0-9]+[[:space:]] ]]; then
			in=0
			if [[ $l == *'name="M7"'* ]]; then in=1 seen=1; fi
			acc=""
			continue
		fi
		[ "$in" = 1 ] || continue
		l=$(printf '%s' "$l" | tr -s '[:space:]' ' ')
		l=${l# }
		l=${l% }
		if [[ $l == *"$bs" ]]; then
			l=${l%"$bs"}
			acc+="$l "
			continue
		fi
		l="$acc$l"
		acc=""
		l=$(printf '%s' "$l" | tr -s '[:space:]' ' ')
		l=${l# }
		l=${l% }
		[ -z "$l" ] || out+=("$l")
	done <"$1"
	[ "$seen" = 1 ] || die "no M7 LM block in ${1##*/}"
	[ -z "$acc" ] || { l=$(printf '%s' "$acc" | tr -s ' '); l=${l% }; [ -z "$l" ] || out+=("$l"); }
	[ "${#out[@]}" -gt 0 ] || return 0
	printf '%s\n' "${out[@]}" | LC_ALL=C sort
}

# allow <file>: the allowlist, normalised the same way (comments, blanks).
allow() {
	local l out=()
	[ -r "$1" ] && [ -f "$1" ] || die "no allowlist ${1##*/}"
	while IFS= read -r l || [ -n "$l" ]; do
		l=${l%%#*}
		l=$(printf '%s' "$l" | tr -s '[:space:]' ' ')
		l=${l# }
		l=${l% }
		[ -z "$l" ] || out+=("$l")
	done <"$1"
	[ "${#out[@]}" -gt 0 ] || die "allowlist ${1##*/} is empty"
	printf '%s\n' "${out[@]}" | LC_ALL=C sort
}

if [ "${1:-}" = "--print" ]; then
	[ $# -eq 2 ] || die "usage: --print <cfg>"
	grants "$2"
	exit 0
fi
[ $# -eq 2 ] || die "usage: sm-grants-check.sh <patched cfg> <allowlist> | --print <cfg>"

have=$(grants "$1")
want=$(allow "$2")
bad=0
while IFS= read -r l; do
	[ -n "$l" ] || continue
	echo "grants: UNLISTED $l"
	bad=1
done < <(LC_ALL=C comm -23 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
while IFS= read -r l; do
	[ -n "$l" ] || continue
	echo "grants: STALE $l"
	bad=1
done < <(LC_ALL=C comm -13 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
if [ "$bad" = 1 ]; then
	echo "grants: FAILED"
	exit 1
fi
echo "grants: OK ($(printf '%s\n' "$want" | wc -l) lines)"
