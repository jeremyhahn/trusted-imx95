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
-e) echo "SOURCE_DATE_EPOCH=\"1700000000\""; exit 0 ;;
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

# Options.
brun "$stub:$tools" --bogus
check "an unknown option: fails" nonzero "unknown option --bogus"

# The artefacts directory is git-ignored.
expect ".platform-image/ is git-ignored" git -C "$ROOT" check-ignore -q .platform-image/out/SHA256SUMS

finish
