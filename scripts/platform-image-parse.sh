#!/usr/bin/env bash
# platform-image-parse.sh [DIR]: the metadata check of platform-image/. Fetch the
# layers platform-image/manifest.lock pins into DIR (scripts/platform-image-fetch.sh),
# write the build directory's conf from the templates, run `bitbake -p`, then
# `bitbake -e <target>` for both image targets and show MACHINE. No image is
# built. Needs the network and a Yocto build host; it is not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${1:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
targets="trusted-imx95-image trusted-imx95-image-debug"

"${PLATFORM_IMAGE_FETCH:-$root/scripts/platform-image-fetch.sh}" "$root/platform-image/manifest.lock" "$dir"
dir=$(cd "$dir" && pwd -P)
build=$dir/build
mkdir -p "$build/conf"
cp "$root/platform-image/conf/local.conf.template" "$build/conf/local.conf"
sed -e "s|##FETCH_DIR##|$dir|g" -e "s|##REPO_DIR##|$root|g" \
	"$root/platform-image/conf/bblayers.conf.template" >"$build/conf/bblayers.conf"

want=$(sed -n 's/^machine=//p' "$root/platform-image/manifest.lock")
[ -n "$want" ] || { echo "platform-image-parse: no machine in the lock" >&2; exit 1; }

# shellcheck disable=SC1091
. "$dir/sources/openembedded-core/oe-init-build-env" "$build" >/dev/null
command -v bitbake >/dev/null 2>&1 || { echo "platform-image-parse: bitbake is not on PATH; run this on a Yocto build host" >&2; exit 1; }
bitbake -p
for t in $targets; do
	got=$(bitbake -e "$t" | sed -n 's/^MACHINE="\(.*\)"$/\1/p')
	[ "$got" = "$want" ] || { echo "platform-image-parse: $t: MACHINE is '$got', the lock pins '$want'" >&2; exit 1; }
	echo "platform-image-parse: $t MACHINE=$got"
done
echo "platform-image-parse: OK"
