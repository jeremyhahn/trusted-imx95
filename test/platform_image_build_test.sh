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
-e) printf '%s\n' "${BB_E_OUT-export SOURCE_DATE_EPOCH=\"1700000000\"}"; exit 0 ;;
esac
echo "bitbake $*" >>"$BB_LOG"
[ -z "${BB_FAIL:-}" ] || exit 1
d=tmp/deploy/images/$BB_MACHINE
mkdir -p "$d"
for t in "$@"; do
	[ -n "${BB_NOART:-}" ] && continue
	echo wic-$t >"$d/$t-$BB_MACHINE-20261123000000.rootfs.wic.zst"
	echo tar-$t >"$d/$t-$BB_MACHINE-20261123000000.rootfs.tar.zst"
	echo mf-$t >"$d/$t-$BB_MACHINE-20261123000000.rootfs.manifest"
	ln -sf "$t-$BB_MACHINE-20261123000000.rootfs.wic.zst" "$d/$t-$BB_MACHINE.rootfs.wic.zst"
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
check "build: passes" 0 "OK, 2 artefacts"
expect "build: bitbake got the production target only" test "$(bbtargets)" = trusted-imx95-image
expect "build: conf written from the templates" cmp -s "$ROOT/platform-image/conf/local.conf.template" "$tmp/d/build/conf/local.conf"
expect "build: wic copied" test -f "$tmp/out/trusted-imx95-image-$want-20261123000000.rootfs.wic.zst"
expect "build: rootfs copied" test -f "$tmp/out/trusted-imx95-image-$want-20261123000000.rootfs.tar.zst"
expect "build: the symlink is not copied" test ! -e "$tmp/out/trusted-imx95-image-$want.rootfs.wic.zst"
expect "build: the manifest file is not copied" test ! -e "$tmp/out/trusted-imx95-image-$want-20261123000000.rootfs.manifest"
expect "build: SHA256SUMS verifies" bash -c "cd '$tmp/out' && sha256sum -c --quiet SHA256SUMS"
expect "build: SHA256SUMS lists 2 files" test "$(wc -l <"$tmp/out/SHA256SUMS")" -eq 2
info=$(cat "$tmp/out/build-info.txt")
for s in "machine=$want" "distro=trusted-imx95" "SOURCE_DATE_EPOCH=1700000000" "manifest_commit=" "layer_bitbake_commit="; do
	expect "build-info.txt holds $s" test "${info##*"$s"*}" != "$info"
done

# PI_DEBUG=1 adds the debug image.
rm -rf "$tmp/d" "$tmp/out"
PI_DEBUG=1 brun "$stub:$tools"
check "PI_DEBUG=1: passes" 0 "OK, 4 artefacts"
expect "PI_DEBUG=1: bitbake got both targets" test "$(bbtargets)" = "trusted-imx95-image trusted-imx95-image-debug"
sums=$(cat "$tmp/out/SHA256SUMS")
dbg=trusted-imx95-image-debug-
nodebug=${sums//$dbg/}
expect "PI_DEBUG=1: two debug files and two production files are listed" \
	test "$(((${#sums} - ${#nodebug}) / ${#dbg}))" -eq 2

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
check "no artefacts: fails" nonzero "left no wic or rootfs artefact"

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
orun "$(dirname "$ROOT")"
check "OUT = an ancestor of the checkout: refused" nonzero "contains this clone"
expect "OUT = an ancestor: the checkout survives" test -f "$ROOT/Makefile"
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
	check "OUT $v: accepted like the plain path" 0 "OK, 2 artefacts"
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
check "build writes the marker" 0 "OK, 2 artefacts"
expect "the output dir carries the ownership marker" test -f "$tmp/out/.platform-image-out"
expect "the marker is not in SHA256SUMS" test "$(wc -l <"$tmp/out/SHA256SUMS")" -eq 2
: >"$tmp/out/stale"
brun "$stub:$tools"
check "a marked OUT: accepted" 0 "OK, 2 artefacts"
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
check "exported SOURCE_DATE_EPOCH: build ok" 0 "OK, 2 artefacts"
expect "exported SOURCE_DATE_EPOCH: in build-info" grep -q '^SOURCE_DATE_EPOCH=1700000000$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='SOURCE_DATE_EPOCH="1700000001"' brun "$stub:$tools"
check "plain SOURCE_DATE_EPOCH: build ok" 0 "OK, 2 artefacts"
expect "plain SOURCE_DATE_EPOCH: in build-info" grep -q '^SOURCE_DATE_EPOCH=1700000001$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT=$(printf '%s\n' 'SOURCE_DATE_EPOCH="1"' 'export SOURCE_DATE_EPOCH="1700000002"') brun "$stub:$tools"
check "two SOURCE_DATE_EPOCH lines: build ok" 0 "OK, 2 artefacts"
expect "two lines: the last wins" grep -q '^SOURCE_DATE_EPOCH=1700000002$' "$tmp/out/build-info.txt"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='export SOURCE_DATE_EPOCH="12ab"' brun "$stub:$tools"
check "non-numeric SOURCE_DATE_EPOCH: dies" nonzero "no SOURCE_DATE_EPOCH in bitbake -e"
rm -rf "$tmp/d" "$tmp/out"
BB_E_OUT='' brun "$stub:$tools"
check "no SOURCE_DATE_EPOCH: dies" nonzero "no SOURCE_DATE_EPOCH in bitbake -e"
rm -rf "$tmp/d" "$tmp/out"
brun "$stub:$tools"
check "default stub (exported form): build ok" 0 "OK, 2 artefacts"

# build-info names this checkout's commit and whether platform-image/ is dirty.
info=$(cat "$tmp/out/build-info.txt")
head=$(git -C "$ROOT" rev-parse HEAD)
expect "build-info holds checkout_commit" test "${info##*"checkout_commit=$head"*}" != "$info"
expect "build-info holds the dirty marker" test "${info##*"platform_image_dirty="*}" != "$info"
expect "build-info holds the dirty sha256" test "${info##*"platform_image_dirty_sha256="*}" != "$info"

# Options.
brun "$stub:$tools" --bogus
check "an unknown option: fails" nonzero "unknown option --bogus"

# The artefacts directory is git-ignored.
expect ".platform-image/ is git-ignored" git -C "$ROOT" check-ignore -q .platform-image/out/SHA256SUMS

finish
