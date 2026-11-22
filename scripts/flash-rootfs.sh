#!/usr/bin/env bash
# Rewrite the root partition of a disk or disk image and erase the fTPM NV with it.
#
#   flash-rootfs.sh TARGET WIC
#
# TARGET is a block device or a regular-file disk image already carrying this image's
# partition table; WIC is the built disk image (the .wic). SPEC row ftpm requires the
# REE-FS NV to be wiped with the root file system. The NV lives in the tee-data
# partition (platform-image/files/wic/trusted-imx95.wks), which a rootfs write leaves
# alone, so this script is the only supported way to rewrite the root partition.
# A raw write of the root partition by any other means is unsupported and keeps the NV.
# The boot-time tee-nv-wipe unit is a second barrier, for a different build only.
#
# The target's partition table is not parsed and trusted: it is compared with the WIC's.
# One reader checks each table (header and entry-array CRC32s, usable-LBA range, no two
# entries overlapping, names without whitespace or control characters, root and tee-data
# each present once) and the script refuses unless the target's entries equal the WIC's
# exactly (count, index, names, type GUIDs, first and last LBA). Only then it erases
# tee-data (zeroed whole, file system made again) and copies the root partition's byte
# range from the WIC, both ranges taken from the validated WIC table. The erase comes
# first, so an interrupted run never leaves a new rootfs next to the old NV.
# Both paths are resolved with realpath and must then be a regular file or a block device
# (a symlink is followed, never measured). A block device needs FLASH_ROOTFS_YES=1.
# A blank target has no table to match: write the whole WIC to it by the boot-container
# flow first (docs/ftpm/README.md).
set -euo pipefail

die() { echo "flash-rootfs: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: flash-rootfs.sh TARGET WIC"
command -v realpath >/dev/null || die "realpath not found; nothing written"
command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 not found; nothing written"
command -v python3 >/dev/null || die "python3 not found; nothing written"
target=$(realpath -e -- "$1") || die "$1 does not exist"
wic=$(realpath -e -- "$2") || die "$2 does not exist"
{ [ -b "$target" ] || [ -f "$target" ]; } || die "$target is neither a block device nor a regular file"
{ [ -b "$wic" ] || [ -f "$wic" ]; } || die "$wic is neither a block device nor a regular file"
for p in "$target" "$wic"; do
	if [[ $p =~ [[:space:][:cntrl:]] ]]; then
		die "$(printf '%q' "$p") contains whitespace or a control character; nothing written"
	fi
done
if [ "$target" -ef "$wic" ]; then die "target and WIC are the same file"; fi
if [ -b "$target" ] && [ "${FLASH_ROOTFS_YES:-}" != 1 ]; then
	die "$target is a block device: set FLASH_ROOTFS_YES=1 to write it"
fi

# Never write a target that is in use: the target or one of its partitions is the source of
# a mount in mountinfo (by name or by device number), or something holds it (sysfs holders:
# device-mapper, md, loop). FLASH_ROOTFS_MOUNTINFO and FLASH_ROOTFS_SYSFS exist for the test.
mountinfo=${FLASH_ROOTFS_MOUNTINFO:-/proc/self/mountinfo}
sysfs=${FLASH_ROOTFS_SYSFS:-/sys}
[ -r "$mountinfo" ] || die "cannot read $mountinfo; nothing written"
devnos=" "
if [ -b "$target" ]; then
	hex=$(stat -L -c '%t:%T' "$target") || die "cannot stat $target; nothing written"
	node=$(cd -P "$sysfs/dev/block/$((16#${hex%:*})):$((16#${hex#*:}))" 2>/dev/null && pwd -P) ||
		die "cannot find $target in sysfs; nothing written"
	if [ -e "$node/partition" ]; then node=${node%/*}; fi
	for d in "$node" "$node"/*/; do
		d=${d%/}
		[ -e "$d/dev" ] || continue
		if [ -n "$(ls -A "$d/holders" 2>/dev/null)" ]; then
			die "$target (or a partition of it) is held by another device; nothing written"
		fi
		devnos="$devnos$(<"$d/dev") "
	done
fi
while read -r -a mi; do
	for i in "${!mi[@]}"; do
		[ "${mi[$i]}" = - ] && break
	done
	src=${mi[$((i + 2))]:-}
	case $src in
	"$target" | "$target"[0-9]* | "$target"p[0-9]*)
		die "$src is mounted (mountinfo); nothing written" ;;
	esac
	case $devnos in
	*" ${mi[2]} "*) die "$target (or a partition of it) is mounted (device ${mi[2]}); nothing written" ;;
	esac
done <"$mountinfo"

# A regular-file image that backs an attached loop device is in use (mountinfo names the
# loop device, not the file): refuse whether or not a loop partition is mounted.
if [ -f "$target" ]; then
	for bf in "$sysfs"/block/loop*/loop/backing_file; do
		[ -e "$bf" ] || continue
		IFS= read -r backing <"$bf" || backing=
		[ -n "$backing" ] || continue
		if [ "$(realpath -m -- "$backing")" = "$target" ] || [ "$backing" -ef "$target" ]; then
			lp=${bf%/loop/backing_file}
			die "$target backs the loop device ${lp##*/}; nothing written"
		fi
	done
fi

nums=$(python3 -I - "$target" "$wic" <<'PY'
import struct, sys, zlib

SS = 512

def fail(msg):
    sys.exit(msg)

def table(path):
    """The validated entries of the primary GPT: [(index, type, first, last, name)]."""
    with open(path, "rb") as f:
        f.seek(0, 2)
        disk = f.tell()
        f.seek(SS)
        hdr = f.read(SS)
        if len(hdr) < 92 or hdr[:8] != b"EFI PART":
            fail(path + ": no GPT")
        hsize = struct.unpack_from("<I", hdr, 12)[0]
        if hsize < 92 or hsize > SS:
            fail(path + ": bad GPT header size")
        hdr = hdr[:hsize]
        z = bytearray(hdr)
        z[16:20] = bytes(4)
        if zlib.crc32(bytes(z)) != struct.unpack_from("<I", hdr, 16)[0]:
            fail(path + ": GPT header CRC32 mismatch")
        cur, _alt, usable_first, usable_last = struct.unpack_from("<QQQQ", hdr, 24)
        lba, count, size, ecrc = struct.unpack_from("<QIII", hdr, 72)
        if cur != 1 or size != 128 or not 1 <= count <= 4096 or lba < 2:
            fail(path + ": bad GPT header fields")
        if usable_first > usable_last or (usable_last + 1) * SS > disk:
            fail(path + ": usable LBA range outside the disk")
        if (lba * SS) + count * size > usable_first * SS:
            fail(path + ": entry array overlaps the usable area")
        f.seek(lba * SS)
        raw = f.read(count * size)
    if len(raw) != count * size or zlib.crc32(raw) != ecrc:
        fail(path + ": GPT entry array CRC32 mismatch")
    out, names = [], set()
    for i in range(count):
        e = raw[i * size:(i + 1) * size]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        try:
            name = e[56:128].decode("utf-16le").split("\0")[0]
        except UnicodeDecodeError:
            fail(path + ": undecodable partition name")
        if any(c.isspace() or not c.isprintable() for c in name):
            fail(path + ": partition name with whitespace or control characters")
        if name:
            if name in names:
                fail(path + ": duplicate partition name " + ascii(name))
            names.add(name)
        if last < first or first < usable_first or last > usable_last:
            fail(path + ": partition " + str(i) + " outside the usable LBA range")
        out.append((i, bytes(e[:16]), first, last, name))
    spans = sorted((e[2], e[3]) for e in out)
    for (_a, b), (c, _d) in zip(spans, spans[1:]):
        if c <= b:
            fail(path + ": overlapping partitions")
    return out

target, wic = table(sys.argv[1]), table(sys.argv[2])
if target != wic:
    fail("the target's partition table differs from the WIC's")
byname = {e[4]: e for e in wic}
for n in ("root", "tee-data"):
    if n not in byname:
        fail("no partition named " + n)
r, d = byname["root"], byname["tee-data"]
print(r[2] * SS, (r[3] - r[2] + 1) * SS, d[2] * SS, (d[3] - d[2] + 1) * SS)
PY
) || die "the partition tables of $target and $wic do not match as required; nothing written"
read -r root_off root_size data_off data_size <<<"$nums"
# Only integers may reach the dd and mkfs arguments.
for v in "$root_off" "$root_size" "$data_off" "$data_size"; do
	[[ $v =~ ^[0-9]+$ ]] || die "partition table gave a non-numeric value; nothing written"
done

# 1. Erase the NV: zero tee-data whole, then make its file system again.
dd if=/dev/zero of="$target" bs=1M iflag=count_bytes oflag=seek_bytes \
	seek="$data_off" count="$data_size" conv=notrunc status=none
mkfs.ext4 -q -F -L tee-data -E "offset=$data_off" "$target" "$((data_size / 1024))k"
# 2. Copy the root partition's range, and only that range, from the WIC.
dd if="$wic" of="$target" bs=1M iflag=skip_bytes,count_bytes oflag=seek_bytes \
	skip="$root_off" seek="$root_off" count="$root_size" conv=notrunc,fsync status=none
sync
echo "flash-rootfs: wrote the root partition of $wic and erased tee-data on $target"
