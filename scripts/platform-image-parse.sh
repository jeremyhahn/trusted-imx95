#!/usr/bin/env bash
# platform-image-parse.sh [DIR]: the metadata check of platform-image/. Fetch the
# layers platform-image/manifest.lock pins into DIR (scripts/platform-image-fetch.sh),
# write the build directory's conf from the templates (refusing to overwrite a
# conf that differs, unless PLATFORM_IMAGE_PARSE_FORCE=1), run `bitbake -p`,
# then `bitbake -e <target>` for both image targets and check the effective
# MACHINE (the lock's), DISTRO (local.conf.template's), INIT_MANAGER (the
# distro's) and that IMAGE_FEATURES holds no root-login relaxation. No image is
# built. Needs the network and a Yocto build host; it is not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${1:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
targets="trusted-imx95-image trusted-imx95-image-debug"
force=${PLATFORM_IMAGE_PARSE_FORCE:-0}
localt=$root/platform-image/conf/local.conf.template
bblt=$root/platform-image/conf/bblayers.conf.template
distroconf=$root/platform-image/conf/distro/trusted-imx95.conf

# confval KEY FILE: the quoted value of the last KEY = "v" line of FILE.
confval() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" "$2" | sed -n '$p'; }

want=$(sed -n 's/^machine=//p' "$root/platform-image/manifest.lock")
[ -n "$want" ] || { echo "platform-image-parse: no machine in the lock" >&2; exit 1; }
want_distro=$(confval DISTRO "$localt")
[ -n "$want_distro" ] || { echo "platform-image-parse: no DISTRO in local.conf.template" >&2; exit 1; }
want_init=$(confval INIT_MANAGER "$distroconf")
[ -n "$want_init" ] || { echo "platform-image-parse: no INIT_MANAGER in the distro conf" >&2; exit 1; }

"${PLATFORM_IMAGE_FETCH:-$root/scripts/platform-image-fetch.sh}" "$root/platform-image/manifest.lock" "$dir"
dir=$(cd "$dir" && pwd -P)
build=$dir/build
conf=$build/conf

want_local=$(cat "$localt")
want_bbl=$(sed -e "s|##FETCH_DIR##|$dir|g" -e "s|##REPO_DIR##|$root|g" "$bblt")
# refuse_if_differs NAME WANT: an existing conf file that differs is not overwritten.
refuse_if_differs() {
	[ "$force" = 1 ] && return 0
	if [ -e "$conf/$1" ] && [ "$(cat "$conf/$1")" != "$2" ]; then
		echo "platform-image-parse: $conf/$1 exists and differs from the template; remove it, or set PLATFORM_IMAGE_PARSE_FORCE=1 to overwrite it" >&2
		exit 1
	fi
}
refuse_if_differs local.conf "$want_local"
refuse_if_differs bblayers.conf "$want_bbl"
mkdir -p "$conf"
printf '%s\n' "$want_local" >"$conf/local.conf"
printf '%s\n' "$want_bbl" >"$conf/bblayers.conf"

# oe-init-build-env reads unset variables and may return nonzero: source it
# with -u off, then restore -u. It takes the build dir and the bitbake dir.
export BITBAKEDIR=$dir/sources/bitbake
restore_u=0
case $- in *u*) restore_u=1 ;; esac
set +u
# shellcheck disable=SC1091
. "$dir/sources/openembedded-core/oe-init-build-env" "$build" "$BITBAKEDIR" >/dev/null
[ "$restore_u" -eq 0 ] || set -u
command -v bitbake >/dev/null 2>&1 || { echo "platform-image-parse: bitbake is not on PATH; run this on a Yocto build host" >&2; exit 1; }
bitbake -p

# bbval ENV KEY: the value of KEY in `bitbake -e` output (a value may span lines).
bbval() {
	printf '%s\n' "$1" | sed -n "/^$2=\"/{/\"\$/!{:a;N;/\"\$/!ba;};p;}" | sed -e "1s/^$2=\"//" -e '$s/"$//'
}
# must_equal TARGET KEY GOT WANT WHAT
must_equal() {
	[ "$3" = "$4" ] || { echo "platform-image-parse: $1: $2 is '$3', $5 '$4'" >&2; exit 1; }
}
for t in $targets; do
	benv=$(bitbake -e "$t")
	got=$(bbval "$benv" MACHINE)
	must_equal "$t" MACHINE "$got" "$want" "the lock pins"
	must_equal "$t" DISTRO "$(bbval "$benv" DISTRO)" "$want_distro" "local.conf.template sets"
	must_equal "$t" INIT_MANAGER "$(bbval "$benv" INIT_MANAGER)" "$want_init" "the distro sets"
	feats=$(bbval "$benv" IMAGE_FEATURES)
	[ -n "$feats" ] || { echo "platform-image-parse: $t: no IMAGE_FEATURES in bitbake -e" >&2; exit 1; }
	for bad in debug-tweaks empty-root-password allow-empty-password allow-root-login; do
		case " $feats " in
		*[[:space:]]"$bad"[[:space:]]*) echo "platform-image-parse: $t: IMAGE_FEATURES holds $bad" >&2; exit 1 ;;
		esac
	done
	echo "platform-image-parse: $t MACHINE=$got DISTRO=$want_distro INIT_MANAGER=$want_init"
done
echo "platform-image-parse: OK"
