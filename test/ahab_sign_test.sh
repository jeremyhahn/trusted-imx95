#!/usr/bin/env bash
# make ahab-sign-test (issue #9): a throwaway ECDSA P-384 test PKI outside the
# tree, an i.MX 95 B0 AHAB container around a random payload, signed and
# verified with the pinned SPSDK 3.13.0.
#   (a) the run succeeds and the container it hands back verifies;
#   (b) a copy with one signature byte or one payload byte flipped is rejected;
#   (c) the run leaves no new or changed file in the clone, and no private key;
#   (d) the run fails when the venv's SPSDK is not the pinned version.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGN="$ROOT/scripts/ahab/sign-test.sh"
out="$TMP_ROOT/out"
mkdir -p "$out"

# u16 <file> <offset>: the little-endian 16-bit word at <offset>.
u16() {
	local lo hi
	lo=$(od -An -tu1 -j"$2" -N1 "$1" | tr -d ' ')
	hi=$(od -An -tu1 -j"$(($2 + 1))" -N1 "$1" | tr -d ' ')
	echo $((lo + 256 * hi))
}

# flip <src> <dst> <offset>: <dst> is <src> with the byte at <offset> inverted.
flip() {
	local v
	cp "$1" "$2"
	v=$(od -An -tu1 -j"$3" -N1 "$2" | tr -d ' ')
	# shellcheck disable=SC2059 # the format is the byte itself, as an octal escape
	printf "$(printf '\\%03o' $((v ^ 0xff)))" | dd of="$2" bs=1 seek="$3" conv=notrunc status=none
}

stamp="$TMP_ROOT/stamp"
touch "$stamp"

# (a) the target builds, signs and verifies; the container it hands back
# verifies again through the same step.
run env AHAB_OUT_DIR="$out" make -C "$ROOT" --no-print-directory ahab-sign-test
check "(a) make ahab-sign-test builds, signs and verifies a mimx9596 b0 container" 0 \
	"nxpimage, version 3.13.0" "verify: OK" "SRK table hash (test PKI only):" "ahab-sign-test: OK"
bin="$out/container.bin"
if [ -s "$bin" ]; then
	run "$SIGN" verify "$bin"
	check "(a) the handed-back container passes nxpimage ahab verify" 0 "verify: OK"

	# (b) The container header's word at 12 is the signature block's offset;
	# the block's word at 8 is the signature's offset in it; the signature
	# data starts 8 bytes into its record. The payload is the image's last
	# bytes: its hash is in the signed image array.
	sb=$(u16 "$bin" 12)
	so=$(u16 "$bin" $((sb + 8)))
	flip "$bin" "$TMP_ROOT/sig.bin" $((sb + so + 8))
	run "$SIGN" verify "$TMP_ROOT/sig.bin"
	check "(b) a container with one signature byte flipped is rejected" nonzero "verify: FAILED"
	flip "$bin" "$TMP_ROOT/payload.bin" $(($(stat -c %s "$bin") - 1))
	run "$SIGN" verify "$TMP_ROOT/payload.bin"
	check "(b) a container with one payload byte flipped is rejected" nonzero "verify: FAILED"
else
	fail "(a) the run handed back no container in AHAB_OUT_DIR"
fi

# (c) nothing in the clone is new or changed, and no untracked or ignored
# file holds a private key.
changed=$(find "$ROOT" -path "$ROOT/.git" -prune -o -newer "$stamp" -print)
if [ -z "$changed" ]; then pass "(c) the run wrote nothing inside the clone"; else
	fail "(c) the run wrote inside the clone" "$changed"; fi
keys=$(git -C "$ROOT" ls-files -z --others | xargs -0 -r -I{} grep -l -E 'BEGIN (EC |ENCRYPTED )?PRIVATE KEY' "$ROOT/{}" 2>/dev/null || true)
if [ -z "$keys" ]; then pass "(c) no private key under the clone"; else
	fail "(c) private key material under the clone" "$keys"; fi

# (d) a venv whose SPSDK is not 3.13.0 fails the run, naming the pin.
fake="$TMP_ROOT/fake-venv"
mkdir -p "$fake/bin"
printf '#!/bin/sh\necho "nxpimage, version 3.12.1"\n' >"$fake/bin/nxpimage"
chmod +x "$fake/bin/nxpimage"
run env SPSDK_VENV="$fake" "$SIGN"
check "(d) a run with SPSDK 3.12.1 in the venv fails naming the pin" nonzero "3.13.0" "3.12.1"

finish
