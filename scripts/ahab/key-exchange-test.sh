#!/usr/bin/env bash
# key-exchange-test.sh: build and verify a key_exchange_req signed message for
# the i.MX 95 B0 (mimx9596 b0) on a throwaway test SRK set (issue #163,
# docs/oem-key-provisioning/key-exchange-msg.md).
#
#   key-exchange-test.sh        generate four ECDSA P-384 test SRKs and a fifth,
#                               foreign key in a mktemp -d work directory
#                               outside the clone, build the message with
#                               nxpimage signed-msg export, verify it with
#                               nxpimage signed-msg verify, then check that a
#                               tampered signature and a message signed by a key
#                               outside the SRK table are rejected. The work
#                               directory, keys included, is removed on exit.
#
# This exercises the message format only. Nothing is sent to a device: no
# board, no blhost, no fuse, no life-cycle step. The message holds no ECDH key
# (oem_private_key and nxp_prod_ka_pub are left out) and the test SRK set
# belongs to this run only. The SPSDK venv comes from spsdk-venv.sh (pinned).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

die() {
	echo "key-exchange-test: $*" >&2
	exit 1
}

venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
nxpcrypto=$venv/bin/nxpcrypto

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) die "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

for i in 0 1 2 3 4; do
	"$nxpcrypto" key generate -k secp384r1 -o "$work/srk$i.pem" >/dev/null 2>"$work/keygen.log" ||
		{ tail -n 3 "$work/keygen.log" >&2; die "nxpcrypto key generate failed for srk$i"; }
done

# config <signer pem> <output name>: the key_exchange_req configuration. The
# fields are the template's (nxpimage signed-msg get-template -m
# key_exchange_req) with test values only.
config() {
	cat >"$work/$2.yaml" <<EOF
family: $FAMILY
revision: $REVISION
output: $2.bin
container_version: 2
srk_set: oem
used_srk_id: 0
srk_revoke_mask: 0
fuse_version: 0
sw_version: 0
check_all_signatures: default
signer: type=file;file_path=$1
srk_table:
  flag_ca: false
  hash_algorithm: default
  srk_array:
    - srk0.pem
    - srk1.pem
    - srk2.pem
    - srk3.pem
message:
  issue_date: 2026-11
  uuid: '00000000000000000000000000000000'
  flags: 0
  command:
    KEY_EXCHANGE_REQ:
      key_store_id: 0
      key_exchange_algorithm: ECDH HKDF SHA256 KEY IMPORT
      salt_flags: 0
      derived_key_grp: 0
      derived_key_size_bits: 256
      derived_key_type: AES
      derived_key_lifetime: PERSISTENT
      derived_key_usage:
        - Cache
        - Derive
      derived_key_permitted_algorithm: HKDF SHA256
      derived_key_lifecycle: CURRENT
      derived_key_id: 0
      private_key_id: 0
      input_peer_public_key_digest: '0x0000000000000000000000000000000000000000000000000000000000000000'
      input_user_fixed_info_digest: '0x0000000000000000000000000000000000000000000000000000000000000000'
EOF
}

verify() { (cd "$work" && "$nxpimage" signed-msg verify -f "$FAMILY" -r "$REVISION" -b "$1") >"$work/verify.log" 2>&1; }

# The set's own SRK 0 signs.
config srk0.pem msg
(cd "$work" && "$nxpimage" signed-msg export -c msg.yaml) >"$work/export.log" 2>&1 ||
	{ tail -n 5 "$work/export.log" >&2; die "nxpimage signed-msg export failed"; }
[ -s "$work/msg.bin" ] || die "nxpimage signed-msg export wrote no msg.bin"
ok "message built"
if verify msg.bin; then ok "message verifies"; else tail -n 3 "$work/verify.log" >&2; bad "message does not verify"; fi

# tamper <offset> <name>: copy msg.bin with the byte at <offset> set to 0xff
# (or 0x00 when it already is 0xff).
tamper() {
	cp "$work/msg.bin" "$work/$2.bin"
	cur=$(od -An -tu1 -j "$1" -N 1 "$work/msg.bin" | tr -d ' ')
	if [ "$cur" = 255 ]; then
		printf '\000' | dd of="$work/$2.bin" bs=1 seek="$1" conv=notrunc 2>/dev/null
	else
		printf '\377' | dd of="$work/$2.bin" bs=1 seek="$1" conv=notrunc 2>/dev/null
	fi
}
size=$(wc -c <"$work/msg.bin")
[ "$size" -gt 600 ] || die "the message is only $size bytes"

# u16 <file> <offset>: little-endian 16-bit value.
u16() {
	local lo hi
	read -r lo hi < <(od -An -tu1 -j "$2" -N 2 "$1")
	echo $((lo + hi * 256))
}
# Offsets come from the message itself: the container header (byte 12) gives the
# signature block, whose header gives the SRK table (+6) and the signature (+8).
block=$(u16 "$work/msg.bin" 12)
srk_off=$((block + $(u16 "$work/msg.bin" $((block + 6)))))
sig_off=$((block + $(u16 "$work/msg.bin" $((block + 8)))))
{ [ "$block" -gt 16 ] && [ "$srk_off" -gt "$block" ] && [ "$sig_off" -gt "$srk_off" ] &&
	[ $((sig_off + 8 + 96)) -le "$size" ]; } ||
	die "implausible offsets in the message header ($block $srk_off $sig_off, size $size)"
body_off=$((16 + (block - 16) / 2))
echo "offsets from the header: signature block $block, SRK table $srk_off, signature $sig_off, size $size"
sig_data_off=$((sig_off + 8 + 10)) # a byte inside the r value of the signature
tamper "$((srk_off + 20))" tampered-srk-table
if verify tampered-srk-table.bin; then bad "tampered srk-table accepted"; else ok "tampered srk-table rejected"; fi
# A flipped byte inside the message body (the command fields) is not rejected by
# SPSDK verify; the signature covers it, which the independent check below shows.
tamper "$body_off" tampered-body
if verify tampered-body.bin; then ok "SPSDK verify accepts a flipped body byte (the signature check below rejects it)"; else ok "SPSDK verify rejects a flipped body byte"; fi

# The signature is checked independently of SPSDK: nxpimage signed-msg verify of
# the pinned SPSDK accepted a flipped signature byte (see
# docs/oem-key-provisioning/key-exchange-msg.md).
sigcheck() { "$venv/bin/python" -I "$here/msg-sig-check.py" "$1" "$2" >"$work/sigcheck.log" 2>&1; }
if sigcheck "$work/msg.bin" "$work/srk0.pub"; then ok "signature valid (independent check)"; else tail -n 3 "$work/sigcheck.log" >&2; bad "signature of the message is not valid"; fi
tamper "$sig_data_off" tampered-signature
if sigcheck "$work/tampered-signature.bin" "$work/srk0.pub"; then bad "flipped signature byte accepted by the independent check"; else ok "flipped signature byte rejected (independent check)"; fi
tamper "$body_off" tampered-body-sig
if sigcheck "$work/tampered-body-sig.bin" "$work/srk0.pub"; then bad "flipped body byte accepted by the independent check"; else ok "flipped body byte rejected (independent check)"; fi
if sigcheck "$work/msg.bin" "$work/srk1.pub"; then bad "signature accepted under another SRK"; else ok "signature rejected under another SRK"; fi

# A message signed under another SRK set. parse writes the SRK hash of the
# table inside the message; srk-hash-check must agree with it for the right
# set, and the other set's message must not match the first set's hash.
parse_hash() { # parse_hash <bin> <dir>
	mkdir "$work/$2"
	"$nxpimage" signed-msg parse -f "$FAMILY" -r "$REVISION" -b "$work/$1" -o "$work/$2" >"$work/parse.log" 2>&1 ||
		{ tail -n 3 "$work/parse.log" >&2; die "nxpimage signed-msg parse failed"; }
	tr -d '[:space:]' <"$work/$2/oem_srk0_hash.txt"
}
hash_a=$(parse_hash msg.bin parsed-a)
printf '%s\n' "$hash_a" >"$work/hash-a.txt"
check=$here/srk-hash-check.sh
pubs=("$work/srk0.pub" "$work/srk1.pub" "$work/srk2.pub" "$work/srk3.pub")
if "$check" "$work/hash-a.txt" "${pubs[@]}" >"$work/check.log" 2>&1; then ok "message SRK hash matches its set"; else tail -n 3 "$work/check.log" >&2; bad "message SRK hash differs from its set"; fi

# Set B: SRK 0 replaced by the foreign key, which signs.
cfgb=$(<"$work/msg.yaml")
cfgb=${cfgb//srk0.pem/srk4.pem}
cfgb=${cfgb//output: msg.bin/output: msgb.bin}
printf '%s\n' "$cfgb" >"$work/msgb.yaml"
(cd "$work" && "$nxpimage" signed-msg export -c msgb.yaml) >"$work/exportb.log" 2>&1 ||
	{ tail -n 5 "$work/exportb.log" >&2; die "export of the second set's message failed"; }
if verify msgb.bin; then ok "second set's message verifies on its own"; else bad "second set's message does not verify"; fi
hash_b=$(parse_hash msgb.bin parsed-b)
if [ "$hash_b" != "$hash_a" ]; then ok "second set has another SRK hash"; else bad "second set has the same SRK hash"; fi
rc=0
"$check" "$work/hash-a.txt" "$work/srk4.pub" "${pubs[@]:1}" >"$work/check.log" 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then ok "message of another SRK set does not match the expected hash"; else bad "other set: srk-hash-check exit $rc, want 1"; fi

[ "$fails" -eq 0 ] || die "$fails FAILED"
echo "okp-keyexchange-test: OK"