#!/usr/bin/env bash
# srk-hash-check.sh: compare the SRK table hash of a set of public SRK
# certificates or keys with an expected value (issue #163,
# docs/oem-key-provisioning/srk-hash-check.md).
#
#   srk-hash-check.sh <expected-hash-file> <srk0> <srk1> <srk2> <srk3>
#
# <expected-hash-file> holds the expected hash as one hex string (128 digits,
# any case). The four SRK files are PEM public keys or PEM certificates, in
# SRK index order. A file that is not PEM, or that holds a private key of any
# kind, is refused. Prints "match" or "mismatch" and the computed hash.
# Exit: 0 match, 1 mismatch, 2 refused input or usage.
#
# The hash is the one SPSDK 3.13.0 (spsdk-venv.sh) computes for the i.MX 95 B0
# OEM SRK table. The script loads an AHAB configuration to get it: nothing is
# signed or exported, no fuse script is written, no fuse or life-cycle tool is
# called, and no fuse word layout is printed. Programming the hash is the
# owner's decision and is not done here.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
SRK_COUNT=4

refuse() {
	echo "srk-hash-check: $*" >&2
	exit 2
}

[ $# -eq $((SRK_COUNT + 1)) ] ||
	refuse "usage: srk-hash-check.sh <expected-hash-file> <srk0> <srk1> <srk2> <srk3> (exactly $SRK_COUNT SRK files, got $(($# - 1)))"
expected_file=$1
shift
[ -f "$expected_file" ] || refuse "no such expected-hash file: $expected_file"

# The expected value: one hex string of 128 digits (SHA-512, 64 bytes).
expected=$(tr -d '[:space:]' <"$expected_file" | tr 'a-f' 'A-F')
case "$expected" in
*[!0-9A-F]* | "") refuse "$expected_file is not a hex string" ;;
esac
[ ${#expected} -eq 128 ] || refuse "$expected_file holds ${#expected} hex digits; the SRK table hash has 128"

# Every input: a regular PEM file, public material only.
for f in "$@"; do
	[ -f "$f" ] || refuse "no such file: $f"
	pem=$(tr -d '\r' <"$f")
	case "$pem" in
	*PRIVATE\ KEY*) refuse "$f holds a private key; refused" ;;
	esac
	case "$pem" in
	*"-----BEGIN PUBLIC KEY-----"* | *"-----BEGIN CERTIFICATE-----"*) ;;
	*) refuse "$f is neither a PEM public key nor a PEM certificate; refused" ;;
	esac
done

venv=$("$here/spsdk-venv.sh")

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) refuse "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

i=0
for f in "$@"; do
	cp "$f" "$work/srk$i.pem"
	i=$((i + 1))
done

# SPSDK wants a signer to load a configuration; it is never used to sign. A
# throwaway key, born and deleted in the work directory, stands in.
"$venv/bin/nxpcrypto" key generate -k secp384r1 -o "$work/signer.pem" >/dev/null 2>"$work/keygen.log" ||
	{ tail -n 3 "$work/keygen.log" >&2; refuse "nxpcrypto key generate failed"; }

cat >"$work/srk.yaml" <<EOF
family: mimx9596
revision: b0
target_memory: standard
output: unused.bin
containers:
  - container:
      srk_set: oem
      used_srk_id: 0
      srk_revoke_mask: '0x00'
      fuse_version: 0
      sw_version: 0
      signer: type=file;file_path=signer.pem
      images: []
      srk_table:
        srk_array:
          - srk0.pem
          - srk1.pem
          - srk2.pem
          - srk3.pem
EOF

got=$(cd "$work" && "$venv/bin/python" -I "$here/srk-hash.py" srk.yaml 2>"$work/hash.log") ||
	{ tail -n 3 "$work/hash.log" >&2; refuse "SPSDK could not load the SRK set"; }
[ ${#got} -eq 128 ] || refuse "SPSDK returned an unexpected hash '$got'"

echo "SRK table hash: $got"
if [ "$got" = "$expected" ]; then
	echo "srk-hash-check: match"
else
	echo "srk-hash-check: mismatch (expected $expected)"
	exit 1
fi
