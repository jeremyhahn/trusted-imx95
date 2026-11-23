#!/usr/bin/env bash
# platform-image-build.sh [DIR [OUT]]: build the platform image on a Yocto build
# host. Fetch the layers platform-image/manifest.lock pins into DIR
# (scripts/platform-image-fetch.sh), write the build conf from the templates
# (refusing to overwrite a conf that differs), run
# `bitbake trusted-imx95-image trusted-imx95-image-debug`, then write OUT/SHA256SUMS:
# the digests of the wic image, kernel, dtbs and rootfs tarballs in
# DEPLOY_DIR_IMAGE. DIR and OUT are outside this clone (OUT defaults to DIR/out).
#
# This script never sets ACCEPT_FSL_EULA and has no switch that does: the NXP EULA
# is the owner's to accept (#14), and the owner has not. It refuses an
# ACCEPT_FSL_EULA in its environment or in the conf. If the build stops on a
# recipe the EULA gates, it lists those recipes and exits nonzero.
# Needs the network and a Yocto build host; it is not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${1:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
out=${2:-${PLATFORM_IMAGE_OUT:-$dir/out}}
targets="trusted-imx95-image trusted-imx95-image-debug"
localt=$root/platform-image/conf/local.conf.template
bblt=$root/platform-image/conf/bblayers.conf.template

die() {
	echo "platform-image-build: $*" >&2
	exit 1
}

[ -z "${ACCEPT_FSL_EULA+x}" ] || die "ACCEPT_FSL_EULA is set in the environment; this script does not accept the NXP EULA for the owner, unset it"

# outside_clone PATH: fails if PATH, resolved, is inside this clone.
outside_clone() {
	local abs=$1 anc rest= phys
	case $abs in /*) ;; *) abs=$PWD/$abs ;; esac
	anc=$abs
	while [ ! -d "$anc" ]; do
		rest=/$(basename "$anc")$rest
		anc=$(dirname "$anc")
	done
	phys=$(cd "$anc" && pwd -P)$rest
	case "$phys/" in "$root"/*) die "$1 is inside this clone; use a directory outside it" ;; esac
}
outside_clone "$dir"
outside_clone "$out"

"${PLATFORM_IMAGE_FETCH:-$root/scripts/platform-image-fetch.sh}" "$root/platform-image/manifest.lock" "$dir"
dir=$(cd "$dir" && pwd -P)
build=$dir/build
conf=$build/conf

want_local=$(cat "$localt")
want_bbl=$(sed -e "s|##FETCH_DIR##|$dir|g" -e "s|##REPO_DIR##|$root|g" "$bblt")
for f in local.conf bblayers.conf; do
	want=$want_local
	[ "$f" = bblayers.conf ] && want=$want_bbl
	if [ -e "$conf/$f" ] && [ "$(cat "$conf/$f")" != "$want" ]; then
		die "$conf/$f exists and differs from the template; remove it"
	fi
done
mkdir -p "$conf"
printf '%s\n' "$want_local" >"$conf/local.conf"
printf '%s\n' "$want_bbl" >"$conf/bblayers.conf"
# No conf this script wrote may assign ACCEPT_FSL_EULA (a comment may name it).
for f in local.conf bblayers.conf; do
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; esac
		case $l in *ACCEPT_FSL_EULA*) die "$conf/$f sets ACCEPT_FSL_EULA; the owner has not accepted the NXP EULA" ;; esac
	done <"$conf/$f"
done

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

mkdir -p "$out"
rm -f "$out/SHA256SUMS"
log=$dir/platform-image-build.log
rc=0
# shellcheck disable=SC2086
bitbake $targets 2>&1 | tee "$log" || rc=$?
if [ "$rc" -ne 0 ]; then
	declare -A gated=()
	eula_lines=()
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in *EULA* | *fsl-eula*) ;; *) continue ;; esac
		eula_lines+=("$l")
		if [[ $l =~ ^ERROR:\ ([A-Za-z0-9_+.]+(-[A-Za-z0-9_+.]+)*-[0-9][A-Za-z0-9_+.-]*)[\ :] ]]; then
			r=${BASH_REMATCH[1]}
			gated[${r%%-[0-9]*}]=1
		elif [[ $l =~ Skipping\ ([A-Za-z0-9_+.-]+) ]]; then
			gated[${BASH_REMATCH[1]}]=1
		fi
	done <"$log"
	if [ "${#eula_lines[@]}" -gt 0 ]; then
		echo "platform-image-build: the owner has not accepted the NXP EULA (#14); this script does not set ACCEPT_FSL_EULA. The build stopped on recipes the EULA gates:" >&2
		if [ "${#gated[@]}" -gt 0 ]; then
			printf '%s\n' "${!gated[@]}" | LC_ALL=C sort | while IFS= read -r r; do
				echo "platform-image-build: EULA-gated recipe: $r" >&2
			done
		else
			echo "platform-image-build: no recipe name could be read; the EULA lines of $log follow" >&2
			printf 'platform-image-build:   %s\n' "${eula_lines[@]}" >&2
		fi
		exit 1
	fi
	die "bitbake failed (exit $rc), not on the EULA; see $log"
fi

deploy=$(bitbake -e "${targets%% *}" | sed -n 's/^DEPLOY_DIR_IMAGE="\(.*\)"$/\1/p' | sed -n '$p')
[ -n "$deploy" ] && [ -d "$deploy" ] || die "no DEPLOY_DIR_IMAGE in bitbake -e"
files=()
for f in "$deploy"/*; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	case ${f##*/} in
	*.wic | *.wic.* | Image | Image-* | Image.* | *.dtb | *.tar.zst | *.tar.gz | *.tar.xz | *.tar.bz2)
		case ${f##*/} in *.manifest | *.json | *.txt | *.conf) continue ;; esac
		files+=("${f##*/}")
		;;
	esac
done
[ "${#files[@]}" -gt 0 ] || die "no wic image, kernel, dtb or rootfs tarball in $deploy"
sorted=$(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
(
	cd "$deploy"
	while IFS= read -r f; do sha256sum "$f"; done <<<"$sorted"
) >"$out/SHA256SUMS"
echo "platform-image-build: OK; digests in $out/SHA256SUMS (${#files[@]} files from $deploy)"
