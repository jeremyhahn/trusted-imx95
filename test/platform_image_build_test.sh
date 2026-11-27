#!/usr/bin/env bash
# Offline checks of scripts/platform-image-build.sh (provisional default,
# pending the owner's answer on #14): a stub fetcher and a stub bitbake on
# PATH, in a mktemp dir outside the clone. No network, no Yocto.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

script=$ROOT/scripts/platform-image-build.sh
want=$(sed -n 's/^machine=//p' "$ROOT/platform-image/manifest.lock")
expect "the lock names a machine" test -n "$want"

tmp=$TMP_ROOT
real_bash=$(command -v bash)
BB_INIT=$(sed -n 's/^INIT_MANAGER[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ROOT/platform-image/conf/distro/trusted-imx95.conf" | sed -n '$p')
export BB_INIT
hosttools="gcc g++ make git python3 tar xz bzip2 patch perl unzip wget diffstat chrpath gawk cpio file socat zstd lz4c"

# A PATH with only the tools the script uses; the host tools are stubs.
tools=$tmp/tools
stub=$tmp/stub
mkdir -p "$tools" "$stub"
for t in env sed cp mkdir dirname basename cat rm git date sha256sum ln; do
	ln -s "$(command -v "$t")" "$tools/$t"
done
for t in $hosttools; do
	[ "$t" != git ] || continue # the real git (in $tools) records the checkout
	printf '#!/bin/sh\nexit 0\n' >"$stub/$t"
	chmod +x "$stub/$t"
done

cat >"$tmp/fetch" <<'EOF'
#!/bin/sh
echo fetch >>"$BB_LOG"
mkdir -p "$2/sources/openembedded-core" "$2/sources/bitbake"
cat >"$2/sources/openembedded-core/oe-init-build-env" <<'INNER'
mkdir -p "$1"
cd "$1"
INNER
EOF
chmod +x "$tmp/fetch"
# Stub bitbake: `bitbake TARGET...` logs its arguments and writes the deploy
# files a Yocto build leaves (real files, plus the plain-name symlinks);
# `-e` prints SOURCE_DATE_EPOCH; `-m` is the server stop.
cat >"$stub/bitbake" <<'EOF'
#!/bin/sh
case $1 in
-m) exit 0 ;;
-e) # the effective values (BB_EXTRA_FEATURES: what an auto.conf adds), then SDE
	printf '%s\n' "MACHINE=\"$BB_MACHINE\"" "DISTRO=\"trusted-imx95\"" "INIT_MANAGER=\"$BB_INIT\"" \
		"IMAGE_FEATURES=\"ssh-server-dropbear\"" "EXTRA_IMAGE_FEATURES=\"${BB_EXTRA_FEATURES:-}\""
	printf '%s\n' "${BB_E_OUT-export SOURCE_DATE_EPOCH=\"1700000000\"}"; exit 0 ;;
esac
echo "bitbake $*" >>"$BB_LOG"
n=0
for f in "${SSTATE_DIR:-/nonexistent}"/* "${SSTATE_DIR:-/nonexistent}"/.[!.]*; do [ -e "$f" ] && n=$((n + 1)); done
echo "${SSTATE_DIR-unset} $n" >>"$BB_LOG.sstate"
[ -z "${BB_FAIL:-}" ] || exit 1
d=tmp/deploy/images/$BB_MACHINE
mkdir -p "$d"
for t in "$@"; do
	[ -n "${BB_NOART:-}" ] && continue
	# Yocto's real layout: <image>-<machine>.rootfs-<timestamp>.<ext>, plus
	# unsuffixed symlinks. BB_TS sets the timestamp of this build.
	ts=${BB_TS:-20261123000000}
	if [ -n "${BB_TS_SEQ:-}" ]; then # a new timestamp on every target built
		seq=$(cat "$BB_TS_SEQ" 2>/dev/null || echo 0)
		seq=$((seq + 1))
		echo "$seq" >"$BB_TS_SEQ"
		ts=$((20261123000000 + seq))
	fi
	b="$t-$BB_MACHINE.rootfs-$ts"
	# BB_SKIP=<target>: that target leaves nothing. BB_META=<target>: only a
	# bmap, a manifest and an SBOM, no wic or rootfs image.
	[ "${BB_SKIP:-}" != "$t" ] || continue
	if [ "${BB_META:-}" = "$t" ]; then
		echo bmap-$t >"$d/$b.wic.bmap"
		echo mf-$t >"$d/$b.manifest"
		echo spdx-$t >"$d/$b.spdx.json"
		echo td-$t >"$d/$b.testdata.json"
		continue
	fi
	echo wic-$t >"$d/$b.wic.zst"
	echo tar-$t >"$d/$b.tar.zst"
	echo ext4-$t >"$d/$b.ext4"
	echo bmap-$t >"$d/$b.wic.bmap"
	# BB_NONDET: a run-dependent byte (the process id) in the rootfs tarball.
	[ -z "${BB_NONDET:-}" ] || echo "$$" >>"$d/$b.tar.zst"
	echo mf-$t >"$d/$b.manifest"
	echo tj-$t >"$d/$b.testdata.json"
	# BB_NOSPDX: a build that wrote no SBOM.
	if [ -z "${BB_NOSPDX:-}" ]; then
		echo spdx-$t >"$d/$b.spdx.json"
		ln -sf "$b.spdx.json" "$d/$t-$BB_MACHINE.rootfs.spdx.json"
	fi
	ln -sf "$b.wic.zst" "$d/$t-$BB_MACHINE.rootfs.wic.zst"
	ln -sf "$b.tar.zst" "$d/$t-$BB_MACHINE.rootfs.tar.zst"
	ln -sf "$b.ext4" "$d/$t-$BB_MACHINE.rootfs.ext4"
done
EOF
chmod +x "$stub/bitbake"

# brun PATH-dir [args...]: the script into $tmp/d and $tmp/out; sets RC and OUT.
brun() {
	local p=$1
	shift
	rm -f "$tmp/log"
	RC=0
	OUT=$(PATH=$p PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$want \
		PLATFORM_IMAGE_OUT=$tmp/out "$real_bash" "$script" "$@" "$tmp/d" 2>&1) || RC=$?
}
bbtargets() { sed -n 's/^bitbake //p' "$tmp/log"; }

# Missing host tools are all named, and nothing is fetched.
brun "$tools"
check "no host tools: fails" nonzero "missing host tools:" gcc make diffstat lz4c
expect "no host tools: nothing fetched" test ! -e "$tmp/log"

# --check and --dry-run build and fetch nothing.
for flag in --check --dry-run; do
	rm -rf "$tmp/d" "$tmp/out"
	brun "$stub:$tools" "$flag"
	check "$flag: passes" 0 "check: OK, nothing fetched or built" "MACHINE=$want" "targets: trusted-imx95-image"
	expect "$flag: nothing fetched or built" test ! -e "$tmp/log"
	expect "$flag: no output directory" test ! -e "$tmp/out"
done
brun "$tools" --check
check "--check names a missing tool" nonzero "missing host tools:"

# A full run with the production image only.
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
check "build: passes" 0 "OK, 6 artefacts"
expect "build: bitbake got the production target only" test "$(bbtargets)" = trusted-imx95-image
expect "build: conf written from the templates" cmp -s "$ROOT/platform-image/conf/local.conf.template" "$tmp/d/build/conf/local.conf"
for e in wic.zst tar.zst ext4 wic.bmap manifest spdx.json; do
	expect "build: real-layout $e copied" test -f "$tmp/out/trusted-imx95-image-$want.rootfs-20261123000000.$e"
done
for e in rootfs.wic.zst rootfs.tar.zst rootfs.ext4 rootfs.spdx.json; do
	expect "build: the $e symlink is not copied" test ! -e "$tmp/out/trusted-imx95-image-$want.$e"
done
expect "build: the testdata.json file is not copied" test ! -e "$tmp/out/trusted-imx95-image-$want.rootfs-20261123000000.testdata.json"
for e in manifest spdx.json; do
	expect "build: SHA256SUMS lists the $e" grep -q "trusted-imx95-image-$want.rootfs-20261123000000.$e\$" "$tmp/out/SHA256SUMS"
done
expect "build: SHA256SUMS verifies" bash -c "cd '$tmp/out' && sha256sum -c --quiet SHA256SUMS"
expect "build: SHA256SUMS lists the 6 artefacts" test "$(wc -l <"$tmp/out/SHA256SUMS")" -eq 6
info=$(cat "$tmp/out/build-info.txt")
for s in "machine=$want" "distro=trusted-imx95" "SOURCE_DATE_EPOCH=1700000000" "manifest_commit=" "layer_bitbake_commit="; do
	expect "build-info.txt holds $s" test "${info##*"$s"*}" != "$info"
done

# PI_DEBUG=1 adds the debug image.
rm -rf "$tmp/d" "$tmp/out"
PI_DEBUG=1 brun "$stub:$tools"
check "PI_DEBUG=1: passes" 0 "OK, 12 artefacts"
expect "PI_DEBUG=1: bitbake got both targets" test "$(bbtargets)" = "trusted-imx95-image trusted-imx95-image-debug"
sums=$(cat "$tmp/out/SHA256SUMS")
dbg=trusted-imx95-image-debug-
nodebug=${sums//$dbg/}
expect "PI_DEBUG=1: six debug files and six production files are listed" \
	test "$(((${#sums} - ${#nodebug}) / ${#dbg}))" -eq 6

rm -rf "$tmp/d" "$tmp/out"
PLATFORM_IMAGE_BITBAKE_ARGS=-k brun "$stub:$tools"
expect "PLATFORM_IMAGE_BITBAKE_ARGS goes before the targets" test "$(bbtargets)" = "-k trusted-imx95-image"

# Failures.
rm -rf "$tmp/d" "$tmp/out"
BB_FAIL=1 brun "$stub:$tools"
check "a failing bitbake fails the script" nonzero
expect "a failing bitbake leaves no artefacts" test ! -e "$tmp/out"
rm -rf "$tmp/d" "$tmp/out"
BB_NOART=1 brun "$stub:$tools"
check "no artefacts: fails" nonzero "left no wic or rootfs image for trusted-imx95-image"
rm -rf "$tmp/d" "$tmp/out"
BB_NOSPDX=1 brun "$stub:$tools"
check "no SBOM: fails and names the target" nonzero "no SPDX SBOM" "trusted-imx95-image"

# A target with only a bmap, manifest and SBOM, or with nothing, is no image.
rm -rf "$tmp/d" "$tmp/out"
BB_META=trusted-imx95-image brun "$stub:$tools"
check "production target with metadata only: fails" nonzero "no wic or rootfs image for trusted-imx95-image"
rm -rf "$tmp/d" "$tmp/out"
PI_DEBUG=1 BB_META=trusted-imx95-image-debug brun "$stub:$tools"
check "debug target with metadata only: fails" nonzero "no wic or rootfs image for trusted-imx95-image-debug"
rm -rf "$tmp/d" "$tmp/out"
PI_DEBUG=1 BB_SKIP=trusted-imx95-image-debug brun "$stub:$tools"
check "debug target missing: fails" nonzero "no wic or rootfs image for trusted-imx95-image-debug"

# An existing conf that differs is refused, unless forced.
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
printf '# local edit\n' >>"$tmp/d/build/conf/local.conf"
brun "$stub:$tools"
check "a differing local.conf: refused" nonzero "PLATFORM_IMAGE_BUILD_FORCE=1"
expect "a differing local.conf: bitbake did not run" test -z "$(bbtargets)"
PLATFORM_IMAGE_BUILD_FORCE=1 brun "$stub:$tools"
check "forced: passes" 0
expect "forced: local.conf is the template again" cmp -s "$ROOT/platform-image/conf/local.conf.template" "$tmp/d/build/conf/local.conf"

# A directory inside the clone is rejected before anything is created.
inside=$ROOT/.build-test-inside-$$
RC=0
OUT=$(PATH="$stub:$tools" PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$want \
	PLATFORM_IMAGE_OUT=$tmp/out "$real_bash" "$script" "$inside" 2>&1) || RC=$?
check "a directory inside the clone: refused" nonzero "is inside this clone"
expect "a directory inside the clone: nothing created" test ! -e "$inside"

# The artefacts directory is checked before anything is removed: a full run
# (no stub bitbake is reached) with each bad PLATFORM_IMAGE_OUT is refused.
orun() {
	rm -f "$tmp/log"
	RC=0
	OUT=$(PATH="$stub:$tools" PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$want \
		PLATFORM_IMAGE_OUT=$1 "$real_bash" "$script" "$tmp/d" 2>&1) || RC=$?
}
rm -rf "$tmp/d" "$tmp/out" "$tmp/un"
mkdir -p "$tmp/d/sub" "$tmp/un"
: >"$tmp/d/sentinel"
: >"$tmp/d/sub/sentinel"
: >"$tmp/un/sentinel"
orun "$ROOT"
check "OUT = the checkout: refused" nonzero "is this clone"
expect "OUT = the checkout: Makefile survives" test -f "$ROOT/Makefile"
# The ancestor case runs on a scratch clone, so it holds wherever the real
# checkout lives (CI checks out directly under /, whose parent is the root).
rm -rf "$tmp/p"
mkdir -p "$tmp/p/clone"
cp -a "$ROOT/scripts" "$ROOT/platform-image" "$ROOT/Makefile" "$tmp/p/clone/"
real_script=$script
script=$tmp/p/clone/scripts/platform-image-build.sh
orun "$tmp/p"
check "OUT = an ancestor of the checkout: refused" nonzero "contains this clone"
expect "OUT = an ancestor: the checkout survives" test -f "$tmp/p/clone/Makefile"
script=$real_script
rm -rf "$tmp/p"
orun "$tmp/d"
check "OUT = PLATFORM_IMAGE_DIR: refused" nonzero "platform-image directory"
expect "OUT = PLATFORM_IMAGE_DIR: sentinel survives" test -f "$tmp/d/sentinel"
orun "$tmp/d/sub"
check "OUT inside PLATFORM_IMAGE_DIR: refused" nonzero "platform-image directory"
expect "OUT inside PLATFORM_IMAGE_DIR: sentinel survives" test -f "$tmp/d/sub/sentinel"
orun "$tmp"
check "OUT containing PLATFORM_IMAGE_DIR: refused" nonzero "contains"
expect "OUT containing PLATFORM_IMAGE_DIR: sentinel survives" test -f "$tmp/d/sentinel"
orun "$tmp/un"
check "an unmarked existing dir: refused" nonzero "not written by this script"
expect "an unmarked existing dir: sentinel survives" test -f "$tmp/un/sentinel"
orun ""
check "an empty OUT: refused" nonzero "PLATFORM_IMAGE_OUT is empty"
orun /
check "OUT = /: refused" nonzero "root directory"
orun "$ROOT/docs"
check "OUT inside the checkout, outside .platform-image: refused" nonzero "outside .platform-image"
expect "OUT inside the checkout: docs survive" test -d "$ROOT/docs"
orun "$tmp/new/../un"
check "OUT with '..' to an unmarked dir: refused" nonzero "'..' component"
expect "'..' case: sentinel survives" test -f "$tmp/un/sentinel"
expect "'..' case: no marker written" test ! -e "$tmp/un/.platform-image-out"
expect "'..' case: nothing fetched" test ! -e "$tmp/log"
orun "relative/out"
check "a relative OUT: refused" nonzero "not an absolute path"
# a/./b and a trailing slash behave like the plain path.
rm -rf "$tmp/d" "$tmp/out"
for v in "$tmp/./out" "$tmp/out/" "$tmp//out"; do
	brun "$stub:$tools" --check
	orun "$v"
	check "OUT $v: accepted like the plain path" 0 "OK, 6 artefacts"
	expect "OUT $v: marker in the plain path" test -f "$tmp/out/.platform-image-out"
	rm -rf "$tmp/d" "$tmp/out"
done
orun "$tmp/un/./"
check "OUT unmarked with ./ and slash: refused" nonzero "not written by this script"
expect "unmarked with ./: sentinel survives" test -f "$tmp/un/sentinel"
# A fresh dir and a marked dir are accepted (check mode, then a full run).
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools" --check
check "a fresh OUT: accepted" 0 "check: OK"
brun "$stub:$tools"
check "build writes the marker" 0 "OK, 6 artefacts"
expect "the output dir carries the ownership marker" test -f "$tmp/out/.platform-image-out"
expect "the marker is not in SHA256SUMS" test "$(wc -l <"$tmp/out/SHA256SUMS")" -eq 6
: >"$tmp/out/stale"
brun "$stub:$tools"
check "a marked OUT: accepted" 0 "OK, 6 artefacts"
expect "a marked OUT is rebuilt: the stale file is gone" test ! -e "$tmp/out/stale"

# The fetch directory is canonical before the overlap guard: a ".." under a
# missing parent is refused, and the marked OUT it names survives.
rm -rf "$tmp/d" "$tmp/out" "$tmp/missing" "$tmp/result"
mkdir -p "$tmp/result"
: >"$tmp/result/.platform-image-out"
: >"$tmp/result/sentinel"
rm -f "$tmp/log"
RC=0
OUT=$(PATH="$stub:$tools" PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$want \
	PLATFORM_IMAGE_OUT=$tmp/result "$real_bash" "$script" "$tmp/missing/../result" 2>&1) || RC=$?
check "DIR with '..' under a missing parent: refused" nonzero "contains a '..' component"
expect "DIR with '..': nothing fetched or built" test ! -e "$tmp/log"
expect "DIR with '..': the marked OUT sentinel survives" test -f "$tmp/result/sentinel"
rm -rf "$tmp/result"

# bitbake -e prints SOURCE_DATE_EPOCH exported (OE-core) or plain; the last
# value wins; only a decimal integer is accepted.
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='export SOURCE_DATE_EPOCH="1700000000"' brun "$stub:$tools"
check "exported SOURCE_DATE_EPOCH: build ok" 0 "OK, 6 artefacts"
expect "exported SOURCE_DATE_EPOCH: in build-info" grep -q '^SOURCE_DATE_EPOCH=1700000000$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='SOURCE_DATE_EPOCH="1700000001"' brun "$stub:$tools"
check "plain SOURCE_DATE_EPOCH: build ok" 0 "OK, 6 artefacts"
expect "plain SOURCE_DATE_EPOCH: in build-info" grep -q '^SOURCE_DATE_EPOCH=1700000001$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT=$(printf '%s\n' 'SOURCE_DATE_EPOCH="1"' 'export SOURCE_DATE_EPOCH="1700000002"') brun "$stub:$tools"
check "two SOURCE_DATE_EPOCH lines: build ok" 0 "OK, 6 artefacts"
expect "two lines: the last wins" grep -q '^SOURCE_DATE_EPOCH=1700000002$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='export SOURCE_DATE_EPOCH="12ab"' brun "$stub:$tools"
check "non-numeric SOURCE_DATE_EPOCH: dies" nonzero "no SOURCE_DATE_EPOCH in bitbake -e"
# The plain form passes the old anchored sed, so only the decimal check refuses it.
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='SOURCE_DATE_EPOCH="12ab"' brun "$stub:$tools"
check "plain non-numeric SOURCE_DATE_EPOCH: dies" nonzero "no SOURCE_DATE_EPOCH in bitbake -e"
expect "plain non-numeric SOURCE_DATE_EPOCH: no artefacts" test ! -e "$tmp/out"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='' brun "$stub:$tools"
check "no SOURCE_DATE_EPOCH: dies" nonzero "no SOURCE_DATE_EPOCH in bitbake -e"
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
check "default stub (exported form): build ok" 0 "OK, 6 artefacts"

# build-info names this checkout's commit and whether platform-image/ is dirty.
info=$(cat "$tmp/out/build-info.txt")
head=$(git -C "$ROOT" rev-parse HEAD)
expect "build-info holds checkout_commit" test "${info##*"checkout_commit=$head"*}" != "$info"
expect "build-info holds the dirty marker" test "${info##*"platform_image_dirty="*}" != "$info"
expect "build-info holds the dirty sha256" test "${info##*"platform_image_dirty_sha256="*}" != "$info"

# A conf/auto.conf the templates do not know sets EXTRA_IMAGE_FEATURES: bitbake -e
# shows it, and the build is refused before bitbake builds anything.
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
printf 'EXTRA_IMAGE_FEATURES = "debug-tweaks"\n' >"$tmp/d/build/conf/auto.conf"
rm -rf "$tmp/out"
BB_EXTRA_FEATURES=debug-tweaks brun "$stub:$tools"
check "auto.conf: refused before bitbake" nonzero "holds configuration this script did not write (auto.conf)"
expect "auto.conf: bitbake built nothing" test -z "$(bbtargets)"
# with ALLOW_DIRTY=1 the effective-value check still refuses debug-tweaks
rm -rf "$tmp/out"
ALLOW_DIRTY=1 BB_EXTRA_FEATURES=debug-tweaks brun "$stub:$tools"
check "auto.conf + ALLOW_DIRTY=1: effective EXTRA_IMAGE_FEATURES still refused" nonzero "EXTRA_IMAGE_FEATURES holds debug-tweaks"

# An auto.conf that sets IMAGE_FEATURES (the effective values look fine) is
# refused; so is a site.conf; ALLOW_DIRTY=1 builds, records dirty=yes and a hash.
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
printf 'IMAGE_FEATURES = "ssh-server-dropbear"\n' >"$tmp/d/build/conf/auto.conf"
rm -rf "$tmp/out"
brun "$stub:$tools"
check "auto.conf IMAGE_FEATURES: refused" nonzero "auto.conf"
rm -f "$tmp/d/build/conf/auto.conf"
printf 'BB_NUMBER_THREADS = "1"\n' >"$tmp/d/build/conf/site.conf"
rm -rf "$tmp/out"
brun "$stub:$tools"
check "site.conf: refused" nonzero "site.conf"
rm -rf "$tmp/out"
ALLOW_DIRTY=1 brun "$stub:$tools"
check "site.conf + ALLOW_DIRTY=1: builds" 0 "OK, 6 artefacts"
einfo=$(cat "$tmp/out/build-info.txt")
expect "ALLOW_DIRTY=1 records dirty=yes" test "${einfo##*"platform_image_dirty=yes"*}" != "$einfo"
sitesha=$(sha256sum <"$tmp/d/build/conf/site.conf" | sed 's/ .*//')
expect "ALLOW_DIRTY=1 records the site.conf hash" test "${einfo##*"platform_image_extra_conf=site.conf:$sitesha"*}" != "$einfo"
vout=$(bash "$ROOT/scripts/platform-image-verify.sh" "$tmp/out" 2>&1 || true)
expect "the verifier rejects that output without --allow-dirty" test "${vout##*"platform_image_dirty=yes"*}" != "$vout"
rm -rf "$tmp/d" "$tmp/out"
BB_INIT=other brun "$stub:$tools"
check "a different effective INIT_MANAGER: refused" nonzero "INIT_MANAGER is 'other'"
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
check "no override: build ok again" 0 "OK, 6 artefacts"

# An ignored input (.git/info/exclude) that BitBake still loads is dirty. The
# build runs from a scratch git copy of the script and platform-image/.
sc=$tmp/scratch-clone
rm -rf "$sc" "$tmp/d" "$tmp/out"
mkdir -p "$sc/scripts"
cp "$script" "$ROOT/scripts/platform-image-effective.sh" "$sc/scripts/"
cp -r "$ROOT/platform-image" "$sc/platform-image"
git -C "$sc" init -q
git -C "$sc" add -A
git -C "$sc" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m scratch
sbrun() {
	RC=0
	OUT=$(PATH=$stub:$tools PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$want \
		PLATFORM_IMAGE_OUT=$tmp/out "$real_bash" "$sc/scripts/platform-image-build.sh" "$tmp/d" 2>&1) || RC=$?
}
sbrun
check "scratch clone, clean: build ok" 0 "OK, 6 artefacts"
expect "scratch clone, clean: dirty=no" grep -q '^platform_image_dirty=no$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
echo "platform-image/hidden.bbappend" >>"$sc/.git/info/exclude"
echo "# loaded by BBFILES" >"$sc/platform-image/hidden.bbappend"
sbrun
check "scratch clone, ignored bbappend: build ok" 0 "OK, 6 artefacts"
expect "an ignored input records dirty=yes" grep -q '^platform_image_dirty=yes$' "$tmp/out/build-info.txt"

# --repro: two builds in separate directories, compared, published on a match.
rm -rf "$tmp/d" "$tmp/out" "$tmp"/d.repro-* "$tmp"/out.repro-*
BB_TS_SEQ="$tmp/seq" brun "$stub:$tools" --repro
check "--repro: deterministic stub passes" 0 "OK, 6 artefacts" "two builds identical"
expect "--repro: bitbake ran twice" test "$(wc -l <"$tmp/log")" -eq 4
expect "--repro: SHA256SUMS published and verifies" bash -c "cd '$tmp/out' && sha256sum -c --quiet SHA256SUMS"
expect "--repro: build-info published" test -f "$tmp/out/build-info.txt"
expect "--repro: the marker is published" test -f "$tmp/out/.platform-image-out"
expect "--repro: build 1 had its own directory" test -d "$tmp/d.repro-a/build/conf"
expect "--repro: build 2 had its own directory" test -d "$tmp/d.repro-b/build/conf"
expect "--repro: staged outputs removed" test ! -e "$tmp/out.repro-a" -a ! -e "$tmp/out.repro-b"
# A second run empties the two directories first.
: >"$tmp/d.repro-a/stale"
BB_TS_SEQ="$tmp/seq" brun "$stub:$tools" --repro
check "--repro: a second run passes" 0 "two builds identical"
expect "--repro: the stale file in a build directory is gone" test ! -e "$tmp/d.repro-a/stale"
# Each --repro build has its own SSTATE_DIR, empty when bitbake starts.
rm -f "$tmp/log.sstate"
BB_TS_SEQ="$tmp/seq" brun "$stub:$tools" --repro
expect "--repro: two bitbake runs recorded an SSTATE_DIR" test "$(wc -l <"$tmp/log.sstate")" -eq 2
expect "--repro: build 1 SSTATE_DIR is its own and empty" test "$(sed -n 1p "$tmp/log.sstate")" = "$tmp/d.repro-a/sstate-cache 0"
expect "--repro: build 2 SSTATE_DIR is its own and empty" test "$(sed -n 2p "$tmp/log.sstate")" = "$tmp/d.repro-b/sstate-cache 0"

rm -rf "$tmp/d" "$tmp/out" "$tmp"/d.repro-* "$tmp"/out.repro-*
BB_NONDET=1 BB_TS_SEQ="$tmp/seq" brun "$stub:$tools" --repro
check "--repro: a nondeterministic artefact fails" nonzero "tar.zst differs" "not reproducible" "nothing published"
expect "--repro: nothing published" test ! -e "$tmp/out"

# An existing, unmarked directory is never emptied.
rm -rf "$tmp/d" "$tmp/out" "$tmp"/d.repro-* "$tmp"/out.repro-*
mkdir -p "$tmp/d.repro-a"
: >"$tmp/d.repro-a/sentinel"
BB_TS_SEQ="$tmp/seq" brun "$stub:$tools" --repro
check "--repro: an unmarked directory is refused" nonzero "was not written by --repro"
expect "--repro: the unmarked directory survives" test -f "$tmp/d.repro-a/sentinel"
rm -rf "$tmp/d.repro-a"

# --check with --repro builds and fetches nothing.
rm -rf "$tmp/d" "$tmp/out" "$tmp"/d.repro-* "$tmp"/out.repro-*
brun "$stub:$tools" --repro --check
check "--repro --check: passes" 0 "check: --repro:" "check: OK, nothing fetched or built"
expect "--repro --check: no bitbake, no fetch" test ! -e "$tmp/log"
expect "--repro --check: no directories" test ! -e "$tmp/d.repro-a" -a ! -e "$tmp/out"

# Options.
brun "$stub:$tools" --bogus
check "an unknown option: fails" nonzero "unknown option --bogus"

# The artefacts directory is git-ignored.
expect ".platform-image/ is git-ignored" git -C "$ROOT" check-ignore -q .platform-image/out/SHA256SUMS

finish
