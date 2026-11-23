#!/usr/bin/env bash
# boot-image-inputs.sh: collect the inputs of the boot image
# (docs/boot-container/boot-image.md; PROVISIONAL).
#
#   boot-image-inputs.sh --check [--lock FILE]
#       Validate the pins of boot-container/inputs.lock offline: every name
#       known and present once, commits of 40 hex digits, digests of 64, https
#       URLs, no UNREAD or MISSING, and meta_imx_commit equal to the one
#       secure-world/bsp.lock pins. Nothing is fetched.
#   boot-image-inputs.sh --fetch DIR [--lock FILE]
#       Download the two pinned sources (the U-Boot archive and the ELE
#       installer) into DIR and fail closed unless each SHA-256 matches. Needs
#       network. The ELE installer is never run or unpacked (licence).
#   boot-image-inputs.sh --collect DIR [--system-manager F] [--m7 F] [--bl31 F]
#                        [--tee F] [--uboot F] [--ele F] [--lock FILE]
#       Copy the six inputs into DIR as m33_image.bin, m7_image.bin, bl31.bin,
#       tee.bin, u-boot.bin and ele.bin, and write DIR/inputs.txt with one
#       "name source sha256" line each. System Manager defaults to
#       $SM_OUT/m33_image.bin (make system-manager), BL31 and tee.bin to
#       $SW_OUT (make secure-world) when those files exist. The M7 image is
#       trusted-firmware's (docs/SPEC.md): --m7 FILE when given, else a
#       STAND-IN. An input with no
#       file is replaced by a STAND-IN payload (a labelled random blob, not a
#       real image) and inputs.txt says "STAND-IN". The pins are checked first.
#
# No key, no board, no fuse. DIR is created if missing and must not be inside
# the git work tree's tracked files (the Makefile passes a git-ignored path).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/.." && pwd -P)

die() {
	echo "boot-image-inputs: $*" >&2
	exit 1
}

lock=$root/boot-container/inputs.lock
mode=
dir=
declare -A given=()

while [ $# -gt 0 ]; do
	case "$1" in
	--check) mode=check ;;
	--fetch | --collect)
		mode=${1#--}
		[ $# -ge 2 ] || die "$1 needs a directory"
		dir=$2
		shift
		;;
	--lock)
		[ $# -ge 2 ] || die "--lock needs a file"
		lock=$2
		shift
		;;
	--system-manager | --m7 | --bl31 | --tee | --uboot | --ele)
		[ $# -ge 2 ] || die "$1 needs a file"
		given[${1#--}]=$2
		shift
		;;
	*) die "usage: boot-image-inputs.sh --check | --fetch DIR | --collect DIR [--system-manager F] [--m7 F] [--bl31 F] [--tee F] [--uboot F] [--ele F] [--lock FILE]" ;;
	esac
	shift
done
[ -n "$mode" ] || die "usage: boot-image-inputs.sh --check | --fetch DIR | --collect DIR ..."

declare -A pin=()
names="meta_imx_commit uboot_repo uboot_branch uboot_commit uboot_archive_url uboot_archive_sha256 ele_version ele_installer_url ele_installer_sha256"

# parse_lock: read $lock into pin[] without sourcing it; fail closed on an
# unknown, repeated, missing, empty or malformed value.
parse_lock() {
	[ -f "$lock" ] || die "no lock file: $lock"
	local line k v n found
	pin=()
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		[[ "$line" == *=* ]] || die "malformed line in $lock: $line"
		k=${line%%=*}
		v=${line#*=}
		found=
		for n in $names; do [ "$n" = "$k" ] && found=1; done
		[ -n "$found" ] || die "unknown name in $lock: $k"
		[ -z "${pin[$k]+x}" ] || die "$k appears twice in $lock"
		pin[$k]=$v
	done <"$lock"
	for n in $names; do
		[ -n "${pin[$n]:-}" ] || die "$n missing or empty in $lock"
		case "${pin[$n]}" in UNREAD* | MISSING*) die "$n is ${pin[$n]} in $lock" ;; esac
	done
	for n in meta_imx_commit uboot_commit; do
		[[ "${pin[$n]}" =~ ^[0-9a-f]{40}$ ]] || die "$n is not 40 hex digits"
	done
	for n in uboot_archive_sha256 ele_installer_sha256; do
		[[ "${pin[$n]}" =~ ^[0-9a-f]{64}$ ]] || die "$n is not 64 hex digits"
	done
	for n in uboot_repo uboot_archive_url ele_installer_url; do
		[[ "${pin[$n]}" =~ ^https://[A-Za-z0-9._/-]+$ ]] || die "$n is not an https URL"
	done
	[[ "${pin[ele_version]}" =~ ^[0-9.]+$ ]] || die "ele_version is not a version"
}

# check_bsp: meta_imx_commit must be the commit secure-world/bsp.lock pins.
check_bsp() {
	local bsp=$root/secure-world/bsp.lock want
	[ -f "$bsp" ] || die "no $bsp"
	[ -f "$root/system-manager/sm.lock" ] || die "no $root/system-manager/sm.lock"
	want=
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in META_IMX_COMMIT=*) want=${line#*=} ;; esac
	done <"$bsp"
	[ -n "$want" ] || die "no META_IMX_COMMIT in $bsp"
	[ "$want" = "${pin[meta_imx_commit]}" ] ||
		die "meta_imx_commit differs from META_IMX_COMMIT of secure-world/bsp.lock"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

case "$mode" in
check)
	parse_lock
	check_bsp
	echo "boot-image-inputs: pins OK ($lock)"
	exit 0
	;;
fetch)
	parse_lock
	command -v curl >/dev/null || die "curl is needed for --fetch"
	mkdir -p "$dir"
	for kind in uboot_archive ele_installer; do
		url=${pin[${kind}_url]}
		want=${pin[${kind}_sha256]}
		f=$dir/$(basename "$url")
		[ "$kind" != uboot_archive ] || f=$dir/uboot-imx-${pin[uboot_commit]}.tar.gz
		curl -fsSL --proto '=https' -o "$f.part" "$url" || {
			rm -f "$f.part"
			die "download failed: $url"
		}
		got=$(sha "$f.part")
		if [ "$got" != "$want" ]; then
			rm -f "$f.part"
			die "SHA-256 mismatch for $url: got $got, want $want"
		fi
		mv "$f.part" "$f"
		echo "fetched $f ($got)"
	done
	exit 0
	;;
esac

# --collect
parse_lock
check_bsp
[ -n "$dir" ] || die "--collect needs a directory"
mkdir -p "$dir"

# default locations of what this repository builds
sm_default=${SM_OUT:-$root/out/system-manager}/m33_image.bin
sw_default=${SW_OUT:-$root/.secure-world/out}
[ -n "${given[system-manager]:-}" ] || { [ ! -f "$sm_default" ] || given[system-manager]=$sm_default; }
[ -n "${given[bl31]:-}" ] || { [ ! -f "$sw_default/bl31.bin" ] || given[bl31]=$sw_default/bl31.bin; }
[ -n "${given[tee]:-}" ] || { [ ! -f "$sw_default/tee.bin" ] || given[tee]=$sw_default/tee.bin; }

: >"$dir/inputs.txt"
# take <key> <file name in DIR> <label>
take() {
	local name=$2 label=$3 src=${given[$1]:-}
	if [ -n "$src" ]; then
		[ -f "$src" ] || die "$label: no such file: $src"
		[ -s "$src" ] || die "$label: empty file: $src"
		cp "$src" "$dir/$name"
		printf '%s real %s\n' "$name" "$(sha "$dir/$name")" >>"$dir/inputs.txt"
	else
		{
			printf 'STAND-IN %s: not a real image\n' "$label"
			head -c 4096 /dev/urandom
		} >"$dir/$name"
		printf '%s STAND-IN %s\n' "$name" "$(sha "$dir/$name")" >>"$dir/inputs.txt"
		echo "boot-image-inputs: $label: STAND-IN payload (no input file)" >&2
	fi
}
take system-manager m33_image.bin "System Manager"
take m7 m7_image.bin "Cortex-M7 image"
take bl31 bl31.bin "TF-A BL31"
take tee tee.bin "OP-TEE tee.bin"
take uboot u-boot.bin "U-Boot"
take ele ele.bin "ELE firmware"
echo "boot-image-inputs: collected into $dir"
