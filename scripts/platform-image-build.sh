#!/usr/bin/env bash
# platform-image-build.sh [--check|--dry-run] [--repro] [DIR]: build trusted-imx95-image
# (and trusted-imx95-image-debug with PI_DEBUG=1) from the layers
# platform-image/manifest.lock pins. Fetches the pins into DIR (outside the
# clone), writes the build directory's conf from the templates (refusing to
# overwrite a conf that differs, unless PLATFORM_IMAGE_BUILD_FORCE=1), runs
# bitbake, then copies the wic and rootfs artefacts, SHA256SUMS and
# build-info.txt into OUT (default <clone>/.platform-image/out, git-ignored).
# --check names every missing host tool and prints the plan; it fetches and
# builds nothing. --repro builds twice in separate directories and publishes
# to OUT only when platform-image-repro-compare.sh finds the outputs equal.
# Needs the network and a Yocto build host; not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lock=$root/platform-image/manifest.lock
die() {
	echo "platform-image-build: $*" >&2
	exit 1
}

check=0
repro=0
dir=
while [ $# -gt 0 ]; do
	case $1 in
	--check | --dry-run) check=1 ;;
	--repro) repro=1 ;;
	-*) die "unknown option $1" ;;
	*) [ -z "$dir" ] || die "more than one directory given"; dir=$1 ;;
	esac
	shift
done
dir=${dir:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
out_marker=.platform-image-out
# A set but empty PLATFORM_IMAGE_OUT is an error, not the default.
out=${PLATFORM_IMAGE_OUT-$root/.platform-image/out}
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
# A ".." under a missing parent cannot be resolved by cd; refuse it, as
# check_out does for PLATFORM_IMAGE_OUT, so phys is a canonical path.
case "/$abs/" in */../*) die "$dir contains a '..' component; refusing" ;; esac

# canon PATH: the absolute, symlink-free path of PATH, which need not exist.
canon() {
	local a='' d='' r='' c in=$1 IFS=/
	# Lexical clean-up (check_out has refused "..", relative paths): drop
	# empty and "." components, so a/./b and a/b/ are the plain path.
	set -f
	for c in $in; do
		case $c in '' | .) ;; *) a=$a/$c ;; esac
	done
	set +f
	[ -n "$a" ] || a=/
	IFS=$' \t\n'
	while [ ! -d "$a" ]; do
		[ ! -L "$a" ] || { echo "$a"; return 0; }
		r=/$(basename "$a")$r
		a=$(dirname "$a")
	done
	d=$(cd "$a" && pwd -P)
	[ "$d" != / ] || d=
	echo "$d$r"
}
phys=$(canon "$abs")
case "$phys/" in "$root"/*) die "$dir is inside this clone; use a directory outside it" ;; esac
# check_out: refuse an artefacts directory that rm -rf must not touch. Run
# before anything is fetched or built, and again before the removal.
check_out() {
	local o
	[ -n "$out" ] || die "PLATFORM_IMAGE_OUT is empty; refusing to use it as the artefacts directory"
	case $out in /*) ;; *) die "$out is not an absolute path; refusing" ;; esac
	case "/$out/" in */../*) die "$out contains a '..' component; refusing" ;; esac
	[ ! -L "$out" ] || die "$out is a symbolic link; refusing to use it as the artefacts directory"
	o=$(canon "$out")
	[ -n "$o" ] && [ "$o" != / ] || die "$out is the root directory; refusing"
	[ "$o" != "$root" ] || die "$out is this clone; refusing"
	case "$root/" in "$o"/*) die "$out contains this clone; refusing" ;; esac
	case "$o/" in
	"$root/.platform-image/"*) ;;
	"$root"/*) die "$out is inside this clone outside .platform-image/; refusing" ;;
	esac
	case "$o/" in "$phys"/*) die "$out is the platform-image directory or inside it ($phys); refusing" ;; esac
	case "$phys/" in "$o"/*) die "$out contains the platform-image directory ($phys); refusing" ;; esac
	if [ -e "$o" ]; then
		[ -d "$o" ] || die "$out exists and is not a directory; refusing"
		local f any=0
		for f in "$o"/* "$o"/.[!.]* "$o"/..?*; do
			if [ -e "$f" ] || [ -L "$f" ]; then any=1; fi
		done
		if [ "$any" -eq 1 ] && { [ ! -f "$o/$out_marker" ] || [ -L "$o/$out_marker" ]; }; then
			die "$out exists and was not written by this script (no $out_marker); remove it yourself or choose another PLATFORM_IMAGE_OUT"
		fi
	fi
	out=$o
}
check_out

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
	[ "$repro" -eq 0 ] || echo "platform-image-build: check: --repro: two builds in $phys.repro-a and $phys.repro-b, compared before publishing"
	echo "platform-image-build: check: OK, nothing fetched or built"
	exit 0
fi

# --repro: this script twice, each in its own freshly emptied layer, build and
# output directories ($phys.repro-a, $phys.repro-b; $out.repro-a, -b), under
# the same pinned layers; the two outputs are compared by
# platform-image-repro-compare.sh, and $out is written only when they match.
# A directory is emptied only when absent, empty or marked by this mode.
if [ "$repro" -eq 1 ]; then
	repro_marker=.platform-image-repro-dir
	rdirs=()
	routs=()
	for k in a b; do
		d=$phys.repro-$k
		if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
			die "$d is not a plain directory; refusing"
		fi
		if [ -d "$d" ]; then
			any=0
			for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
				if [ -e "$f" ] || [ -L "$f" ]; then any=1; fi
			done
			if [ "$any" -eq 1 ] && { [ ! -f "$d/$repro_marker" ] || [ -L "$d/$repro_marker" ]; }; then
				die "$d exists and was not written by --repro (no $repro_marker); remove it yourself"
			fi
			rm -rf "$d"
		fi
		mkdir -p "$d"
		printf '%s\n' "written by scripts/platform-image-build.sh --repro; the script may delete this directory" >"$d/$repro_marker"
		rdirs+=("$d")
		routs+=("$out.repro-$k")
	done
	for i in 0 1; do
		echo "platform-image-build: repro: build $((i + 1)) of 2 in ${rdirs[$i]}"
		PLATFORM_IMAGE_OUT=${routs[$i]} "$BASH" "$root/scripts/platform-image-build.sh" "${rdirs[$i]}" ||
			die "build $((i + 1)) of 2 failed; nothing published"
	done
	"$BASH" "$root/scripts/platform-image-repro-compare.sh" "${routs[0]}" "${routs[1]}" ||
		die "not reproducible: the two builds differ (outputs kept in ${routs[0]} and ${routs[1]}); nothing published"
	check_out
	rm -rf "$out"
	mkdir -p "$out"
	cp -R "${routs[0]}/." "$out/"
	(cd "$out" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS does not verify in $out"
	rm -rf "${routs[0]}" "${routs[1]}"
	n=0
	while IFS= read -r _; do n=$((n + 1)); done <"$out/SHA256SUMS"
	echo "platform-image-build: OK, $n artefacts in $out (two builds identical)"
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

# This checkout's own layer (platform-image/: layer, templates) as the build
# sees it: the commit, and when the tree differs from it, the sha256 of the
# status and the diff (recorded, not refused).
checkout_commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
[ -n "$checkout_commit" ] || checkout_commit=unknown
inputs_status=$(git -C "$root" status --porcelain --untracked-files=all -- platform-image 2>/dev/null || echo unknown)
if [ -z "$inputs_status" ]; then
	inputs_dirty=no
	inputs_sha=-
else
	inputs_dirty=yes
	inputs_sha=$({
		echo "$inputs_status"
		git -C "$root" diff HEAD -- platform-image 2>/dev/null || true
	} | sha256sum | sed 's/ .*//')
fi

start=$(date +%s)
# PLATFORM_IMAGE_BITBAKE_ARGS (for example -k) goes before the targets.
# shellcheck disable=SC2086
bitbake ${PLATFORM_IMAGE_BITBAKE_ARGS:-} $targets
elapsed=$(($(date +%s) - start))

# The SOURCE_DATE_EPOCH bitbake used for the first target.
# shellcheck disable=SC2086
sde=$(bitbake -e ${targets%% *} | sed -n 's/^\(export[[:space:]][[:space:]]*\)\{0,1\}SOURCE_DATE_EPOCH="\(.*\)"$/\2/p' | sed -n '$p')
case $sde in '' | *[!0-9]*) sde= ;; esac
[ -n "$sde" ] || die "no SOURCE_DATE_EPOCH in bitbake -e"

deploy=$build/tmp/deploy/images/$machine
[ -d "$deploy" ] || die "no deploy directory $deploy after the build"
check_out
rm -rf "$out"
mkdir -p "$out"
printf '%s\n' "written by scripts/platform-image-build.sh; the script may delete this directory" >"$out/$out_marker"
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
	echo "checkout_commit=$checkout_commit"
	echo "platform_image_dirty=$inputs_dirty"
	echo "platform_image_dirty_sha256=$inputs_sha"
	echo "manifest_commit=$(sed -n 's/^manifest_commit=//p' "$lock")"
	sed -n 's/^\(layer_[A-Za-z0-9_]*_commit=.*\)$/\1/p' "$lock"
} >"$out/build-info.txt"
echo "platform-image-build: OK, $n artefacts in $out"
