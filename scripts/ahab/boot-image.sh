#!/usr/bin/env bash
# boot-image.sh: assemble the i.MX 95 B0 boot image on a throwaway test PKI,
# verify every container and tamper-test every signed payload
# (docs/boot-container/boot-image.md; PROVISIONAL).
#
#   boot-image.sh [--inputs DIR] [--out DIR] [--policy-out FILE]
#       --inputs  a directory written by scripts/boot-image-inputs.sh --collect
#                 (m33_image.bin, m7_image.bin, bl31.bin, tee.bin, u-boot.bin,
#                 ele.bin, inputs.txt). Default: collect one into the work
#                 directory with that script's defaults (stand-ins where an
#                 input is not built).
#       --out     where boot-image.bin, inputs.txt and SHA256SUMS go (default
#                 out/boot-image, git-ignored). Never a key.
#       --policy-out  also copy the policy file the whole-image check used (the
#                 test-PKI SRK table hash and values read from the image) to FILE.
#   boot-image.sh verify <image>
#       nxpimage ahab verify of <image>: "verify: OK" and exit 0, or
#       "verify: FAILED" and exit 1.
#
# The build generates four ECDSA P-384 test SRKs in a mktemp -d directory
# outside the clone, signs three OEM containers (boot-image.yaml), runs
# nxpimage ahab verify on the image and checks that each of the three
# containers authenticates, that the payloads nxpimage ahab parse extracts are
# the inputs byte for byte, runs scripts/ahab/policy-check.sh on the whole image
# against boot-image-manifest.yaml (it must print policy: OK), then flips one byte
# in each signed payload, each container header and each signature block and
# requires verification to fail every time. The work directory is deleted on
# exit. The .bcf fuse script nxpimage writes is deleted unread and never run.
# No board, no fuse, no life cycle, no block device.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0
CONTAINERS=3
# The signed payloads, in image order (the order of boot-image.yaml).
PAYLOADS="ele.bin m33_image.bin m7_image.bin bl31.bin u-boot.bin tee.bin"

die() {
	echo "boot-image: $*" >&2
	exit 1
}

venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
nxpcrypto=$venv/bin/nxpcrypto
py=$venv/bin/python

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) die "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

# verify <image> [log]: 0 when nxpimage ahab verify accepts the image.
verify() {
	local log=${2:-$work/verify.log}
	[ -f "$1" ] || die "verify: no such file: $1"
	if (cd "$work" && "$nxpimage" ahab verify -f "$FAMILY" -r "$REVISION" -b "$1") >"$log" 2>&1; then
		return 0
	fi
	return 1
}

# count_in <file> <substring>: the number of lines holding <substring>.
count_in() {
	local n=0 l
	while IFS= read -r l; do [[ "$l" != *"$2"* ]] || n=$((n + 1)); done <"$1"
	echo "$n"
}

if [ "${1:-}" = verify ]; then
	[ $# -eq 2 ] || die "usage: boot-image.sh verify <image>"
	if verify "$(realpath "$2")"; then
		echo "verify: OK ($2)"
		exit 0
	fi
	tail -n 3 "$work/verify.log" >&2
	echo "verify: FAILED ($2)"
	exit 1
fi

inputs=
policy_out=
out=$root/out/boot-image
while [ $# -gt 0 ]; do
	case "$1" in
	--inputs)
		[ $# -ge 2 ] || die "--inputs needs a directory"
		inputs=$2
		shift
		;;
	--out)
		[ $# -ge 2 ] || die "--out needs a directory"
		out=$2
		shift
		;;
	--policy-out)
		[ $# -ge 2 ] || die "--policy-out needs a file"
		policy_out=$2
		shift
		;;
	*) die "usage: boot-image.sh [--inputs DIR] [--out DIR] [--policy-out FILE] | verify <image>" ;;
	esac
	shift
done

if [ -z "$inputs" ]; then
	inputs=$work/inputs
	"$root/scripts/boot-image-inputs.sh" --collect "$inputs" >/dev/null
fi
for f in $PAYLOADS inputs.txt; do
	[ -s "$inputs/$f" ] || die "the inputs directory has no $f: $inputs"
done

"$nxpimage" --version 2>/dev/null
cp "$here/boot-image.yaml" "$work/"
for f in $PAYLOADS; do cp "$inputs/$f" "$work/$f"; done

# Before anything is signed: every payload copied for signing must be the one
# inputs.txt recorded ("name real|STAND-IN sha256"), one entry per payload and
# no other. A payload changed after collection is refused.
declare -A recorded=()
while read -r name label digest extra; do
	[ -n "$name" ] || continue
	[ -z "$extra" ] || die "inputs.txt: malformed line for $name"
	case " $PAYLOADS " in *" $name "*) ;; *) die "inputs.txt names $name, which is not a payload" ;; esac
	[ -z "${recorded[$name]+set}" ] || die "inputs.txt lists $name twice"
	case "$label" in real | STAND-IN) ;; *) die "inputs.txt: $name has label $label, want real or STAND-IN" ;; esac
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "inputs.txt: $name has no SHA-256"
	recorded[$name]=$digest
done <"$inputs/inputs.txt"
for f in $PAYLOADS; do
	[ -n "${recorded[$f]+set}" ] || die "inputs.txt has no entry for $f"
	got=$(sha256sum "$work/$f" | cut -d' ' -f1)
	[ "$got" = "${recorded[$f]}" ] ||
		die "the payload $f is $got, inputs.txt records ${recorded[$f]}: changed since collection, nothing signed"
done
for i in 0 1 2 3; do
	# Writes srk$i.pem (the private key) and srk$i.pub, both in $work only.
	"$nxpcrypto" key generate -k secp384r1 -o "$work/srk$i.pem" >/dev/null 2>"$work/keygen.log" ||
		{ cat "$work/keygen.log" >&2; die "nxpcrypto key generate failed for srk$i"; }
	[ -s "$work/srk$i.pub" ] || die "nxpcrypto wrote no srk$i.pub"
done

(cd "$work" && "$nxpimage" ahab export -c boot-image.yaml) >"$work/export.log" 2>&1 ||
	{ tail -n 5 "$work/export.log" >&2; die "nxpimage ahab export failed"; }
# The fuse script is for a real device's fuses: delete it, never run it.
rm -f "$work"/*.bcf
image=$work/boot-image.bin
[ -s "$image" ] || die "nxpimage ahab export wrote no boot-image.bin"

# 1. Every container verifies.
verify "$image" || { tail -n 5 "$work/verify.log" >&2; die "verify FAILED for the assembled image"; }
[ "$(count_in "$work/verify.log" "Overall  result: Succeeded")" -eq 1 ] || die "verify did not report an overall success"
n=$(count_in "$work/verify.log" "Container authenticity(Succeeded): oem, Signed by OEM keys")
[ "$n" -eq "$CONTAINERS" ] || die "$n containers authenticate against the OEM test SRK, want $CONTAINERS"
n=$(count_in "$work/verify.log" "Signature #0(Succeeded)")
[ "$n" -eq "$CONTAINERS" ] || die "$n container signatures verify, want $CONTAINERS"
echo "verify: OK, $CONTAINERS of $CONTAINERS containers authenticate (test SRK)"

# 2. The payloads parsed back out of the image are the inputs, byte for byte.
mkdir "$work/parsed"
"$nxpimage" ahab parse -f "$FAMILY" -r "$REVISION" -b "$image" -o "$work/parsed" >"$work/parse.log" 2>&1 ||
	{ tail -n 5 "$work/parse.log" >&2; die "nxpimage ahab parse failed"; }
rm -f "$work"/parsed/*.bcf
parsed=("$work"/parsed/container*_image*.bin)
[ "${#parsed[@]}" -eq 6 ] || die "nxpimage ahab parse wrote ${#parsed[@]} payloads, want 6"
i=0
for f in $PAYLOADS; do
	# SPSDK pads the System Manager, BL31, U-Boot and tee entries to its 1 KiB
	# alignment (the U-Boot padding is not all zero bytes): the input must be
	# the prefix of the parsed payload.
	"$py" -I - "${parsed[$i]}" "$inputs/$f" <<'PY' ||
import sys
got = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
sys.exit(0 if got[: len(want)] == want else 1)
PY
		die "the payload ${parsed[$i]##*/} differs from the input $f"
	i=$((i + 1))
done
echo "parse: OK, 6 payloads equal their inputs"

# The SRK table hash belongs to this test PKI only.
hash_file=$work/ahab_oem_srk0_hash.txt
[ -s "$hash_file" ] || die "nxpimage ahab export wrote no $(basename "$hash_file")"

# 2b. The whole image against its own manifest (scripts/ahab/policy-check.sh,
# scripts/ahab/boot-image-manifest.yaml). The policy file holds the test-PKI
# hash and values read from the image: each _IMAGE_SHA256 is the sha256 of the
# payload as parsed (SPSDK pads it, so it is not the inputs.txt digest; step 2
# tied the parse to the input). The ele, M7 and tee addresses are boot-image.yaml's;
# the System Manager, BL31 and U-Boot entries are SPSDK shorthands that carry no
# address in boot-image.yaml, so theirs are read from the parse. layout.txt
# holds one "C <k> <header offset> <header length> <signature offset>
# <signature length>" line per container, from the parse, for the tamper step.
policy=$work/policy.txt
"$py" -I - "$image" "$work/boot-image.yaml" "$hash_file" "$policy" "$work/layout.txt" <<'PY' ||
import hashlib
import sys

import yaml
from spsdk.image.ahab.ahab_image import AHABImage
from spsdk.utils.family import FamilyRevision

image, cfg, hash_file, policy, layout = sys.argv[1:6]
data = open(image, "rb").read()
off = AHABImage.find_offset_of_ahab(data, True)
img = AHABImage.parse(data[off:], FamilyRevision("mimx9596", "b0"))
conf = yaml.safe_load(open(cfg))["containers"]
# (policy name, container, image, "yaml" or "parse")
entries = [("ELE", 0, 0, "yaml"), ("SYSMGR", 1, 0, "parse"), ("M7", 1, 1, "yaml"),
           ("ATF", 2, 0, "parse"), ("UBOOT", 2, 1, "parse"), ("TEE", 2, 2, "yaml")]
lines = [
    "SRK_TABLE_HASH=" + "".join(open(hash_file).read().split()),
    "USED_SRK_ID=0",
    "SRK_REVOKE_MASK=0",
    "FUSE_VERSION_MIN=0",
]
for name, k, j, src in entries:
    c = img.ahab_containers[k]
    i = c.image_array[j]
    seg = data[off + i.image_offset:off + i.image_offset + i.image_size]
    if src == "yaml":
        y = conf[k]["container"]["images"][j]
        load, entry = int(str(y["load_address"]), 16), int(str(y["entry_point"]), 16)
    else:
        load, entry = int(i.load_address), int(i.entry_point)
    lines.append("%s_IMAGE_SHA256=%s" % (name, hashlib.sha256(seg).hexdigest()))
    lines.append("%s_LOAD_ADDRESS=0x%x" % (name, load))
    lines.append("%s_ENTRY_POINT=0x%x" % (name, entry))
# policy-check.sh needs the vendor record too: the image has no nxp container,
# so these keys are inert placeholders of the right shape, not a value for any device.
lines += ["NXP_SRK_TABLE_HASH=00", "NXP_USED_SRK_ID=0", "NXP_SRK_REVOKE_MASK=0", "NXP_FUSE_VERSION=0"]
open(policy, "w").write("\n".join(lines) + "\n")
out = []
for k, c in enumerate(img.ahab_containers):
    h = off + c.get_container_offset(k)
    hl = c._signature_block_offset
    out.append("C %d %d %d %d %d" % (k, h, hl, h + hl, c.signature_block.length))
open(layout, "w").write("\n".join(out) + "\n")
PY
	die "cannot write the policy file from the image"
"$here/policy-check.sh" "$image" "$policy" "$here/boot-image-manifest.yaml" >"$work/policy.log" 2>&1 ||
	{ tail -n 5 "$work/policy.log" >&2; die "policy-check FAILED for the assembled image"; }
[ "$(tail -n 1 "$work/policy.log")" = "policy: OK" ] || die "policy-check did not end with policy: OK"
echo "policy: OK"
if [ -n "$policy_out" ]; then
	cp "$policy" "$policy_out"
fi

# 3. Tamper test: one flipped byte in each signed payload must fail verify.
for f in $PAYLOADS; do
	"$py" -I - "$image" "$work/$f" "$work/tampered.bin" <<'PY' || die "cannot place $f in the image"
import sys
image, payload, out = sys.argv[1:4]
d = bytearray(open(image, "rb").read())
p = open(payload, "rb").read()
off = d.find(p)
if off < 0 or d.find(p, off + 1) >= 0:
    sys.exit(1)
d[off + len(p) // 2] ^= 0xFF
open(out, "wb").write(d)
PY
	if verify "$work/tampered.bin" "$work/tamper.log"; then
		die "tamper: verify ACCEPTED an image with one flipped byte in $f"
	fi
	echo "tamper: $f, one flipped byte: verify FAILED as required"
done

# One flipped byte in each container header (past the 4-byte tag word) and in
# each signature block: offsets from the parse (layout.txt), not a byte scan.
while read -r tag k hoff _ soff slen; do
	[ "$tag" = C ] || continue
	for spec in "header:$((hoff + 20))" "signature block:$((soff + slen / 2))"; do
		what=${spec%%:*}
		at=${spec##*:}
		"$py" -I - "$image" "$work/tampered.bin" "$at" <<'PY' || die "cannot flip byte $at"
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[int(sys.argv[3])] ^= 0xFF
open(sys.argv[2], "wb").write(d)
PY
		if verify "$work/tampered.bin" "$work/tamper.log"; then
			die "tamper: verify ACCEPTED an image with one flipped byte in the $what of container $k"
		fi
		echo "tamper: container $k $what, one flipped byte: verify FAILED as required"
	done
done <"$work/layout.txt"

# The SRK table hash belongs to this test PKI only.
echo "SRK table hash (test PKI only): $(tr -d '[:space:]' <"$hash_file")"
echo "  This hash belongs to a throwaway test PKI. It is not a value for any device's fuses."

mkdir -p "$out"
cp "$image" "$out/boot-image.bin"
cp "$inputs/inputs.txt" "$out/inputs.txt"
(cd "$out" && sha256sum boot-image.bin inputs.txt >SHA256SUMS)
echo "image: $out/boot-image.bin"
n=$(count_in "$out/inputs.txt" STAND-IN)
if [ "$n" -gt 0 ]; then
	echo "STAND-IN payloads in this image: $n (see $out/inputs.txt)"
fi
echo "boot-image-test: OK"
