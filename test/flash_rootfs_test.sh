#!/usr/bin/env bash
# Offline test of scripts/flash-rootfs.sh (SPEC row ftpm, issue #140): rewriting the
# root partition erases the tee-data partition with it. Everything runs on regular-file
# disk images built here (a GPT written by python3, no root, no loop devices) with a
# stub mkfs.ext4 first on PATH; no real device is ever a target.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

flash=$ROOT/scripts/flash-rootfs.sh
wks=$ROOT/platform-image/files/wic/trusted-imx95.wks
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
mkdir "$w/bin"
MiB=1048576

# mkfs.ext4 stub: marks the start of the file system it was asked to make
# (-E offset=N, size as the last argument) with "MKFS-STUB" and logs the size.
cat >"$w/bin/mkfs.ext4" <<'STUB'
#!/usr/bin/env bash
off=0
while [ $# -gt 1 ]; do
	case $1 in -E) off=${2#offset=}; shift ;; esac
	shift
done
printf 'MKFS-STUB' | dd of="$MKFS_TARGET" bs=1 seek="$off" conv=notrunc status=none 2>/dev/null
STUB
chmod +x "$w/bin/mkfs.ext4"

# mkdisk FILE NAMES: a 16 MiB GPT disk image; partitions boot (1 MiB at 1 MiB),
# then root (4 MiB at 2 MiB) and tee-data (4 MiB at 6 MiB) as named in NAMES
# ("boot root tee-data"; fewer names leave the slots out). Each partition is filled:
# boot 0xBB, root 0xDD, tee-data 0xAA.
mkdisk() {
	python3 -I - "$1" "$2" "${3-}" "${4-}" <<'PY'
import struct, sys, zlib

path, names, tweak = sys.argv[1], sys.argv[2].split(), sys.argv[4]
ss, total = 512, 16 * 1048576
disk = bytearray(total)
starts = {"boot": (1, 1, 0xBB), "root": (2, 4, 0xDD), "tee-data": (6, 4, 0xAA), "extra": (10, 4, 0xEE)}
# Optional third argument: the GPT names to write, "|"-separated, one per slot in
# NAMES (so a slot can carry a name with spaces or a newline, or a duplicate name).
labels = sys.argv[3].split("|") if sys.argv[3] else names
entries = b""
for slot, n in zip(names, labels):
    s, size, fill = starts[slot]
    first, last = s * 2048, (s + size) * 2048 - 1
    disk[first * ss:(last + 1) * ss] = bytes([fill]) * (size * 1048576)
    if slot == "tee-data":
        # Table damage on the tee-data entry (the data stays where it is).
        if tweak == "tee-first0":
            first = 0
        elif tweak == "tee-overlap-boot":
            first = 2048
        elif tweak == "shift":
            first, last = first + 1, last + 1
    e = bytes(range(1, 17)) + bytes(range(17, 33)) + struct.pack("<QQQ", first, last, 0)
    e += n.encode("utf-16le").ljust(72, b"\0")
    entries += e
entries = entries.ljust(128 * 128, b"\0")
hdr = bytearray(92)
hdr[:8] = b"EFI PART"
struct.pack_into("<IIIIQQQQ", hdr, 8, 0x10000, 92, 0, 0, 1, total // ss - 1, 34, total // ss - 34)
hdr[56:72] = bytes(16)
struct.pack_into("<QIII", hdr, 72, 2, 128, 128, zlib.crc32(entries))
struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr)))
if tweak == "badcrc":
    hdr[16] ^= 1
disk[ss:ss + 92] = hdr
disk[2 * ss:2 * ss + len(entries)] = entries
open(path, "wb").write(disk)
PY
}

# region FILE OFFSET-MiB SIZE-MiB OUT: copy a region of a disk to OUT.
region() { dd if="$1" of="$4" bs=$MiB skip="$2" count="$3" status=none; }

# run DISK WIC: run the script, print its exit status (output is not shown).
run() {
	local r=0
	FLASH_ROOTFS_MOUNTINFO=${MI:-/dev/null} MKFS_TARGET=$1 PATH="$w/bin:$PATH" bash "$flash" "$1" "$2" >"$w/out" 2>&1 || r=$?
	echo "$r"
}

# mkwic FILE [TWEAK] [NAMES]: the built image the script reads: the same layout as a
# target, with a random root (so a copy is visible) and a boot partition of 0xCC.
mkwic() {
	mkdisk "$1" "${3-boot root tee-data}" "" "${2-}"
	head -c $((4 * MiB)) /dev/urandom | dd of="$1" bs=$MiB seek=2 conv=notrunc status=none
	head -c $MiB /dev/zero | tr '\0' '\314' | dd of="$1" bs=$MiB seek=1 conv=notrunc status=none
}

mkwic "$w/wic"

# A target with the WIC's layout: the root range is copied, tee-data erased, the rest untouched.
mkdisk "$w/disk" "boot root tee-data"
expect "the script exits 0 on a target with the WIC's layout" test "$(run "$w/disk" "$w/wic")" -eq 0
region "$w/disk" 2 4 "$w/got-root"
region "$w/wic" 2 4 "$w/want-root"
expect "the WIC's root partition is in the root partition" cmp -s "$w/got-root" "$w/want-root"
region "$w/disk" 6 4 "$w/got-data"
{ printf 'MKFS-STUB'; head -c $((4 * MiB - 9)) /dev/zero; } >"$w/want-data"
expect "tee-data is zeroed and its file system made again" cmp -s "$w/got-data" "$w/want-data"
region "$w/disk" 1 1 "$w/got-boot"
expect "the boot partition is untouched, not copied from the WIC" test "$(tr -d '\273' <"$w/got-boot" | wc -c)" -eq 0
region "$w/disk" 0 1 "$w/got-head"
region "$w/wic" 0 1 "$w/want-head"
expect "the partition table is as it was" cmp -s "$w/got-head" "$w/want-head"

# Links are followed: a target and a WIC given as symlinks work the same.
mkdisk "$w/disk2" "boot root tee-data"
ln -s "$w/disk2" "$w/disk2.lnk"
ln -s "$w/wic" "$w/wic.lnk"
expect "symlinks to the target and the WIC are resolved" test "$(run "$w/disk2.lnk" "$w/wic.lnk")" -eq 0
region "$w/disk2" 2 4 "$w/got-root2"
expect "the root partition is copied through the links" cmp -s "$w/got-root2" "$w/want-root"

# Refusals write nothing.
refused() { # NAME DISK WIC: a non-zero exit and an unchanged disk
	local sum
	sum=$(cksum <"$2")
	expect "refused: $1" test "$(run "$2" "$3")" -ne 0
	expect "refused, nothing written: $1" test "$(cksum <"$2")" = "$sum"
}
mkdisk "$w/nodata" "boot root"
mkwic "$w/wic-nodata" "" "boot root"
refused "no tee-data partition" "$w/nodata" "$w/wic-nodata"
mkdisk "$w/noroot" "boot tee-data"
mkwic "$w/wic-noroot" "" "boot tee-data"
refused "no root partition" "$w/noroot" "$w/wic-noroot"
# The size of a link is not the size of what it points at (the old size check measured the link).
mkwic "$w/wic-short"
truncate -s $((5 * MiB)) "$w/wic-short"
ln -s "$w/wic-short" "$w/wic-short.lnk"
mkdisk "$w/short" "boot root tee-data"
refused "a symlink to a WIC cut short of its partitions" "$w/short" "$w/wic-short.lnk"
mkwic "$w/wic-shift" shift
ln -s "$w/wic-shift" "$w/wic-shift.lnk"
mkdisk "$w/shiftlink" "boot root tee-data"
refused "a symlink to a WIC laid out one LBA differently" "$w/shiftlink" "$w/wic-shift.lnk"
mkdisk "$w/tee0" "boot root tee-data" "" tee-first0
refused "a target tee-data entry starting at LBA 0" "$w/tee0" "$w/wic"
mkwic "$w/wic-tee0" tee-first0
mkdisk "$w/tee0b" "boot root tee-data"
refused "a WIC tee-data entry starting at LBA 0" "$w/tee0b" "$w/wic-tee0"
mkdisk "$w/teeboot" "boot root tee-data" "" tee-overlap-boot
refused "a target tee-data entry overlapping boot" "$w/teeboot" "$w/wic"
mkwic "$w/wic-teeboot" tee-overlap-boot
mkdisk "$w/teebootb" "boot root tee-data"
refused "a WIC tee-data entry overlapping boot" "$w/teebootb" "$w/wic-teeboot"
mkdisk "$w/crc" "boot root tee-data" "" badcrc
refused "a target with a corrupted header CRC" "$w/crc" "$w/wic"
mkwic "$w/wic-crc" badcrc
mkdisk "$w/crcb" "boot root tee-data"
refused "a WIC with a corrupted header CRC" "$w/crcb" "$w/wic-crc"
mkdisk "$w/shift" "boot root tee-data" "" shift
refused "a target whose layout differs from the WIC's by one LBA" "$w/shift" "$w/wic"
# GPT names are data from the disk: none may inject offsets or sizes (security P1).
mkdisk "$w/inj1" "boot root tee-data" "boot|root|tee-data 0 1048576"
refused "a partition named 'tee-data 0 1048576'" "$w/inj1" "$w/wic"
mkdisk "$w/inj2" "boot root tee-data" $'boot|root|tee-data\n0 1048576'
refused "a partition name with a newline" "$w/inj2" "$w/wic"
mkdisk "$w/inj3" "boot root tee-data" $'boot|root|tee-data\t'
refused "a partition name with a tab" "$w/inj3" "$w/wic"
mkdisk "$w/wic-inj" "boot root tee-data" "boot|root|tee-data 0 1048576"
mkdisk "$w/inj4" "boot root tee-data" "boot|root|tee-data 0 1048576"
refused "a WIC with a partition named 'tee-data 0 1048576'" "$w/inj4" "$w/wic-inj"
mkdisk "$w/dup" "boot root tee-data extra" "boot|root|tee-data|tee-data"
refused "a duplicate tee-data partition" "$w/dup" "$w/wic"
mkdisk "$w/duproot" "boot root tee-data extra" "boot|root|tee-data|root"
refused "a duplicate root partition" "$w/duproot" "$w/wic"
head -c $((4 * MiB)) /dev/zero >"$w/nogpt"
refused "no partition table" "$w/nogpt" "$w/wic"
mkdisk "$w/same" "boot root tee-data"
refused "the target and the WIC are the same file" "$w/same" "$w/same"
mkdisk "$w/stubless" "boot root tee-data"
expect "refused without mkfs.ext4 on PATH" test "$(
	r=0
	mkdir -p "$w/empty"
	PATH="$w/empty" "$BASH" "$flash" "$w/stubless" "$w/wic" >/dev/null 2>&1 || r=$?
	echo "$r"
)" -ne 0
# A device node is never a regular-file target; the script refuses before any write.
expect "refused: a character device is not a disk" test "$(run /dev/null "$w/wic")" -ne 0

# The script looks for the names the wks gives.
wkstext=$(<"$wks")
expect "the wks names the root partition" test "${wkstext#*--part-name root}" != "$wkstext"
expect "the wks names the tee-data partition" test "${wkstext#*--part-name tee-data}" != "$wkstext"

# A target (or a partition of it) that is a mount source is refused, nothing written.
mkdisk "$w/busy" "boot root tee-data"
mkwic "$w/wic-busy" "" "boot root tee-data"
for src in "$w/busy" "$w/busy2" "$w/busyp3"; do
	printf '36 1 8:3 / /data rw - ext4 %s rw\n' "$src" >"$w/mi"
	MI=$w/mi refused "a mount whose source is $(basename "$src") of the target" "$w/busy" "$w/wic-busy"
done
printf '36 1 8:3 / /data rw - ext4 %s rw\n' "$w/other" >"$w/mi"
expect "an unrelated mount does not stop the flash" test "$(MI=$w/mi run "$w/busy" "$w/wic-busy")" -eq 0
expect "an unreadable mountinfo refuses" test "$(MI=$w/nonexistent run "$w/busy" "$w/wic-busy")" -ne 0

# A regular-file target that backs a loop device is refused, nothing written.
mkdir -p "$w/sys/block/loop0/loop" "$w/sys/block/loop1/loop"
printf '%s\n' "$w/busy" >"$w/sys/block/loop0/loop/backing_file"
printf '%s\n' "$w/elsewhere.img" >"$w/sys/block/loop1/loop/backing_file"
FLASH_ROOTFS_SYSFS=$w/sys refused "target image backs loop0" "$w/busy" "$w/wic-busy"
printf '%s\n' "$w/elsewhere.img" >"$w/sys/block/loop0/loop/backing_file"
expect "an unrelated loop backing file does not stop the flash" \
	test "$(FLASH_ROOTFS_SYSFS=$w/sys run "$w/busy" "$w/wic-busy")" -eq 0

finish
