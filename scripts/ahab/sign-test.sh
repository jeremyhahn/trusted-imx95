#!/usr/bin/env bash
# sign-test.sh: the host-side AHAB signing pipeline on a throwaway test PKI
# (issue #9, docs/boot-container/signing-pipeline.md).
#
#   sign-test.sh            generate four ECDSA P-384 test SRKs in a mktemp -d
#                           work directory outside the clone, build and sign an
#                           i.MX 95 B0 (mimx9596 b0) AHAB container around a
#                           random payload (container.yaml), verify it, print
#                           the test SRK table hash, and remove the work
#                           directory. AHAB_OUT_DIR, if set, receives a copy of
#                           container.bin (the container only, never a key).
#   sign-test.sh verify <bin>
#                           nxpimage ahab verify of <bin>: prints "verify: OK"
#                           and exits 0, or "verify: FAILED" and exits 1.
#
# The SPSDK venv comes from spsdk-venv.sh (SPSDK_VENV, pinned 3.13.0). No real
# key, no HSM, no fuse: the .bcf fuse script nxpimage ahab export writes is
# deleted unread and never run, and the printed SRK table hash belongs to this
# test PKI only.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

die() {
	echo "sign-test: $*" >&2
	exit 1
}

venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
nxpcrypto=$venv/bin/nxpcrypto

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) die "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

# verify <bin>: 0 when nxpimage ahab verify accepts <bin>.
verify() {
	[ -f "$1" ] || die "verify: no such file: $1"
	if (cd "$work" && "$nxpimage" ahab verify -f "$FAMILY" -r "$REVISION" -b "$1") >"$work/verify.log" 2>&1; then
		echo "verify: OK ($1)"
	else
		tail -n 3 "$work/verify.log" >&2
		echo "verify: FAILED ($1)"
		return 1
	fi
}

case "${1:-}" in
verify)
	[ $# -eq 2 ] || die "usage: sign-test.sh verify <container.bin>"
	verify "$(realpath "$2")"
	exit
	;;
"") mode=sign ;;
m7)
	mode=m7
	[ $# -le 2 ] || die "usage: sign-test.sh m7 [<payload file>]"
	payload_src=${2:-}
	[ -z "$payload_src" ] || [ -f "$payload_src" ] || die "m7: no such payload file: $payload_src"
	[ -z "$payload_src" ] || payload_src=$(realpath "$payload_src")
	;;
*) die "usage: sign-test.sh [verify <container.bin> | m7 [<payload file>]]" ;;
esac

"$nxpimage" --version 2>/dev/null

cfg=container.yaml
out=container.bin
if [ "$mode" = m7 ]; then
	cfg=m7-container.yaml
	out=m7-container.bin
fi
cp "$here/$cfg" "$work/"
for i in 0 1 2 3; do
	# Writes srk$i.pem (the private key) and srk$i.pub, both in $work only.
	"$nxpcrypto" key generate -k secp384r1 -o "$work/srk$i.pem" >/dev/null 2>"$work/keygen.log" ||
		{ cat "$work/keygen.log" >&2; die "nxpcrypto key generate failed for srk$i"; }
	[ -s "$work/srk$i.pub" ] || die "nxpcrypto wrote no srk$i.pub"
done
if [ "$mode" = m7 ] && [ -n "$payload_src" ]; then
	cp "$payload_src" "$work/payload.bin"
else
	# The default M7 stand-in is a 4 KiB random blob, not an ELF.
	head -c 4096 /dev/urandom >"$work/payload.bin"
fi

(cd "$work" && "$nxpimage" ahab export -c "$cfg") >"$work/export.log" 2>&1 ||
	{ tail -n 5 "$work/export.log" >&2; die "nxpimage ahab export failed"; }
# The fuse script is for a real device's fuses: delete it, never run it.
rm -f "$work"/*.bcf
[ -s "$work/$out" ] || die "nxpimage ahab export wrote no $out"

verify "$work/$out"

if [ "$mode" = m7 ]; then
	# Print the image entry's fields from nxpimage ahab parse (the parse
	# output is kept in the work directory only).
	mkdir "$work/parsed"
	"$nxpimage" ahab parse -f "$FAMILY" -r "$REVISION" -b "$work/$out" -o "$work/parsed" >"$work/parse.log" 2>&1 ||
		{ tail -n 5 "$work/parse.log" >&2; die "nxpimage ahab parse failed"; }
	rm -f "$work"/parsed/*.bcf
	pcfg=$(ls "$work"/parsed/*.yaml 2>/dev/null | head -n 1) || true
	[ -n "$pcfg" ] || die "nxpimage ahab parse wrote no yaml configuration"
	echo "M7 image entry (nxpimage ahab parse):"
	for f in core_id load_address entry_point image_type hash_type; do
		line=$(tr -d '\r' <"$pcfg" | while IFS= read -r l; do case "$l" in *"$f:"*) echo "$l" ;; esac; done | head -n 1)
		[ -n "$line" ] || die "nxpimage ahab parse reports no $f"
		echo "  $f: $(echo "${line#*:}" | tr -d " '\"")"
	done
fi

hash_file=$work/ahab_oem0_srk0_hash.txt
[ -s "$hash_file" ] || die "nxpimage ahab export wrote no $(basename "$hash_file")"
echo "SRK table hash (test PKI only): $(tr -d '[:space:]' <"$hash_file")"
echo "  This hash belongs to a throwaway test PKI. It is not a value for any device's fuses."

if [ -n "${AHAB_OUT_DIR:-}" ]; then
	mkdir -p "$AHAB_OUT_DIR"
	cp "$work/$out" "$AHAB_OUT_DIR/$out"
	echo "container: $AHAB_OUT_DIR/$out"
fi
if [ "$mode" = m7 ]; then echo "ahab-m7-test: OK"; else echo "ahab-sign-test: OK"; fi
