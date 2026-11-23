#!/bin/sh
# The "unbound" marker of the root partition image (SPEC row ftpm; docs/ftpm/README.md).
# tee-nv-wipe keeps the NV's root binding token in the first 512-byte sector of the
# root partition. The image must carry a NONZERO value there: a sparse writer
# (GNU dd conv=sparse, bmaptool, a hole-punching copy) skips an all-zero block, so
# a sector of zeros would keep the old token and let the old NV survive a rewrite.
# The marker is "TEEUNBND1 <rootfs id> " filled with 'U' up to a final newline: no
# byte of the sector is zero, so no block of any size inside it is a hole. At boot
# the marker, like zeros or any value that is not this device's saved token, means a
# fresh root: the NV is wiped and the bound token is written.
#
#   root-marker.sh sector ID            the 512-byte marker sector, on stdout
#   root-marker.sh write FILE OFFSET ID write it at byte OFFSET (a multiple of 512) of FILE
#   root-marker.sh start                read `sfdisk -d` on stdin; print the byte offset of
#                                       the partition named root (512-byte sectors)
#   root-marker.sh wic WIC ID           write the marker at the start of WIC's root partition
set -eu

die() { echo "root-marker: $*" >&2; exit 1; }

sector() {
	id=$1
	case $id in '' | *[!A-Za-z0-9._-]*) die "the id must be non-empty and made of A-Za-z0-9._- only" ;; esac
	head="TEEUNBND1 $id "
	n=$((511 - ${#head}))
	[ "$n" -ge 0 ] || die "the id is too long"
	printf '%s' "$head"
	head -c 512 /dev/zero | tr '\000' U | head -c "$n"
	printf '\n'
}

start() {
	while IFS= read -r l; do
		case $l in
		*'name="root"'*)
			s=${l#*start=}
			s=${s%%,*}
			s=$(printf '%s' "$s" | tr -d ' ')
			case $s in '' | *[!0-9]*) die "bad start in the partition table dump" ;; esac
			echo $((s * 512))
			return 0
			;;
		esac
	done
	die "no partition named root in the partition table dump"
}

put() { # FILE OFFSET ID
	case $2 in '' | *[!0-9]*) die "bad offset" ;; esac
	[ $(($2 % 512)) -eq 0 ] || die "the offset is not a multiple of 512"
	sector "$3" | dd of="$1" bs=512 seek=$(($2 / 512)) count=1 conv=notrunc 2>/dev/null || die "cannot write $1"
}

case ${1:-} in
sector) [ $# -eq 2 ] || die "usage: sector ID"; sector "$2" ;;
write) [ $# -eq 4 ] || die "usage: write FILE OFFSET ID"; put "$2" "$3" "$4" ;;
start) start ;;
wic)
	[ $# -eq 3 ] || die "usage: wic WIC ID"
	off=$(sfdisk -d "$2" | start) || die "cannot find the root partition of $2"
	put "$2" "$off" "$3"
	;;
*) die "usage: sector|write|start|wic" ;;
esac
