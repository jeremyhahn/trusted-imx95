#!/bin/sh
# Build-host check of a real image build (SPEC row ftpm; docs/ftpm/README.md, "Where the NV lives"):
# every disk image the build emitted carries the nonzero "unbound" marker in the first sector of
# its root partition, and every .bmap maps that sector.
#
#   platform-image-check-root-marker.sh DEPLOY_DIR
#
# DEPLOY_DIR is the build's deploy directory for the image (DEPLOY_DIR_IMAGE). Each *.wic,
# *.wic.gz, *.wic.bz2, *.wic.xz and *.wic.zst in it (a symlink is followed) is decompressed to a
# scratch file when compressed; the root partition's start is read from `sfdisk -d` (through
# platform-image/files/root-marker.sh start), and its first sector must be 512 bytes, start with
# "TEEUNBND1 " and hold no zero byte. A "<image>.wic.bmap" next to a variant is read too: some
# <Range> must cover the marker's block, the checksum of that range (BlockMap chksum, the file's
# ChecksumType) must match the image's bytes, and the file's own BmapFileChecksum, if present,
# must match (the file hashed with that field set to zeros). Any miss, an unreadable or
# unknown file, or no image at all is a nonzero exit. Reads files only: no device, no network.
set -eu

die() {
	echo "check-root-marker: $*" >&2
	exit 1
}

[ $# -eq 1 ] || die "usage: $0 DEPLOY_DIR"
dir=$1
[ -d "$dir" ] || die "$dir is not a directory"
here=$(cd "$(dirname "$0")" && pwd)
rm_sh=$here/../platform-image/files/root-marker.sh
[ -f "$rm_sh" ] || die "cannot find $rm_sh"
PATH=$PATH:/sbin:/usr/sbin
export PATH

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
seen=0

fail() {
	echo "check-root-marker: FAIL $*" >&2
	fails=$((fails + 1))
}

# materialise FILE: prints the path of a plain image holding FILE's bytes.
materialise() {
	case $1 in
	*.wic) printf '%s\n' "$1" ;;
	*)
		case $1 in
		*.gz) dec="gzip -dc" ;;
		*.bz2) dec="bzip2 -dc" ;;
		*.xz) dec="xz -dc" ;;
		*.zst) dec="zstd -dc" ;;
		*) return 1 ;;
		esac
		# shellcheck disable=SC2086 # the decompressor is a word list chosen above
		$dec <"$1" | dd of="$tmp/img" bs=1M conv=sparse 2>/dev/null || return 1
		printf '%s\n' "$tmp/img"
		;;
	esac
}

# check_bmap BMAP IMAGE BLOCKOFFSET: ranges, range checksum, file checksum.
check_bmap() {
	bm=$1
	img=$2
	off=$3
	bs=
	ct=
	fc=
	covered=0
	while IFS= read -r l; do
		case $l in
		*'<BlockSize>'*) bs=$(printf '%s' "$l" | tr -dc '0-9') ;;
		*'<ChecksumType>'*)
			ct=$(printf '%s' "$l" | tr -d ' \t')
			ct=${ct#*<ChecksumType>}
			ct=${ct%%<*}
			;;
		*'<BmapFileChecksum>'*)
			fc=${l#*<BmapFileChecksum>}
			fc=${fc%%<*}
			fc=$(printf '%s' "$fc" | tr -d ' \t')
			;;
		esac
	done <"$bm"
	case $bs in '' | *[!0-9]*) fail "$bm: no block size" && return 0 ;; esac
	blk=$((off / bs))
	while IFS= read -r l; do
		case $l in *'<Range'*) ;; *) continue ;; esac
		sum=${l#*chksum=\"}
		sum=${sum%%\"*}
		r=${l#*>}
		r=${r%%<*}
		r=$(printf '%s' "$r" | tr -d ' \t')
		case $r in
		*-*) a=${r%-*} b=${r#*-} ;;
		*) a=$r b=$r ;;
		esac
		case "$a$b" in '' | *[!0-9]*) fail "$bm: bad range $r" && return 0 ;; esac
		if [ "$blk" -ge "$a" ] && [ "$blk" -le "$b" ]; then
			covered=1
			case $ct in
			sha256) got=$(dd if="$img" bs="$bs" skip="$a" count=$((b - a + 1)) 2>/dev/null | sha256sum | cut -d' ' -f1) ;;
			*) fail "$bm: unsupported checksum type '$ct'" && return 0 ;;
			esac
			[ "$got" = "$sum" ] || fail "$bm: the checksum of range $r does not match the image"
		fi
	done <"$bm"
	[ "$covered" -eq 1 ] || fail "$bm: no mapped range covers the marker (block $blk of $bs bytes)"
	if [ -n "$fc" ]; then
		z=0000000000000000000000000000000000000000000000000000000000000000
		got=$(sed "s|\(<BmapFileChecksum>[^0-9a-f]*\)[0-9a-f]\{64\}|\1$z|" "$bm" | sha256sum | cut -d' ' -f1)
		[ "$got" = "$fc" ] || fail "$bm: the file checksum does not match"
	fi
}

for f in "$dir"/*.wic "$dir"/*.wic.gz "$dir"/*.wic.bz2 "$dir"/*.wic.xz "$dir"/*.wic.zst; do
	[ -e "$f" ] || [ -L "$f" ] || continue
	seen=$((seen + 1))
	[ -f "$f" ] || { fail "$f is not a readable file (a dangling link?)"; continue; }
	rm -f "$tmp/img"
	img=$(materialise "$f") || { fail "$f: cannot be decompressed"; continue; }
	if ! start=$(sfdisk -d "$img" 2>/dev/null | sh "$rm_sh" start 2>/dev/null); then
		fail "$f: no partition named root in its partition table"
		continue
	fi
	dd if="$img" of="$tmp/sector" bs=512 skip=$((start / 512)) count=1 2>/dev/null
	n=$(wc -c <"$tmp/sector")
	nz=$(tr -d '\000' <"$tmp/sector" | wc -c)
	if [ "$n" -ne 512 ] || [ "$nz" -ne 512 ]; then
		fail "$f: the root sector is not 512 nonzero bytes (size $n, nonzero $nz)"
	elif [ "$(head -c 10 "$tmp/sector")" != "TEEUNBND1 " ]; then
		fail "$f: the root sector carries no unbound marker"
	else
		echo "check-root-marker: ok $f: marker at byte $start"
	fi
	stem=${f%.gz}
	stem=${stem%.bz2}
	stem=${stem%.xz}
	stem=${stem%.zst}
	if [ -f "$stem.bmap" ]; then
		check_bmap "$stem.bmap" "$img" "$start"
	fi
done
[ "$seen" -gt 0 ] || die "no .wic image in $dir"
for b in "$dir"/*.bmap; do
	[ -e "$b" ] || continue
	[ -f "${b%.bmap}" ] || [ -f "${b%.bmap}.gz" ] || [ -f "${b%.bmap}.bz2" ] || [ -f "${b%.bmap}.xz" ] ||
		[ -f "${b%.bmap}.zst" ] || fail "$b has no image next to it"
done
[ "$fails" -eq 0 ] || die "$fails check(s) failed in $dir"
echo "check-root-marker: OK ($seen image file(s) in $dir)"
