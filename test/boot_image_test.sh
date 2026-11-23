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
# the test must not pick up a real make system-manager / secure-world output
export SM_OUT=$TMP_ROOT/no-sm SW_OUT=$TMP_ROOT/no-sw
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
# what make secure-world publishes: SHA256SUMS and build-info.txt with the lock: line
(cd "$TMP_ROOT/sw" && sha256sum bl31.bin tee.bin >SHA256SUMS)
printf 'lock: %s\nrelease: test\n' "$(sha256sum "$ROOT/secure-world/bsp.lock" | cut -d' ' -f1)" >"$TMP_ROOT/sw/build-info.txt"
run env SM_OUT="$TMP_ROOT/sm" SW_OUT="$TMP_ROOT/sw" "$SCRIPT" --collect "$TMP_ROOT/in2"
check "collect: System Manager, BL31 and tee.bin come from their make outputs" 0
if [ "$(count_in "$TMP_ROOT/in2/inputs.txt" ' real ')" -eq 3 ] && [ "$(cat "$TMP_ROOT/in2/tee.bin")" = tee ]; then
	pass "collect: three real inputs, three stand-ins"
else
	fail "collect: three real inputs, three stand-ins" "$(cat "$TMP_ROOT/in2/inputs.txt")"
fi

if [ "$(count_in "$TMP_ROOT/in2/inputs.txt" 'm7_image.bin STAND-IN')" -eq 1 ]; then
	pass "collect: with no --m7 the M7 image is a labelled stand-in (it is trusted-firmware's)"
else
	fail "collect: with no --m7 the M7 image is a labelled stand-in" "$(cat "$TMP_ROOT/in2/inputs.txt")"
fi

# BL31 and tee.bin from make secure-world are checked against that build
sw_case() { # sw_case <name> <mutation command run in the copy>
	rm -rf "$TMP_ROOT/swx" "$TMP_ROOT/inx"
	cp -r "$TMP_ROOT/sw" "$TMP_ROOT/swx"
	(cd "$TMP_ROOT/swx" && eval "$2")
	run env SM_OUT="$TMP_ROOT/sm" SW_OUT="$TMP_ROOT/swx" "$SCRIPT" --collect "$TMP_ROOT/inx"
}
sw_case x ':'
check "collect: a matching SHA256SUMS and build-info.txt keep bl31.bin and tee.bin real" 0
if [ "$(count_in "$TMP_ROOT/inx/inputs.txt" 'bl31.bin real')" -eq 1 ] && [ "$(count_in "$TMP_ROOT/inx/inputs.txt" 'tee.bin real')" -eq 1 ]; then
	pass "collect: bl31.bin and tee.bin are real after the build check"
else
	fail "collect: bl31.bin and tee.bin are real after the build check" "$(cat "$TMP_ROOT/inx/inputs.txt")"
fi
sw_refused() { # sw_refused <label> <mutation> <message>
	sw_case x "$2"
	check "collect: $1 is refused" nonzero "$3"
	if [ ! -e "$TMP_ROOT/inx/inputs.txt" ]; then
		pass "collect: $1 leaves no inputs.txt"
	else
		fail "collect: $1 leaves no inputs.txt" "$(cat "$TMP_ROOT/inx/inputs.txt")"
	fi
}
sw_refused "a changed bl31.bin byte" "printf 'X' | dd of=bl31.bin bs=1 seek=1 conv=notrunc 2>/dev/null" "bl31.bin: SHA-256"
sw_refused "a changed tee.bin byte" "printf 'X' | dd of=tee.bin bs=1 seek=1 conv=notrunc 2>/dev/null" "tee.bin: SHA-256"
sw_refused "a missing SHA256SUMS" "rm SHA256SUMS" "SHA256SUMS: missing"
sw_refused "a missing build-info.txt" "rm build-info.txt" "build-info.txt: missing"
sw_refused "a lock: line for a different bsp.lock" "printf 'lock: %064d\n' 0 >build-info.txt" "is not the SHA-256 of secure-world/bsp.lock"
sw_refused "a SHA256SUMS with no entry for tee.bin" "sha256sum bl31.bin >SHA256SUMS" "no entry for tee.bin"

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

# --no-tamper is not an option: the tamper checks cannot be skipped
run "$BI" --inputs "$TMP_ROOT/in3" --out "$TMP_ROOT/img-nt" --no-tamper
check "image: --no-tamper is rejected as an unknown option" nonzero "usage: boot-image.sh"
expect "image: --no-tamper wrote no image" [ ! -e "$TMP_ROOT/img-nt/boot-image.bin" ]

# a payload changed after collection, inputs.txt left alone: refused, nothing written
cp -r "$TMP_ROOT/in3" "$TMP_ROOT/in4"
printf 'X' >>"$TMP_ROOT/in4/bl31.bin"
run "$BI" --inputs "$TMP_ROOT/in4" --out "$TMP_ROOT/img-ch"
check "image: a payload changed after collection is refused" nonzero "bl31.bin" "changed since collection"
expect "image: the refused run wrote no image" [ ! -e "$TMP_ROOT/img-ch/boot-image.bin" ]
# a missing inputs.txt entry is refused too
cp -r "$TMP_ROOT/in3" "$TMP_ROOT/in5"
: >"$TMP_ROOT/in5/inputs.txt.new"
while IFS= read -r l; do case "$l" in tee.bin*) ;; *) echo "$l" >>"$TMP_ROOT/in5/inputs.txt.new" ;; esac; done <"$TMP_ROOT/in3/inputs.txt"
mv "$TMP_ROOT/in5/inputs.txt.new" "$TMP_ROOT/in5/inputs.txt"
run "$BI" --inputs "$TMP_ROOT/in5" --out "$TMP_ROOT/img-ms"
check "image: an inputs.txt without an entry for a payload is refused" nonzero "no entry for tee.bin"

run "$BI" verify "$img_out/boot-image.bin"
check "verify: the written image verifies" 0 "verify: OK"

# The M7 execution metadata of the built image, read back with nxpimage ahab parse.
# The constants are docs/boot-container/boot-image.md:31 (container 2, entry "executable"):
# core cortex-m7-1, load 0x00000000, entry 0x303C0000. The container offset is the place of
# container 2 in the image: containers start at 0x0, 0x4000 and 0x8000 (AHAB tag 0x87 at +3).
WANT_M7_CORE=cortex-m7-1
WANT_M7_TYPE=executable
WANT_M7_LOAD=0x00000000
WANT_M7_ENTRY=0x303c0000
WANT_M7_CONTAINER_OFFSET=$((0x4000))
spsdk_venv=$("$ROOT/scripts/ahab/spsdk-venv.sh")
mkdir -p "$TMP_ROOT/m7parse"
run "$spsdk_venv/bin/nxpimage" ahab parse -f mimx9596 -r b0 -b "$img_out/boot-image.bin" -o "$TMP_ROOT/m7parse"
expect "m7: nxpimage ahab parse reads the full image" [ "$RC" -eq 0 -a -f "$TMP_ROOT/m7parse/parsed_config.yaml" ]
# m7_field <key>: <key> of the second image of the second container in parsed_config.yaml
m7_field() {
	local l ci=-1 ii=-1
	while IFS= read -r l; do
		l=${l%$'\r'}
		case "$l" in
		"    container:"*) ci=$((ci + 1)); ii=-1 ;;
		*"image_path:"*) ii=$((ii + 1)) ;;
		*"$1:"*)
			if [ "$ci" -eq 1 ] && [ "$ii" -eq 1 ] && [[ "$l" != "#"* && "$l" != *"# "* ]]; then
				l=${l#*"$1:"}; l=${l//[\'\" ]/}; echo "${l,,}"; return
			fi ;;
		esac
	done <"$TMP_ROOT/m7parse/parsed_config.yaml"
}
# m7_num_eq <got> <want>: numeric equality of two 0x addresses (SPSDK prints 0x0 for 0x00000000)
m7_num_eq() { [[ "$1" =~ ^0x[0-9a-f]+$ && "$2" =~ ^0x[0-9a-f]+$ ]] && [ $(($1)) -eq $(($2)) ]; }
got=$(m7_field core_id)
expect "m7: the M7 entry's core is $WANT_M7_CORE (parsed '$got')" [ "$got" = "$WANT_M7_CORE" ]
got=$(m7_field image_type)
expect "m7: the M7 entry's image type is $WANT_M7_TYPE (parsed '$got')" [ "$got" = "$WANT_M7_TYPE" ]
got=$(m7_field load_address)
expect "m7: the M7 entry's load address is $WANT_M7_LOAD (parsed '$got')" m7_num_eq "$got" "$WANT_M7_LOAD"
got=$(m7_field entry_point)
expect "m7: the M7 entry's entry point is $WANT_M7_ENTRY (parsed '$got')" m7_num_eq "$got" "$WANT_M7_ENTRY"
# the container offsets: the container headers sit below the first image payload, so walk only
# [0, first image_offset) from the parse output, 0x400-aligned, version 2 at +0 and AHAB tag 0x87 at +3;
# no payload byte is ever read
first_payload=0
all_image_offsets=()
while IFS= read -r l; do
	if [[ "$l" =~ image_offset:\ \'(0x[0-9a-f]+)\' ]]; then
		m=${BASH_REMATCH[1]}
		v=$((m))
		all_image_offsets+=("$m")
		if [ "$first_payload" -eq 0 ] || [ "$v" -lt "$first_payload" ]; then first_payload=$v; fi
	fi
done <"$TMP_ROOT/m7parse/parsed_config.yaml"
echo "# m7: parsed image_offset values: ${all_image_offsets[*]}"
expect "m7: the parse output records the first payload offset (got '$first_payload')" [ "${first_payload:-0}" -gt 0 ]
# walk_containers <image> <bound>: the 0x400-aligned offsets below <bound> that start a container header
walk_containers() {
	python3 -I - "$1" "$2" <<'PY'
import sys
f = open(sys.argv[1], "rb")
out = []
for o in range(0, int(sys.argv[2]), 0x400):
    f.seek(o)
    h = f.read(4)
    if len(h) == 4 and h[0] == 2 and h[3] == 0x87:
        out.append(str(o))
print(" ".join(out))
PY
}
offsets=$(walk_containers "$img_out/boot-image.bin" "${first_payload:-0}")
read -r -a offs <<<"$offsets"
WANT_LAST_CONTAINER_OFFSET=$((0x8000))
# the bound must lie past the last container header, or the walk could not see it
expect "m7: the walk bound $first_payload lies past the last container header $WANT_LAST_CONTAINER_OFFSET (offsets: ${all_image_offsets[*]}; headers: $offsets)" \
	[ "$first_payload" -gt "$WANT_LAST_CONTAINER_OFFSET" ]
m7_offsets_ok() { [ "$#" -eq 3 ] && [ "$2" -eq "$WANT_M7_CONTAINER_OFFSET" ]; }
expect "m7: the image holds three containers, the M7 one second, at $WANT_M7_CONTAINER_OFFSET (found: $offsets)" \
	m7_offsets_ok "${offs[@]}"
# patch_image <in> <out> <offset> <hex bytes>: a scratch copy with bytes written at <offset>
patch_image() {
	python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
b = bytes.fromhex(sys.argv[4])
d[int(sys.argv[3]):int(sys.argv[3]) + len(b)] = b
open(sys.argv[2], "wb").write(d)
PY
}
m7_refused() { ! m7_offsets_ok "$@"; }
# (a) a header-shaped 0x02 ?? ?? 0x87 inside a payload, past the bound, is not a container
planted=$((0x10000))
patch_image "$img_out/boot-image.bin" "$TMP_ROOT/plant.bin" "$planted" "02a1b287"
read -r -a poffs <<<"$(walk_containers "$TMP_ROOT/plant.bin" "$first_payload")"
expect "m7: a planted 02 ?? ?? 87 at $planted, past the bound $first_payload, is not counted (found: ${poffs[*]})" \
	m7_offsets_ok "${poffs[@]}"
# (b) the M7 container header dropped, or moved off its offset, is refused
patch_image "$img_out/boot-image.bin" "$TMP_ROOT/nom7.bin" "$WANT_M7_CONTAINER_OFFSET" "00000000"
read -r -a doffs <<<"$(walk_containers "$TMP_ROOT/nom7.bin" "$first_payload")"
expect "m7: a dropped M7 container header is refused (found: ${doffs[*]})" m7_refused "${doffs[@]}"
patch_image "$img_out/boot-image.bin" "$TMP_ROOT/mv.bin" "$WANT_M7_CONTAINER_OFFSET" "00000000"
patch_image "$TMP_ROOT/mv.bin" "$TMP_ROOT/mv2.bin" "$((WANT_M7_CONTAINER_OFFSET + 0x400))" "02ac0387"
read -r -a moffs <<<"$(walk_containers "$TMP_ROOT/mv2.bin" "$first_payload")"
expect "m7: an M7 container header moved off its offset is refused (found: ${moffs[*]})" m7_refused "${moffs[@]}"
# --- the Cortex-A55 container (the third, index 2) read back from the parse ---
# field <container> <image> <key>: the value of <key> of that entry in the parse,
# lower-cased, quotes stripped; comment lines skipped. Same walk as m7_field.
field() {
	local l ci=-1 ii=-1
	while IFS= read -r l; do
		l=${l%$'\r'}
		case "$l" in
		"    container:"*) ci=$((ci + 1)); ii=-1 ;;
		*"image_path:"*) ii=$((ii + 1)) ;;
		*"$3:"*)
			if [ "$ci" -eq "$1" ] && [ "$ii" -eq "$2" ] && [[ "$l" != "#"* && "$l" != *"# "* ]]; then
				l=${l#*"$3:"}; l=${l//[\'\" ]/}; echo "${l,,}"; return
			fi ;;
		esac
	done <"$TMP_ROOT/m7parse/parsed_config.yaml"
}
# Entries of container 3, counted from the parse: three, in the order atf, uboot, tee
# (the parse names each payload file after its image type and core, so the order is
# read from the load addresses below, not from file names).
# a55_carries <extracted payload> <input>: the payload starts with the input's bytes
a55_carries() { [ -n "$1" ] && cmp -s -n "$(stat -c %s "$2")" "$2" "$1"; }
a55_entries=0
for ii in 0 1 2 3; do [ -n "$(field 2 "$ii" image_offset)" ] && a55_entries=$((a55_entries + 1)); done
expect "a55: container 3 holds exactly three entries (found $a55_entries)" [ "$a55_entries" -eq 3 ]
for ii in 0 1 2; do
	expect "a55: container 3 entry $ii runs on cortex-a55 (parsed '$(field 2 "$ii" core_id)')" [ "$(field 2 "$ii" core_id)" = cortex-a55 ]
done
# Cited constants (read at the pins of secure-world/bsp.lock, 2026-11-23):
#  tee: TF-A da738d5eae93 plat/imx/imx9/imx95/platform.mk:56, BL32_BASE ?= 0x8C000000, and
#       imx-optee-os 99f40897 core/arch/arm/plat-imx/conf.mk:729, CFG_TZDRAM_START =
#       CFG_DRAM_BASE + 0x0C000000 (the DRAM base itself not read: OPEN).
#  atf: no citation. TF-A's BL31 base is in plat/imx/imx9/imx95/include/platform_def.h,
#       which the lane could not read: OPEN. The value pinned here is SPSDK 3.13.0's
#       default for the atf entry, so a change of it is noticed, not endorsed.
#  uboot: a stand-in, SPSDK's default, not asserted.
WANT_ATF_LOAD=0x8a200000 WANT_ATF_ENTRY=0x8a200000
WANT_TEE_LOAD=0x8c000000 WANT_TEE_ENTRY=0x8c000000
for spec in "0 atf $WANT_ATF_LOAD $WANT_ATF_ENTRY" "2 tee $WANT_TEE_LOAD $WANT_TEE_ENTRY"; do
	read -r ii nm wl we <<<"$spec"
	expect "a55: the $nm load_address is $wl (parsed '$(field 2 "$ii" load_address)')" m7_num_eq "$(field 2 "$ii" load_address)" "$wl"
	expect "a55: the $nm entry_point is $we (parsed '$(field 2 "$ii" entry_point)')" m7_num_eq "$(field 2 "$ii" entry_point)" "$we"
done
# the order atf, uboot, tee: the payload the parse extracts for each entry starts with
# that input's bytes
for spec in "0 bl31.bin" "1 u-boot.bin" "2 tee.bin"; do
	read -r ii nm <<<"$spec"
	pf=$(ls "$TMP_ROOT/m7parse/container2_image${ii}_"*.bin 2>/dev/null | head -n 1)
	expect "a55: container 3 entry $ii carries $nm" a55_carries "$pf" "$TMP_ROOT/in3/$nm"
done
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
