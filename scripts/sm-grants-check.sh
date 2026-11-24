#!/usr/bin/env bash
# sm-grants-check.sh <patched cfg> <allowlist>   check the M7 LM's grants
# sm-grants-check.sh --print <cfg>               print them, normalised
#
# The M7 LM (LMn name="M7") block of the patched System Manager configuration
# must grant exactly what the reviewed allowlist (system-manager/m7-grants.txt)
# lists: a grant the list lacks is UNLISTED, a listed grant the file lacks is
# STALE. Normalisation: comments and blank lines dropped, backslash
# continuations joined, whitespace collapsed, sorted (C locale), so the order of
# the file does not matter. The LM header line itself is not a grant.
# With --ap-s first, the same check runs on the AP-S agent's section instead: the
# lines after the SCMI_AGENTn name="AP-S" line (inside the LM named "AP") up to
# the next SCMI_AGENT line or LM header, against system-manager/ap-s-grants.txt.
# The agent header line is not a grant and is not listed.
# Host side only.
set -euo pipefail

die() {
	echo "sm-grants-check: $*" >&2
	exit 1
}

# grants <cfg>: the normalised grant lines of the M7 LM block, sorted.
grants() {
	local l acc="" in=0 lm=0 seen=0 out=() bs=$'\\'
	[ -r "$1" ] && [ -f "$1" ] || die "cannot read ${1##*/}"
	while IFS= read -r l || [ -n "$l" ]; do
		l=${l%%#*}
		if [[ $l =~ ^LM[0-9]+[[:space:]] ]]; then
			in=0 lm=0
			if [ "$mode" = m7 ] && [[ $l == *'name="M7"'* ]]; then in=1 seen=1; fi
			if [ "$mode" = aps ] && [[ $l == *'name="AP"'* ]]; then lm=1; fi
			acc=""
			continue
		fi
		if [ "$mode" = aps ] && [ "$lm" = 1 ] && [[ $l =~ ^[[:space:]]*SCMI_AGENT[0-9]+[[:space:]] ]]; then
			in=0 acc=""
			if [[ $l == *'name="AP-S"'* ]]; then in=1 seen=1; fi
			continue # the agent header line itself is not a grant
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
	if [ "$seen" != 1 ]; then
		if [ "$mode" = aps ]; then die "no AP-S agent block in LM AP of ${1##*/}"; fi
		die "no M7 LM block in ${1##*/}"
	fi
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

mode=m7
if [ "${1:-}" = "--ap-s" ]; then
	mode=aps
	shift
fi
if [ "${1:-}" = "--print" ]; then
	[ $# -eq 2 ] || die "usage: [--ap-s] --print <cfg>"
	grants "$2"
	exit 0
fi
[ $# -eq 2 ] || die "usage: sm-grants-check.sh [--ap-s] <patched cfg> <allowlist> | [--ap-s] --print <cfg>"

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
