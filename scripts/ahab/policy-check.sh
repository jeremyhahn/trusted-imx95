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
num() {
	if [[ "$1" =~ ^0[xX]([0-9a-fA-F]{1,16})$ ]]; then
		echo $((16#${BASH_REMATCH[1]}))
	elif [[ "$1" =~ ^[0-9]{1,18}$ ]]; then
		echo $((10#$1))
	else
		return 1
	fi
}

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
p_id=$(num "${pol[USED_SRK_ID]}") || fail "USED_SRK_ID is not an integer"
p_mask=$(num "${pol[SRK_REVOKE_MASK]}") || fail "SRK_REVOKE_MASK is not hex or an integer"
p_min=$(num "${pol[FUSE_VERSION_MIN]}") || fail "FUSE_VERSION_MIN is not an integer"
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

# cfg_val <key>: the first "<key>: <value>" line of the parsed configuration
# (the first container), without quotes. Comment lines never match.
pcfg=$work/parsed/parsed_config.yaml
[ -f "$pcfg" ] || fail "nxpimage ahab parse wrote no parsed_config.yaml"
cfg_val() {
	local l
	while IFS= read -r l; do
		l=$(trim "${l%$'\r'}")
		case "$l" in
		"$1:"*)
			l=$(trim "${l#*:}")
			l=${l//[\'\"]/}
			[ -n "$l" ] || return 1
			echo "$l"
			return 0
			;;
		esac
	done <"$pcfg"
	return 1
}

hash_file=$work/parsed/ahab_oem0_srk0_hash.txt
[ -s "$hash_file" ] || fail "nxpimage ahab parse wrote no SRK table hash (ahab_oem0_srk0_hash.txt)"
c_hash=$(tr -d '[:space:]' <"$hash_file")
c_hash=${c_hash^^}
[[ "$c_hash" =~ ^[0-9A-F]+$ ]] || fail "the container's SRK table hash is not hex"
c_id=$(cfg_val used_srk_id) || fail "the parsed container reports no used_srk_id"
c_id=$(num "$c_id") || fail "the parsed used_srk_id is not an integer"
c_mask=$(cfg_val srk_revoke_mask) || fail "the parsed container reports no srk_revoke_mask"
c_mask=$(num "$c_mask") || fail "the parsed srk_revoke_mask is not a number"
c_fuse=$(cfg_val fuse_version) || fail "the parsed container reports no fuse_version"
c_fuse=$(num "$c_fuse") || fail "the parsed fuse_version is not an integer"

# --- Compare, one line per field.
bad=0
report() { # <field> <ok 0|1> <container> <policy>
	if [ "$2" = 0 ]; then
		echo "policy: $1 OK"
	else
		echo "policy: $1 MISMATCH (container $3, policy $4)"
		bad=1
	fi
}
[ "$c_hash" = "$p_hash" ] && r=0 || r=1
report srk_table_hash "$r" "$c_hash" "$p_hash"
[ "$c_id" -eq "$p_id" ] && r=0 || r=1
report used_srk_id "$r" "$c_id" "$p_id"
[ "$c_mask" -eq "$p_mask" ] && r=0 || r=1
report srk_revoke_mask "$r" "$c_mask" "$p_mask"
[ "$c_fuse" -ge "$p_min" ] && r=0 || r=1
report fuse_version "$r" "$c_fuse" ">= $p_min"

if [ "$bad" = 0 ]; then
	echo "policy: OK"
else
	echo "policy: FAILED"
	exit 1
fi
