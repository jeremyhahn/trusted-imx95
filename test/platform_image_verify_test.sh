#!/usr/bin/env bash
# Offline test of scripts/platform-image-verify.sh: a stub output directory is
# built from the real platform-image/manifest.lock, then broken one way at a time.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

script=$ROOT/scripts/platform-image-verify.sh
lock=$ROOT/platform-image/manifest.lock
tmp=$TMP_ROOT
d=$tmp/out
t=trusted-imx95-image
machine=$(sed -n 's/^machine=//p' "$lock")

# mk DIR [DIRTY]: an image, a manifest and an SBOM for one target, SHA256SUMS,
# and a build-info.txt carrying the lock's pins.
mk() {
	rm -rf "$1"
	mkdir -p "$1"
	echo wic >"$1/$t-$machine.rootfs-20261123000001.wic.zst"
	echo mf >"$1/$t-$machine.rootfs-20261123000001.manifest"
	echo spdx >"$1/$t-$machine.rootfs-20261123000001.spdx.json"
	echo marker >"$1/.platform-image-out"
	(cd "$1" && sha256sum -- * >SHA256SUMS)
	{
		echo "# platform-image build-info (provisional, pending #14)"
		echo "machine=$machine"
		echo "distro=d"
		echo "targets=$t"
		echo "SOURCE_DATE_EPOCH=1700000000"
		echo "build_seconds=1"
		echo "checkout_commit=abc"
		echo "platform_image_dirty=${2:-no}"
		echo "platform_image_dirty_sha256=-"
		echo "manifest_commit=$(sed -n 's/^manifest_commit=//p' "$lock")"
		sed -n 's/^\(layer_[A-Za-z0-9_]*_commit=.*\)$/\1/p' "$lock"
	} >"$1/build-info.txt"
}
info=$d/build-info.txt

mk "$d"
run bash "$script" "$d"
check "a matching output directory" 0 "platform-image-verify: OK, 3 artefacts, pins match"

run bash "$script" "$d" "$lock"
check "LOCK given explicitly" 0 "OK, 3 artefacts"

mk "$d"
echo changed >"$d/$t-$machine.rootfs-20261123000001.wic.zst"
run bash "$script" "$d"
check "one changed byte" 1 "bytes do not match" "does not match"

mk "$d"
echo loose >"$d/unlisted.bin"
run bash "$script" "$d"
check "an unlisted file" 1 "unlisted.bin: in $d but not listed"

mk "$d"
k=layer_bitbake_commit
sed -i "s/^$k=.*/$k=0000000000000000000000000000000000000000/" "$info"
run bash "$script" "$d"
check "a changed layer commit" 1 "$k differs"

mk "$d"
sed -i "/^$k=/d" "$info"
run bash "$script" "$d"
check "a missing layer key" 1 "$k: in " "but missing from build-info.txt"

mk "$d"
echo layer_extra_commit=abc >>"$info"
run bash "$script" "$d"
check "an extra layer key" 1 "layer_extra_commit: in build-info.txt but not in "

mk "$d"
sed -i "s/^machine=.*/machine=other/" "$info"
run bash "$script" "$d"
check "a different machine" 1 "machine differs" "other"

mk "$d"
sed -i "s/^manifest_commit=.*/manifest_commit=bad/" "$info"
run bash "$script" "$d"
check "a different manifest commit" 1 "manifest_commit differs"

mk "$d"
echo "$k=dup" >>"$info"
run bash "$script" "$d"
check "a key twice" 1 "key $k appears twice"

mk "$d"
sed -i "/^distro=/d" "$info"
run bash "$script" "$d"
check "a missing key" 1 "key distro is missing"

mk "$d"
rm "$info"
run bash "$script" "$d"
check "no build-info.txt" 1 "no build-info.txt"

mk "$d" yes
run bash "$script" "$d"
check "dirty without --allow-dirty" 1 "platform_image_dirty=yes"
run bash "$script" --allow-dirty "$d"
check "dirty with --allow-dirty" 0 "OK, 3 artefacts"

mk "$d"
rm "$d/$t-$machine.rootfs-20261123000001.spdx.json"
(cd "$d" && sha256sum -- * >SHA256SUMS)
run bash "$script" "$d"
check "a missing SBOM" 1 "$t: no .spdx.json listed"

# The production manifest holds no debug package (named in the debug recipe).
mf=$d/$t-$machine.rootfs-20261123000001.manifest
rehash() {
	local f l=()
	cd "$d"
	for f in *; do
		case $f in SHA256SUMS | build-info.txt) ;; *) l+=("$f") ;; esac
	done
	sha256sum -- "${l[@]}" >SHA256SUMS
	cd - >/dev/null
}
mk "$d"
printf 'busybox cortexa55 1.36\ngdb cortexa55 14.2\n' >"$mf"
rehash
run bash "$script" "$d"
check "gdb in the production manifest" 1 "debug package gdb is in the production manifest" "$t-$machine.rootfs-20261123000001.manifest"

mk "$d"
printf 'busybox cortexa55 1.36\nstrace cortexa55 6.8\nimx-test cortexa55 1\n' >"$mf"
rehash
run bash "$script" "$d"
check "two debug packages" 1 "debug package strace is" "debug package imx-test is"

mk "$d"
printf 'busybox cortexa55 1.36\ngdbserver cortexa55 14.2\nbash-completion all 2\n' >"$mf"
rehash
run bash "$script" "$d"
check "a prefix of a debug package name" 0 "OK, 3 artefacts"

mk "$d"
: >"$mf"
rehash
run bash "$script" "$d"
check "an empty production manifest" 1 "the production manifest is empty"

mk "$d"
rm "$mf"
rehash
run bash "$script" "$d"
check "no production manifest" 1 "no .manifest listed"

# The debug target's manifest may hold them: only the production target is read.
mk "$d"
dm=$d/trusted-imx95-image-debug-$machine.rootfs-20261123000001
printf 'busybox cortexa55 1.36\ngdb cortexa55 14.2\n' >"$dm.manifest"
echo spdx >"$dm.spdx.json"
rehash
sed -i "s/^targets=.*/targets=$t trusted-imx95-image-debug/" "$info"
run bash "$script" "$d"
check "debug package in the debug target's manifest" 0 "OK, 5 artefacts"

# Several problems are all named.
mk "$d" yes
sed -i "s/^machine=.*/machine=other/" "$info"
echo loose >"$d/unlisted.bin"
run bash "$script" "$d"
check "every problem is named" 1 "machine differs" "platform_image_dirty=yes" "unlisted.bin"

mk "$d"
run make -s -C "$ROOT" platform-image-verify OUT="$d"
check "make platform-image-verify" 0 "OK, 3 artefacts"
run make -s -C "$ROOT" platform-image-verify
check "make without OUT" 2 "set OUT="
run make -C "$ROOT" help
check "make help lists the target" 0 "platform-image-verify"

run bash "$script"
check "no arguments" 2 "usage:"
run bash "$script" --bogus "$d"
check "an unknown option" 2 "unknown option --bogus"
run bash "$script" "$tmp/nodir"
check "a missing directory" 2 "is not a directory"
run bash "$script" "$d" "$tmp/nolock"
check "a missing lock" 2 "is not a file"

finish
