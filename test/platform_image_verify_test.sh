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

# Several problems are all named.
mk "$d" yes
sed -i "s/^machine=.*/machine=other/" "$info"
echo loose >"$d/unlisted.bin"
run bash "$script" "$d"
check "every problem is named" 1 "machine differs" "platform_image_dirty=yes" "unlisted.bin"

run bash "$script"
check "no arguments" 2 "usage:"
run bash "$script" --bogus "$d"
check "an unknown option" 2 "unknown option --bogus"
run bash "$script" "$tmp/nodir"
check "a missing directory" 2 "is not a directory"
run bash "$script" "$d" "$tmp/nolock"
check "a missing lock" 2 "is not a file"

finish
