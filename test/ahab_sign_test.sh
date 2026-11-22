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

# (e) make ahab-m7-test (issue #12): the container's one image entry targets the
# Cortex-M7; the parsed core, load and entry address match m7-container.yaml;
# a flipped payload byte is rejected.
# yaml_val <key>: the value of the image entry's <key> in m7-container.yaml.
yaml_val() {
	local l
	while IFS= read -r l; do
		case "$l" in
		*"$1:"*) l=${l#*"$1:"}; l=${l//[\' ]/}; echo "${l,,}"; return ;;
		esac
	done <"$ROOT/scripts/ahab/m7-container.yaml"
}
# field_eq <key> <parsed> <yaml>: exact equality; addresses compare numerically
# (SPSDK prints 0x0 for 0x00000000), core_id as an exact string.
field_eq() {
	case "$1" in
	core_id) [ "$2" = "$3" ] ;;
	*) [[ "$2" =~ ^0x[0-9a-f]+$ && "$3" =~ ^0x[0-9a-f]+$ ]] && [ $(($2)) -eq $(($3)) ] ;;
	esac
}
m7out="$TMP_ROOT/m7out"
mkdir -p "$m7out"
run env AHAB_OUT_DIR="$m7out" make -C "$ROOT" --no-print-directory ahab-m7-test
check "(e) make ahab-m7-test builds, signs and verifies a Cortex-M7 container" 0 \
	"verify: OK" "M7 image entry (nxpimage ahab parse):" "ahab-m7-test: OK"
m7bin="$m7out/m7-container.bin"
if [ -s "$m7bin" ]; then
	for k in core_id load_address entry_point; do
		want=$(yaml_val "$k")
		got=""
		found=0
		while IFS= read -r l; do
			l=${l#"${l%%[![:space:]]*}"}
			case "$l" in
			"$k:"*) got=${l#"$k:"}; got=${got//[\' ]/}; got=${got,,}; found=1; break ;;
			esac
		done <<<"$OUT"
		if [ "$found" = 0 ]; then
			fail "(e) the parsed $k is missing from the nxpimage ahab parse output" "m7-container.yaml: $want"
		elif field_eq "$k" "$got" "$want"; then
			pass "(e) the parsed $k is exactly $got, as in m7-container.yaml"
		else
			fail "(e) the parsed $k differs from m7-container.yaml" "parsed: '$got' yaml: '$want'"
		fi
	done
	# Self-test of the comparison: a trailing extra digit must not match.
	if field_eq entry_point 0x303c00000 0x303c0000; then
		fail "(e) self-test: entry_point 0x303c00000 matched 0x303c0000"
	else
		pass "(e) self-test: entry_point 0x303c00000 does not match 0x303c0000"
	fi
	if field_eq core_id cortex-m70 cortex-m7; then
		fail "(e) self-test: core_id cortex-m70 matched cortex-m7"
	else
		pass "(e) self-test: core_id cortex-m70 does not match cortex-m7"
	fi
	run "$SIGN" verify "$m7bin"
	check "(e) the handed-back M7 container passes nxpimage ahab verify" 0 "verify: OK"
	flip "$m7bin" "$TMP_ROOT/m7-payload.bin" $(($(stat -c %s "$m7bin") - 1))
	run "$SIGN" verify "$TMP_ROOT/m7-payload.bin"
	check "(e) an M7 container with one payload byte flipped is rejected" nonzero "verify: FAILED"
else
	fail "(e) the M7 run handed back no container in AHAB_OUT_DIR"
fi

# (e2) M7_PAYLOAD reaches the script as one argument, with no shell
# interpretation: spaces, a semicolon, $(...) and a wildcard in the file name.
qdir="$TMP_ROOT/quote dir"
mkdir -p "$qdir" "$TMP_ROOT/m7qout"
qpayload="$qdir/a b;\$(touch PWNED)*.bin"
{ printf 'M7-QUOTE-MARKER-%s' "$$"; head -c 4000 /dev/urandom; } >"$qpayload"
qmarker="M7-QUOTE-MARKER-$$"
run env AHAB_OUT_DIR="$TMP_ROOT/m7qout" M7_PAYLOAD="$qpayload" make -C "$ROOT" --no-print-directory ahab-m7-test
check "(e2) make ahab-m7-test accepts a payload path with spaces and shell characters" 0 \
	"verify: OK" "ahab-m7-test: OK"
if [ -s "$TMP_ROOT/m7qout/m7-container.bin" ] && grep -q -a -F "$qmarker" "$TMP_ROOT/m7qout/m7-container.bin"; then
	pass "(e2) the container is built from that exact file"
else
	fail "(e2) the container does not carry the supplied payload"
fi
if [ -e "$qdir/PWNED" ] || [ -e "$ROOT/PWNED" ] || [ -e "$TMP_ROOT/PWNED" ] || [ -e PWNED ]; then
	fail "(e2) an injected command ran from M7_PAYLOAD"
else
	pass "(e2) no command injected through M7_PAYLOAD ran"
fi

# (c) nothing in the clone is new or changed, and no file git would track
# (tracked, or untracked and not ignored) holds a private key in text form.
# Ignored tool directories such as .tools/ hold binaries whose strings
# include the PEM markers.
changed=$(find "$ROOT" -path "$ROOT/.git" -prune -o -newer "$stamp" -print)
if [ -z "$changed" ]; then pass "(c) the run wrote nothing inside the clone"; else
	fail "(c) the run wrote inside the clone" "$changed"; fi
keys=$(git -C "$ROOT" ls-files -z --cached --others --exclude-standard | xargs -0 -r -I{} grep -l -I -E 'BEGIN (EC |ENCRYPTED )?PRIVATE KEY' "$ROOT/{}" 2>/dev/null || true)
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
