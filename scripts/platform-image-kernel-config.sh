#!/usr/bin/env bash
# platform-image-kernel-config.sh [DIR]: the kernel configuration check of
# platform-image/. In the build directory scripts/platform-image-parse.sh left
# in DIR, run `bitbake linux-imx -c configure` (which merges hardening.cfg and
# resolves dependencies), find the generated .config through
# `bitbake -e linux-imx` (B), and check it against the required table
# platform-image/kernel-required.txt, the one test/platform_image_kernel_test.sh
# checks the fragment against. A required `n` holds when the symbol is "is not
# set" or absent (unmet dependencies leave it out of .config). Needs a Yocto
# build host and the fetched layers; it is not in CI.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${1:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
req=$root/platform-image/kernel-required.txt
[ -f "$req" ] || { echo "platform-image-kernel-config: $req is missing" >&2; exit 1; }
[ -d "$dir/build/conf" ] || { echo "platform-image-kernel-config: no build directory in $dir; run scripts/platform-image-parse.sh first" >&2; exit 1; }
dir=$(cd "$dir" && pwd -P)
build=$dir/build

# Cap the load: BitBake threads and make jobs from nproc (at most 16; 6 if
# nproc is not there), passed through the filtered task environment.
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
command -v bitbake >/dev/null 2>&1 || { echo "platform-image-kernel-config: bitbake is not on PATH; run this on a Yocto build host" >&2; exit 1; }

# A BitBake server this script started must not outlive it: it would keep the
# socket and make the next client time out. Stop it on every exit; stop a
# stale one a crashed earlier run left in this build directory first.
if [ -e "$build/bitbake.sock" ]; then
	echo "platform-image-kernel-config: a BitBake server from an earlier run holds $build/bitbake.sock; stopping it" >&2
	bitbake -m >/dev/null 2>&1 || true
fi
trap 'bitbake -m >/dev/null 2>&1 || true' EXIT
bitbake linux-imx -c configure
b=$(bitbake -e linux-imx | sed -n 's/^B="\(.*\)"$/\1/p')
[ -n "$b" ] || { echo "platform-image-kernel-config: no B in bitbake -e linux-imx" >&2; exit 1; }
cfg=$b/.config
[ -f "$cfg" ] || { echo "platform-image-kernel-config: $cfg was not generated" >&2; exit 1; }

declare -A got=()
while IFS= read -r l || [ -n "$l" ]; do
	if [[ $l =~ ^#\ CONFIG_([A-Z0-9_]+)\ is\ not\ set$ ]]; then
		got[${BASH_REMATCH[1]}]=n
	elif [[ $l =~ ^CONFIG_([A-Z0-9_]+)=(.*)$ ]]; then
		got[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
	fi
done <"$cfg"

rc=0 n=0
while IFS= read -r l || [ -n "$l" ]; do
	case $l in '' | '#'*) continue ;; esac
	s=${l%%=*} w=${l#*=}
	n=$((n + 1))
	g=${got[$s]:-}
	if [ -z "$g" ] && [ "$w" = n ]; then g=n; fi
	if [ "$g" != "$w" ]; then
		echo "platform-image-kernel-config: required $s: want $w, got ${g:-missing}" >&2
		rc=1
	fi
done <"$req"
[ "$n" -gt 0 ] || { echo "platform-image-kernel-config: no required symbols in $req" >&2; exit 1; }
[ "$rc" -eq 0 ] || exit 1
echo "platform-image-kernel-config: OK ($n symbols in $cfg)"
