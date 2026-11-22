#!/usr/bin/env bash
# Offline checks of scripts/platform-image-parse.sh (provisional default,
# pending the owner's answer on #14): a stub fetcher and a stub bitbake on
# PATH, in a mktemp dir outside the clone. No network, no Yocto.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILS=0
export LC_ALL=C

script=$ROOT/scripts/platform-image-parse.sh
want=$(sed -n 's/^machine=//p' "$ROOT/platform-image/manifest.lock")
expect "the lock names a machine" test -n "$want"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_bash=$(command -v bash)

# A PATH with only the tools the script uses, and no bitbake of the host.
tools=$tmp/tools
mkdir -p "$tools" "$tmp/stub"
for t in env sed cp mkdir dirname basename cat; do
	ln -s "$(command -v "$t")" "$tools/$t"
done

# Stub fetcher: lays out the layer root the script sources from.
cat >"$tmp/fetch" <<'EOF'
#!/bin/sh
mkdir -p "$2/sources/openembedded-core" "$2/sources/bitbake"
cat >"$2/sources/openembedded-core/oe-init-build-env" <<'INNER'
printf '%s|%s|%s\n' "$1" "$2" "$BITBAKEDIR" >"$BB_INIT_LOG"
: "$BB_UNSET_ON_SOURCE"
INNER
EOF
chmod +x "$tmp/fetch"
# Stub bitbake: `-p` exits BB_P_RC; `-e TARGET` logs the target and prints the
# variables the script checks (BB_MACHINE, BB_DISTRO, BB_INIT, BB_FEATURES).
cat >"$tmp/stub/bitbake" <<'EOF'
#!/bin/sh
case $1 in
-p) exit "${BB_P_RC:-0}" ;;
-e)
	echo "$2" >>"$BB_LOG"
	echo "MACHINE=\"$BB_MACHINE\""
	echo "DISTRO=\"${BB_DISTRO-trusted-imx95}\""
	echo "INIT_MANAGER=\"${BB_INIT-systemd}\""
	echo "IMAGE_FEATURES=\"${BB_FEATURES-read-only-rootfs tools-debug package-management}\""
	;;
esac
EOF
chmod +x "$tmp/stub/bitbake"

run2() { # PATH-dir MACHINE [P-RC]: runs the script into $tmp/d as it is; sets rc and out
	rm -f "$tmp/log"
	rc=0
	out=$(PATH=$1 PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_INIT_LOG=$tmp/init.log \
		BB_MACHINE=$2 BB_P_RC=${3:-0} "$real_bash" "$script" "$tmp/d" 2>&1) || rc=$?
}
run() { # PATH-dir MACHINE [P-RC]: the same into a fresh dir
	rm -rf "$tmp/d"
	run2 "$@"
}

run "$tools" "$want"
expect "no bitbake: the script fails" test "$rc" -ne 0
expect "no bitbake: it says bitbake is not on PATH" test "${out##*bitbake is not on PATH*}" != "$out"

run "$tmp/stub:$tools" "$want"
expect "matching MACHINE: the script passes" test "$rc" -eq 0
expect "matching MACHINE: it reports OK" test "${out##*parse: OK*}" != "$out"
expect "both image targets were queried" test "$(cat "$tmp/log")" = "trusted-imx95-image
trusted-imx95-image-debug"
expect "the build conf was written from the templates" test -f "$tmp/d/build/conf/bblayers.conf" -a -f "$tmp/d/build/conf/local.conf"

run "$tmp/stub:$tools" other-machine
expect "differing MACHINE: the script fails" test "$rc" -ne 0
msg="trusted-imx95-image: MACHINE is 'other-machine', the lock pins '$want'"
expect "differing MACHINE: it names the target and the pin" test "${out##*"$msg"*}" != "$out"

run "$tmp/stub:$tools" "$want" 1
expect "a failing bitbake -p fails the script" test "$rc" -ne 0
expect "a failing bitbake -p queries no target" test ! -e "$tmp/log"

# oe-init-build-env is sourced with -u off, given the build dir and the pinned bitbake dir.
run "$tmp/stub:$tools" "$want"
expect "oe-init-build-env reading an unset variable does not stop the script" test "$rc" -eq 0
d=$(cd "$tmp/d" && pwd -P)
expect "oe-init-build-env got the build dir and the bitbake dir (argument 2 and BITBAKEDIR)" \
	test "$(cat "$tmp/init.log")" = "$d/build|$d/sources/bitbake|$d/sources/bitbake"

# Each effective-value check fails by name, with no further target queried.
BB_DISTRO=other run "$tmp/stub:$tools" "$want"
expect "differing DISTRO: the script fails" test "$rc" -ne 0
expect "differing DISTRO: it names the target and the policy" \
	test "${out##*"trusted-imx95-image: DISTRO is 'other', local.conf.template sets 'trusted-imx95'"*}" != "$out"
BB_INIT=sysvinit run "$tmp/stub:$tools" "$want"
expect "differing INIT_MANAGER: the script fails" test "$rc" -ne 0
expect "differing INIT_MANAGER: it names the target and the policy" \
	test "${out##*"trusted-imx95-image: INIT_MANAGER is 'sysvinit', the distro sets 'systemd'"*}" != "$out"
for bad in debug-tweaks empty-root-password allow-empty-password allow-root-login; do
	BB_FEATURES="read-only-rootfs $bad tools-debug" run "$tmp/stub:$tools" "$want"
	expect "IMAGE_FEATURES with $bad: the script fails" test "$rc" -ne 0
	expect "IMAGE_FEATURES with $bad: it names the feature" test "${out##*"IMAGE_FEATURES holds $bad"*}" != "$out"
done
BB_FEATURES="read-only-rootfs
tools-debug debug-tweaks" run "$tmp/stub:$tools" "$want"
expect "IMAGE_FEATURES with debug-tweaks on a continuation line: the script fails" test "$rc" -ne 0
BB_FEATURES="read-only-rootfs no-debug-tweaks-here" run "$tmp/stub:$tools" "$want"
expect "IMAGE_FEATURES naming only a longer word: the script passes" test "$rc" -eq 0
BB_FEATURES='' run "$tmp/stub:$tools" "$want"
expect "empty IMAGE_FEATURES: the script fails" test "$rc" -ne 0

# An existing conf that differs from the templates is refused, unless forced.
run "$tmp/stub:$tools" "$want"
printf '# local edit\n' >>"$tmp/d/build/conf/local.conf"
cp "$tmp/d/build/conf/local.conf" "$tmp/local.edited"
run2 "$tmp/stub:$tools" "$want"
expect "a differing local.conf: the script fails" test "$rc" -ne 0
expect "a differing local.conf: it says so and names the override" \
	test "${out##*PLATFORM_IMAGE_PARSE_FORCE=1*}" != "$out"
expect "a differing local.conf: it was not overwritten" cmp -s "$tmp/local.edited" "$tmp/d/build/conf/local.conf"
expect "a differing local.conf: bitbake did not run" test ! -e "$tmp/log"
PLATFORM_IMAGE_PARSE_FORCE=1 run2 "$tmp/stub:$tools" "$want"
expect "PLATFORM_IMAGE_PARSE_FORCE=1: the script passes" test "$rc" -eq 0
expect "PLATFORM_IMAGE_PARSE_FORCE=1: local.conf is the template again" \
	cmp -s "$ROOT/platform-image/conf/local.conf.template" "$tmp/d/build/conf/local.conf"
printf '# local edit\n' >>"$tmp/d/build/conf/bblayers.conf"
run2 "$tmp/stub:$tools" "$want"
expect "a differing bblayers.conf: the script fails" test "$rc" -ne 0
run "$tmp/stub:$tools" "$want"
run2 "$tmp/stub:$tools" "$want"
expect "unchanged confs on a re-run: the script passes" test "$rc" -eq 0

finish
