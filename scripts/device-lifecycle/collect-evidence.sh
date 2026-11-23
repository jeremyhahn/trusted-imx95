#!/usr/bin/env bash
# collect-evidence.sh: compose the endorse-01 evidence bundle on the A55
# (proposed, pending owner approval; the order is owner ruling 1234).
#
#   ELE_ATTEST_CMD=<cmd> collect-evidence.sh --nonce HEX32 --response-version N \
#       --ek-handle 0x81HHHHHH --ek-template NAME -o OUT
#
# Order: (1) the enclave attestation through $ELE_ATTEST_CMD, (2) only if it
# succeeded, the fTPM EK public area with the read-only tpm2_readpublic,
# (3) evidence-bundle.py build, (4) an optional self-check when ELE_ATTEST_PUB
# names the enclave public key PEM. No default for the enclave command or the
# handle. Never creates, clears or evicts anything in the TPM.
#
# ELE_ATTEST_CMD is run as: $ELE_ATTEST_CMD NONCE_HEX SIGNED_OUT SIGNATURE_OUT
# and must write the signed region and the 96-byte signature there, exit 0.
# EVIDENCE_PYTHON names the interpreter (needs `cryptography`), default python3.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
tool="$here/evidence-bundle.py"

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
[[ "$version" =~ ^[0-9]+$ ]] || die "--response-version must be a number"
[[ "$handle" =~ ^0x81[0-9a-fA-F]{6}$ ]] || die "--ek-handle must be in 0x81000000-0x81FFFFFF"

py=${EVIDENCE_PYTHON:-python3}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. Enclave attestation first (ruling 1234).
# shellcheck disable=SC2086 # the command may carry its own arguments
$ELE_ATTEST_CMD "$nonce" "$work/signed.bin" "$work/sig.bin" ||
	die "enclave attestation failed; the TPM was not read"
[ -s "$work/signed.bin" ] && [ -s "$work/sig.bin" ] || die "enclave attestation wrote no output"

# 2. The EK public area, read-only.
tpm2_readpublic -c "$handle" -f tss -o "$work/ek.bin" >/dev/null ||
	die "tpm2_readpublic failed"

# 3. Compose into a temp file, publish only when everything passed.
"$py" -I "$tool" build --signed "$work/signed.bin" --signature "$work/sig.bin" \
	--nonce "$nonce" --response-version "$version" --ek-public "$work/ek.bin" \
	--ek-template "$template" -o "$work/bundle.json" >/dev/null || die "bundle build failed"

# 4. Optional self-check; a device normally has no verifier key.
if [ -n "${ELE_ATTEST_PUB:-}" ]; then
	"$py" -I "$tool" check "$work/bundle.json" --ele-pub "$ELE_ATTEST_PUB" \
		--nonce "$nonce" --ek-public "$work/ek.bin" >/dev/null || die "bundle self-check failed"
fi

cp "$work/bundle.json" "$out.tmp.$$" && mv "$out.tmp.$$" "$out"
echo "collect-evidence: wrote $out"
