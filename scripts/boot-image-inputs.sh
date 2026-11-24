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
#       STAND-IN. m33_image.bin taken from $SM_OUT is real only if SHA256SUMS
#       and sm-manifest.txt there match it and system-manager/sm.lock and say
#       reproducible=yes; --system-manager, --bl31 and --tee files are not
#       checked. An input with no
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
sm_used=0
[ -n "${given[system-manager]:-}" ] || { [ ! -f "$sm_default" ] || { given[system-manager]=$sm_default; sm_used=1; }; }
sw_used=()
[ -n "${given[bl31]:-}" ] || { [ ! -f "$sw_default/bl31.bin" ] || { given[bl31]=$sw_default/bl31.bin; sw_used+=(bl31.bin); }; }
[ -n "${given[tee]:-}" ] || { [ ! -f "$sw_default/tee.bin" ] || { given[tee]=$sw_default/tee.bin; sw_used+=(tee.bin); }; }

# check_sw_build: bl31.bin and tee.bin taken from the make secure-world output
# count as real only if that build's SHA256SUMS lists them with the hashes of
# the files, and build-info.txt names the SHA-256 of this tree's bsp.lock.
check_sw_build() {
	local sums=$sw_default/SHA256SUMS info=$sw_default/build-info.txt f want got locksum infolock
	[ -f "$sums" ] || die "$sums: missing; $sw_default is not a verified make secure-world output"
	[ -f "$info" ] || die "$info: missing; $sw_default is not a verified make secure-world output"
	for f in "${sw_used[@]}"; do
		want=$(while read -r h n; do if [ "${n#\*}" = "$f" ]; then echo "$h"; fi; done <"$sums")
		[ -n "$want" ] || die "$sums: no entry for $f"
		got=$(sha "$sw_default/$f")
		[ "$got" = "$want" ] || die "$f: SHA-256 $got differs from $sums ($want)"
	done
	infolock=$(while IFS= read -r l; do case "$l" in "lock: "*) echo "${l#lock: }" ;; esac; done <"$info")
	[ -n "$infolock" ] || die "$info: no lock: line"
	locksum=$(sha "$root/secure-world/bsp.lock")
	[ "$infolock" = "$locksum" ] || die "$info: lock: $infolock is not the SHA-256 of secure-world/bsp.lock ($locksum); rebuild with make secure-world"
}
[ "${#sw_used[@]}" -eq 0 ] || check_sw_build

# check_sm_build: m33_image.bin taken from the make system-manager output
# (not given with --system-manager) must match that build: SHA256SUMS has its
# digest, sm-manifest.txt repeats every system-manager/sm.lock key=value, and
# says reproducible=yes. Both files are read, never sourced.
check_sm_build() {
	local d=${sm_default%/*} sums sman f=$sm_default want got line k mline found
	sums=$d/SHA256SUMS
	sman=$d/sm-manifest.txt
	[ -f "$sums" ] || die "$f: $sums missing; $d is not a verified make system-manager output"
	[ -f "$sman" ] || die "$f: $sman missing; $d is not a verified make system-manager output"
	want=$(while read -r h n; do if [ "${n#\*}" = m33_image.bin ]; then echo "$h"; fi; done <"$sums")
	[ -n "$want" ] || die "$f: $sums has no entry for m33_image.bin"
	got=$(sha "$f")
	[ "$got" = "$want" ] || die "$f: SHA-256 $got differs from $sums ($want)"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		[[ $line =~ ^([a-z0-9_]+)=(.+)$ ]] || die "$root/system-manager/sm.lock: not key=value: $line"
		k=${BASH_REMATCH[1]}
		found=
		while IFS= read -r mline || [ -n "$mline" ]; do
			case "$mline" in "$k="*) found=$mline; break ;; esac
		done <"$sman"
		[ -n "$found" ] || die "$f: $sman has no $k line; sm.lock pins $line"
		[ "$found" = "$line" ] || die "$f: $sman has $found but sm.lock pins $line; rebuild with make system-manager"
	done <"$root/system-manager/sm.lock"
	found=
	while IFS= read -r mline || [ -n "$mline" ]; do
		[ "$mline" != reproducible=yes ] || found=1
	done <"$sman"
	[ -n "$found" ] || die "$f: $sman does not say reproducible=yes"
}
[ "$sm_used" -eq 0 ] || check_sm_build

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
