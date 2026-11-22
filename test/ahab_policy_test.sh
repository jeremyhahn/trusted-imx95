#!/usr/bin/env bash
# make ahab-policy-test (issue #12): scripts/ahab/policy-check.sh compares a
# signed container's SRK table hash, used_srk_id, srk_revoke_mask and
# fuse_version with a policy file (test plan C2, C3, C4). The container comes
# from sign-test.sh (a throwaway test PKI); the policy files are written here,
# in a temp directory, from the container's own parsed values. Nothing is
# committed: no key, container or policy.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGN="$ROOT/scripts/ahab/sign-test.sh"
POLICY="$ROOT/scripts/ahab/policy-check.sh"
out="$TMP_ROOT/out"
mkdir -p "$out"

run env AHAB_OUT_DIR="$out" "$SIGN"
check "the test container builds through sign-test.sh" 0 "verify: OK" "SRK table hash (test PKI only):"
bin="$out/container.bin"
if [ ! -s "$bin" ]; then
	fail "sign-test.sh handed back no container"
	finish
	exit 1
fi

# The container's own values: the hash sign-test.sh printed, the rest from
# nxpimage ahab parse.
hash=${OUT#*"SRK table hash (test PKI only): "}
hash=${hash%%$'\n'*}
venv=$("$ROOT/scripts/ahab/spsdk-venv.sh")
mkdir "$TMP_ROOT/parsed"
(cd "$TMP_ROOT" && "$venv/bin/nxpimage" ahab parse -f mimx9596 -r b0 -b "$bin" -o parsed) >"$TMP_ROOT/parse.log" 2>&1 ||
	{ tail -n 5 "$TMP_ROOT/parse.log"; fail "nxpimage ahab parse failed"; }
cfg_val() {
	local l
	while IFS= read -r l; do
		l=${l#"${l%%[![:space:]]*}"}
		case "$l" in
		"$1:"*) l=${l#*:}; l=${l//[\' ]/}; echo "$l"; return ;;
		esac
	done <"$TMP_ROOT/parsed/parsed_config.yaml"
}
id=$(cfg_val used_srk_id)
mask=$(cfg_val srk_revoke_mask)
fuse=$(cfg_val fuse_version)
if [[ ! "$hash" =~ ^[0-9A-Fa-f]{16,}$ || ! "$id" =~ ^[0-9]+$ || ! "$mask" =~ ^(0x[0-9a-f]+|[0-9]+)$ || ! "$fuse" =~ ^[0-9]+$ ]]; then
	fail "the container's own values could not be read" "hash='$hash' id='$id' mask='$mask' fuse='$fuse'"
	finish
	exit 1
fi

# mkpol <file> <hash> <id> <mask> <min>: a complete policy file.
mkpol() {
	{
		echo "# test policy, written from the container's own values"
		echo
		echo "SRK_TABLE_HASH=$2"
		echo "USED_SRK_ID=$3"
		echo "SRK_REVOKE_MASK=$4"
		echo "FUSE_VERSION_MIN=$5"
	} >"$1"
}

good="$TMP_ROOT/good.policy"
mkpol "$good" "$hash" "$id" "$mask" "$fuse"
run "$POLICY" "$bin" "$good"
check "a container with a matching policy passes" 0 \
	"policy: srk_table_hash OK" "policy: used_srk_id OK" "policy: srk_revoke_mask OK" "policy: fuse_version OK" "policy: OK"

# Case-insensitive hash, numeric mask: the same values written differently.
alt="$TMP_ROOT/alt.policy"
mkpol "$alt" "${hash,,}" "$id" "$((mask))" "$fuse"
run "$POLICY" "$bin" "$alt"
check "the hash compares case-insensitively and the mask numerically" 0 "policy: OK"

# C2: a wrong SRK table hash; a hash that is a prefix of the right one.
first=${hash:0:1}
[ "$first" = 0 ] && flipped=1 || flipped=0
mkpol "$TMP_ROOT/hash.policy" "$flipped${hash:1}" "$id" "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/hash.policy"
check "C2: a wrong SRK table hash fails" 1 "policy: srk_table_hash MISMATCH (container" "policy: FAILED"
mkpol "$TMP_ROOT/prefix.policy" "${hash:0:64}" "$id" "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/prefix.policy"
check "C2: a truncated SRK table hash fails" 1 "policy: srk_table_hash MISMATCH" "policy: FAILED"

# C2b/C3: used_srk_id and srk_revoke_mask.
mkpol "$TMP_ROOT/id.policy" "$hash" "$((id + 1))" "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/id.policy"
check "C2b/C3: a policy whose USED_SRK_ID differs fails" 1 "policy: used_srk_id MISMATCH (container $id, policy $((id + 1)))" "policy: FAILED"
mkpol "$TMP_ROOT/mask.policy" "$hash" "$id" "$(printf '0x%x' $((mask ^ 1)))" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/mask.policy"
check "C3: a policy whose SRK_REVOKE_MASK differs fails" 1 "policy: srk_revoke_mask MISMATCH" "policy: FAILED"

# C4: FUSE_VERSION_MIN above the container's fails, at or below passes.
mkpol "$TMP_ROOT/fuse-hi.policy" "$hash" "$id" "$mask" "$((fuse + 1))"
run "$POLICY" "$bin" "$TMP_ROOT/fuse-hi.policy"
check "C4: a FUSE_VERSION_MIN above the container's fuse_version fails" 1 "policy: fuse_version MISMATCH" "policy: FAILED"
mkpol "$TMP_ROOT/fuse-eq.policy" "$hash" "$id" "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/fuse-eq.policy"
check "C4: a FUSE_VERSION_MIN equal to the container's fuse_version passes" 0 "policy: fuse_version OK" "policy: OK"
if [ "$fuse" -gt 0 ]; then
	mkpol "$TMP_ROOT/fuse-lo.policy" "$hash" "$id" "$mask" "$((fuse - 1))"
	run "$POLICY" "$bin" "$TMP_ROOT/fuse-lo.policy"
	check "C4: a FUSE_VERSION_MIN below the container's fuse_version passes" 0 "policy: OK"
fi

# Integer range: every policy integer is held to its field width (id 0..3,
# mask 0..0xF, fuse 0..255) before any arithmetic; out of range is a policy
# error, never a pass.
mkpol "$TMP_ROOT/codex.policy" "$hash" "$id" "$mask" 0xffffffffffffffff
run "$POLICY" "$bin" "$TMP_ROOT/codex.policy"
check "FUSE_VERSION_MIN=0xffffffffffffffff is a policy error" 1 "policy-check: FUSE_VERSION_MIN is not" "policy: FAILED"
mkpol "$TMP_ROOT/hex17.policy" "$hash" "$id" "$mask" 0x10000000000000000
run "$POLICY" "$bin" "$TMP_ROOT/hex17.policy"
check "a 17-digit hex FUSE_VERSION_MIN is a policy error" 1 "policy-check: FUSE_VERSION_MIN is not" "policy: FAILED"
mkpol "$TMP_ROOT/neg.policy" "$hash" "$id" "$mask" -1
run "$POLICY" "$bin" "$TMP_ROOT/neg.policy"
check "a negative FUSE_VERSION_MIN is a policy error" 1 "policy-check: FUSE_VERSION_MIN is not" "policy: FAILED"
mkpol "$TMP_ROOT/over-id.policy" "$hash" 4 "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/over-id.policy"
check "USED_SRK_ID above 3 is a policy error" 1 "policy-check: USED_SRK_ID is not" "policy: FAILED"
mkpol "$TMP_ROOT/over-mask.policy" "$hash" "$id" 0x10 "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/over-mask.policy"
check "SRK_REVOKE_MASK above 0xF is a policy error" 1 "policy-check: SRK_REVOKE_MASK is not" "policy: FAILED"
mkpol "$TMP_ROOT/over-fuse.policy" "$hash" "$id" "$mask" 256
run "$POLICY" "$bin" "$TMP_ROOT/over-fuse.policy"
check "FUSE_VERSION_MIN above 255 is a policy error" 1 "policy-check: FUSE_VERSION_MIN is not" "policy: FAILED"
# Decimal and per-field long forms: each must fail closed, naming the field.
# negpol <label> <field> <id> <mask> <min>
negpol() {
	mkpol "$TMP_ROOT/neg-$1.policy" "$hash" "$3" "$4" "$5"
	run "$POLICY" "$bin" "$TMP_ROOT/neg-$1.policy"
	check "$2 $6 is a policy error" 1 "policy-check: $2 is not" "policy: FAILED"
}
negpol fuse-dec20 FUSE_VERSION_MIN "$id" "$mask" 18446744073709551615 "as a 20-digit decimal"
negpol fuse-dec5 FUSE_VERSION_MIN "$id" "$mask" 65536 "as a 5-digit decimal"
negpol id-hex17 USED_SRK_ID 0x10000000000000000 "$mask" "$fuse" "as a 17-digit hex"
negpol id-hexmax USED_SRK_ID 0xffffffffffffffff "$mask" "$fuse" "as 0xffffffffffffffff"
negpol id-dec20 USED_SRK_ID 18446744073709551615 "$mask" "$fuse" "as a long decimal"
negpol id-hex4 USED_SRK_ID 0x4 "$mask" "$fuse" "as hex 0x4"
negpol mask-hex17 SRK_REVOKE_MASK "$id" 0x10000000000000000 "$fuse" "as a 17-digit hex"
negpol mask-hexmax SRK_REVOKE_MASK "$id" 0xffffffffffffffff "$fuse" "as 0xffffffffffffffff"
negpol mask-dec20 SRK_REVOKE_MASK "$id" 18446744073709551615 "$fuse" "as a long decimal"
# In range with leading zeros: still accepted.
mkpol "$TMP_ROOT/lz-id.policy" "$hash" 0003 "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/lz-id.policy"
if [ "$id" = 3 ]; then
	check "USED_SRK_ID 0003 is accepted as 3" 0 "policy: used_srk_id OK"
else
	check "USED_SRK_ID 0003 is accepted as 3" 1 "policy: used_srk_id MISMATCH (container $id, policy 3)"
fi
mkpol "$TMP_ROOT/lz-mask.policy" "$hash" "$id" 0015 "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/lz-mask.policy"
if [ "$((mask))" = 15 ]; then
	check "SRK_REVOKE_MASK 0015 is accepted as 15" 0 "policy: srk_revoke_mask OK"
else
	check "SRK_REVOKE_MASK 0015 is accepted as 15" 1 "policy: srk_revoke_mask MISMATCH"
fi
mkpol "$TMP_ROOT/lz-fuse.policy" "$hash" "$id" "$mask" 0000
run "$POLICY" "$bin" "$TMP_ROOT/lz-fuse.policy"
check "FUSE_VERSION_MIN 0000 is accepted as 0" 0 "policy: fuse_version OK" "policy: OK"
mkpol "$TMP_ROOT/hex-id17.policy" "$hash" 0x00000000000000000 "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/hex-id17.policy"
check "leading zeros do not widen a field: 17 digits of 0 are still the value 0" 0 "policy: used_srk_id OK" "policy: OK"
# At the maximum: accepted as a value, then compared normally.
mkpol "$TMP_ROOT/max-id.policy" "$hash" 3 "$mask" "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/max-id.policy"
if [ "$id" = 3 ]; then
	check "USED_SRK_ID at its maximum is accepted and compared" 0 "policy: used_srk_id OK"
else
	check "USED_SRK_ID at its maximum is accepted and compared" 1 "policy: used_srk_id MISMATCH (container $id, policy 3)"
fi
mkpol "$TMP_ROOT/max-mask.policy" "$hash" "$id" 0xF "$fuse"
run "$POLICY" "$bin" "$TMP_ROOT/max-mask.policy"
if [ "$((mask))" = 15 ]; then
	check "SRK_REVOKE_MASK at its maximum is accepted and compared" 0 "policy: srk_revoke_mask OK"
else
	check "SRK_REVOKE_MASK at its maximum is accepted and compared" 1 "policy: srk_revoke_mask MISMATCH"
fi
mkpol "$TMP_ROOT/max-fuse.policy" "$hash" "$id" "$mask" 255
run "$POLICY" "$bin" "$TMP_ROOT/max-fuse.policy"
if [ "$fuse" = 255 ]; then
	check "FUSE_VERSION_MIN at its maximum is accepted and compared" 0 "policy: fuse_version OK"
else
	check "FUSE_VERSION_MIN at its maximum is accepted and compared" 1 "policy: fuse_version MISMATCH (container $fuse, policy >= 255)"
fi

# A policy file that is missing, empty, or malformed fails; never a skip.
run "$POLICY" "$bin" "$TMP_ROOT/no-such.policy"
check "a missing policy file fails" 1 "no such" "policy: FAILED"
: >"$TMP_ROOT/empty.policy"
run "$POLICY" "$bin" "$TMP_ROOT/empty.policy"
check "an empty policy file fails" 1 "empty policy file" "policy: FAILED"
{ cat "$good"; echo "USED_SRK_ID=$id"; } >"$TMP_ROOT/dup.policy"
run "$POLICY" "$bin" "$TMP_ROOT/dup.policy"
check "a repeated key fails" 1 "repeated policy key: USED_SRK_ID" "policy: FAILED"
{ cat "$good"; echo "EXTRA_KEY=1"; } >"$TMP_ROOT/unknown.policy"
run "$POLICY" "$bin" "$TMP_ROOT/unknown.policy"
check "an unknown key fails" 1 "unknown policy key: EXTRA_KEY" "policy: FAILED"
printf 'SRK_TABLE_HASH=%s\nUSED_SRK_ID=%s\nSRK_REVOKE_MASK=%s\n' "$hash" "$id" "$mask" >"$TMP_ROOT/missing.policy"
run "$POLICY" "$bin" "$TMP_ROOT/missing.policy"
check "a missing key fails" 1 "missing policy key: FUSE_VERSION_MIN" "policy: FAILED"

# A container that does not exist, or is not a container, fails.
run "$POLICY" "$TMP_ROOT/no-such.bin" "$good"
check "a container path that does not exist fails" 1 "no such container" "policy: FAILED"
head -c 4096 /dev/urandom >"$TMP_ROOT/junk.bin"
run "$POLICY" "$TMP_ROOT/junk.bin" "$good"
check "a file that is not a container fails" 1 "policy: FAILED"
run "$POLICY" "$bin"
check "a call without a policy file fails" 1 "usage" "policy: FAILED"

# The checks leave nothing in the clone.
expect "the clone is clean after the checks" test -z "$(git -C "$ROOT" status --porcelain)"
expect "no key, container or policy file is tracked" \
	test -z "$(git -C "$ROOT" ls-files | { while IFS= read -r f; do case "$f" in *.pem | *.bin | *.policy) echo "$f" ;; esac; done; })"

finish
