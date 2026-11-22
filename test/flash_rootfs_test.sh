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
	python3 -I - "$1" "$2" "${3-}" <<'PY'
import struct, sys, zlib

path, names = sys.argv[1], sys.argv[2].split()
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
disk[ss:ss + 92] = hdr
disk[2 * ss:2 * ss + len(entries)] = entries
open(path, "wb").write(disk)
PY
}

# region FILE OFFSET-MiB SIZE-MiB OUT: copy a region of a disk to OUT.
region() { dd if="$1" of="$4" bs=$MiB skip="$2" count="$3" status=none; }

# run DISK IMAGE: run the script, print its exit status (output is not shown).
run() {
	local r=0
	MKFS_TARGET=$1 PATH="$w/bin:$PATH" bash "$flash" "$1" "$2" >"$w/out" 2>&1 || r=$?
	echo "$r"
}

head -c $((3 * MiB)) /dev/urandom >"$w/rootfs.ext4"

# A full disk: the rootfs is written, tee-data erased, the rest untouched.
mkdisk "$w/disk" "boot root tee-data"
expect "the script exits 0 on a disk with root and tee-data" test "$(run "$w/disk" "$w/rootfs.ext4")" -eq 0
region "$w/disk" 2 3 "$w/got-root"
expect "the rootfs bytes are in the root partition" cmp -s "$w/got-root" "$w/rootfs.ext4"
region "$w/disk" 5 1 "$w/got-tail"
expect "the rest of the root partition is as it was" test "$(tr -d '\335' <"$w/got-tail" | wc -c)" -eq 0
region "$w/disk" 6 4 "$w/got-data"
{ printf 'MKFS-STUB'; head -c $((4 * MiB - 9)) /dev/zero; } >"$w/want-data"
expect "tee-data is zeroed and its file system made again" cmp -s "$w/got-data" "$w/want-data"
region "$w/disk" 1 1 "$w/got-boot"
expect "the boot partition is untouched" test "$(tr -d '\273' <"$w/got-boot" | wc -c)" -eq 0

# Refusals write nothing.
refused() { # NAME DISK IMAGE: a non-zero exit and an unchanged disk
	local sum
	sum=$(cksum <"$2")
	expect "refused: $1" test "$(run "$2" "$3")" -ne 0
	expect "refused, nothing written: $1" test "$(cksum <"$2")" = "$sum"
}
mkdisk "$w/nodata" "boot root"
refused "no tee-data partition" "$w/nodata" "$w/rootfs.ext4"
mkdisk "$w/noroot" "boot tee-data"
refused "no root partition" "$w/noroot" "$w/rootfs.ext4"
head -c $((5 * MiB)) /dev/zero >"$w/big.ext4"
mkdisk "$w/fit" "boot root tee-data"
refused "the image does not fit the root partition" "$w/fit" "$w/big.ext4"
# GPT names are data from the disk: none may inject offsets or sizes (security P1).
mkdisk "$w/inj1" "boot root tee-data" "boot|root|tee-data 0 1048576"
refused "a partition named 'tee-data 0 1048576'" "$w/inj1" "$w/rootfs.ext4"
mkdisk "$w/inj2" "boot root tee-data" $'boot|root|tee-data\n0 1048576'
refused "a partition name with a newline" "$w/inj2" "$w/rootfs.ext4"
mkdisk "$w/inj3" "boot root tee-data" $'boot|root|tee-data\t'
refused "a partition name with a tab" "$w/inj3" "$w/rootfs.ext4"
mkdisk "$w/dup" "boot root tee-data extra" "boot|root|tee-data|tee-data"
refused "a duplicate tee-data partition" "$w/dup" "$w/rootfs.ext4"
mkdisk "$w/duproot" "boot root tee-data extra" "boot|root|tee-data|root"
refused "a duplicate root partition" "$w/duproot" "$w/rootfs.ext4"
head -c $((4 * MiB)) /dev/zero >"$w/nogpt"
refused "no partition table" "$w/nogpt" "$w/rootfs.ext4"
mkdisk "$w/stubless" "boot root tee-data"
expect "refused without mkfs.ext4 on PATH" test "$(
	r=0
	mkdir -p "$w/empty"
	PATH="$w/empty" "$BASH" "$flash" "$w/stubless" "$w/rootfs.ext4" >/dev/null 2>&1 || r=$?
	echo "$r"
)" -ne 0
# A device node is never a regular-file target; the script refuses before any write.
expect "refused: a character device is not a disk" test "$(run /dev/null "$w/rootfs.ext4")" -ne 0

# The script looks for the names the wks gives.
wkstext=$(<"$wks")
expect "the wks names the root partition" test "${wkstext#*--part-name root}" != "$wkstext"
expect "the wks names the tee-data partition" test "${wkstext#*--part-name tee-data}" != "$wkstext"

finish
