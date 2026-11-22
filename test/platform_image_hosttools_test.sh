#!/usr/bin/env bash
# Offline checks of scripts/platform-image-hosttools.sh (provisional default,
# pending the owner's answer on #14): stub curl, apt-get and dpkg, in a mktemp
# dir outside the clone. No network, no apt, no Yocto.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILS=0
export LC_ALL=C

script=$ROOT/scripts/platform-image-hosttools.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/serve"

# The "release": an installer stub that wants a `file` on PATH, and its hash.
cat >"$tmp/serve/installer.sh" <<'EOF'
#!/bin/sh
# usage: installer -y -d DIR
command -v file >/dev/null 2>&1 || { echo "no file" >&2; exit 1; }
mkdir -p "$3" && : >"$3/environment-setup-x86_64-pokysdk-linux"
EOF
good=$(sha256sum "$tmp/serve/installer.sh")
good=${good%% *}
printf '%s  installer.sh\n' "$good" >"$tmp/serve/installer.sh.sha256sum"
printf '%s  installer.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$tmp/serve/bad.sha256sum"

# Stub curl: `-fsSL -o OUT URL` copies serve/<kind> to OUT; logs the URL.
cat >"$tmp/curl" <<'EOF'
#!/bin/sh
echo "$4" >>"$STUB_LOG/curl"
[ -z "$CURL_FAIL" ] || exit 22
case $4 in
*.sha256sum) cp "$STUB_SERVE/${PUB_SUM:-installer.sh.sha256sum}" "$3" ;;
*) cp "$STUB_SERVE/${INSTALLER:-installer.sh}" "$3" ;;
esac
EOF
# Stub apt-get: logs its arguments; `download` makes one .deb per package in cwd.
cat >"$tmp/apt-get" <<'EOF'
#!/bin/sh
echo "$*" >>"$STUB_LOG/apt"
case " $* " in *" update "*) [ -z "$APT_UPDATE_FAIL" ] || exit 100; exit 0 ;; esac
[ -z "$APT_DL_FAIL" ] || exit 100
seen=0
for a in "$@"; do
	[ "$seen" = 0 ] || : >"$a.deb"
	[ "$a" != download ] || seen=1
done
EOF
# Stub dpkg: `-x DEB ROOT` unpacks a fake `file` and its magic into ROOT.
cat >"$tmp/dpkg" <<'EOF'
#!/bin/sh
[ -z "$DPKG_FAIL" ] || exit 2
mkdir -p "$3/usr/bin" "$3/usr/lib/file"
printf '#!/bin/sh\n' >"$3/usr/bin/file"
chmod +x "$3/usr/bin/file"
: >"$3/usr/lib/file/magic.mgc"
EOF
chmod +x "$tmp/curl" "$tmp/apt-get" "$tmp/dpkg"

run() { # DIR: runs the script with the stubs; sets rc and out
	mkdir -p "$tmp/log"
	rc=0
	out=$(STUB_LOG=$tmp/log STUB_SERVE=$tmp/serve HOSTTOOLS_CURL=$tmp/curl HOSTTOOLS_APT_GET=$tmp/apt-get \
		HOSTTOOLS_DPKG=$tmp/dpkg HOSTTOOLS_BUILDTOOLS_SHA256=$good HOSTTOOLS_BUILDTOOLS_URL=https://example.invalid/bt \
		CURL_FAIL=${CURL_FAIL-} APT_UPDATE_FAIL=${APT_UPDATE_FAIL-} APT_DL_FAIL=${APT_DL_FAIL-} DPKG_FAIL=${DPKG_FAIL-} \
		bash "$script" "$1" 2>&1) || rc=$?
}
has() { [ "${out##*"$1"*}" != "$out" ]; }

# A good run.
run "$tmp/d"
expect "a good run passes" test "$rc" -eq 0
expect "it reports OK and names the env file" has "OK; source "
expect "env.sh was written" test -f "$tmp/d/env.sh"
expect "the SDK installer ran with a file on PATH (its env-setup exists)" test -e "$tmp/d/buildtools/environment-setup-x86_64-pokysdk-linux"
expect "the private apt state directory is used" grep -q "Dir::State=$tmp/d/apt/state" "$tmp/log/apt"
expect "the apt packages include file and gawk" grep -q "download cpio diffstat file libmagic1t64 libmagic-mgc gawk libsigsegv2 socat libwrap0" "$tmp/log/apt"
expect "the installer URL is under the download base" grep -q "^https://example.invalid/bt/x86_64-buildtools-extended-nativesdk-standalone-6.0.1.sh$" "$tmp/log/curl"
expect "env.sh sets the locale, MAGIC and the cache dirs" grep -q 'MAGIC=' "$tmp/d/env.sh"
expect "env.sh sources the SDK setup" grep -q "environment-setup-x86_64-pokysdk-linux" "$tmp/d/env.sh"
expect "env.sh passes DL_DIR through to bitbake" grep -q 'BB_ENV_PASSTHROUGH_ADDITIONS="PLATFORM_IMAGE_DIR DL_DIR SSTATE_DIR' "$tmp/d/env.sh"
expect "env.sh names no repository path" test -z "$(grep -F "$ROOT" "$tmp/d/env.sh" || true)"

# Idempotent: a second run downloads and installs nothing.
: >"$tmp/log/curl"
: >"$tmp/log/apt"
run "$tmp/d"
expect "a second run passes" test "$rc" -eq 0
expect "a second run downloads nothing" test ! -s "$tmp/log/curl"
expect "a second run runs no apt-get" test ! -s "$tmp/log/apt"

# A hash that is not the pin fails closed and installs nothing.
rm -rf "$tmp/d" "$tmp/log"
printf '#!/bin/sh\necho tampered\n' >"$tmp/serve/tampered.sh"
INSTALLER=tampered.sh run "$tmp/d"
expect "a tampered installer: the script fails" test "$rc" -ne 0
expect "a tampered installer: it names the pin" has "the pin is $good"
expect "a tampered installer: nothing was installed" test ! -e "$tmp/d/buildtools"
expect "a tampered installer: no env.sh" test ! -e "$tmp/d/env.sh"

# A published sum that differs fails closed too.
rm -rf "$tmp/d"
PUB_SUM=bad.sha256sum run "$tmp/d"
expect "a differing published sum: the script fails" test "$rc" -ne 0
expect "a differing published sum: it says so" has "the published .sha256sum says"
expect "a differing published sum: nothing was installed" test ! -e "$tmp/d/buildtools"

# Each failing step fails the script by name.
rm -rf "$tmp/d"
CURL_FAIL=1 run "$tmp/d"
expect "a failing download fails the script" test "$rc" -ne 0
expect "a failing download names the file" has "download of x86_64-buildtools-extended"
rm -rf "$tmp/d"
APT_UPDATE_FAIL=1 run "$tmp/d"
expect "a failing apt-get update fails the script" test "$rc" -ne 0
expect "a failing apt-get update is named" has "apt-get update failed"
rm -rf "$tmp/d"
APT_DL_FAIL=1 run "$tmp/d"
expect "a failing apt-get download fails the script" test "$rc" -ne 0
expect "a failing apt-get download is named" has "apt-get download failed"
rm -rf "$tmp/d"
DPKG_FAIL=1 run "$tmp/d"
expect "a failing dpkg -x fails the script" test "$rc" -ne 0
expect "a failing dpkg -x is named" has "dpkg -x"

# The default directory is under the cache, not the repository.
rm -rf "$tmp/d" "$tmp/cache"
rc=0
out=$(XDG_CACHE_HOME=$tmp/cache STUB_LOG=$tmp/log STUB_SERVE=$tmp/serve HOSTTOOLS_CURL=$tmp/curl \
	HOSTTOOLS_APT_GET=$tmp/apt-get HOSTTOOLS_DPKG=$tmp/dpkg HOSTTOOLS_BUILDTOOLS_SHA256=$good \
	CURL_FAIL='' APT_UPDATE_FAIL='' APT_DL_FAIL='' DPKG_FAIL='' bash "$script" 2>&1) || rc=$?
expect "the default directory: the script passes" test "$rc" -eq 0
expect "the default directory is under XDG_CACHE_HOME" test -f "$tmp/cache/trusted-imx95/hosttools/env.sh"

finish
