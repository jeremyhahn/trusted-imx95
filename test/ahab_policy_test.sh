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
			m7) printf '  - role: oem\n    images:\n      - core_id: cortex-m7-1\n        image_type: executable\n        sha256: %s\n        load_address: "%s"\n        entry_point: "%s"\n' "$M7_SHA" "$M7_LOAD" "$M7_ENTRY" ;;
			a55) printf '  - role: oem\n    images:\n      - core_id: cortex-a55\n        image_type: data\n        sha256: %s\n        load_address: "%s"\n' "$A55_SHA" "$A55_LOAD" ;;
			esac
		done
	} >"$f"
}
# The field tests below run policy-check.sh on A55-only images: POLICY is the
# real script with PC_MANIFEST (default: one OEM A55 container) as its manifest;
# single.yaml is written once the container exists (its image values are read
# from the container below).
# shellcheck disable=SC2016 # the wrapper's own $# and $@ stay literal
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

# imgrec <bin>: "<sha256 of the first image's bytes> <load address> <entry point>"
# as SPSDK parses the first container's first image entry.
imgrec() {
	"$venv/bin/python" -I -c '
import hashlib, sys
from spsdk.image.ahab.ahab_image import AHABImage
from spsdk.utils.family import FamilyRevision
d = open(sys.argv[1], "rb").read()
o = AHABImage.find_offset_of_ahab(d, True)
i = AHABImage.parse(d[o:], FamilyRevision("mimx9596", "b0")).ahab_containers[0].image_array[0]
print(hashlib.sha256(d[o + i.image_offset:o + i.image_offset + i.image_size]).hexdigest(), "0x%x" % i.load_address, "0x%x" % i.entry_point)
' "$1"
}
# nxprec <bin>: "<hash> <id> <mask> <fuse>" of the first container's own record.
nxprec() {
	"$venv/bin/python" -I -c '
import sys
from spsdk.image.ahab.ahab_image import AHABImage
from spsdk.utils.family import FamilyRevision
d = open(sys.argv[1], "rb").read()
o = AHABImage.find_offset_of_ahab(d, True)
c = AHABImage.parse(d[o:], FamilyRevision("mimx9596", "b0")).ahab_containers[0]
print(c.signature_block.srk_assets.compute_srk_hash().hex().upper(), int(str(c.flag_used_srk_id), 0), int(str(c.flag_srk_revoke_mask), 0), int(str(c.fuse_version), 0))
' "$1"
}
read -r A55_SHA A55_LOAD _ <<<"$(imgrec "$bin")"
M7_SHA=$A55_SHA M7_LOAD=0x00000000 M7_ENTRY=0x303C0000
mkman "$TMP_ROOT/single.yaml" a55

# mkpol <file> <hash> <id> <mask> <min>: a complete policy file; the vendor
# record is a placeholder (VREC) unless a test sets it: an image with no nxp
# container never compares it, but the file must carry it.
VREC=(NXP_SRK_TABLE_HASH=00 NXP_USED_SRK_ID=0 NXP_SRK_REVOKE_MASK=0 NXP_FUSE_VERSION=0)
mkpol() {
	{
		echo "# test policy, written from the container's own values"
		echo
		echo "SRK_TABLE_HASH=$2"
		echo "USED_SRK_ID=$3"
		echo "SRK_REVOKE_MASK=$4"
		echo "FUSE_VERSION_MIN=$5"
		printf '%s\n' "${VREC[@]}"
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
head -c 4096 /dev/urandom >"$pki/payload2.bin"
PAY_SHA=$(sha256sum "$pki/payload.bin")
PAY_SHA=${PAY_SHA%% *}
# The images built from here carry payload.bin: the default manifest binds its digest.
A55_SHA=$PAY_SHA A55_LOAD=0x90000000 M7_SHA=$PAY_SHA
mkman "$TMP_ROOT/single.yaml" a55

# ymlc <fuse_version> <first SRK of the table, 0 or 4> [srk_set]: one container
# block (srk_set oem, nxp or none; default oem).
ymlc() {
	local core=cortex-a55 type=data load=0x90000000 entry=0x90000000
	if [ "${4:-a55}" = m7 ]; then
		core=cortex-m7-1 type=executable load=0x00000000 entry=0x303C0000
	fi
	[ -z "${6:-}" ] || load=$6
	echo "  - container:"
	echo "      srk_set: ${3:-oem}"
	echo "      used_srk_id: 0"
	echo "      srk_revoke_mask: '0x00'"
	echo "      fuse_version: $1"
	echo "      sw_version: 0"
	echo "      signer: type=file;file_path=srk$2.pem"
	echo "      images:"
	echo "        - image_path: ${5:-payload.bin}"
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
# "<fuse>:<srk base>[:<srk_set>[:<m7|a55>[:<payload file>[:<load address>]]]]" per container; the first container's SRK table hash goes to $pki/<name>.hash.
mkbin() {
	local name=$1 spec sf sb ss sk sp sl
	shift
	mkdir "$pki/$name.d"
	cp "$pki"/*.pem "$pki"/payload.bin "$pki"/payload2.bin "$pki/$name.d/"
	for i in 0 1 2 3 4 5 6 7; do cp "$pki/srk$i.pub" "$pki/$name.d/" 2>/dev/null || true; done
	{
		echo "family: mimx9596"
		echo "revision: b0"
		echo "target_memory: standard"
		echo "output: $name.bin"
		echo "containers:"
		for spec in "$@"; do
			IFS=: read -r sf sb ss sk sp sl <<<"$spec"
			ymlc "$sf" "$sb" "${ss:-oem}" "${sk:-a55}" "${sp:-payload.bin}" "${sl:-}"
		done
	} >"$pki/$name.d/c.yaml"
	(cd "$pki/$name.d" && "$venv/bin/nxpimage" ahab export -c c.yaml) >"$pki/$name.log" 2>&1 ||
		{ tail -n 5 "$pki/$name.log"; fail "nxpimage ahab export failed for $name"; return 1; }
	cp "$pki/$name.d/$name.bin" "$pki/$name.bin"
	local hf found=0
	for hf in "$pki/$name.d"/ahab_*_hash.txt; do
		[ -f "$hf" ] || continue
		tr -d '[:space:]' <"$hf" >"$pki/$name.hash"
		found=1
		break
	done
	[ "$found" -eq 1 ] || { fail "nxpimage ahab export wrote no ahab_*_hash.txt for $name"; return 1; }
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

# From here the images are built from payload.bin: the manifests bind its digest.
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
#
# The digest is left in DG (not echoed: a command substitution would run in a
# subshell and lose the failure count). A parse failure, or a missing extracted
# container, is a recorded test failure with the parser log, never a silent skip.
nxpdigest() {
	local d="$pki/$1.parsed" s
	DG=
	mkdir -p "$d"
	if ! "$venv/bin/nxpimage" ahab parse -f mimx9596 -r b0 -b "$pki/$1.bin" -o "$d" >"$pki/$1.plog" 2>&1; then
		tail -n 5 "$pki/$1.plog"
		fail "nxpimage ahab parse failed for $1"
		return 1
	fi
	if [ ! -f "$d/ahab_nxp_containers_0.bin" ]; then
		tail -n 5 "$pki/$1.plog"
		fail "nxpimage ahab parse of $1 extracted no nxp container"
		return 1
	fi
	s=$(sha256sum "$d/ahab_nxp_containers_0.bin")
	DG=${s%% *}
}
MIXED_RAN=0
RAN_subst=0 RAN_moved=0 RAN_fullf=0 RAN_nom7=0 RAN_swapped=0 RAN_distinct=0
# mixpol <file> <oem hash> <nxp digest> [<image name>]: with a name, the vendor
# record is that image's first container's own record.
mixpol() {
	local rec
	if [ -n "${4:-}" ]; then
		read -r -a rec <<<"$(nxprec "$pki/$4.bin")"
		VREC=("NXP_SRK_TABLE_HASH=${rec[0]}" "NXP_USED_SRK_ID=${rec[1]}" "NXP_SRK_REVOKE_MASK=${rec[2]}" "NXP_FUSE_VERSION=${rec[3]}")
	fi
	mkpol "$1" "$2" 0 0 0
	echo "NXP_CONTAINER_SHA256=$3" >>"$1"
	VREC=(NXP_SRK_TABLE_HASH=00 NXP_USED_SRK_ID=0 NXP_SRK_REVOKE_MASK=0 NXP_FUSE_VERSION=0)
}
# dropkey <src> <dst> <KEY>: <src> without the line for KEY.
dropkey() {
	local l
	while IFS= read -r l; do
		case "$l" in "$3="*) ;; *) echo "$l" ;; esac
	done <"$1" >"$2"
}
mkman "$pki/mix.yaml" nxp m7 a55
if mkbin full 0:4:nxp:a55 0:0:oem:m7 0:0:oem:a55 && nxpdigest full && dg=$DG; then
	MIXED_RAN=1
	h=$(<"$pki/full.hash")
	mixpol "$pki/full.policy" "$h" "$dg" full
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a complete mixed-signer image (nxp, OEM M7, OEM A55) passes" 0 \
		"policy: position 0 nxp container sha256 OK" "policy: position 1 oem image entries OK" "policy: position 2 oem image entries OK" \
		"policy: 3 container(s) to check" "policy: srk_table_hash [container 2] OK" "policy: OK"
	dropkey "$pki/full.policy" "$pki/full-env.policy" NXP_CONTAINER_SHA256
	run env NXP_CONTAINER_SHA256="$dg" "$REAL" "$pki/full.bin" "$pki/full-env.policy" "$pki/mix.yaml"
	check "the nxp pin comes from the environment when the policy file has none" 0 "policy: position 0 nxp container sha256 OK" "policy: OK"
	run "$REAL" "$pki/full.bin" "$pki/full-env.policy" "$pki/mix.yaml"
	check "no nxp pin anywhere fails" 1 "no 64-hex sha256 pin" "policy: FAILED"
	# The vendor record is compared against the nxp container only, and is exact.
	dropkey "$pki/full.policy" "$pki/full-vid.policy" NXP_USED_SRK_ID
	echo "NXP_USED_SRK_ID=1" >>"$pki/full-vid.policy"
	run "$REAL" "$pki/full.bin" "$pki/full-vid.policy" "$pki/mix.yaml"
	check "a vendor record is compared against the nxp container only" 1 "policy: nxp_used_srk_id [container 0] MISMATCH" "policy: FAILED"
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/mix.yaml"
	check "a complete matching vendor record passes" 0 "policy: nxp_srk_table_hash [container 0] OK" "policy: nxp_used_srk_id [container 0] OK" "policy: nxp_srk_revoke_mask [container 0] OK" "policy: nxp_fuse_version [container 0] OK" "policy: OK"
	# Each vendor key is mandatory: absent fails closed, naming the key.
	for k in NXP_SRK_TABLE_HASH NXP_USED_SRK_ID NXP_SRK_REVOKE_MASK NXP_FUSE_VERSION; do
		dropkey "$pki/full.policy" "$pki/full-no-$k.policy" "$k"
		run "$REAL" "$pki/full.bin" "$pki/full-no-$k.policy" "$pki/mix.yaml"
		check "a policy file without $k fails" 1 "missing policy key: $k" "policy: FAILED"
	done
	# The old floor key is not a vendor key any more.
	{ cat "$pki/full.policy"; echo "NXP_FUSE_VERSION_MIN=0"; } >"$pki/full-min.policy"
	run "$REAL" "$pki/full.bin" "$pki/full-min.policy" "$pki/mix.yaml"
	check "NXP_FUSE_VERSION_MIN is an unknown key" 1 "unknown policy key: NXP_FUSE_VERSION_MIN" "policy: FAILED"
	# Malformed vendor values fail.
	for kv in NXP_SRK_TABLE_HASH=zz NXP_USED_SRK_ID=4 NXP_SRK_REVOKE_MASK=0x10 NXP_FUSE_VERSION=256; do
		dropkey "$pki/full.policy" "$pki/full-bad.policy" "${kv%%=*}"
		echo "$kv" >>"$pki/full-bad.policy"
		run "$REAL" "$pki/full.bin" "$pki/full-bad.policy" "$pki/mix.yaml"
		check "a malformed ${kv%%=*} fails" 1 "policy-check: ${kv%%=*} is not" "policy: FAILED"
	done
	# An OEM payload substituted (its own header matches it) fails the manifest digest.
	if mkbin subst 0:4:nxp:a55 0:0:oem:m7:payload2.bin 0:0:oem:a55 && nxpdigest subst && dg2=$DG; then
		RAN_subst=1
		mixpol "$pki/subst.policy" "$(<"$pki/subst.hash")" "$dg2" subst
		run "$REAL" "$pki/subst.bin" "$pki/subst.policy" "$pki/mix.yaml"
		check "a substituted M7 payload with a matching header fails" 1 "position 1 image 0: sha256" "policy: FAILED"
	fi
	# An image at a changed load address fails.
	if mkbin moved 0:4:nxp:a55 0:0:oem:m7:payload.bin:0x00001000 0:0:oem:a55 && nxpdigest moved && dg2=$DG; then
		RAN_moved=1
		mixpol "$pki/moved.policy" "$(<"$pki/moved.hash")" "$dg2" moved
		run "$REAL" "$pki/moved.bin" "$pki/moved.policy" "$pki/mix.yaml"
		check "an M7 image at a changed load address fails" 1 "position 1 image 0: load_address" "policy: FAILED"
	fi
	# An entry point that differs from the manifest fails; one the manifest omits is not checked.
	M7_ENTRY=0x303C0004 mkman "$pki/entry.yaml" nxp m7 a55
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/entry.yaml"
	check "an M7 image at a changed entry point fails" 1 "position 1 image 0: entry_point" "policy: FAILED"
	# The nxp vendor fuse version is exact, not a floor: 2 in the image, 1 and 3 in the policy.
	if mkbin fullf 2:4:nxp:a55 0:0:oem:m7 0:0:oem:a55 && nxpdigest fullf && dgf=$DG; then
		RAN_fullf=1
		mixpol "$pki/fullf.policy" "$(<"$pki/fullf.hash")" "$dgf" fullf
		run "$REAL" "$pki/fullf.bin" "$pki/fullf.policy" "$pki/mix.yaml"
		check "a vendor fuse version equal to the pin passes" 0 "policy: nxp_fuse_version [container 0] OK" "policy: OK"
		for fv in 1 3; do
			dropkey "$pki/fullf.policy" "$pki/fullf-$fv.policy" NXP_FUSE_VERSION
			echo "NXP_FUSE_VERSION=$fv" >>"$pki/fullf-$fv.policy"
			run "$REAL" "$pki/fullf.bin" "$pki/fullf-$fv.policy" "$pki/mix.yaml"
			check "a vendor fuse version of 2 against a pin of $fv fails" 1 "policy: nxp_fuse_version [container 0] MISMATCH (container 2, policy $fv)" "policy: FAILED"
		done
	fi
	# A manifest naming policy:<KEY> takes the values from the policy file, else the environment.
	printf 'containers:\n  - role: nxp\n    sha256: policy\n  - role: oem\n    images:\n      - core_id: cortex-m7-1\n        image_type: executable\n        sha256: policy:M7_IMAGE_SHA256\n        load_address: policy:M7_LOAD_ADDRESS\n        entry_point: policy:M7_ENTRY_POINT\n  - role: oem\n    images:\n      - core_id: cortex-a55\n        image_type: data\n        sha256: %s\n        load_address: "0x90000000"\n' "$PAY_SHA" >"$pki/ref.yaml"
	{ cat "$pki/full.policy"; echo "M7_IMAGE_SHA256=${PAY_SHA^^}"; echo "M7_LOAD_ADDRESS=0x0"; } >"$pki/ref.policy"
	run env M7_ENTRY_POINT=0x303c0000 "$REAL" "$pki/full.bin" "$pki/ref.policy" "$pki/ref.yaml"
	check "image values named policy:<KEY> come from the policy file and the environment" 0 "policy: position 1 oem image entries OK" "policy: OK"
	run "$REAL" "$pki/full.bin" "$pki/ref.policy" "$pki/ref.yaml"
	check "a policy:<KEY> value found nowhere fails" 1 "no value for M7_ENTRY_POINT" "policy: FAILED"
	dropkey "$pki/ref.policy" "$pki/ref2.policy" M7_LOAD_ADDRESS
	echo "M7_LOAD_ADDRESS=0x1" >>"$pki/ref2.policy"
	run env M7_ENTRY_POINT=0x303c0000 "$REAL" "$pki/full.bin" "$pki/ref2.policy" "$pki/ref.yaml"
	check "a policy:<KEY> load address that differs fails" 1 "position 1 image 0: load_address" "policy: FAILED"
	printf 'containers:\n  - role: oem\n    images:\n      - core_id: cortex-a55\n        image_type: data\n        sha256: policy:evil\n        load_address: "0x0"\n' >"$pki/badkey.yaml"
	run "$REAL" "$pki/full.bin" "$pki/full.policy" "$pki/badkey.yaml"
	check "a policy: reference to an unusable key fails" 1 "unusable policy key" "policy: FAILED"
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
if mkbin nom7 0:4:nxp:a55 0:0:oem:a55 0:0:oem:a55 && nxpdigest nom7 && dg=$DG; then
	RAN_nom7=1
	mixpol "$pki/nom7.policy" "$(<"$pki/nom7.hash")" "$dg"
	run "$REAL" "$pki/nom7.bin" "$pki/nom7.policy" "$pki/mix.yaml"
	check "an image without the M7 image fails" 1 "differs from the manifest" "policy: FAILED"
fi
if mkbin swapped 0:4:nxp:a55 0:0:oem:a55 0:0:oem:m7 && nxpdigest swapped && dg=$DG; then
	RAN_swapped=1
	mixpol "$pki/swapped.policy" "$(<"$pki/swapped.hash")" "$dg"
	run "$REAL" "$pki/swapped.bin" "$pki/swapped.policy" "$pki/mix.yaml"
	check "an image with the two OEM containers swapped fails" 1 "differs from the manifest" "policy: FAILED"
fi
# Two OEM containers with distinct SRK tables, the second off-policy: each
# container's own table is hashed, so the shared-hash-file shortcut cannot hide it.
if mkbin distinct 0:4:nxp:a55 0:0:oem:m7 0:4:oem:a55 && nxpdigest distinct && dg=$DG; then
	RAN_distinct=1
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
check "an image entry without image_type fails" 1 "an image entry takes core_id" "policy: FAILED"
# imgman <file> <extra lines>: an A55 image entry with the given binding fields.
imgman() {
	printf 'containers:\n  - role: oem\n    images:\n      - core_id: cortex-a55\n        image_type: data\n%b' "$2" >"$1"
}
imgman "$TMP_ROOT/nosha.yaml" '        load_address: "0x90000000"\n'
run "$REAL" "$bin" "$good" "$TMP_ROOT/nosha.yaml"
check "an image entry without sha256 fails" 1 "an image entry takes core_id" "policy: FAILED"
imgman "$TMP_ROOT/noload.yaml" "        sha256: $PAY_SHA\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/noload.yaml"
check "an image entry without load_address fails" 1 "an image entry takes core_id" "policy: FAILED"
imgman "$TMP_ROOT/shortsha.yaml" "        sha256: ${PAY_SHA:0:63}\n        load_address: \"0x90000000\"\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/shortsha.yaml"
check "an image entry with a 63-digit sha256 fails" 1 "sha256 is not 64 hex digits" "policy: FAILED"
imgman "$TMP_ROOT/nothexsha.yaml" "        sha256: ${PAY_SHA:0:63}g\n        load_address: \"0x90000000\"\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/nothexsha.yaml"
check "an image entry with a non-hex sha256 fails" 1 "sha256 is not 64 hex digits" "policy: FAILED"
imgman "$TMP_ROOT/baddr.yaml" "        sha256: $PAY_SHA\n        load_address: \"90000000\"\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/baddr.yaml"
check "an image entry with a load address that is not 0x hex fails" 1 "load_address is not a hex address" "policy: FAILED"
imgman "$TMP_ROOT/bentry.yaml" "        sha256: $PAY_SHA\n        load_address: \"0x90000000\"\n        entry_point: \"0xzz\"\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/bentry.yaml"
check "an image entry with a malformed entry_point fails" 1 "entry_point is not a hex address" "policy: FAILED"
imgman "$TMP_ROOT/numaddr.yaml" "        sha256: $PAY_SHA\n        load_address: 2415919104\n"
run "$REAL" "$bin" "$good" "$TMP_ROOT/numaddr.yaml"
check "an image entry with a numeric (non-string) load address fails" 1 "all strings" "policy: FAILED"
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
check "an A55-only container fails under the repository manifest (no image values given)" 1 "no value for M7_IMAGE_SHA256" "policy: FAILED"

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

# The mixed-signer control must have run: a skipped block is a failure.
expect "the complete mixed-signer control ran" test "$MIXED_RAN" -eq 1
expect "the mixed-signer block subst ran" test "$RAN_subst" -eq 1
expect "the mixed-signer block moved ran" test "$RAN_moved" -eq 1
expect "the mixed-signer block fullf ran" test "$RAN_fullf" -eq 1
expect "the mixed-signer block nom7 ran" test "$RAN_nom7" -eq 1
expect "the mixed-signer block swapped ran" test "$RAN_swapped" -eq 1
expect "the mixed-signer block distinct ran" test "$RAN_distinct" -eq 1

# The checks leave nothing in the clone.
expect "the clone is clean after the checks" test -z "$(git -C "$ROOT" status --porcelain)"
expect "no key, container or policy file is tracked" \
	test -z "$(git -C "$ROOT" ls-files | { while IFS= read -r f; do case "$f" in *.pem | *.bin | *.policy) echo "$f" ;; esac; done; })"

finish
