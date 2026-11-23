#!/usr/bin/env bash
# Tests of scripts/m7-image-build.sh: the pins, a refused toolchain download,
# and (when the pinned toolchain tarball is already cached) the built image:
# ARMv7E-M Thumb ELF, a stack pointer inside the linker's TCM window, an odd
# reset vector inside the image, and two builds with the same SHA-256.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=$ROOT/scripts/m7-image-build.sh
LOCK=$ROOT/boot-container/m7-idle.lock
SMLOCK=$ROOT/system-manager/sm.lock
LD=$ROOT/boot-container/m7-idle/m7-idle.ld

run "$SCRIPT" --check
check "check: the committed pins are valid" 0 "OK (sources"

# variant <src> <out> <key> <new line, or empty to drop the key>
variant() {
	local src=$1 out=$2 key=$3 new=$4 line
	: >"$out"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"$key="*) [ -z "$new" ] || echo "$new" >>"$out" ;;
		*) echo "$line" >>"$out" ;;
		esac
	done <"$src"
}

v=$TMP_ROOT/v.lock
variant "$LOCK" "$v" sources_sha256 "sources_sha256=$(printf 0%.0s {1..64})"
run "$SCRIPT" --check --lock "$v"
check "check: a sources digest that does not match the sources is refused" nonzero "the lock pins"

variant "$LOCK" "$v" sources_sha256 "sources_sha256=xyz"
run "$SCRIPT" --check --lock "$v"
check "check: a non-hex sources digest is refused" nonzero "a SHA-256"

variant "$LOCK" "$v" sources_sha256 ""
run "$SCRIPT" --check --lock "$v"
check "check: a missing sources digest is refused" nonzero "sources_sha256 is missing"

variant "$LOCK" "$v" sources_sha256 "sources_sha256=a
sources_sha256=b"
run "$SCRIPT" --check --lock "$v"
check "check: a repeated key is refused" nonzero "set twice"

run "$SCRIPT" --check --lock "$TMP_ROOT/none.lock"
check "check: a missing lock is refused" nonzero "no lock file"

variant "$SMLOCK" "$v" toolchain_sha256 "toolchain_sha256=abc"
run "$SCRIPT" --check --sm-lock "$v"
check "check: a toolchain digest that is not a SHA-256 is refused" nonzero "toolchain_sha256 must be a SHA-256"

variant "$SMLOCK" "$v" toolchain_url "toolchain_url=http://example.invalid/x.tar.xz"
run "$SCRIPT" --check --sm-lock "$v"
check "check: a non-https toolchain URL is refused" nonzero "toolchain_url must be"

variant "$SMLOCK" "$v" toolchain_sha256 ""
run "$SCRIPT" --check --sm-lock "$v"
check "check: a missing toolchain digest is refused" nonzero "toolchain_sha256 is missing"

# --- a toolchain whose SHA-256 differs from the pin is refused, nothing extracted ---
printf 'not the pinned toolchain' >"$TMP_ROOT/fake.tar.xz"
variant "$SMLOCK" "$TMP_ROOT/fake.lock" toolchain_url "toolchain_url=file://$TMP_ROOT/fake.tar.xz"
run env M7_OUT="$TMP_ROOT/o1" SM_OUT="$TMP_ROOT/no-sm" "$SCRIPT" --sm-lock "$TMP_ROOT/fake.lock"
check "build: a toolchain download with the wrong SHA-256 fails closed" nonzero "toolchain SHA-256 mismatch"
if [ ! -e "$TMP_ROOT/o1/toolchain" ] && [ -z "$(ls "$TMP_ROOT/o1/cache")" ]; then
	pass "build: nothing is cached or extracted after a mismatch"
else
	fail "build: nothing is cached or extracted after a mismatch" "$(ls -R "$TMP_ROOT/o1")"
fi

# a cached tarball of the wrong content is not trusted either
mkdir -p "$TMP_ROOT/o2/cache"
cp "$TMP_ROOT/fake.tar.xz" "$TMP_ROOT/o2/cache/fake.tar.xz"
run env M7_OUT="$TMP_ROOT/o2" SM_OUT="$TMP_ROOT/no-sm" "$SCRIPT" --sm-lock "$TMP_ROOT/fake.lock"
check "build: a cached tarball with the wrong SHA-256 is not used" nonzero "toolchain SHA-256 mismatch"

# --- the built image, when the pinned toolchain is already on disk (no download here) ---
tc_name=
while IFS= read -r line; do
	case "$line" in toolchain_url=*) tc_name=${line##*/} ;; esac
done <"$SMLOCK"
want_sha=
while IFS= read -r line; do
	case "$line" in toolchain_sha256=*) want_sha=${line#*=} ;; esac
done <"$SMLOCK"
cached=
for d in "${SM_OUT:-$ROOT/out/system-manager}" "${M7_OUT:-$ROOT/out/m7-image}"; do
	f=$d/cache/$tc_name
	if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want_sha" ]; then cached=$d; break; fi
done
if [ -z "$cached" ]; then
	echo "skip: the pinned toolchain tarball is not cached (run make m7-image once); image checks not run"
	finish
	exit 0
fi

o=$TMP_ROOT/build
run env M7_OUT="$o" SM_OUT="$cached" "$SCRIPT"
check "build: two builds in separate directories give one SHA-256" 0 "reproducible, m7_image.bin"
h1=$(sha256sum "$o/build-1/m7_image.bin" | cut -d' ' -f1)
h2=$(sha256sum "$o/build-2/m7_image.bin" | cut -d' ' -f1)
expect "build: build 1 and build 2 are byte-identical and SHA256SUMS names them" \
	[ "$h1" = "$h2" ] && [[ "$(cat "$o/SHA256SUMS")" == "$h1  m7_image.bin" ]]

readelf=$(echo "$o"/toolchain/*/bin/arm-none-eabi-readelf)
hdr=$("$readelf" -h -A "$o/m7_image.elf")
if [[ "$hdr" == *"Machine:"*"ARM"* ]] && [[ "$hdr" == *"ELF32"* ]] &&
	[[ "$hdr" == *'Tag_CPU_arch: v7E-M'* ]] && [[ "$hdr" == *'Tag_THUMB_ISA_use: Thumb-2'* ]]; then
	pass "elf: ARMv7E-M, Thumb-2, ELF32 ARM"
else
	fail "elf: ARMv7E-M, Thumb-2, ELF32 ARM" "$hdr"
fi

# the linker's TCM window: ORIGIN and LENGTH of the MEMORY block
origin='' length=''
while IFS= read -r line; do
	if [[ $line =~ ORIGIN[[:space:]]*=[[:space:]]*(0x[0-9A-Fa-f]+),[[:space:]]*LENGTH[[:space:]]*=[[:space:]]*([0-9]+)K ]]; then
		origin=$((BASH_REMATCH[1])) length=$((BASH_REMATCH[2] * 1024))
	fi
done <"$LD"
[ -n "$length" ] || fail "ld: ORIGIN and LENGTH found"

word() { # word <file> <byte offset>: the little-endian 32-bit word
	local b
	read -r -a b < <(od -An -tu1 -j "$2" -N4 "$1")
	echo $((b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24))
}
size=$(stat -c %s "$o/m7_image.bin")
sp=$(word "$o/m7_image.bin" 0)
reset=$(word "$o/m7_image.bin" 4)
if [ "$sp" -gt "$origin" ] && [ "$sp" -le $((origin + length)) ] && [ $((sp % 8)) -eq 0 ]; then
	pass "vectors: word 0 is a stack pointer inside the linker's TCM window, 8-byte aligned"
else
	fail "vectors: word 0 is a stack pointer inside the linker's TCM window" "sp=$sp origin=$origin length=$length"
fi
if [ $((reset & 1)) -eq 1 ] && [ $((reset - 1)) -ge $((origin + 64)) ] && [ $((reset - 1)) -lt $((origin + size)) ]; then
	pass "vectors: the reset vector is odd (Thumb) and inside the image after the table"
else
	fail "vectors: the reset vector is odd and inside the image" "reset=$reset size=$size"
fi
if [ "$size" -le "$length" ] && [ "$size" -ge 64 ]; then
	pass "image: it fits the TCM window"
else
	fail "image: it fits the TCM window" "size=$size length=$length"
fi
# every exception vector but the reserved ones is a Thumb address inside the image
bad=0
for i in 2 3 4 5 6 11 12 14 15; do
	w=$(word "$o/m7_image.bin" $((i * 4)))
	{ [ $((w & 1)) -eq 1 ] && [ $((w - 1)) -lt $((origin + size)) ]; } || bad=$((bad + 1))
done
expect "vectors: every system exception vector is a Thumb address inside the image" [ "$bad" -eq 0 ]

finish
