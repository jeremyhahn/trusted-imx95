#!/usr/bin/env bash
# platform-image-hosttools.sh [DIR]: set up a non-root Yocto build host for
# scripts/platform-image-parse.sh, in DIR (default
# $PLATFORM_IMAGE_HOSTTOOLS_DIR, else $XDG_CACHE_HOME or $HOME/.cache, under
# trusted-imx95/hosttools; never the repository). Idempotent.
#  1. Yocto buildtools-extended for the pinned release is fetched with curl and
#     checked against its published .sh.sha256sum AND the hash pinned here; a
#     mismatch fails closed and installs nothing.
#  2. cpio, diffstat, file, gawk and socat (with their libraries) are fetched
#     with `apt-get download` (a private apt state directory, no root) and
#     unpacked with `dpkg -x` under DIR; `file` needs MAGIC and the libraries
#     LD_LIBRARY_PATH: each tool is reached through a wrapper that sets them. The SDK installer needs a real `file` on PATH.
#  3. DIR/env.sh is written: source it, then run make platform-image-parse.
# Test seams: HOSTTOOLS_CURL, HOSTTOOLS_APT_GET, HOSTTOOLS_DPKG, and
# HOSTTOOLS_BUILDTOOLS_SHA256 / HOSTTOOLS_BUILDTOOLS_URL (the pin and the
# download directory). Needs the network. Provisional, pending #14.
set -euo pipefail

version=6.0.1
sha256=${HOSTTOOLS_BUILDTOOLS_SHA256:-fe21a5aaf7084db0792d0c7392201875ab813bef68e8ab04b02ad5d15447cd2c}
base=${HOSTTOOLS_BUILDTOOLS_URL:-https://downloads.yoctoproject.org/releases/yocto/yocto-$version/buildtools}
name=x86_64-buildtools-extended-nativesdk-standalone-$version.sh
curl_cmd=${HOSTTOOLS_CURL:-curl}
apt_cmd=${HOSTTOOLS_APT_GET:-apt-get}
dpkg_cmd=${HOSTTOOLS_DPKG:-dpkg}
debs="cpio diffstat file libmagic1t64 libmagic-mgc gawk libsigsegv2 socat libwrap0"

die() { echo "platform-image-hosttools: $*" >&2; exit 1; }

dir=${1:-${PLATFORM_IMAGE_HOSTTOOLS_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/hosttools}}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)
[ "$(id -u)" -ne 0 ] || echo "platform-image-hosttools: running as root; bitbake refuses to run as root" >&2

pkgroot=$dir/pkgroot
tools_lib=$pkgroot/usr/lib/x86_64-linux-gnu:$pkgroot/lib/x86_64-linux-gnu

# 2. The host tools from apt, unpacked under DIR.
if [ ! -e "$dir/.pkgs-done" ]; then
	mkdir -p "$dir/apt/state/lists/partial" "$dir/apt/cache/archives/partial" "$dir/debs" "$pkgroot"
	aptopts=(-o "Dir::State=$dir/apt/state" -o "Dir::State::status=/var/lib/dpkg/status"
		-o "Dir::Cache=$dir/apt/cache" -o Debug::NoLocking=1)
	"$apt_cmd" "${aptopts[@]}" update >"$dir/apt-update.log" 2>&1 || die "apt-get update failed (see $dir/apt-update.log)"
	# shellcheck disable=SC2086
	(cd "$dir/debs" && "$apt_cmd" "${aptopts[@]}" download $debs) || die "apt-get download failed"
	for d in "$dir"/debs/*.deb; do
		"$dpkg_cmd" -x "$d" "$pkgroot" || die "dpkg -x $d failed"
	done
	: >"$dir/.pkgs-done"
fi
# Bitbake runs its tasks with a filtered environment, so LD_LIBRARY_PATH and MAGIC
# do not reach the extracted tools there: each is reached through a wrapper that
# sets them (bitbake's hosttools symlinks point at the wrapper).
magic=$pkgroot/usr/lib/file/magic.mgc
[ -e "$magic" ] || magic=$pkgroot/usr/share/misc/magic.mgc
wrap=$dir/wrappers
rm -rf "$wrap"
mkdir -p "$wrap"
for t in cpio diffstat file gawk socat; do
	for p in usr/bin usr/sbin bin; do
		[ -x "$pkgroot/$p/$t" ] || continue
		# shellcheck disable=SC2016 # the wrapper expands $LD_LIBRARY_PATH and "$@" when it runs
		printf '#!/bin/sh\nLD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nMAGIC="%s"\nexport LD_LIBRARY_PATH MAGIC\nexec "%s" "$@"\n' \
			"$tools_lib" "$magic" "$pkgroot/$p/$t" >"$wrap/$t"
		chmod +x "$wrap/$t"
		break
	done
done
export PATH="$wrap:$PATH"

# 1. buildtools-extended, checked before it is run.
bt=$dir/buildtools
if [ ! -e "$dir/.buildtools-$version-done" ]; then
	mkdir -p "$dir/download"
	"$curl_cmd" -fsSL -o "$dir/download/$name" "$base/$name" || die "download of $name failed"
	"$curl_cmd" -fsSL -o "$dir/download/$name.sha256sum" "$base/$name.sha256sum" || die "download of $name.sha256sum failed"
	got=$(sha256sum "$dir/download/$name")
	got=${got%% *}
	published=$(cat "$dir/download/$name.sha256sum")
	published=${published%% *}
	[ "$got" = "$sha256" ] || die "$name sha256 is $got, the pin is $sha256; nothing installed"
	[ "$got" = "$published" ] || die "$name sha256 is $got, the published .sha256sum says $published; nothing installed"
	command -v file >/dev/null 2>&1 || die "no file on PATH; the SDK installer needs it"
	rm -rf "$bt"
	sh "$dir/download/$name" -y -d "$bt" >"$dir/buildtools-install.log" 2>&1 || die "the buildtools installer failed (see $dir/buildtools-install.log)"
	: >"$dir/.buildtools-$version-done"
fi
setup=
for f in "$bt"/environment-setup-*; do
	[ -f "$f" ] && setup=$f
done
[ -n "$setup" ] || die "no environment-setup file under $bt"

# 3. The env file.
cat >"$dir/env.sh" <<EOF
# Written by scripts/platform-image-hosttools.sh. Source it, then run
# make platform-image-parse and make platform-image-kernel-config.
. "$setup"
export PATH="$wrap:\$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="$dir/pycache"
export PLATFORM_IMAGE_DIR="$dir/platform-image"
export DL_DIR="$dir/downloads"
export SSTATE_DIR="$dir/sstate-cache"
export BB_ENV_PASSTHROUGH_ADDITIONS="PLATFORM_IMAGE_DIR DL_DIR SSTATE_DIR PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX LANG LC_ALL"
EOF
echo "platform-image-hosttools: OK; source $dir/env.sh"
