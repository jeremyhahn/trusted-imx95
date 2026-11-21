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
"") ;;
*) die "usage: sign-test.sh [verify <container.bin>]" ;;
esac

"$nxpimage" --version 2>/dev/null

cp "$here/container.yaml" "$work/"
for i in 0 1 2 3; do
	# Writes srk$i.pem (the private key) and srk$i.pub, both in $work only.
	"$nxpcrypto" key generate -k secp384r1 -o "$work/srk$i.pem" >/dev/null 2>"$work/keygen.log" ||
		{ cat "$work/keygen.log" >&2; die "nxpcrypto key generate failed for srk$i"; }
	[ -s "$work/srk$i.pub" ] || die "nxpcrypto wrote no srk$i.pub"
done
head -c 4096 /dev/urandom >"$work/payload.bin"

(cd "$work" && "$nxpimage" ahab export -c container.yaml) >"$work/export.log" 2>&1 ||
	{ tail -n 5 "$work/export.log" >&2; die "nxpimage ahab export failed"; }
# The fuse script is for a real device's fuses: delete it, never run it.
rm -f "$work"/*.bcf
[ -s "$work/container.bin" ] || die "nxpimage ahab export wrote no container.bin"

verify "$work/container.bin"

hash_file=$work/ahab_oem0_srk0_hash.txt
[ -s "$hash_file" ] || die "nxpimage ahab export wrote no $(basename "$hash_file")"
echo "SRK table hash (test PKI only): $(tr -d '[:space:]' <"$hash_file")"
echo "  This hash belongs to a throwaway test PKI. It is not a value for any device's fuses."

if [ -n "${AHAB_OUT_DIR:-}" ]; then
	mkdir -p "$AHAB_OUT_DIR"
	cp "$work/container.bin" "$AHAB_OUT_DIR/container.bin"
	echo "container: $AHAB_OUT_DIR/container.bin"
fi
echo "ahab-sign-test: OK"
