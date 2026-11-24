#!/usr/bin/env bash
# Offline checks of scripts/platform-image-repro-compare.sh (provisional,
# pending the owner's answer on #14): synthetic output directories in
# $TMP_ROOT. No network, no bitbake.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

script=$ROOT/scripts/platform-image-repro-compare.sh
tmp=$TMP_ROOT

# mk DIR [SECONDS] [SDE]: two artefacts, SHA256SUMS and build-info.txt.
mk() {
	rm -rf "$1"
	mkdir -p "$1"
	echo wic >"$1/img.wic.zst"
	echo tar >"$1/img.rootfs.tar.zst"
	(cd "$1" && sha256sum -- img.* >SHA256SUMS)
	printf '%s\n' "# build-info" "SOURCE_DATE_EPOCH=${3:-1700000000}" \
		"build_seconds=${2:-10}" "checkout_commit=abc" "layer_x_commit=def" >"$1/build-info.txt"
}
# rehash DIR: rewrite DIR/SHA256SUMS from the files.
rehash() { (cd "$1" && sha256sum -- img.* >SHA256SUMS); }
sum() { local s; s=$(sha256sum <"$1"); echo "${s%% *}"; }

a=$tmp/a
b=$tmp/b

mk "$a"
mk "$b" 99
run bash "$script" "$a" "$b"
check "identical dirs (build_seconds differs only)" 0 "platform-image-repro: OK, 2 artefacts identical"

mk "$a"
mk "$b"
echo other >"$b/img.wic.zst"
rehash "$b"
ha=$(sum "$a/img.wic.zst")
hb=$(sum "$b/img.wic.zst")
run bash "$script" "$a" "$b"
check "one artefact differs" 1 "img.wic.zst differs" "$ha" "$hb"
expect "the identical artefact is not named" test "${OUT##*img.rootfs.tar.zst*}" = "$OUT"

run bash "$script" --allow img.wic.zst "$a" "$b"
check "--allow on the differing artefact" 0 "OK, 1 artefacts identical" "img.wic.zst differs but is allowed"
run bash "$script" --allow img.rootfs.tar.zst "$a" "$b"
check "--allow on another artefact does not help" 1 "img.wic.zst differs"

mk "$a"
mk "$b"
echo more >"$b/img.extra.zst"
rehash "$b"
run bash "$script" "$a" "$b"
check "an artefact only in one dir" 1 "img.extra.zst: only in $b"

mk "$a"
mk "$b"
echo tampered >"$b/img.wic.zst"
run bash "$script" "$a" "$b"
check "bytes no longer match the dir's SHA256SUMS" 1 "img.wic.zst: bytes do not match"

mk "$a"
mk "$b"
echo loose >"$b/unlisted.bin"
run bash "$script" "$a" "$b"
check "a file not listed in SHA256SUMS" 1 "unlisted.bin: in $b but not listed"

mk "$a"
mk "$b"
rm "$b/img.rootfs.tar.zst"
run bash "$script" "$a" "$b"
check "a listed file is missing" 1 "img.rootfs.tar.zst: listed in"

mk "$a"
mk "$b" 10 1700000001
run bash "$script" "$a" "$b"
check "SOURCE_DATE_EPOCH differs" 1 "build-info SOURCE_DATE_EPOCH differs" "1700000000" "1700000001"

mk "$a"
mk "$b"
printf 'layer_y_commit=zzz\n' >>"$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info has an extra line" 1 "build-info.txt has"

# Yocto's names carry the build timestamp (.rootfs-<14 digits>.<ext>): two
# builds made at different times compare by the name without it.
# mkts DIR TIMESTAMP [TAR-CONTENT]
mkts() {
	rm -rf "$1"
	mkdir -p "$1"
	echo wic >"$1/img-m.rootfs-$2.wic.zst"
	echo "${3:-tar}" >"$1/img-m.rootfs-$2.tar.zst"
	echo ext4 >"$1/img-m.rootfs-$2.ext4"
	(cd "$1" && sha256sum -- img-m.* >SHA256SUMS)
	printf '%s\n' "# build-info" "SOURCE_DATE_EPOCH=1700000000" >"$1/build-info.txt"
}
mkts "$a" 20261123000001
mkts "$b" 20261123000002
run bash "$script" "$a" "$b"
check "identical bytes, different timestamps" 0 "3 artefacts identical"
mkts "$b" 20261123000002 other
run bash "$script" "$a" "$b"
check "different bytes, different timestamps: names the member" 1 "img-m.rootfs.tar.zst differs"
mkts "$b" 20261123000002
rm "$b/img-m.rootfs-20261123000002.ext4"
(cd "$b" && sha256sum -- img-m.* >SHA256SUMS)
run bash "$script" "$a" "$b"
check "a member missing from one build: named" 1 "img-m.rootfs.ext4: only in $a"

run bash "$script" "$a"
check "a missing argument" 2 "need exactly two output directories"
run bash "$script"
check "no arguments" 2 "usage:"
run bash "$script" --allow
check "--allow without a name" 2 "--allow needs"
run bash "$script" --bogus "$a" "$b"
check "an unknown option" 2 "unknown option --bogus"
run bash "$script" "$a" "$tmp/nodir"
check "a missing directory" 2 "is not a directory"

finish
