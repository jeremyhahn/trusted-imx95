#!/usr/bin/env bash
# boot-image.sh: assemble the i.MX 95 B0 boot image on a throwaway test PKI,
# verify every container and tamper-test every signed payload
# (docs/boot-container/boot-image.md; PROVISIONAL).
#
#   boot-image.sh [--inputs DIR] [--out DIR]
#       --inputs  a directory written by scripts/boot-image-inputs.sh --collect
#                 (m33_image.bin, m7_image.bin, bl31.bin, tee.bin, u-boot.bin,
#                 ele.bin, inputs.txt). Default: collect one into the work
#                 directory with that script's defaults (stand-ins where an
#                 input is not built).
#       --out     where boot-image.bin, inputs.txt and SHA256SUMS go (default
#                 out/boot-image, git-ignored). Never a key.
#   boot-image.sh verify <image>
#       nxpimage ahab verify of <image>: "verify: OK" and exit 0, or
#       "verify: FAILED" and exit 1.
#
# The build generates four ECDSA P-384 test SRKs in a mktemp -d directory
# outside the clone, signs three OEM containers (boot-image.yaml), runs
# nxpimage ahab verify on the image and checks that each of the three
# containers authenticates, that the payloads nxpimage ahab parse extracts are
# the inputs byte for byte, then flips one byte in each signed payload and
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
	*) die "usage: boot-image.sh [--inputs DIR] [--out DIR] | verify <image>" ;;
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

# The SRK table hash belongs to this test PKI only.
hash_file=$work/ahab_oem_srk0_hash.txt
[ -s "$hash_file" ] || die "nxpimage ahab export wrote no $(basename "$hash_file")"
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
