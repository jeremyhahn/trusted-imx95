#!/usr/bin/env bash
# test/boot_image_test.sh: the boot image inputs (scripts/boot-image-inputs.sh)
# and, from the assembly slice on, the signed image. Offline; no board.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=$ROOT/scripts/boot-image-inputs.sh
LOCK=$ROOT/boot-container/inputs.lock

# --- the committed lock ---
run "$SCRIPT" --check
check "check: the committed pins are valid" 0 "pins OK"

# --- a fixture tree: the script, the lock and the two BSP lock files ---
fx=$TMP_ROOT/fx
mkdir -p "$fx/scripts" "$fx/boot-container" "$fx/secure-world" "$fx/system-manager"
cp "$SCRIPT" "$fx/scripts/"
cp "$LOCK" "$fx/boot-container/"
cp "$ROOT/secure-world/bsp.lock" "$fx/secure-world/"
cp "$ROOT/system-manager/sm.lock" "$fx/system-manager/"
FX=$fx/scripts/boot-image-inputs.sh
FXLOCK=$fx/boot-container/inputs.lock

# count_in <file> <substring>: the number of lines holding <substring>.
count_in() {
	local n=0 l
	while IFS= read -r l; do [[ "$l" != *"$2"* ]] || n=$((n + 1)); done <"$1"
	echo "$n"
}

# variant <out> <key> <new line>: write the lock with one line changed.
variant() { # variant <out> <key> <new line, or empty to drop the key>
	local out=$1 key=$2 new=$3 line
	: >"$out"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"$key="*) [ -z "$new" ] || echo "$new" >>"$out" ;;
		*) echo "$line" >>"$out" ;;
		esac
	done <"$LOCK"
}

v=$TMP_ROOT/v.lock
variant "$v" uboot_commit "uboot_commit=abc"
run "$SCRIPT" --check --lock "$v"
check "check: a short commit is refused" nonzero "not 40 hex"

variant "$v" uboot_archive_sha256 "uboot_archive_sha256=UNREAD"
run "$SCRIPT" --check --lock "$v"
check "check: UNREAD is refused" nonzero "UNREAD"

variant "$v" ele_installer_sha256 "ele_installer_sha256=${LOCK}"
run "$SCRIPT" --check --lock "$v"
check "check: a non-hex digest is refused" nonzero "not 64 hex"

variant "$v" ele_installer_sha256 ""
run "$SCRIPT" --check --lock "$v"
check "check: a missing name is refused" nonzero "ele_installer_sha256 missing"

variant "$v" uboot_branch "uboot_branch=x
uboot_branch=y"
run "$SCRIPT" --check --lock "$v"
check "check: a repeated name is refused" nonzero "twice"

variant "$v" ele_installer_url "ele_installer_url=http://example.invalid/x.bin"
run "$SCRIPT" --check --lock "$v"
check "check: a non-https URL is refused" nonzero "not an https URL"

variant "$v" uboot_branch "bogus_name=1"
run "$SCRIPT" --check --lock "$v"
check "check: an unknown name is refused" nonzero "unknown name"

run "$SCRIPT" --check --lock "$TMP_ROOT/none.lock"
check "check: a missing lock is refused" nonzero "no lock file"

variant "$FXLOCK" meta_imx_commit "meta_imx_commit=0000000000000000000000000000000000000000"
run "$FX" --check
check "check: meta-imx pin differing from secure-world/bsp.lock is refused" nonzero "differs from META_IMX_COMMIT"
cp "$LOCK" "$FXLOCK"

# --- collect ---
out=$TMP_ROOT/in
run "$SCRIPT" --collect "$out" --system-manager "$TMP_ROOT/none.bin"
check "collect: a named file that is missing is refused" nonzero "no such file"

: >"$TMP_ROOT/empty.bin"
run "$SCRIPT" --collect "$out" --m7 "$TMP_ROOT/empty.bin"
check "collect: an empty file is refused" nonzero "empty file"

printf 'real m7 bytes' >"$TMP_ROOT/m7.bin"
run env SM_OUT="$TMP_ROOT/no-sm" SW_OUT="$TMP_ROOT/no-sw" "$SCRIPT" --collect "$out" --m7 "$TMP_ROOT/m7.bin"
check "collect: one real input, five stand-ins" 0 "System Manager: STAND-IN" "ELE firmware: STAND-IN"
if [ "$(cat "$out/m7_image.bin")" = "real m7 bytes" ] &&
	[ "$(wc -l <"$out/inputs.txt")" -eq 6 ] &&
	[[ "$(cat "$out/inputs.txt")" == *"m7_image.bin real $(sha256sum "$TMP_ROOT/m7.bin" | cut -d' ' -f1)"* ]] &&
	[ "$(count_in "$out/inputs.txt" STAND-IN)" -eq 5 ]; then
	pass "collect: inputs.txt names each source and digest"
else
	fail "collect: inputs.txt names each source and digest" "$(cat "$out/inputs.txt")"
fi
if [[ "$(head -c 8 "$out/bl31.bin")" == STAND-IN* ]]; then
	pass "collect: a stand-in payload is labelled in its own bytes"
else
	fail "collect: a stand-in payload is labelled in its own bytes"
fi

# defaults from the make system-manager and make secure-world output dirs
mkdir -p "$TMP_ROOT/sm" "$TMP_ROOT/sw"
printf 'sm' >"$TMP_ROOT/sm/m33_image.bin"
printf 'bl31' >"$TMP_ROOT/sw/bl31.bin"
printf 'tee' >"$TMP_ROOT/sw/tee.bin"
run env SM_OUT="$TMP_ROOT/sm" SW_OUT="$TMP_ROOT/sw" "$SCRIPT" --collect "$TMP_ROOT/in2"
check "collect: System Manager, BL31 and tee.bin come from their make outputs" 0
if [ "$(count_in "$TMP_ROOT/in2/inputs.txt" ' real ')" -eq 3 ] && [ "$(cat "$TMP_ROOT/in2/tee.bin")" = tee ]; then
	pass "collect: three real inputs, three stand-ins"
else
	fail "collect: three real inputs, three stand-ins" "$(cat "$TMP_ROOT/in2/inputs.txt")"
fi

# --- fetch fails closed on a digest mismatch (curl stubbed, no network) ---
stub=$TMP_ROOT/stub
mkdir -p "$stub"
cat >"$stub/curl" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
	[ "$1" != -o ] || { shift; out=$1; }
	shift
done
printf 'not the pinned bytes' >"$out"
EOF
chmod +x "$stub/curl"
run env PATH="$stub:$PATH" "$SCRIPT" --fetch "$TMP_ROOT/fetch"
check "fetch: a download whose SHA-256 differs fails closed" nonzero "SHA-256 mismatch"
if [ -z "$(ls "$TMP_ROOT/fetch")" ]; then
	pass "fetch: nothing is left behind after a mismatch"
else
	fail "fetch: nothing is left behind after a mismatch" "$(ls "$TMP_ROOT/fetch")"
fi

# --- assembly, signing, verification and tamper (scripts/ahab/boot-image.sh) ---
BI=$ROOT/scripts/ahab/boot-image.sh
img_out=$TMP_ROOT/img
run "$BI" --inputs "$TMP_ROOT/none" --out "$img_out"
check "image: a missing inputs directory is refused" nonzero "has no ele.bin"

run "$SCRIPT" --collect "$TMP_ROOT/in3"
expect "image: stand-in inputs collected" [ -s "$TMP_ROOT/in3/inputs.txt" ]
run "$BI" --inputs "$TMP_ROOT/in3" --out "$img_out"
check "image: assemble, verify every container, tamper every payload" 0 \
	"3 of 3 containers authenticate" "6 payloads equal their inputs" \
	"tamper: ele.bin" "tamper: m33_image.bin" "tamper: m7_image.bin" \
	"tamper: bl31.bin" "tamper: u-boot.bin" "tamper: tee.bin" \
	"STAND-IN payloads in this image: 6" "boot-image-test: OK"
expect "image: boot-image.bin and SHA256SUMS written" [ -s "$img_out/boot-image.bin" ] && [ -s "$img_out/SHA256SUMS" ]
if (cd "$img_out" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
	pass "image: SHA256SUMS verifies"
else
	fail "image: SHA256SUMS verifies"
fi
extra=0
for f in "$img_out"/*; do
	case "${f##*/}" in boot-image.bin | inputs.txt | SHA256SUMS) ;; *) extra=$((extra + 1)) ;; esac
done
if [ "$extra" -eq 0 ]; then
	pass "image: the out directory holds no key or fuse script"
else
	fail "image: the out directory holds no key or fuse script" "$(ls "$img_out")"
fi

run "$BI" verify "$img_out/boot-image.bin"
check "verify: the written image verifies" 0 "verify: OK"
# One flipped byte in the first signed payload (the ELE entry): the standalone verify rejects it.
python3 -I - "$img_out/boot-image.bin" "$TMP_ROOT/bad.bin" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
off = d.find(b"STAND-IN ELE firmware") + 100
d[off] ^= 0xFF
open(sys.argv[2], "wb").write(d)
PY
run "$BI" verify "$TMP_ROOT/bad.bin"
check "verify: an image with one changed payload byte is rejected" 1 "verify: FAILED"

finish
