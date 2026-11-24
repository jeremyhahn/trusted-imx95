#!/usr/bin/env bash
# collect-evidence.sh: compose the endorse-01 evidence bundle on the A55
# (proposed, pending owner approval; the order is owner ruling 1234).
#
#   ELE_ATTEST_CMD=<cmd> collect-evidence.sh --nonce HEX32 --response-version N \
#       --ek-handle 0x81HHHHHH --ek-template NAME -o OUT
#
# Order: (1) the enclave attestation through $ELE_ATTEST_CMD, (2) only if it
# succeeded, the fTPM EK public area with the read-only tpm2_readpublic,
# (3) compose the JSON bundle, no verification. No default for the enclave
# command or the handle. Never creates, clears or evicts anything in the TPM.
#
# ELE_ATTEST_CMD is run as: $ELE_ATTEST_CMD NONCE_HEX SIGNED_OUT SIGNATURE_OUT
# and must write the signed region and the 96-byte signature there, exit 0.
# No interpreter: the bundle is composed in shell with base64, tr, stat and od
# (the production image has no python3). --ek-template matches
# [A-Za-z0-9._-]{1,64}, refused with exit 2 before the enclave command runs.
set -euo pipefail

die() {
	echo "collect-evidence: $*" >&2
	exit 2
}

nonce= version= handle= template= out=
while [ $# -gt 0 ]; do
	case "$1" in
	--nonce | --response-version | --ek-handle | --ek-template | -o)
		[ $# -ge 2 ] || die "$1 needs a value"
		case "$1" in
		--nonce) nonce=$2 ;;
		--response-version) version=$2 ;;
		--ek-handle) handle=$2 ;;
		--ek-template) template=$2 ;;
		-o) out=$2 ;;
		esac
		shift 2
		;;
	*) die "usage: collect-evidence.sh --nonce HEX --response-version N --ek-handle 0xHHHHHHHH --ek-template S -o OUT" ;;
	esac
done

[ -n "$nonce" ] && [ -n "$version" ] && [ -n "$handle" ] && [ -n "$template" ] && [ -n "$out" ] ||
	die "usage: collect-evidence.sh --nonce HEX --response-version N --ek-handle 0xHHHHHHHH --ek-template S -o OUT"
[ -n "${ELE_ATTEST_CMD:-}" ] || die "ELE_ATTEST_CMD is not set (no default)"
[[ "$nonce" =~ ^[0-9a-fA-F]{32}$ ]] || die "--nonce must be 32 hex digits"
[[ "$version" =~ ^[23]$ ]] || die "--response-version must be 2 or 3 (decimal)"
[[ "$handle" =~ ^0x81[0-9a-fA-F]{6}$ ]] || die "--ek-handle must be in 0x81000000-0x81FFFFFF"
# Shell cannot JSON-escape safely, so the template is restricted (proposed,
# pending owner approval; B5 stays open).
[[ "$template" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--ek-template must match [A-Za-z0-9._-]{1,64}"

[ ! -d "$out" ] || die "$out is a directory (or a link to one); -o names a file"

work=$(mktemp -d)
tmp=
trap 'rm -rf "$work"; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT

# 1. Enclave attestation first (ruling 1234).
# shellcheck disable=SC2086 # the command may carry its own arguments
$ELE_ATTEST_CMD "$nonce" "$work/signed.bin" "$work/sig.bin" ||
	die "enclave attestation failed; the TPM was not read"
[ -s "$work/signed.bin" ] && [ -s "$work/sig.bin" ] || die "enclave attestation wrote no output"
# Shape check on the device's own output, a length check only (not verification).
[ "$(stat -c %s -- "$work/sig.bin")" -eq 96 ] || die "enclave signature is not 96 bytes; the TPM was not read"

# 2. The EK public area, read-only.
tpm2_readpublic -c "$handle" -f tss -o "$work/ek.bin" >/dev/null ||
	die "tpm2_readpublic failed"
# Shape check on the device's own output: a TPM2B_PUBLIC whose 2-byte big-endian
# size equals the remaining length. No type or content check.
eklen=$(stat -c %s -- "$work/ek.bin")
[ "$eklen" -ge 4 ] || die "EK file is shorter than 4 bytes"
read -r b0 b1 < <(od -An -tu1 -N2 -- "$work/ek.bin")
[ $((b0 * 256 + b1)) -eq $((eklen - 2)) ] || die "EK size field does not match the EK file length"

# 3. Compose into a temp file, publish only when everything passed. This only
# arranges the collected bytes; it verifies nothing (verification belongs to
# go-xkms and go-trusted-platform, docs/SPEC.md).
b64() { # unpadded base64url of a file (no -w flag: portable to busybox)
	base64 <"$1" | tr -d '\n=' | tr '+/' '-_'
}
nonce_bytes=
for ((i = 0; i < 32; i += 2)); do nonce_bytes+="\\x${nonce:i:2}"; done
# shellcheck disable=SC2059 # the format is the \xHH string built from validated hex
printf "$nonce_bytes" >"$work/nonce.bin"
# Compact JSON, keys in sorted order, as the fixture's build writes it. The
# template matched [A-Za-z0-9._-]{1,64} above, so it needs no JSON escaping.
b_sig=$(b64 "$work/sig.bin") && b_signed=$(b64 "$work/signed.bin") &&
	b_nonce=$(b64 "$work/nonce.bin") && b_ek=$(b64 "$work/ek.bin") ||
	die "bundle composition failed"
printf '{"binding":"session","ele_attestation":{"response_version":%s,"signature":"%s","signed":"%s","verifier_nonce":"%s"},"format":"trusted-imx95/endorse-evidence","ftpm_ek":{"public":"%s","template":"%s"},"version":1}\n' \
	"$version" "$b_sig" "$b_signed" "$b_nonce" "$b_ek" "$template" >"$work/bundle.json" ||
	die "bundle composition failed"

# 4. Publish. Each step fails the script on its own: a failed step in a
# non-final `&&` position would not trip errexit.
# The temp file is created exclusively (mktemp, O_EXCL) in OUT's parent, so no
# pre-created name or symlink is ever written through; the trap removes it on
# every exit path. mv -T never moves into a directory.
tmp=$(mktemp "$(dirname -- "$out")/.$(basename -- "$out").XXXXXX") ||
	die "cannot create a temp file next to $out; nothing was published"
if ! cat "$work/bundle.json" >"$tmp"; then
	die "cannot write $out; nothing was published"
fi
if ! mv -T -- "$tmp" "$out"; then
	die "cannot move the bundle to $out; nothing was published"
fi
tmp=
echo "collect-evidence: wrote $out"
