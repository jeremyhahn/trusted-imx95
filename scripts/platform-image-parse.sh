#!/usr/bin/env bash
# platform-image-parse.sh [DIR]: fetches the pinned layers, writes the build conf, runs bitbake -p and -e and checks MACHINE, DISTRO, INIT_MANAGER and IMAGE_FEATURES; needs a Yocto build host, not in CI.
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

die() {
	echo "platform-image-parse: $*" >&2
	exit 1
}
# The fetch directory is never inside this clone: checked here, before anything
# in it is touched (the fetcher repeats the check).
abs=$dir
case $abs in /*) ;; *) abs=$PWD/$abs ;; esac
anc=$abs
rest=
while [ ! -d "$anc" ]; do
	rest=/$(basename "$anc")$rest
	anc=$(dirname "$anc")
done
phys=$(cd "$anc" && pwd -P)$rest
case "$phys/" in "$root"/*) die "$dir is inside this clone; use a directory outside it" ;; esac

# Remove bitbake's generated ignored file only when git reports exactly that path as ignored and untracked; anything else fails closed.
bb=$phys/sources/bitbake
pysh=lib/bb/pysh/pyshtables.py
if [ -e "$bb/$pysh" ] || [ -L "$bb/$pysh" ]; then
	top=$(git -C "$bb" rev-parse --show-toplevel 2>/dev/null || true)
	st=$(git -C "$bb" status --porcelain --ignored --untracked-files=all -- "$pysh" 2>/dev/null || true)
	{ [ "$top" = "$bb" ] && [ "$st" = "!! $pysh" ]; } ||
		die "$bb/$pysh is not an ignored, untracked generated file of the bitbake checkout; not removing it: remove it yourself or the directory $phys"
	rm -f "$bb/$pysh"
fi
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

# Cap the load: BitBake threads and make jobs from nproc (at most 16; 6 if
# nproc is not there), passed through the filtered task environment.
cpus=$(nproc 2>/dev/null || echo 6)
[ "$cpus" -le 16 ] || cpus=16
export BB_NUMBER_THREADS=${BB_NUMBER_THREADS:-$cpus} PARALLEL_MAKE=${PARALLEL_MAKE:--j $cpus}
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} BB_NUMBER_THREADS PARALLEL_MAKE"

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
# A BitBake server this script started must not outlive it: it would keep the
# socket and make the next client time out. Stop it on every exit; stop a
# stale one a crashed earlier run left in this build directory first.
if [ -e "$build/bitbake.sock" ]; then
	echo "platform-image-parse: a BitBake server from an earlier run holds $build/bitbake.sock; stopping it" >&2
	bitbake -m >/dev/null 2>&1 || true
fi
trap 'bitbake -m >/dev/null 2>&1 || true' EXIT
bitbake -p

# The effective-value checks (bbval, must_equal, effective_check) are shared with the build.
export effective_who=platform-image-parse
effective_machine=
# shellcheck disable=SC1091
. "$root/scripts/platform-image-effective.sh"
for t in $targets; do
	effective_check "$t" "$want" "$want_distro" "$want_init"
	echo "platform-image-parse: $t MACHINE=$effective_machine DISTRO=$want_distro INIT_MANAGER=$want_init"
done
echo "platform-image-parse: OK"
