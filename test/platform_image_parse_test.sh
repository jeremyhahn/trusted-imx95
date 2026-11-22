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
mkdir -p "$2/sources/openembedded-core"
: >"$2/sources/openembedded-core/oe-init-build-env"
EOF
chmod +x "$tmp/fetch"
# Stub bitbake: `-p` exits BB_P_RC; `-e TARGET` prints MACHINE="$BB_MACHINE" and logs the target.
cat >"$tmp/stub/bitbake" <<'EOF'
#!/bin/sh
case $1 in
-p) exit "${BB_P_RC:-0}" ;;
-e) echo "$2" >>"$BB_LOG"; echo "MACHINE=\"$BB_MACHINE\"" ;;
esac
EOF
chmod +x "$tmp/stub/bitbake"

run() { # PATH-dir... runs the script into a fresh dir; sets rc and out
	rm -rf "$tmp/d" "$tmp/log"
	rc=0
	out=$(PATH=$1 PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_MACHINE=$2 BB_P_RC=${3:-0} \
		"$real_bash" "$script" "$tmp/d" 2>&1) || rc=$?
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

finish
