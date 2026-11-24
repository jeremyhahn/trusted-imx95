#!/usr/bin/env bash
# key-import-test.sh: build, parse and verify a key_import TLV blob (a wrapped
# key) for the i.MX 95 B0 (mimx9596 b0) on throwaway test keys (issue #163,
# docs/oem-key-provisioning/key-import-tlv.md).
#
#   key-import-test.sh          generate, in a mktemp -d work directory outside
#                               the clone, two P-256 keys (one stands in for the
#                               device key-agreement key), a fresh 32-byte test
#                               key and a test MK_SK from their ECDH; build the
#                               blob with nxpimage signed-msg tlv export, parse
#                               and verify it with SPSDK, check the CMAC and the
#                               wrapped key independently, and check that a
#                               flipped CMAC byte, a flipped ciphertext byte and
#                               a different MK_SK are rejected. The work
#                               directory, keys included, is removed on exit.
#
# Nothing is sent to a device and nothing here is a production import path: no
# board, no blhost, no fuse, no life-cycle step. The key-agreement key is a
# throwaway P-256 key, not a device key. The SPSDK venv comes from spsdk-venv.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

die() {
	echo "key-import-test: $*" >&2
	exit 1
}

venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
nxpcrypto=$venv/bin/nxpcrypto
tool() { "$venv/bin/python" -I "$here/key-import-check.py" "$@"; }

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) die "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

for k in device oem other; do
	"$nxpcrypto" key generate -k secp256r1 -o "$work/$k.pem" >/dev/null 2>"$work/keygen.log" ||
		{ tail -n 3 "$work/keygen.log" >&2; die "nxpcrypto key generate failed for $k"; }
done
head -c 32 /dev/urandom >"$work/raw.bin"

# The test MK_SK: ECDH of the two throwaway keys, from either side.
tool derive "$work/oem.pem" "$work/device.pub" >"$work/mksk.hex" || die "derive failed"
tool derive "$work/device.pem" "$work/oem.pub" >"$work/mksk-device.hex" || die "derive (device side) failed"
if cmp -s "$work/mksk.hex" "$work/mksk-device.hex"; then ok "both sides derive the same test MK_SK"; else bad "the two sides derive different values"; fi
tool derive "$work/other.pem" "$work/device.pub" >"$work/mksk-other.hex" || die "derive (other) failed"

mksk=$(<"$work/mksk.hex")
cat >"$work/tlv.yaml" <<EOF
family: $FAMILY
revision: $REVISION
output: tlv.bin
command:
  KEY_IMPORT:
    key_id: 0
    permitted_algorithm: CMAC
    key_usage:
      - Cache
      - Sign message
    key_type: AES
    key_size_bits: 256
    key_lifetime: ELE_KEY_IMPORT_PERSISTENT
    key_lifecycle: CURRENT
    oem_mk_sk_key_id: 0
    key_wrapping_algorithm: RFC3394
    signing_algorithm: CMAC
    import_key: raw.bin
    oem_import_mk_sk_key: '0x$mksk'
EOF

(cd "$work" && "$nxpimage" signed-msg tlv export -c tlv.yaml) >"$work/export.log" 2>&1 ||
	{ tail -n 5 "$work/export.log" >&2; die "nxpimage signed-msg tlv export failed"; }
[ -s "$work/tlv.bin" ] || die "nxpimage signed-msg tlv export wrote no tlv.bin"
ok "blob built"

tlv_verify() { (cd "$work" && "$nxpimage" signed-msg tlv verify -f "$FAMILY" -r "$REVISION" -b "$1") >"$work/verify.log" 2>&1; }
if tlv_verify tlv.bin; then ok "blob verifies (SPSDK)"; else tail -n 3 "$work/verify.log" >&2; bad "blob does not verify"; fi

mkdir "$work/parsed"
if "$nxpimage" signed-msg tlv parse -f "$FAMILY" -r "$REVISION" -b "$work/tlv.bin" -o "$work/parsed" >"$work/parse.log" 2>&1; then
	ok "blob parses (SPSDK)"
else
	tail -n 3 "$work/parse.log" >&2
	bad "blob does not parse"
fi

size=$(wc -c <"$work/tlv.bin")
# The blob ends with the wrapped key (a TLV with a 2-byte header; 40 bytes for a
# 32-byte key under RFC 3394) and the CMAC TLV (2-byte header, 16 bytes).
wrapped_len=40
cmac_off=$((size - 16))
ct_off=$((size - 18 - wrapped_len + 2 + 10))
[ "$ct_off" -gt 0 ] || die "the blob is only $size bytes"
echo "offsets from the blob layout: ciphertext byte $ct_off, CMAC byte $cmac_off, size $size"

# SPSDK holds no key when it verifies, so the CMAC and the wrapped key are
# checked independently, with the MK_SK of the test.
if tool check "$work/tlv.bin" "$work/mksk.hex" "$work/raw.bin" >"$work/check.log" 2>&1; then
	ok "CMAC valid and the wrapped key unwraps to the raw key (independent check)"
else
	tail -n 3 "$work/check.log" >&2
	bad "independent check of the blob failed"
fi

# tamper <offset> <name>: copy tlv.bin with the byte at <offset> flipped.
tamper() {
	cp "$work/tlv.bin" "$work/$2.bin"
	cur=$(od -An -tu1 -j "$1" -N 1 "$work/tlv.bin" | tr -d ' ')
	if [ "$cur" = 255 ]; then
		printf '\000' | dd of="$work/$2.bin" bs=1 seek="$1" conv=notrunc 2>/dev/null
	else
		printf '\377' | dd of="$work/$2.bin" bs=1 seek="$1" conv=notrunc 2>/dev/null
	fi
}
rejected() { # rejected <what> <blob> <mksk file>
	local rc=0
	tool check "$2" "$3" "$work/raw.bin" >"$work/check.log" 2>&1 || rc=$?
	if [ "$rc" -eq 1 ]; then ok "$1 rejected"; else bad "$1: independent check exit $rc, want 1"; fi
}
tamper "$cmac_off" tampered-cmac
rejected "flipped CMAC byte" "$work/tampered-cmac.bin" "$work/mksk.hex"
tamper "$ct_off" tampered-ciphertext
rejected "flipped ciphertext byte" "$work/tampered-ciphertext.bin" "$work/mksk.hex"
rejected "blob under another MK_SK" "$work/tlv.bin" "$work/mksk-other.hex"
# What SPSDK verify does with the flipped blobs is recorded, not asserted: it
# holds no key, so it cannot check the CMAC.
for t in tampered-cmac tampered-ciphertext; do
	if tlv_verify "$t.bin"; then echo "info: SPSDK tlv verify accepts $t (no key to check against)"; else echo "info: SPSDK tlv verify rejects $t"; fi
done

[ "$fails" -eq 0 ] || die "$fails FAILED"
echo "okp-import-tlv-test: OK"
