#!/usr/bin/env bash
# policy-check.sh: host policy check of a signed AHAB container against
# recorded values (issue #12; docs/boot-container/secure-boot-test-plan.md
# cases C2, C3, C4; docs/boot-container/signing-pipeline.md "Policy check").
#
#   policy-check.sh <container.bin> <policy file>
#
# Parses the container with the pinned SPSDK (nxpimage ahab parse) and fails
# unless its SRK table hash, used_srk_id, srk_revoke_mask and fuse_version
# agree with the policy file. A missing, empty or unreadable policy file, or a
# missing field in either input, FAILS: nothing is skipped.
#
# The policy file is plain KEY=VALUE lines, parsed here and never sourced:
#   SRK_TABLE_HASH=<hex>        compared as a case-insensitive hex string
#   USED_SRK_ID=<integer>       compared numerically
#   SRK_REVOKE_MASK=<hex|int>   compared numerically
#   FUSE_VERSION_MIN=<integer>  the container's fuse_version must be >= this
# Comments (#) and blank lines are allowed; an unknown, repeated or missing
# key is an error.
#
# Never touches a board, a fuse or a key. The .bcf fuse scripts nxpimage
# writes are deleted unread. Exit 0 ("policy: OK") or 1 ("policy: FAILED").
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

fail() {
	echo "policy-check: $*" >&2
	echo "policy: FAILED"
	exit 1
}

[ $# -eq 2 ] || fail "usage: policy-check.sh <container.bin> <policy file>"
bin=$1
policy=$2
[ -f "$bin" ] && [ -r "$bin" ] || fail "no such container: $bin"
[ -f "$policy" ] && [ -r "$policy" ] || fail "no such (or unreadable) policy file: $policy"
[ -s "$policy" ] || fail "empty policy file: $policy"
bin=$(realpath "$bin")

# num <text>: prints the numeric value of 0x<hex> or <decimal>, else fails.
num() { # <text> <max>
	local d
	# Bash arithmetic is signed 64-bit, so range is settled on the string
	# first: leading zeros are stripped and anything longer than 4 digits
	# (far above every field maximum) is rejected before any $(( )).
	if [[ "$1" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
		d=${BASH_REMATCH[1]}
		d=${d#"${d%%[!0]*}"}
		[ ${#d} -le 4 ] || return 1
		d=$((16#${d:-0}))
	elif [[ "$1" =~ ^[0-9]+$ ]]; then
		d=$1
		d=${d#"${d%%[!0]*}"}
		[ ${#d} -le 4 ] || return 1
		d=$((10#${d:-0}))
	else
		return 1
	fi
	[ "$d" -le "$2" ] || return 1
	echo "$d"
}

# Field widths. The script states none, so each is the narrowest width the
# container header holds as nxpimage ahab parse reports it: used_srk_id is a
# 2-bit selector (0..3), srk_revoke_mask a 4-bit mask (0..0xF), fuse_version
# one byte (0..255). The policy and the container are held to the same range.
MAX_ID=3
MAX_MASK=15
MAX_FUSE=255

# trim <text>: prints <text> without leading and trailing whitespace.
trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# --- The policy file: keys, no sourcing.
declare -A pol=()
while IFS= read -r line || [ -n "$line" ]; do
	line=$(trim "${line%$'\r'}")
	case "$line" in "" | "#"*) continue ;; esac
	[[ "$line" == *=* ]] || fail "policy line is not KEY=VALUE: $line"
	k=$(trim "${line%%=*}")
	v=$(trim "${line#*=}")
	case "$k" in
	SRK_TABLE_HASH | USED_SRK_ID | SRK_REVOKE_MASK | FUSE_VERSION_MIN) ;;
	*) fail "unknown policy key: $k" ;;
	esac
	[ -z "${pol[$k]+x}" ] || fail "repeated policy key: $k"
	[ -n "$v" ] || fail "empty value for policy key: $k"
	pol[$k]=$v
done <"$policy"
for k in SRK_TABLE_HASH USED_SRK_ID SRK_REVOKE_MASK FUSE_VERSION_MIN; do
	[ -n "${pol[$k]+x}" ] || fail "missing policy key: $k"
done
[[ "${pol[SRK_TABLE_HASH]}" =~ ^[0-9a-fA-F]+$ ]] || fail "SRK_TABLE_HASH is not hex"
p_id=$(num "${pol[USED_SRK_ID]}" "$MAX_ID") || fail "USED_SRK_ID is not an integer in 0..$MAX_ID"
p_mask=$(num "${pol[SRK_REVOKE_MASK]}" "$MAX_MASK") || fail "SRK_REVOKE_MASK is not hex or an integer in 0..$MAX_MASK (0xF)"
p_min=$(num "${pol[FUSE_VERSION_MIN]}" "$MAX_FUSE") || fail "FUSE_VERSION_MIN is not an integer in 0..$MAX_FUSE"
p_hash=${pol[SRK_TABLE_HASH]^^}

# --- The container, through the pinned SPSDK.
venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) fail "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

mkdir "$work/parsed"
"$nxpimage" ahab parse -f "$FAMILY" -r "$REVISION" -b "$bin" -o "$work/parsed" >"$work/parse.log" 2>&1 ||
	{ tail -n 5 "$work/parse.log" >&2; fail "nxpimage ahab parse failed for $bin"; }
rm -f "$work"/parsed/*.bcf

# Every container in the input is checked against the policy; none is skipped.
# The parsed configuration lists the containers in order, each opened by a
# "container:" line. For each, the first "<key>: <value>" line inside it is
# taken (quotes removed; comment lines never match).
pcfg=$work/parsed/parsed_config.yaml
[ -f "$pcfg" ] || fail "nxpimage ahab parse wrote no parsed_config.yaml"
declare -a c_ids=() c_masks=() c_fuses=()
n=-1
while IFS= read -r l || [ -n "$l" ]; do
	l=$(trim "${l%$'\r'}")
	if [ "$l" = "container:" ]; then
		n=$((n + 1))
		continue
	fi
	[ "$n" -ge 0 ] || continue
	case "$l" in
	used_srk_id:* | srk_revoke_mask:* | fuse_version:*)
		k=${l%%:*}
		v=$(trim "${l#*:}")
		v=${v//[\'\"]/}
		[ -n "$v" ] || fail "container $n: the parsed container has an empty $k"
		case "$k" in
		used_srk_id) [ -n "${c_ids[$n]+x}" ] || c_ids[n]=$v ;;
		srk_revoke_mask) [ -n "${c_masks[$n]+x}" ] || c_masks[n]=$v ;;
		fuse_version) [ -n "${c_fuses[$n]+x}" ] || c_fuses[n]=$v ;;
		esac
		;;
	esac
done <"$pcfg"
count=$((n + 1))
[ "$count" -ge 1 ] || fail "the parsed configuration lists no container"

# SPSDK writes one ahab_<set>[<n>]_srk0_hash.txt per distinct SRK table: a
# single file when the containers share a table (the normal case, as the fuses
# hold one OEM SRK hash), one per table otherwise. Every hash file must equal
# the policy hash, and at least one must exist.
declare -a c_hashes=()
for f in "$work"/parsed/ahab_*_hash.txt; do
	[ -f "$f" ] || continue
	[ -s "$f" ] || fail "an SRK table hash file is empty: $(basename "$f")"
	h=$(tr -d '[:space:]' <"$f")
	h=${h^^}
	[[ "$h" =~ ^[0-9A-F]+$ ]] || fail "the SRK table hash in $(basename "$f") is not hex"
	c_hashes+=("$h")
done
[ "${#c_hashes[@]}" -ge 1 ] || fail "nxpimage ahab parse wrote no SRK table hash"

# --- Compare, one line per field per container.
bad=0
report() { # <label> <ok 0|1> <container> <policy>
	if [ "$2" = 0 ]; then
		echo "policy: $1 OK"
	else
		echo "policy: $1 MISMATCH (container $3, policy $4)"
		bad=1
	fi
}
echo "policy: $count container(s) to check"
for ((i = 0; i < ${#c_hashes[@]}; i++)); do
	[ "${#c_hashes[@]}" -eq 1 ] && sfx= || sfx=" [table $i]"
	[ "${c_hashes[$i]}" = "$p_hash" ] && r=0 || r=1
	report "srk_table_hash$sfx" "$r" "${c_hashes[$i]}" "$p_hash"
done
for ((i = 0; i < count; i++)); do
	[ "$count" -eq 1 ] && sfx= || sfx=" [container $i]"
	[ -n "${c_ids[$i]+x}" ] || fail "container $i: the parsed container reports no used_srk_id"
	c_id=$(num "${c_ids[$i]}" "$MAX_ID") || fail "container $i: the parsed used_srk_id is not an integer in 0..$MAX_ID"
	[ -n "${c_masks[$i]+x}" ] || fail "container $i: the parsed container reports no srk_revoke_mask"
	c_mask=$(num "${c_masks[$i]}" "$MAX_MASK") || fail "container $i: the parsed srk_revoke_mask is not a number in 0..$MAX_MASK"
	[ -n "${c_fuses[$i]+x}" ] || fail "container $i: the parsed container reports no fuse_version"
	c_fuse=$(num "${c_fuses[$i]}" "$MAX_FUSE") || fail "container $i: the parsed fuse_version is not an integer in 0..$MAX_FUSE"
	[ "$c_id" -eq "$p_id" ] && r=0 || r=1
	report "used_srk_id$sfx" "$r" "$c_id" "$p_id"
	[ "$c_mask" -eq "$p_mask" ] && r=0 || r=1
	report "srk_revoke_mask$sfx" "$r" "$c_mask" "$p_mask"
	[ "$c_fuse" -ge "$p_min" ] && r=0 || r=1
	report "fuse_version$sfx" "$r" "$c_fuse" ">= $p_min"
done

if [ "$bad" = 0 ]; then
	echo "policy: OK"
else
	echo "policy: FAILED"
	exit 1
fi
