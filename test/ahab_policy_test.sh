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
REAL="$ROOT/scripts/ahab/policy-check.sh"
out="$TMP_ROOT/out"
mkdir -p "$out"

# mkman <file> <position>...: a container manifest; a position is nxp, m7 (an
# OEM container with the Cortex-M7 image) or a55 (an OEM container with the A55
# data image).
mkman() {
	local f=$1 p
	shift
	{
		echo "containers:"
		for p in "$@"; do
			case "$p" in
			nxp) printf '  - role: nxp\n    sha256: policy\n' ;;
			m7) printf '  - role: oem\n    images:\n      - core_id: cortex-m7-1\n        image_type: executable\n' ;;
			a55) printf '  - role: oem\n    images:\n      - core_id: cortex-a55\n        image_type: data\n' ;;
			esac
		done
	} >"$f"
}
# The field tests below run policy-check.sh on A55-only images: POLICY is the
# real script with PC_MANIFEST (default: one OEM A55 container) as its manifest.
mkman "$TMP_ROOT/single.yaml" a55
printf '#!/usr/bin/env bash\n[ $# -eq 2 ] && set -- "$@" "${PC_MANIFEST:-%s}"\nexec "%s" "$@"\n' "$TMP_ROOT/single.yaml" "$REAL" >"$TMP_ROOT/pc"
chmod +x "$TMP_ROOT/pc"
POLICY="$TMP_ROOT/pc"

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

# Test containers built here from the same throwaway test PKI (temp directory,
# nothing committed): a nonzero fuse_version, and several containers.
pki="$TMP_ROOT/pki"
mkdir "$pki"
for i in 0 1 2 3 4 5 6 7; do
	"$venv/bin/nxpcrypto" key generate -k secp384r1 -o "$pki/srk$i.pem" >/dev/null 2>"$pki/keygen.log" ||
		{ tail -n 3 "$pki/keygen.log"; fail "nxpcrypto key generate failed for srk$i"; finish; exit 1; }
done
head -c 4096 /dev/urandom >"$pki/payload.bin"

# ymlc <fuse_version> <first SRK of the table, 0 or 4> [srk_set]: one container
# block (srk_set oem, nxp or none; default oem).
ymlc() {
	local core=cortex-a55 type=data load=0x90000000 entry=0x90000000
	if [ "${4:-a55}" = m7 ]; then
		core=cortex-m7-1 type=executable load=0x00000000 entry=0x303C0000
	fi
	echo "  - container:"
	echo "      srk_set: ${3:-oem}"
	echo "      used_srk_id: 0"
	echo "      srk_revoke_mask: '0x00'"
	echo "      fuse_version: $1"
	echo "      sw_version: 0"
	echo "      signer: type=file;file_path=srk$2.pem"
	echo "      images:"
	echo "        - image_path: payload.bin"
	echo "          load_address: '$load'"
	echo "          entry_point: '$entry'"
	echo "          image_type: $type"
	echo "          core_id: $core"
	echo "          hash_type: sha384"
	echo "      srk_table:"
	echo "        srk_array:"
	echo "          - srk$2.pub"
	echo "          - srk$(($2 + 1)).pub"
	echo "          - srk$(($2 + 2)).pub"
	echo "          - srk$(($2 + 3)).pub"
}
# mkbin <name> <container spec>...: builds $pki/<name>.bin, one
# "<fuse>:<srk base>[:<srk_set>[:<m7|a55>]]" per container; the first container's SRK table hash goes to $pki/<name>.hash.
mkbin() {
	local name=$1 spec sf sb ss sk
	shift
	mkdir "$pki/$name.d"
	cp "$pki"/*.pem "$pki"/payload.bin "$pki/$name.d/"
	for i in 0 1 2 3 4 5 6 7; do cp "$pki/srk$i.pub" "$pki/$name.d/" 2>/dev/null || true; done
	{
		echo "family: mimx9596"
		echo "revision: b0"
		echo "target_memory: standard"
		echo "output: $name.bin"
		echo "containers:"
		for spec in "$@"; do
			IFS=: read -r sf sb ss sk <<<"$spec"
			ymlc "$sf" "$sb" "${ss:-oem}" "${sk:-a55}"
		done
	} >"$pki/$name.d/c.yaml"
	(cd "$pki/$name.d" && "$venv/bin/nxpimage" ahab export -c c.yaml) >"$pki/$name.log" 2>&1 ||
		{ tail -n 5 "$pki/$name.log"; fail "nxpimage ahab export failed for $name"; return 1; }
	cp "$pki/$name.d/$name.bin" "$pki/$name.bin"
	local hf
	for hf in "$pki/$name.d"/ahab_*_hash.txt; do
		tr -d '[:space:]' <"$hf" >"$pki/$name.hash"
		break
	done
}

# Above the floor: a container with fuse_version 3 is accepted at floors 1 and
# 3 and rejected at floor 4 (a -ge turned into -eq fails the floor-1 case).
if mkbin f3 3:0; then
	h3=$(<"$pki/f3.hash")
	mkpol "$pki/f3-1.policy" "$h3" 0 0 1
	run "$POLICY" "$pki/f3.bin" "$pki/f3-1.policy"
	check "C4: a container with fuse_version 3 is accepted at floor 1" 0 "policy: fuse_version OK" "policy: OK"
	mkpol "$pki/f3-3.policy" "$h3" 0 0 3
	run "$POLICY" "$pki/f3.bin" "$pki/f3-3.policy"
	check "C4: a container with fuse_version 3 is accepted at floor 3" 0 "policy: fuse_version OK" "policy: OK"
	mkpol "$pki/f3-4.policy" "$h3" 0 0 4
	run "$POLICY" "$pki/f3.bin" "$pki/f3-4.policy"
	check "C4: a container with fuse_version 3 is rejected at floor 4" 1 "policy: fuse_version MISMATCH (container 3, policy >= 4)" "policy: FAILED"
fi

# Several containers: each is checked, not only the first. Two OEM A55 containers.
mkman "$pki/two.yaml" a55 a55
if mkbin two-ok 3:0 3:0; then
	h=$(<"$pki/two-ok.hash")
	mkpol "$pki/two.policy" "$h" 0 0 3
	run env PC_MANIFEST="$pki/two.yaml" "$POLICY" "$pki/two-ok.bin" "$pki/two.policy"
	check "two containers sharing one compliant SRK table pass" 0 "policy: 2 container(s) to check" "policy: srk_table_hash [container 1] OK" "policy: OK"
fi
if mkbin two-srk 3:0 3:4; then
	h=$(<"$pki/two-srk.hash")
	mkpol "$pki/two-srk.policy" "$h" 0 0 3
	run env PC_MANIFEST="$pki/two.yaml" "$POLICY" "$pki/two-srk.bin" "$pki/two-srk.policy"
	check "a compliant first container and a second with another signing root fails" 1 \
		"policy: srk_table_hash [container 1] MISMATCH" "policy: FAILED"
fi
if mkbin two-fuse 3:0 1:0; then
	h=$(<"$pki/two-fuse.hash")
	mkpol "$pki/two-fuse.policy" "$h" 0 0 3
	run env PC_MANIFEST="$pki/two.yaml" "$POLICY" "$pki/two-fuse.bin" "$pki/two-fuse.policy"
	check "a compliant first container and a second with fuse_version below the floor fails" 1 \
		"policy: fuse_version [container 1] MISMATCH (container 1, policy >= 3)" "policy: FAILED"
fi
# An unsigned container (srk_set none) fails.
if mkbin oem-none 0:0 0:0:none; then
	h=$(<"$pki/oem-none.hash")
	mkpol "$pki/oem-none.policy" "$h" 0 0 0
	run env PC_MANIFEST="$pki/two.yaml" "$POLICY" "$pki/oem-none.bin" "$pki/oem-none.policy"
	check "an OEM container then an srk_set none container fails" 1 "srk_set none" "policy: FAILED"
fi

# Mixed-signer images (container manifest, per-role records): an nxp fixture
# container (its own SRK table, srk4..7), the OEM M7 container, the OEM A55
# container. The nxp container is held to its pinned sha256 only.
# nxpdigest <name>: sha256 of the nxp binary container SPSDK extracts from <name>.bin.
nxpdigest() {
	local d="$pki/$1.parsed" s
	mkdir "$d"
	"$venv/bin/nxpimage" ahab parse -f mimx9596 -r b0 -b "$pki/$1.bin" -o "$d" >"$pki/$1.plog" 2>&1 || return 1
	s=$(sha256sum "$d/ahab_nxp_containers_0.bin")
	echo "${s%% *}"
}
# mixpol <file> <oem hash> <nxp digest>
mixpol() {
	mkpol "$1" "$2" 0 0 0
	echo "NXP_CONTAINER_SHA256=$3" >>"$1"
}
mkman "$pki/mix.yaml" nxp m7 a55
if mkbin full 0:4:nxp:a55 0:0:oem:m7 0:0:oem:a55 && dg=$(nxpdigest full); then
	h=$(<"$pki/full.hash")
	mixpol "$pki/full.policy" "$h" "$dg"
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a complete mixed-signer image (nxp, OEM M7, OEM A55) passes" 0 \
		"policy: position 0 nxp container sha256 OK" "policy: position 1 oem image entries OK" "policy: position 2 oem image entries OK" \
		"policy: 3 container(s) to check" "policy: srk_table_hash [container 2] OK" "policy: OK"
	mkpol "$pki/full-env.policy" "$h" 0 0 0
	run env NXP_CONTAINER_SHA256="$dg" "$REAL" "$pki/full.bin" "$pki/full-env.policy" "$pki/mix.yaml"
	check "the nxp pin comes from the environment when the policy file has none" 0 "policy: position 0 nxp container sha256 OK" "policy: OK"
	run "$REAL" "$pki/full.bin" "$pki/full-env.policy" "$pki/mix.yaml"
	check "no nxp pin anywhere fails" 1 "no 64-hex sha256 pin" "policy: FAILED"
	# The OEM policy is not applied to the nxp container: a different used_srk_id there is no mismatch.
	{ cat "$pki/full.policy"; echo "NXP_USED_SRK_ID=1"; } >"$pki/full-vid.policy"
	run "$REAL" "$pki/full.bin" "$pki/full-vid.policy" "$pki/mix.yaml"
	check "a vendor record is compared against the nxp container only" 1 "policy: nxp_used_srk_id [container 0] MISMATCH" "policy: FAILED"
	{ cat "$pki/full.policy"; echo "NXP_FUSE_VERSION_MIN=0"; echo "NXP_USED_SRK_ID=0"; echo "NXP_SRK_REVOKE_MASK=0"; } >"$pki/full-vok.policy"
	run "$REAL" "$pki/full.bin" "$pki/full-vok.policy" "$pki/mix.yaml"
	check "a matching vendor record passes" 0 "policy: nxp_fuse_version [container 0] OK" "policy: OK"
	# An nxp container whose digest differs from the pin.
	mixpol "$pki/full-pin.policy" "$h" "$(printf '%064d' 1)"
	run "$REAL" "$pki/full.bin" "$pki/full-pin.policy" "$pki/mix.yaml"
	check "an nxp container whose digest differs from the pin fails" 1 "differs from the pin" "policy: FAILED"
	# An nxp container with its tag byte overwritten.
	cp "$pki/full.bin" "$pki/full-tag.bin"
	printf '\x00' | dd of="$pki/full-tag.bin" bs=1 seek=3 conv=notrunc 2>/dev/null
	run "$REAL" "$pki/full-tag.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "an nxp container with its tag byte overwritten fails" 1 "policy: FAILED"
	# A non-zero byte after the last container, and one in the gap inside the nxp binary.
	cp "$pki/full.bin" "$pki/full-tail.bin"
	printf '\x01' >>"$pki/full-tail.bin"
	run "$REAL" "$pki/full-tail.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a non-zero byte after the last container fails, naming the offset" 1 "non-zero byte at offset 0x$(printf '%x' "$(stat -c %s "$pki/full.bin")")" "policy: FAILED"
	cp "$pki/full.bin" "$pki/full-gap.bin"
	printf '\x01' | dd of="$pki/full-gap.bin" bs=1 seek=$((0x2000)) conv=notrunc 2>/dev/null
	run "$REAL" "$pki/full-gap.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a non-zero byte between an nxp container's header and its image fails, naming the offset" 1 "non-zero byte at offset 0x2000" "policy: FAILED"
	# A truncated image.
	head -c $(($(stat -c %s "$pki/full.bin") - 6000)) "$pki/full.bin" >"$pki/full-cut.bin"
	run "$REAL" "$pki/full-cut.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a truncated mixed-signer image fails" 1 "policy: FAILED"
	# A manifest that lists fewer positions than the image holds.
	mkman "$pki/short.yaml" nxp m7
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/short.yaml"
	check "an image with a container the manifest does not list fails" 1 "the manifest lists" "policy: FAILED"
	mkman "$pki/oemfirst.yaml" m7 nxp a55
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/oemfirst.yaml"
	check "an image whose container order differs from the manifest fails" 1 "the manifest lists" "policy: FAILED"
fi
# The OEM boot container must carry the M7 image; the OEM containers must not be swapped.
if mkbin nom7 0:4:nxp:a55 0:0:oem:a55 0:0:oem:a55 && dg=$(nxpdigest nom7); then
	mixpol "$pki/nom7.policy" "$(<"$pki/nom7.hash")" "$dg"
	run "$REAL" "$pki/nom7.bin" "$pki/nom7.policy" "$pki/mix.yaml"
	check "an image without the M7 image fails" 1 "image entries" "policy: FAILED"
fi
if mkbin swapped 0:4:nxp:a55 0:0:oem:a55 0:0:oem:m7 && dg=$(nxpdigest swapped); then
	mixpol "$pki/swapped.policy" "$(<"$pki/swapped.hash")" "$dg"
	run "$REAL" "$pki/swapped.bin" "$pki/swapped.policy" "$pki/mix.yaml"
	check "an image with the two OEM containers swapped fails" 1 "image entries" "policy: FAILED"
fi
# Two OEM containers with distinct SRK tables, the second off-policy: each
# container's own table is hashed, so the shared-hash-file shortcut cannot hide it.
if mkbin distinct 0:4:nxp:a55 0:0:oem:m7 0:4:oem:a55 && dg=$(nxpdigest distinct); then
	mixpol "$pki/distinct.policy" "$(<"$pki/distinct.hash")" "$dg"
	run "$REAL" "$pki/distinct.bin" "$pki/distinct.policy" "$pki/mix.yaml"
	check "two OEM containers with distinct SRK tables, the second off-policy, fails" 1 \
		"policy: srk_table_hash [container 2] MISMATCH" "policy: FAILED"
fi

# A manifest that is missing, empty or malformed fails; never a skip.
run "$REAL" "$bin" "$good" "$TMP_ROOT/no-such.yaml"
check "a missing manifest fails" 1 "cannot be read" "policy: FAILED"
: >"$TMP_ROOT/empty.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/empty.yaml"
check "an empty manifest fails" 1 "empty or malformed" "policy: FAILED"
printf 'containers: []\n' >"$TMP_ROOT/nolist.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/nolist.yaml"
check "a manifest with no container fails" 1 "empty or malformed" "policy: FAILED"
printf 'containers:\n  - role: root\n' >"$TMP_ROOT/badrole.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/badrole.yaml"
check "a manifest position with an unknown role fails" 1 "role must be nxp or oem" "policy: FAILED"
printf 'containers:\n  - role: oem\n    images:\n      - core_id: cortex-a55\n' >"$TMP_ROOT/badimg.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/badimg.yaml"
check "an image entry without image_type fails" 1 "an image entry takes exactly" "policy: FAILED"
printf 'containers:\n  - role: oem\n' >"$TMP_ROOT/noimg.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/noimg.yaml"
check "an oem position without images fails" 1 "non-empty images list" "policy: FAILED"
printf 'containers:\n  - role: nxp\n    sha256: nothex\n' >"$TMP_ROOT/badpin.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/badpin.yaml"
check "an nxp position with a malformed sha256 fails" 1 "no 64-hex sha256 pin" "policy: FAILED"
printf 'containers:\n  - role: nxp\n' >"$TMP_ROOT/nopin.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/nopin.yaml"
check "an nxp position without sha256 fails" 1 "takes exactly role and sha256" "policy: FAILED"
printf 'containers: [\n' >"$TMP_ROOT/syntax.yaml"
run "$REAL" "$bin" "$good" "$TMP_ROOT/syntax.yaml"
check "a manifest that is not YAML fails" 1 "cannot be read" "policy: FAILED"
# The A55-only test container no longer passes under the repository manifest.
run "$REAL" "$bin" "$good"
check "an A55-only container fails under the repository manifest (no nxp pin given)" 1 "no 64-hex sha256 pin" "policy: FAILED"
mixpol "$TMP_ROOT/a55-pin.policy" "$hash" "$(printf '%064d' 1)"
run "$REAL" "$bin" "$TMP_ROOT/a55-pin.policy"
check "an A55-only container fails under the repository manifest (nxp and M7 positions missing)" 1 "the manifest lists" "policy: FAILED"

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
