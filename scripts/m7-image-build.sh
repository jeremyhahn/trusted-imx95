#!/usr/bin/env bash
# m7-image-build.sh [--check] [--lock FILE] [--sm-lock FILE]: build the
# Cortex-M7 idle image (m7_image.bin) from boot-container/m7-idle/, twice, each
# in its own directory, and fail unless both builds give the same SHA-256.
#
#   --check    validate the pins and stop (offline)
#   --lock     default boot-container/m7-idle.lock: sources_sha256, the digest
#              of startup.c, main.c and m7-idle.ld, in that order
#   --sm-lock  default system-manager/sm.lock: the Arm GNU toolchain pin
#              (toolchain_url, toolchain_sha256, toolchain_version) is read from
#              there, so the idle image is built by the very compiler the
#              System Manager is
#
# Output in $M7_OUT (default out/m7-image, git-ignored): m7_image.elf,
# m7_image.bin, SHA256SUMS, m7-manifest.txt. The toolchain tarball is cached in
# $M7_OUT/cache (copied from $SM_OUT/cache when `make system-manager` has
# downloaded it), checked against its SHA-256 on every run, and extracted
# fresh. A mismatch fails closed. No board, no flash, no key, no vendor code.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
die() {
	echo "m7-image-build: $*" >&2
	exit 1
}
check_only=0
lock=$root/boot-container/m7-idle.lock
smlock=$root/system-manager/sm.lock
while [ $# -gt 0 ]; do
	case $1 in
	--check) check_only=1 ;;
	--lock | --sm-lock)
		[ $# -ge 2 ] || die "$1 needs a file"
		if [ "$1" = --lock ]; then lock=$2; else smlock=$2; fi
		shift
		;;
	*) die "usage: m7-image-build.sh [--check] [--lock FILE] [--sm-lock FILE]" ;;
	esac
	shift
done

# parse <file> <keys...>: only the known keys, each once; sets pin[<key>].
declare -A pin=()
parse() {
	local f=$1 k v line n=0 seen=" " key
	shift
	[ -f "$f" ] || die "no lock file: $f"
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		case $line in '' | '#'*) continue ;; esac
		[[ $line =~ ^([a-z0-9_]+)=(.+)$ ]] || die "$f:$n: not key=value: $line"
		k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
		case " $* " in *" $k "*) ;; *) continue ;; esac
		case $seen in *" $k "*) die "$f:$n: $k set twice" ;; esac
		seen="$seen$k "
		pin[$k]=$v
	done <"$f"
	for key in "$@"; do
		[ -n "${pin[$key]+set}" ] || die "$f: $key is missing"
	done
}
want() { [[ ${pin[$1]} =~ $2 ]] || die "$3: $1 must be $4: ${pin[$1]}"; }

parse "$lock" sources_sha256
want sources_sha256 '^[0-9a-f]{64}$' "$lock" "a SHA-256"
parse "$smlock" toolchain_version toolchain_url toolchain_sha256
want toolchain_url '^(https|file)://[^[:space:]]+\.tar\.xz$' "$smlock" "an https:// or file:// URL of a .tar.xz"
want toolchain_version '^[0-9]+\.[0-9]+\.rel[0-9]+$' "$smlock" "an Arm GNU version such as 15.2.rel1"
want toolchain_sha256 '^[0-9a-f]{64}$' "$smlock" "a SHA-256"

sha() { sha256sum "$1" | cut -d' ' -f1; }
srcdir=$root/boot-container/m7-idle
srcs=(startup.c main.c m7-idle.ld)
for f in "${srcs[@]}"; do [ -f "$srcdir/$f" ] || die "no source: $srcdir/$f"; done
got=$(cd "$srcdir" && cat "${srcs[@]}" | sha256sum | cut -d' ' -f1)
[ "$got" = "${pin[sources_sha256]}" ] ||
	die "sources SHA-256 is $got, the lock pins ${pin[sources_sha256]}"
if [ "$check_only" = 1 ]; then
	echo "m7-image-build: $lock OK (sources ${got:0:12}, Arm GNU ${pin[toolchain_version]})"
	exit 0
fi

for t in curl tar xz sha256sum; do
	command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH"
done
out=${M7_OUT:-$root/out/m7-image}
mkdir -p "$out/cache"
out=$(cd "$out" && pwd -P)

# The toolchain: cached, checked on every run, extracted fresh.
tarball=$out/cache/${pin[toolchain_url]##*/}
if ! [ -f "$tarball" ] || [ "$(sha "$tarball")" != "${pin[toolchain_sha256]}" ]; then
	rm -f "$tarball"
	smcache=${SM_OUT:-$root/out/system-manager}/cache/${pin[toolchain_url]##*/}
	if [ -f "$smcache" ] && [ "$(sha "$smcache")" = "${pin[toolchain_sha256]}" ]; then
		cp "$smcache" "$tarball"
	else
		echo "m7-image-build: fetching ${pin[toolchain_url]}"
		curl -fsSL --retry 3 -o "$tarball.part" "${pin[toolchain_url]}"
		got=$(sha "$tarball.part")
		[ "$got" = "${pin[toolchain_sha256]}" ] ||
			{ rm -f "$tarball.part"; die "toolchain SHA-256 mismatch: got $got, the lock pins ${pin[toolchain_sha256]}"; }
		mv "$tarball.part" "$tarball"
	fi
fi
rm -rf "$out/toolchain"
mkdir -p "$out/toolchain"
tar -C "$out/toolchain" -xJf "$tarball"
gccs=("$out"/toolchain/*/bin/arm-none-eabi-gcc)
[ -x "${gccs[0]}" ] || die "no bin/arm-none-eabi-gcc in ${tarball##*/}"
gcc=${gccs[0]}
objcopy=${gcc%gcc}objcopy

# build <n>: its own directory, the sources copied in; prints the image's SHA-256.
build() {
	local d=$out/build-$1 log=$out/build-$1.log
	rm -rf "$d"
	mkdir -p "$d"
	cp "$srcdir/startup.c" "$srcdir/main.c" "$srcdir/m7-idle.ld" "$d/"
	if ! (cd "$d" && LC_ALL=C "$gcc" -mcpu=cortex-m7 -mthumb -mfloat-abi=soft \
		-Os -g0 -Wall -Wextra -Werror -ffreestanding -fno-builtin \
		-ffunction-sections -fdata-sections "-ffile-prefix-map=$d=." \
		-nostdlib -nostartfiles -Wl,-T,m7-idle.ld -Wl,--gc-sections \
		-Wl,--build-id=none -Wl,--no-warn-rwx-segments \
		-o m7_image.elf startup.c main.c &&
		"$objcopy" -O binary m7_image.elf m7_image.bin) >"$log" 2>&1; then
		tail -n 20 "$log" >&2
		die "build $1 failed; log: $log"
	fi
	[ -s "$d/m7_image.bin" ] || die "build $1 made no m7_image.bin; log: $log"
	sha "$d/m7_image.bin"
}

h1=$(build 1)
echo "m7-image-build: build 1 m7_image.bin $h1"
h2=$(build 2)
echo "m7-image-build: build 2 m7_image.bin $h2"
[ "$h1" = "$h2" ] || die "not reproducible: build 1 $h1, build 2 $h2"

cp "$out/build-1/m7_image.elf" "$out/build-1/m7_image.bin" "$out/"
(cd "$out" && sha256sum m7_image.bin >SHA256SUMS)
{
	echo "sources_sha256=${pin[sources_sha256]}"
	echo "toolchain_version=${pin[toolchain_version]}"
	echo "toolchain_sha256=${pin[toolchain_sha256]}"
	echo "build1_sha256=$h1"
	echo "build2_sha256=$h2"
	echo "reproducible=yes"
} >"$out/m7-manifest.txt"
echo "m7-image-build: reproducible, m7_image.bin $h1"
