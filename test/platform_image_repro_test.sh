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
check "--allow is an unknown option" 2 "unknown option --allow"

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

# build-info.txt that cannot be read or lacks a required key fails the compare
# (it never skips the metadata comparison and prints OK).
noinfo() { expect "$1: no OK printed" test "${OUT##*OK*}" = "$OUT"; }
mk "$a"
mk "$b"
rm "$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info.txt missing" 1 "$b/build-info.txt: missing"
noinfo "build-info.txt missing"
mkdir "$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info.txt is a directory" 1 "$b/build-info.txt: not a regular file"
noinfo "build-info.txt is a directory"
mk "$b"
chmod 000 "$b/build-info.txt"
if [ "$(id -u)" -eq 0 ]; then
	echo "SKIP: build-info.txt chmod 000 (running as root, chmod cannot deny the read; the directory case covers the path)"
else
	run bash "$script" "$a" "$b"
	check "build-info.txt unreadable" 1 "$b/build-info.txt: cannot be read"
	noinfo "build-info.txt unreadable"
fi
chmod 644 "$b/build-info.txt"
: >"$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info.txt empty" 1 "$b/build-info.txt: empty"
noinfo "build-info.txt empty"
mk "$b"
printf '%s\n' "# build-info" "build_seconds=1" "layer_x_commit=def" >"$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info.txt without SOURCE_DATE_EPOCH" 1 "$b/build-info.txt: no SOURCE_DATE_EPOCH"
noinfo "build-info.txt without SOURCE_DATE_EPOCH"
printf '%s\n' "# build-info" "SOURCE_DATE_EPOCH=1700000000" "checkout_commit=abc" >"$b/build-info.txt"
run bash "$script" "$a" "$b"
check "build-info.txt without a layer revision" 1 "$b/build-info.txt: no layer_<name>_commit"
noinfo "build-info.txt without a layer revision"
mk "$a"
chmod 000 "$a/build-info.txt"
mk "$b"
if [ "$(id -u)" -ne 0 ]; then
	run bash "$script" "$a" "$b"
	check "first dir's build-info.txt unreadable" 1 "$a/build-info.txt: cannot be read"
fi
chmod 644 "$a/build-info.txt"

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
	printf '%s\n' "# build-info" "SOURCE_DATE_EPOCH=1700000000" "layer_x_commit=def" >"$1/build-info.txt"
}

# mksbom DIR TIMESTAMP [SPDX-CONTENT]: mkts, plus the package manifest and the
# SPDX SBOM under the same timestamped names, listed in SHA256SUMS.
mksbom() {
	mkts "$1" "$2"
	echo mf >"$1/img-m.rootfs-$2.manifest"
	echo "${3:-spdx}" >"$1/img-m.rootfs-$2.spdx.json"
	(cd "$1" && sha256sum -- img-m.* >SHA256SUMS)
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

# The SBOM and the package manifest are compared like any artefact.
mksbom "$a" 20261123000001
mksbom "$b" 20261123000002
run bash "$script" "$a" "$b"
check "identical SBOM and manifest, different timestamps" 0 "5 artefacts identical"
mksbom "$b" 20261123000002 spdx-changed
run bash "$script" "$a" "$b"
check "an SBOM with one changed byte: names the .spdx.json member" 1 "img-m.rootfs.spdx.json differs"

run bash "$script" "$a"
check "a missing argument" 2 "need exactly two output directories"
run bash "$script"
check "no arguments" 2 "usage:"
run bash "$script" --allow
check "--allow without a name" 2 "unknown option --allow"
run bash "$script" --bogus "$a" "$b"
check "an unknown option" 2 "unknown option --bogus"
run bash "$script" "$a" "$tmp/nodir"
check "a missing directory" 2 "is not a directory"

finish
