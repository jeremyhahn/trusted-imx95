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

# The reader matches the exact names itself and prints four validated integers
# (start and size of root, then of tee-data, in bytes); the shell never splits a name.
# It fails, printing nothing, on a duplicate or missing name, a name with whitespace
# or control characters, or a range outside the disk or overlapping.
nums=$(python3 -I - "$target" <<'PY'
import struct, sys

def fail(msg):
    sys.exit(msg)

with open(sys.argv[1], "rb") as f:
    f.seek(0, 2)
    disk = f.tell()
    for ss in (512, 4096):
        f.seek(ss)
        hdr = f.read(92)
        if hdr[:8] == b"EFI PART":
            break
    else:
        fail("no GPT found")
    lba = struct.unpack_from("<Q", hdr, 72)[0]
    count, size = struct.unpack_from("<II", hdr, 80)
    if size < 128 or count > 4096 or lba * ss + count * size > disk:
        fail("bad GPT header")
    f.seek(lba * ss)
    raw = f.read(count * size)
found = {}
for i in range(count):
    e = raw[i * size:(i + 1) * size]
    if len(e) < 128 or e[:16] == bytes(16):
        continue
    first, last = struct.unpack_from("<QQ", e, 32)
    try:
        name = e[56:128].decode("utf-16le").split("\0")[0]
    except UnicodeDecodeError:
        fail("undecodable partition name")
    if not name or any(c.isspace() or not c.isprintable() for c in name):
        fail("partition name with whitespace or control characters")
    if name in found:
        fail("duplicate partition name " + ascii(name))
    if last < first or (last + 1) * ss > disk:
        fail("partition outside the disk")
    found[name] = (first * ss, (last - first + 1) * ss)
for n in ("root", "tee-data"):
    if n not in found:
        fail("no partition named " + n)
(ro, rs), (do, ds) = found["root"], found["tee-data"]
if ro < do + ds and do < ro + rs:
    fail("root and tee-data overlap")
print(ro, rs, do, ds)
PY
) || die "cannot find unique root and tee-data partitions in $target; nothing written"
read -r root_off root_size data_off data_size <<<"$nums"
# Only integers may reach the dd and mkfs arguments.
for v in "$root_off" "$root_size" "$data_off" "$data_size"; do
	[[ $v =~ ^[0-9]+$ ]] || die "partition table gave a non-numeric value; nothing written"
done

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
