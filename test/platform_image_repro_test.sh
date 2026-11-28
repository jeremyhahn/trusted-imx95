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
	echo wic >"$1/img-m.wic.zst"
	echo tar >"$1/img-m.rootfs.tar.zst"
	(cd "$1" && sha256sum -- img-m.* >SHA256SUMS)
	printf '%s\n' "# build-info" "machine=m" "targets=img" "SOURCE_DATE_EPOCH=${3:-1700000000}" \
		"build_seconds=${2:-10}" "checkout_commit=abc" "layer_x_commit=def" >"$1/build-info.txt"
}
# rehash DIR: rewrite DIR/SHA256SUMS from the files.
rehash() { (cd "$1" && sha256sum -- img-m.* >SHA256SUMS); }
sum() { local s; s=$(sha256sum <"$1"); echo "${s%% *}"; }

a=$tmp/a
b=$tmp/b

mk "$a"
mk "$b" 99
run bash "$script" "$a" "$b"
check "identical dirs (build_seconds differs only)" 0 "platform-image-repro: OK, 2 artefacts identical"

mk "$a"
mk "$b"
echo other >"$b/img-m.wic.zst"
rehash "$b"
ha=$(sum "$a/img-m.wic.zst")
hb=$(sum "$b/img-m.wic.zst")
run bash "$script" "$a" "$b"
check "one artefact differs" 1 "img-m.wic.zst differs" "$ha" "$hb"
expect "the identical artefact is not named" test "${OUT##*img-m.rootfs.tar.zst*}" = "$OUT"

run bash "$script" --allow img-m.wic.zst "$a" "$b"
check "--allow is an unknown option" 2 "unknown option --allow"

mk "$a"
mk "$b"
echo more >"$b/img-m.extra.zst"
rehash "$b"
run bash "$script" "$a" "$b"
check "an artefact only in one dir" 1 "img-m.extra.zst: only in $b"

mk "$a"
mk "$b"
echo tampered >"$b/img-m.wic.zst"
run bash "$script" "$a" "$b"
check "bytes no longer match the dir's SHA256SUMS" 1 "img-m.wic.zst: bytes do not match"

mk "$a"
mk "$b"
echo loose >"$b/unlisted.bin"
run bash "$script" "$a" "$b"
check "a file not listed in SHA256SUMS" 1 "unlisted.bin: in $b but not listed"

mk "$a"
mk "$b"
rm "$b/img-m.rootfs.tar.zst"
run bash "$script" "$a" "$b"
check "a listed file is missing" 1 "img-m.rootfs.tar.zst: listed in"

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
	printf '%s\n' "# build-info" "machine=m" "targets=img" "SOURCE_DATE_EPOCH=1700000000" "layer_x_commit=def" >"$1/build-info.txt"
}

# mksbom DIR TIMESTAMP [SPDX-CONTENT]: mkts, plus the package manifest and the
# SPDX SBOM under the same timestamped names, listed in SHA256SUMS.
mksbom() {
	mkts "$1" "$2"
	echo mf >"$1/img-m.rootfs-$2.manifest"
	printf '{"version":"%s"}\n' "${3:-spdx}" >"$1/img-m.rootfs-$2.spdx.json"
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

# An SBOM is compared normalised: the same graph in another element order and
# with other CreationInfo numbering is equal; a changed package version is not.
sbom() { # DIR TIMESTAMP JSON
	mkts "$1" "$2"
	printf '%s\n' "$3" >"$1/img-m.rootfs-$2.spdx.json"
	(cd "$1" && sha256sum -- img-m.* >SHA256SUMS)
}
ci1='{"@id":"_:CreationInfo_1","type":"CreationInfo","created":"2026-11-23T00:00:00Z"}'
ci2='{"@id":"_:CreationInfo_2","type":"CreationInfo","created":"2026-11-24T00:00:00Z"}'
pa='{"spdxId":"urn:p:a","type":"software_Package","name":"a","software_packageVersion":"1.0","creationInfo":"_:CreationInfo_1"}'
pb='{"spdxId":"urn:p:b","type":"software_Package","name":"b","software_packageVersion":"2.0","creationInfo":"_:CreationInfo_2"}'
sbom "$a" 20261123000001 "{\"@graph\":[$ci1,$ci2,$pa,$pb],\"rootElement\":[\"urn:p:a\",\"urn:p:b\"]}"
# b: reversed graph, the two CreationInfo blank nodes numbered 7 and 3 instead of 1 and 2.
sbom "$b" 20261123000002 "{\"@graph\":[${pb//CreationInfo_2/CreationInfo_3},${pa//CreationInfo_1/CreationInfo_7},${ci2//CreationInfo_2/CreationInfo_3},${ci1//CreationInfo_1/CreationInfo_7}],\"rootElement\":[\"urn:p:b\",\"urn:p:a\"]}"
run bash "$script" "$a" "$b"
check "SBOMs differing only in element order and CreationInfo numbering compare equal" 0 "OK, 4 artefacts identical"
sbom "$b" 20261123000002 "{\"@graph\":[${pb//CreationInfo_2/CreationInfo_3},${pa//CreationInfo_1/CreationInfo_7},${ci2//CreationInfo_2/CreationInfo_3},${ci1//CreationInfo_1/CreationInfo_7}],\"rootElement\":[\"urn:p:b\",\"urn:p:a\"]}"
sed_v=${pa//1.0/1.1}
sbom "$b" 20261123000002 "{\"@graph\":[${pb//CreationInfo_2/CreationInfo_3},${sed_v//CreationInfo_1/CreationInfo_7},${ci2//CreationInfo_2/CreationInfo_3},${ci1//CreationInfo_1/CreationInfo_7}],\"rootElement\":[\"urn:p:b\",\"urn:p:a\"]}"
run bash "$script" "$a" "$b"
check "an SBOM with a changed package version differs" 1 "img-m.rootfs.spdx.json differs"

# The task hash in an id ("<prefix>/<pn>-<uuid>/<64 hex>/<suffix>", OE-core's
# sbom30.py new_spdxid) differs from build to build and is stripped from ids and
# references; the ids here are synthetic.
h1=$(printf 'a%.0s' $(seq 64))
h2=$(printf 'b%.0s' $(seq 64))
uid=12345678-1234-1234-1234-123456789abc
idsbom() { # PREFIX HASH VERSION: one package and a reference to it
	printf '{"@graph":[{"spdxId":"%s/%s/package/a","type":"software_Package","name":"a","software_packageVersion":"%s"}],"rootElement":["%s/%s/package/a"]}' \
		"$1" "$2" "$3" "$1" "$2"
}
sbom "$a" 20261123000001 "$(idsbom "https://example.invalid/spdx/pkg-$uid" "$h1" 1.0)"
sbom "$b" 20261123000002 "$(idsbom "https://example.invalid/spdx/pkg-$uid" "$h2" 1.0)"
run bash "$script" "$a" "$b"
check "SBOMs whose ids differ only in the task-hash segment compare equal" 0 "OK, 4 artefacts identical"
sbom "$b" 20261123000002 "$(idsbom "https://example.invalid/spdx/pkg-$uid" "$h2" 1.1)"
run bash "$script" "$a" "$b"
check "the same pair with a changed package version differs" 1 "img-m.rootfs.spdx.json differs"
# A 64-hex segment that does not follow a <pn>-<uuid> segment is not stripped.
sbom "$a" 20261123000001 "$(idsbom "https://example.invalid/spdx/pkg" "$h1" 1.0)"
sbom "$b" 20261123000002 "$(idsbom "https://example.invalid/spdx/pkg" "$h2" 1.0)"
run bash "$script" "$a" "$b"
check "a hex segment not after <pn>-<uuid> is kept: the SBOMs differ" 1 "img-m.rootfs.spdx.json differs"
# The same text in a non-id field (a download location) is not stripped.
locsbom() { # HASH: ids identical, only the download location digest varies
	printf '{"@graph":[{"spdxId":"https://example.invalid/spdx/pkg-%s/%s/package/a","type":"software_Package","name":"a","software_downloadLocation":"https://example.invalid/spdx/pkg-%s/%s/source.tar.gz"}]}' \
		"$uid" "$h1" "$uid" "$1"
}
sbom "$a" 20261123000001 "$(locsbom "$h1")"
sbom "$b" 20261123000002 "$(locsbom "$h2")"
run bash "$script" "$a" "$b"
check "a digest differing only in a non-id field (download location) differs" 1 "img-m.rootfs.spdx.json differs"

# A shared element is owned by the recipe whose task ran first: a licence id's
# <pn>-<uuid> owner segment, the hash ending a relationship id, the CreationInfo
# "created" time and the image build stamp differ between two builds of the same
# graph and are replaced by constants; the ids here are synthetic.
shbom() { # LICENCE-OWNER RELATIONSHIP-HASH CREATED STAMP LICENCE-EXPRESSION [DOWNLOAD-LOCATION]
	local ns=http://spdx.org/spdxdocs/img-$uid/UNIHASH lic=http://spdx.org/spdxdocs/$1/UNIHASH/license/3_28_0/MIT
	printf '{"@graph":[{"@id":"_:C1","type":"CreationInfo","created":"%s"},' "$3"
	printf '{"spdxId":"%s","type":"simplelicensing_LicenseExpression","simplelicensing_licenseExpression":"%s","creationInfo":"_:C1"},' "$lic" "$5"
	printf '{"spdxId":"%s/relationship/%s","type":"Relationship","relationshipType":"hasDeclaredLicense","from":"%s/package/a","to":["%s"],"creationInfo":"_:C1"},' "$ns" "$2" "$ns" "$lic"
	printf '{"spdxId":"%s/image/img-m_rootfs-%s_wic","name":"img-m.rootfs-%s.wic","software_downloadLocation":"%s","type":"software_File"}]}' "$ns" "$4" "$4" "${6:-https://example.invalid/img.tar.gz}"
}
sbom "$a" 20261123000001 "$(shbom "acl-$uid" 0123456789abcdef0123456789abcdef 2025-02-27T16:29:06Z 20261123000001 MIT)"
sbom "$b" 20261123000002 "$(shbom "attr-87654321-4321-4321-4321-cba987654321" fedcba9876543210fedcba9876543210 2011-04-05T23:00:00Z 20261123000002 MIT)"
run bash "$script" "$a" "$b"
check "SBOMs differing only in licence owner, relationship hash, created time and build stamp compare equal" 0 "OK, 4 artefacts identical"
sbom "$b" 20261123000002 "$(shbom "attr-87654321-4321-4321-4321-cba987654321" fedcba9876543210fedcba9876543210 2011-04-05T23:00:00Z 20261123000002 Apache-2.0)"
run bash "$script" "$a" "$b"
check "the same pair with a changed licence expression differs" 1 "img-m.rootfs.spdx.json differs"
# The stamp is normalised only in names and ids: a download location that
# differs only in a rootfs-<14 digits> pattern is a real difference.
sbom "$a" 20261123000001 "$(shbom "acl-$uid" 0123456789abcdef0123456789abcdef 2025-02-27T16:29:06Z 20261123000001 MIT https://example.invalid/rootfs-20261123000001.tar.gz)"
sbom "$b" 20261123000002 "$(shbom "acl-$uid" 0123456789abcdef0123456789abcdef 2025-02-27T16:29:06Z 20261123000002 MIT https://example.invalid/rootfs-20261123000002.tar.gz)"
run bash "$script" "$a" "$b"
check "SBOMs differing in a download location by a rootfs stamp differ" 1 "img-m.rootfs.spdx.json differs"

# Nothing to compare is a failure, never "0 artefacts identical".
mk "$a"
mk "$b"
: >"$a/SHA256SUMS"
rm -f "$a"/img-m.*
: >"$b/SHA256SUMS"
rm -f "$b"/img-m.*
run bash "$script" "$a" "$b"
check "both SHA256SUMS empty" 1 "no artefact to compare: both SHA256SUMS are empty" "$a" "$b"
noinfo "both SHA256SUMS empty"
mk "$b"
run bash "$script" "$a" "$b"
check "one SHA256SUMS empty, the other populated" 1 "only in $b"
noinfo "one SHA256SUMS empty"

# A target with only a bmap, manifest and SBOM (identical in both) is no image.
for d in "$a" "$b"; do
	mk "$d"
	rm "$d"/img-m.*
	echo bmap >"$d/img-m.rootfs-20261123000001.wic.bmap"
	echo mf >"$d/img-m.rootfs-20261123000001.manifest"
	echo '{"version":"spdx"}' >"$d/img-m.rootfs-20261123000001.spdx.json"
	(cd "$d" && sha256sum -- img-m.* >SHA256SUMS)
done
run bash "$script" "$a" "$b"
check "metadata only, no image: fails" 1 "no wic or rootfs image listed for target img"
# A .rootfs-<ts>.testdata.json in place of the bmap is no image either.
for d in "$a" "$b"; do
	rm "$d/img-m.rootfs-20261123000001.wic.bmap"
	echo td >"$d/img-m.rootfs-20261123000001.testdata.json"
	(cd "$d" && sha256sum -- img-m.* >SHA256SUMS)
done
run bash "$script" "$a" "$b"
check "testdata.json, manifest and SBOM, no image: fails" 1 "no wic or rootfs image listed for target img"
# A requested debug target with no image at all, though the production one has.
for d in "$a" "$b"; do
	mk "$d"
	printf '%s\n' "# build-info" "machine=m" "targets=img img-debug" "SOURCE_DATE_EPOCH=1700000000" \
		"layer_x_commit=def" >"$d/build-info.txt"
done
run bash "$script" "$a" "$b"
check "a requested target with no image: fails" 1 "no wic or rootfs image listed for target img-debug"
# An empty targets= line.
for d in "$a" "$b"; do
	mk "$d"
	printf '%s\n' "# build-info" "machine=m" "targets=" "SOURCE_DATE_EPOCH=1700000000" \
		"layer_x_commit=def" >"$d/build-info.txt"
done
run bash "$script" "$a" "$b"
check "empty targets=: fails" 1 "targets= is empty or missing"

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
