#!/usr/bin/env bash
# platform-image-build.sh [--check|--dry-run] [DIR]: build trusted-imx95-image
# (and trusted-imx95-image-debug with PI_DEBUG=1) from the layers
# platform-image/manifest.lock pins. Fetches the pins into DIR (outside the
# clone), writes the build directory's conf from the templates (refusing to
# overwrite a conf that differs, unless PLATFORM_IMAGE_BUILD_FORCE=1), runs
# bitbake, then copies the wic and rootfs artefacts, SHA256SUMS and
# build-info.txt into OUT (default <clone>/.platform-image/out, git-ignored).
# --check names every missing host tool and prints the plan; it fetches and
# builds nothing. Needs the network and a Yocto build host; not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lock=$root/platform-image/manifest.lock
die() {
	echo "platform-image-build: $*" >&2
	exit 1
}

check=0
dir=
while [ $# -gt 0 ]; do
	case $1 in
	--check | --dry-run) check=1 ;;
	-*) die "unknown option $1" ;;
	*) [ -z "$dir" ] || die "more than one directory given"; dir=$1 ;;
	esac
	shift
done
dir=${dir:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
out=${PLATFORM_IMAGE_OUT:-$root/.platform-image/out}
targets=trusted-imx95-image
[ "${PI_DEBUG:-0}" != 1 ] || targets="$targets trusted-imx95-image-debug"
force=${PLATFORM_IMAGE_BUILD_FORCE:-0}
localt=$root/platform-image/conf/local.conf.template
bblt=$root/platform-image/conf/bblayers.conf.template

machine=$(sed -n 's/^machine=//p' "$lock")
[ -n "$machine" ] || die "no machine in the lock"
distro=$(sed -n 's/^DISTRO[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$localt" | sed -n '$p')
[ -n "$distro" ] || die "no DISTRO in local.conf.template"

# The directory is never inside this clone (the fetcher repeats the check).
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

# Host tools: every missing one is named, not only the first.
missing=
for t in gcc g++ make git python3 tar xz bzip2 patch perl unzip wget diffstat chrpath gawk cpio file socat zstd lz4c; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	echo "platform-image-build: missing host tools:$missing" >&2
	echo "platform-image-build: on a non-root host run 'make platform-image-hosttools' and source its env.sh" >&2
	exit 1
fi

if [ "$check" -eq 1 ]; then
	echo "platform-image-build: check: host tools present"
	echo "platform-image-build: check: MACHINE=$machine DISTRO=$distro"
	echo "platform-image-build: check: targets: $targets"
	echo "platform-image-build: check: layers and build directory: $phys"
	echo "platform-image-build: check: artefacts: $out"
	echo "platform-image-build: check: OK, nothing fetched or built"
	exit 0
fi

# bitbake's generated, git-ignored pyshtables.py would fail the next fetch
# (a layer with ignored files is refused): remove it only when git reports
# exactly that path as an ignored, untracked file of the checkout.
bb=$phys/sources/bitbake
pysh=lib/bb/pysh/pyshtables.py
if [ -e "$bb/$pysh" ] || [ -L "$bb/$pysh" ]; then
	top=$(git -C "$bb" rev-parse --show-toplevel 2>/dev/null || true)
	st=$(git -C "$bb" status --porcelain --ignored --untracked-files=all -- "$pysh" 2>/dev/null || true)
	{ [ "$top" = "$bb" ] && [ "$st" = "!! $pysh" ]; } ||
		die "$bb/$pysh is not an ignored, untracked generated file of the bitbake checkout; not removing it"
	rm -f "$bb/$pysh"
fi
"${PLATFORM_IMAGE_FETCH:-$root/scripts/platform-image-fetch.sh}" "$lock" "$dir"
dir=$(cd "$dir" && pwd -P)
build=$dir/build
conf=$build/conf

want_local=$(cat "$localt")
want_bbl=$(sed -e "s|##FETCH_DIR##|$dir|g" -e "s|##REPO_DIR##|$root|g" "$bblt")
for pair in "local.conf:$want_local" "bblayers.conf:$want_bbl"; do
	n=${pair%%:*}
	w=${pair#*:}
	if [ "$force" != 1 ] && [ -e "$conf/$n" ] && [ "$(cat "$conf/$n")" != "$w" ]; then
		die "$conf/$n exists and differs from the template; remove it, or set PLATFORM_IMAGE_BUILD_FORCE=1 to overwrite it"
	fi
done
mkdir -p "$conf"
printf '%s\n' "$want_local" >"$conf/local.conf"
printf '%s\n' "$want_bbl" >"$conf/bblayers.conf"

cpus=$(nproc 2>/dev/null || echo 6)
[ "$cpus" -le 16 ] || cpus=16
export BB_NUMBER_THREADS=${BB_NUMBER_THREADS:-$cpus} PARALLEL_MAKE=${PARALLEL_MAKE:--j $cpus}
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} BB_NUMBER_THREADS PARALLEL_MAKE"

export BITBAKEDIR=$dir/sources/bitbake
restore_u=0
case $- in *u*) restore_u=1 ;; esac
set +u
# shellcheck disable=SC1091
. "$dir/sources/openembedded-core/oe-init-build-env" "$build" "$BITBAKEDIR" >/dev/null
[ "$restore_u" -eq 0 ] || set -u
command -v bitbake >/dev/null 2>&1 || die "bitbake is not on PATH; run this on a Yocto build host"
if [ -e "$build/bitbake.sock" ]; then
	echo "platform-image-build: a BitBake server from an earlier run holds $build/bitbake.sock; stopping it" >&2
	bitbake -m >/dev/null 2>&1 || true
fi
trap 'bitbake -m >/dev/null 2>&1 || true' EXIT

start=$(date +%s)
# shellcheck disable=SC2086
bitbake $targets
elapsed=$(($(date +%s) - start))

# The SOURCE_DATE_EPOCH bitbake used for the first target.
# shellcheck disable=SC2086
sde=$(bitbake -e ${targets%% *} | sed -n 's/^SOURCE_DATE_EPOCH="\(.*\)"$/\1/p' | sed -n '$p')
[ -n "$sde" ] || die "no SOURCE_DATE_EPOCH in bitbake -e"

deploy=$build/tmp/deploy/images/$machine
[ -d "$deploy" ] || die "no deploy directory $deploy after the build"
rm -rf "$out"
mkdir -p "$out"
n=0
for t in $targets; do
	# Real files only (the deploy directory links the latest build by a plain
	# name): the wic image, its bmap, and the rootfs tarball and ext4. The
	# debug image's prefix "-debug-" never matches the production one.
	for f in "$deploy/$t-$machine"*; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		case $f in
		*.testdata.json | *.manifest | *.spdx.json | *.env) continue ;;
		*.wic* | *.rootfs.*) ;;
		*) continue ;;
		esac
		cp "$f" "$out/"
		n=$((n + 1))
	done
done
[ "$n" -gt 0 ] || die "the build left no wic or rootfs artefact for: $targets"
(cd "$out" && sha256sum -- * >SHA256SUMS)
{
	echo "# platform-image build-info (provisional, pending #14)"
	echo "machine=$machine"
	echo "distro=$distro"
	echo "targets=$targets"
	echo "SOURCE_DATE_EPOCH=$sde"
	echo "build_seconds=$elapsed"
	echo "manifest_commit=$(sed -n 's/^manifest_commit=//p' "$lock")"
	sed -n 's/^\(layer_[A-Za-z0-9_]*_commit=.*\)$/\1/p' "$lock"
} >"$out/build-info.txt"
echo "platform-image-build: OK, $n artefacts in $out"
