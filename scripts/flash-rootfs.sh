#!/usr/bin/env bash
# Rewrite the root partition of a disk or disk image and erase the fTPM NV with it.
#
#   flash-rootfs.sh TARGET ROOTFS_IMAGE
#
# TARGET is a block device or a regular-file disk image with a GPT; ROOTFS_IMAGE is the
# built root file system image (the .ext4 beside the .wic). SPEC row ftpm requires the
# REE-FS NV to be wiped with the root file system. The NV lives in the tee-data
# partition (platform-image/files/wic/trusted-imx95.wks), which a rootfs write leaves
# alone, so this script is the only supported way to rewrite the root partition: it
# finds the partitions "root" and "tee-data" by their GPT names (the wks --part-name),
# erases tee-data (zeroed whole, file system made again), then writes the rootfs.
# A raw write of the root partition by any other means is unsupported and keeps the NV.
# The boot-time tee-nv-wipe unit is a second barrier, for a different build only.
#
# It refuses, with nothing written, when either partition is missing or not unique,
# the image does not fit, or mkfs.ext4 is absent. The erase comes before the rootfs
# write, so an interrupted run never leaves a new rootfs next to the old NV.
# A block device additionally needs FLASH_ROOTFS_YES=1.
set -euo pipefail

die() { echo "flash-rootfs: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: flash-rootfs.sh TARGET ROOTFS_IMAGE"
target=$1
img=$2
[ -e "$target" ] || die "$target does not exist"
[ -f "$img" ] || die "$img is not a file"
if [ -b "$target" ] && [ "${FLASH_ROOTFS_YES:-}" != 1 ]; then
	die "$target is a block device: set FLASH_ROOTFS_YES=1 to write it"
elif [ ! -b "$target" ] && [ ! -f "$target" ]; then
	die "$target is neither a block device nor a regular file"
fi
command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 not found; nothing written"
command -v python3 >/dev/null || die "python3 not found; nothing written"

# Print "name start-byte size-bytes" for each GPT entry, or fail.
table=$(python3 -I - "$target" <<'PY'
import struct, sys

with open(sys.argv[1], "rb") as f:
    for ss in (512, 4096):
        f.seek(ss)
        hdr = f.read(92)
        if hdr[:8] == b"EFI PART":
            break
    else:
        sys.exit("no GPT found")
    lba = struct.unpack_from("<Q", hdr, 72)[0]
    count, size = struct.unpack_from("<II", hdr, 80)
    f.seek(lba * ss)
    raw = f.read(count * size)
for i in range(count):
    e = raw[i * size:(i + 1) * size]
    if len(e) < 128 or e[:16] == bytes(16):
        continue
    first, last = struct.unpack_from("<QQ", e, 32)
    name = e[56:128].decode("utf-16le").split("\0")[0]
    print(name, first * ss, (last - first + 1) * ss)
PY
) || die "cannot read the partition table of $target; nothing written"

find_part() { # name -> "start size", fails unless exactly one entry has the name
	local out
	out=$(awk -v n="$1" '$1 == n { print $2, $3 }' <<<"$table")
	[ -n "$out" ] && [ "$(wc -l <<<"$out")" -eq 1 ] || return 1
	echo "$out"
}
root=$(find_part root) || die "no unique partition named root in $target; nothing written"
data=$(find_part tee-data) || die "no unique partition named tee-data in $target; nothing written"
read -r root_off root_size <<<"$root"
read -r data_off data_size <<<"$data"

img_size=$(stat -c %s "$img")
[ "$img_size" -gt 0 ] || die "$img is empty; nothing written"
[ "$img_size" -le "$root_size" ] || die "$img ($img_size bytes) does not fit the root partition ($root_size bytes); nothing written"

# 1. Erase the NV: zero tee-data whole, then make its file system again.
dd if=/dev/zero of="$target" bs=1M iflag=count_bytes oflag=seek_bytes \
	seek="$data_off" count="$data_size" conv=notrunc status=none
mkfs.ext4 -q -F -L tee-data -E "offset=$data_off" "$target" "$((data_size / 1024))k"
# 2. Write the rootfs.
dd if="$img" of="$target" bs=1M oflag=seek_bytes seek="$root_off" conv=notrunc,fsync status=none
sync
echo "flash-rootfs: wrote $img to root and erased tee-data on $target"
