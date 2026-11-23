#!/usr/bin/env bash
# Offline checks of the firmware TPM image configuration (proposed, pending owner
# approval, SPEC row ftpm, issue #140): the revision pins match
# docs/secure-world/build.md, NV is on REE FS with RPMB off, and the debug image
# alone carries tpm2-tools.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

odir=$ROOT/platform-image/recipes-security/optee
ftpm_bb=$odir/optee-ftpm_4.10.0.bb
os_app=$odir/optee-os_%.bbappend
kit_app=$odir/optee-os-tadevkit_%.bbappend
flags=$odir/optee-ftpm-flags.inc
bsp=$ROOT/secure-world/bsp.lock
swdoc=$ROOT/docs/secure-world/build.md
img=$ROOT/platform-image/recipes-core/images/trusted-imx95-image.bb
dbg=$ROOT/platform-image/recipes-core/images/trusted-imx95-image-debug.bb
doc=$ROOT/docs/ftpm/build.md

# has FILE STRING: FILE contains STRING (fixed text, comments included).
has() {
	local t
	t=$(<"$1")
	[[ $t == *"$2"* ]]
}
# nc FILE REGEX: a non-comment line of FILE matches REGEX (extended).
nc() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '' | '#'*) continue ;; esac
		[[ $l =~ $2 ]] && return 0
	done <"$1"
	return 1
}
# ncstr FILE STRING: a non-comment line of FILE contains STRING.
ncstr() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '' | '#'*) continue ;; esac
		[[ $l == *"$2"* ]] && return 0
	done <"$1"
	return 1
}
# lockval NAME: the value of NAME in secure-world/bsp.lock.
lockval() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in "$1="*) printf '%s\n' "${l#*=}"; return 0 ;; esac
	done <"$bsp"
	return 1
}
# none STRING FILE...: no FILE contains STRING.
none() {
	local s=$1 f
	shift
	for f in "$@"; do
		! has "$f" "$s" || return 1
	done
}
# tree_none STRING DIR: no tracked file under DIR contains STRING.
tree_none() {
	local f
	while IFS= read -r f; do
		! has "$ROOT/$f" "$1" || return 1
	done < <(git -C "$ROOT" ls-files -co --exclude-standard "$2")
}

for f in "$ftpm_bb" "$os_app" "$kit_app" "$flags"; do
	expect "exists: ${f#"$ROOT"/}" test -s "$f"
done

ftpm_rev=$(lockval FTPM_COMMIT)
mstpm_rev=$(lockval MSTPM_COMMIT)
expect "optee-ftpm pins optee_ftpm at the bsp.lock commit" nc "$ftpm_bb" "^SRCREV_ftpm = \"$ftpm_rev\""
expect "optee-ftpm pins ms-tpm-20-ref at the bsp.lock commit" nc "$ftpm_bb" "^SRCREV_mstpm = \"$mstpm_rev\""
expect "docs/secure-world/build.md names the same optee_ftpm commit" has "$swdoc" "$ftpm_rev"
expect "docs/secure-world/build.md names the same ms-tpm-20-ref commit" has "$swdoc" "$mstpm_rev"
expect "no floating revision (no AUTOREV)" none AUTOREV "$ftpm_bb"

expect "optee-os: early TAs on" ncstr "$os_app" 'CFG_EARLY_TA=y'
expect "optee-os: EARLY_TA_PATHS names the fTPM TA UUID" nc "$os_app" 'EARLY_TA_PATHS=.*\$\{FTPM_TA_UUID\}'
expect "the fTPM TA UUID is the one the secure-world doc gives" ncstr "$os_app" 'FTPM_TA_UUID = "bc50d971-d4c9-42c4-82cb-343fb7f37896"'
expect "optee-os: the PKCS#11 TA is an in-tree early TA (as secure-world-build.sh)" ncstr "$os_app" 'CFG_IN_TREE_EARLY_TAS=pkcs11/fd02c9da-306c-48c7-a49c-bbd827ae86ee'

# tee-supplicant and the persistent NV (SPEC row ftpm, #140).
nv=$odir/trusted-imx95-tee-nv_1.0.bb
nvf=$odir/trusted-imx95-tee-nv
wks=$ROOT/platform-image/files/wic/trusted-imx95.wks

expect "image installs the OP-TEE client (tee-supplicant)" nc "$img" 'IMAGE_INSTALL:append = ".* optee-client( |")'
expect "image installs the NV recipe" nc "$img" 'IMAGE_INSTALL:append = ".* trusted-imx95-tee-nv( |")'
expect "the NV recipe enables tee-supplicant at boot" ncstr "$nv" 'basic.target.wants/tee-supplicant@teepriv0.service'
expect "the supplicant stores under /data/tee" ncstr "$nvf/tee-supplicant" '--fs-parent-path=/data/tee'
# /data is the tee-data partition of the root's own disk, never a global by-partlabel path
# (Codex P1: with an eMMC and a microSD image that can mount the other medium's NV).
mnt=$nvf/tee-data-mount
expect "no data.mount unit (it named a global partlabel)" test ! -e "$nvf/data.mount"
expect "no by-partlabel path in the NV files" none 'by-partlabel' "$nvf/tee-data-mount" "$nvf/tee-data-mount.service" "$nvf/tee-nv-wipe.service" "$nvf/10-nv.conf"
expect "the mount service runs the resolver" ncstr "$nvf/tee-data-mount.service" 'ExecStart=/usr/sbin/tee-data-mount'
expect "the mount service has no default dependencies" ncstr "$nvf/tee-data-mount.service" 'DefaultDependencies=no'
expect "the mount service is before the wipe" ncstr "$nvf/tee-data-mount.service" 'Before=tee-nv-wipe.service'
expect "the wipe unit requires the mount service" ncstr "$nvf/tee-nv-wipe.service" 'Requires=tee-data-mount.service'
expect "tee-supplicant requires the mount service" ncstr "$nvf/10-nv.conf" 'Requires=tee-data-mount.service tee-nv-wipe.service'
# The resolver, on a fake sysfs and mountinfo with two disks that each carry tee-data.
fk=$(mktemp -d)
mkdir -p "$fk/dev" "$fk/sys/dev/block"
# fakedisk DISK MAJOR: a disk with partitions p1 boot, p2 root, p3 tee-data (names via PARTNAME)
fakedisk() {
	local d=$fk/sys/devices/$1 i n
	mkdir -p "$d"
	for i in 1 2 3; do
		case $i in 1) n=boot ;; 2) n=root ;; 3) n=tee-data ;; esac
		mkdir -p "$d/$1p$i"
		: >"$d/$1p$i/partition"
		printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%sp%s\nPARTNAME=%s\n' "$2" "$i" "$1" "$i" "$n" >"$d/$1p$i/uevent"
		ln -sfn "../../devices/$1/$1p$i" "$fk/sys/dev/block/$2:$i"
		: >"$fk/dev/$1p$i"
	done
}
fakedisk mmcblk0 179
fakedisk mmcblk1 180
printf '1 0 0:1 / /proc rw - proc proc rw\n20 1 179:2 / / ro - ext4 /dev/root ro\n' >"$fk/mi-emmc"
printf '20 1 180:2 / / ro - ext4 /dev/root ro\n' >"$fk/mi-sd"
printf '#!/bin/sh\necho "$@" >"%s/mounted"\n' "$fk" >"$fk/mountstub"
chmod +x "$fk/mountstub"
resolve() { # MOUNTINFO: prints the exit status; the stub records its arguments
	local r=0
	rm -f "$fk/mounted"
	TEE_NV_MOUNTINFO=$1 TEE_NV_SYS=$fk/sys TEE_NV_DEV=$fk/dev TEE_NV_DATA=/data TEE_NV_MOUNT=$fk/mountstub sh "$mnt" 2>/dev/null || r=$?
	echo "$r"
}
expect "resolver: root on the eMMC mounts the eMMC's tee-data" test "$(resolve "$fk/mi-emmc")$(<"$fk/mounted")" = "0-t ext4 -o rw,nosuid,nodev,noexec $fk/dev/mmcblk0p3 /data"
expect "resolver: root on the microSD mounts the microSD's tee-data" test "$(resolve "$fk/mi-sd")$(<"$fk/mounted")" = "0-t ext4 -o rw,nosuid,nodev,noexec $fk/dev/mmcblk1p3 /data"
# Ambiguous: a second tee-data on the root's disk.
mkdir -p "$fk/sys/devices/mmcblk1/mmcblk1p4"
: >"$fk/sys/devices/mmcblk1/mmcblk1p4/partition"
printf 'DEVNAME=mmcblk1p4\nPARTNAME=tee-data\n' >"$fk/sys/devices/mmcblk1/mmcblk1p4/uevent"
: >"$fk/dev/mmcblk1p4"
expect "resolver: two tee-data on the root's disk is refused" test "$(resolve "$fk/mi-sd")" -ne 0
expect "resolver: nothing was mounted when ambiguous" test ! -e "$fk/mounted"
expect "resolver: the other disk is still resolved on its own" test "$(resolve "$fk/mi-emmc")" -eq 0
# Missing: rename the root disk's tee-data away; the other disk's tee-data must not be used.
printf 'DEVNAME=mmcblk0p3\nPARTNAME=other\n' >"$fk/sys/devices/mmcblk0/mmcblk0p3/uevent"
expect "resolver: no tee-data on the root's disk is refused" test "$(resolve "$fk/mi-emmc")" -ne 0
expect "resolver: nothing was mounted when missing" test ! -e "$fk/mounted"
printf '1 0 0:1 / /proc rw - proc proc rw\n' >"$fk/mi-none"
expect "resolver: no mount on / is refused" test "$(resolve "$fk/mi-none")" -ne 0
printf 'DEVNAME=mmcblk0p3\nPARTNAME=tee-data x\n' >"$fk/sys/devices/mmcblk0/mmcblk0p3/uevent"
expect "resolver: a name that is not exactly tee-data is refused" test "$(resolve "$fk/mi-emmc")" -ne 0
expect "the wks has a writable tee-data partition" ncstr "$wks" '--part-name tee-data'
expect "the wks tee-data line writes no fstab entry (only tee-data-mount.service mounts /data)" nc "$wks" '^part /data .*--part-name tee-data .*--no-fstab-update'
expect "the image uses that wks" ncstr "$img" 'WKS_FILE = "trusted-imx95.wks"'
expect "the root file system stays read-only" ncstr "$img" 'IMAGE_FEATURES += "read-only-rootfs"'
expect "the wks keeps the BSP boot partition (kernel, DTBs)" ncstr "$wks" 'part /boot --source bootimg-partition'
expect "the wks has no raw boot-container entry" none 'rawcopy' "$wks"
expect "the NV recipe installs the /data mountpoint" ncstr "$nv" 'D}/data'
expect "the NV recipe packages /data" ncstr "$nv" '+= "/data '
# The NV wipe is coupled to the rootfs identity (Codex P1): run the script on a temp tree.
wipe=$nvf/tee-nv-wipe
unit=$nvf/tee-nv-wipe.service
wt=$(mktemp -d)
trap 'rm -rf "$wt" "$fk"' EXIT
mkdir -p "$wt/data/tee/sub"
printf 'seed\n' >"$wt/data/tee/sub/obj"
printf 'id-A\n' >"$wt/rootfs-id"
# A fixture root partition: a regular file with an ext4 superblock (magic, block size, 4096 bytes);
# no loop device, no real block device. The 4 MiB file only stands in for the tests of the token
# logic; the layout the image really produces is tested further down, from the wks itself.
put32() { printf '%b' "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($3 & 255)) $((($3 >> 8) & 255)) $((($3 >> 16) & 255)) $((($3 >> 24) & 255)))" |
	dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
mkroot() { # mkroot FILE LOG_BLOCK_SIZE: a fresh "root partition written from an image"
	rm -f "$1"
	truncate -s 4M "$1"
	printf '\123\357' | dd of="$1" bs=1 seek=1080 conv=notrunc 2>/dev/null
	put32 "$1" 1028 1024
	put32 "$1" 1048 "$2"
	sh "$ROOT/platform-image/files/root-marker.sh" write "$1" 0 build-A # the image's unbound marker
}
rootdev=$wt/rootdev
mkroot "$rootdev" 2
wipe_run() { # prints the exit status of the wipe script
	local r=0
	TEE_NV_DATA="$wt/data" TEE_NV_ROOTFS_ID="$wt/rootfs-id" TEE_NV_ROOTDEV="$rootdev" bash "$wipe" 2>/dev/null || r=$?
	echo "$r"
}
tokat() { head -c 512 "$rootdev" | tr -d '\000'; }
expect "wipe: a missing id wipes" test "$(wipe_run)" -eq 0
expect "wipe: the old object is gone" test ! -e "$wt/data/tee/sub/obj"
expect "wipe: the new id is recorded" test "$(<"$wt/data/tee-rootfs-id")" = id-A
printf 'keep\n' >"$wt/data/tee/obj"
expect "wipe: the same id keeps the files" test "$(wipe_run)$(<"$wt/data/tee/obj")" = 0keep
printf 'id-B\n' >"$wt/rootfs-id"
expect "wipe: a different id wipes" test "$(wipe_run)" -eq 0
expect "wipe: the different id removed the files" test ! -e "$wt/data/tee/obj"
expect "wipe: the different id is recorded" test "$(<"$wt/data/tee-rootfs-id")" = id-B
printf 'keep\n' >"$wt/data/tee/obj"
rm "$wt/rootfs-id"
expect "wipe: fails closed without a rootfs id" test "$(wipe_run)" -ne 0
expect "wipe: it kept the files when it failed" test "$(<"$wt/data/tee/obj")" = keep
# A saved marker that exists but cannot be read must not wipe: exit non-zero, files intact.
printf 'id-B\n' >"$wt/rootfs-id"
rm -f "$wt/data/tee-rootfs-id"
mkdir "$wt/data/tee-rootfs-id"
expect "wipe: an unreadable marker (a directory) fails" test "$(wipe_run)" -ne 0
expect "wipe: an unreadable marker leaves the files" test "$(<"$wt/data/tee/obj")" = keep
rmdir "$wt/data/tee-rootfs-id"
printf 'id-B\n' >"$wt/data/tee-rootfs-id"
if [ "$(id -u)" -ne 0 ]; then
	chmod 000 "$wt/data/tee-rootfs-id"
	expect "wipe: an unreadable marker (mode 000) fails" test "$(wipe_run)" -ne 0
	expect "wipe: a mode 000 marker leaves the files" test "$(<"$wt/data/tee/obj")" = keep
	chmod 600 "$wt/data/tee-rootfs-id"
fi
# The root binding token (Codex P1, same-image rewrite): fixture partition files only.
rm -rf "$wt/data/tee" "$wt/data/tee-rootfs-id" "$wt/data/tee-root-token"
mkdir -p "$wt/data/tee"
printf 'id-A\n' >"$wt/rootfs-id"
printf 'seed\n' >"$wt/data/tee/obj"
expect "token: first boot runs ok" test "$(wipe_run)" -eq 0
expect "token: first boot wipes the NV of unknown origin" test ! -e "$wt/data/tee/obj"
expect "token: first boot writes the token to the root partition" test "$(tokat | cut -c1-9)" = "TEEBIND1 "
expect "token: the data side holds the same token" test "$(tokat)" = "$(<"$wt/data/tee-root-token")"
t1=$(tokat)
printf 'seed\n' >"$wt/data/tee/obj"
expect "token: a reboot with no rewrite runs ok" test "$(wipe_run)" -eq 0
expect "token: a reboot with no rewrite keeps the NV" test "$(<"$wt/data/tee/obj")" = seed
expect "token: a reboot keeps the token" test "$(tokat)" = "$t1"
# An image write that replaces only the file-system bytes (here the first 1 MiB of the partition) and
# leaves the rest of the partition untouched, the very same image (same content id).
mkroot "$wt/image" 2
printf 'T' | dd of="$rootdev" bs=1 seek=$((4 * 1024 * 1024 - 1)) conv=notrunc 2>/dev/null
dd if="$wt/image" of="$rootdev" bs=4096 count=256 conv=notrunc 2>/dev/null
expect "token: a file-system-only rewrite left the partition tail alone" test "$(tail -c 1 "$rootdev")" = T
expect "token: a file-system-only identical-image rewrite runs ok" test "$(wipe_run)" -eq 0
expect "token: a file-system-only identical-image rewrite wipes the NV" test ! -e "$wt/data/tee/obj"
expect "token: it writes a fresh token" test "$(tokat)" != "$t1" -a -n "$(tokat)"
printf 'seed\n' >"$wt/data/tee/obj"
# A sparse rewrite of the same image (GNU dd conv=sparse skips all-zero blocks): the image's token
# sector is the nonzero unbound marker, so the old token is replaced. (A zero sector would be skipped.)
printf 'seed\n' >"$wt/data/tee/obj"
t2=$(tokat)
expect "sparse: the NV is bound before the rewrite" test "$(wipe_run)$(<"$wt/data/tee/obj")" = 0seed
cp "$wt/image" "$wt/image.zero"
dd if=/dev/zero of="$wt/image.zero" bs=512 count=1 conv=notrunc 2>/dev/null
dd if="$wt/image.zero" of="$rootdev" bs=512 count=2048 conv=sparse,notrunc 2>/dev/null
expect "sparse: control, a zero token sector is skipped by a sparse writer (the old token stays)" test "$(tokat)" = "$t2"
dd if="$wt/image" of="$rootdev" bs=512 count=2048 conv=sparse,notrunc 2>/dev/null
expect "sparse: the image's marker replaced the token" test "$(tokat | cut -c1-10)" = "TEEUNBND1 "
expect "sparse: the same image rewritten sparse runs ok" test "$(wipe_run)" -eq 0
expect "sparse: the same image rewritten sparse wipes the NV" test ! -e "$wt/data/tee/obj"
expect "sparse: a fresh bound token follows" test "$(tokat | cut -c1-9)" = "TEEBIND1 "
rm -f "$wt/image.zero"
# The marker the image build writes (files/root-marker.sh): 512 bytes, no zero byte, names the build.
rm_sh=$ROOT/platform-image/files/root-marker.sh
sh "$rm_sh" sector build-A >"$wt/marker"
expect "marker: the sector is 512 bytes" test "$(stat -c %s "$wt/marker")" -eq 512
expect "marker: no byte of the sector is zero (no sparse writer can skip it)" test "$(tr -d '\000' <"$wt/marker" | wc -c)" -eq 512
expect "marker: it starts with the unbound magic and the build id" test "$(head -c 20 "$wt/marker")" = "TEEUNBND1 build-A UU"
expect "marker: a different id gives a different sector" test "$(sh "$rm_sh" sector build-B | cmp -s - "$wt/marker"; echo $?)" -ne 0
expect "marker: an id with a space is refused" test "$(sh "$rm_sh" sector 'a b' >/dev/null 2>&1; echo $?)" -ne 0
expect "marker: an offset that is not a multiple of 512 is refused" test "$(sh "$rm_sh" write "$wt/marker" 100 x >/dev/null 2>&1; echo $?)" -ne 0
printf '%s\n' 'label: gpt' 'sector-size: 512' '/dev/x1 : start=        2048, size=      524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="boot"' '/dev/x2 : start=      526336, size=     2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"' >"$wt/dump"
expect "marker: the root partition's byte offset is read from an sfdisk dump" test "$(sh "$rm_sh" start <"$wt/dump")" -eq $((526336 * 512))
expect "the image build registers the marker step as a postfunc of the wic task" ncstr "$img" 'do_image_wic[postfuncs] += "trusted_imx95_mark_root"'
expect "marker: write refuses a file that does not exist (dd would create one)" test "$(sh "$rm_sh" write "$wt/no-such-file" 0 x >/dev/null 2>&1; echo $?)" -ne 0
expect "marker: write left no file behind" test ! -e "$wt/no-such-file"

# Behavioural test of the image's post-step and of root-marker.sh's wic mode, on synthetic build
# artifacts in scratch directories: plain files, dd conv=notrunc, no loop device, no bitbake. The
# hook's shell body is cut out of the .bb by its function name and run with stubbed bitbake variables.
# IMAGE_FSTYPES: the image adds only "wic" (machine defaults are not readable without a build), so the
# variants are .wic, .wic.gz (a compressed variant, in case a build adds one) and a .wic.bmap.
# The order is the one the image class gives the post-step: it is a postfunc of do_image_wic, so it
# runs inside that task, before any compression or bmap conversion, which then run on its output;
# do_image_complete copies the result to the deploy directory. UNBUILT: that order is read from the
# postfunc registration, not observed in a build.
chk=$ROOT/scripts/platform-image-check-root-marker.sh
hookfn=trusted_imx95_mark_root
expect "the hook function is in the image recipe" has "$img" "$hookfn () {"
# The wks geometry: --fixed-size (MiB) and --align (KiB) of each part line, in order.
align=
sizes=()
while IFS= read -r l; do
	case $l in 'part '*)
		[[ $l =~ --align\ ([0-9]+) ]] && align=${BASH_REMATCH[1]}
		[[ $l =~ --fixed-size\ ([0-9]+) ]] && sizes+=("${BASH_REMATCH[1]}")
		;;
	esac
done <"$wks"
expect "wks: three partitions with fixed sizes and an alignment" test "${#sizes[@]}" -eq 3 -a -n "$align"
mib=$((1024 * 1024))
pos=$((align * 1024))
starts=()
for s in "${sizes[@]}"; do
	pos=$(((pos + align * 1024 - 1) / (align * 1024) * (align * 1024)))
	starts+=("$pos")
	pos=$((pos + s * mib))
done
imgsize=$((pos + mib))
rootoff=${starts[1]}
expect "wks: the root partition starts on a 4096-byte block" test $((rootoff % 4096)) -eq 0
printf '%s\n' 'label: gpt' 'sector-size: 512' \
	"/dev/x1 : start=$((starts[0] / 512)), size=$((sizes[0] * 2048)), name=\"boot\"" \
	"/dev/x2 : start=$((starts[1] / 512)), size=$((sizes[1] * 2048)), name=\"root\"" \
	"/dev/x3 : start=$((starts[2] / 512)), size=$((sizes[2] * 2048)), name=\"tee-data\"" >"$wt/geom-dump"
cat >"$wt/genbmap.py" <<'PY'
import hashlib, sys
p, bs = sys.argv[1], 4096
ranges, i, z = [], 0, bytes(4096)
with open(p, "rb") as f:
    while True:
        buf = f.read(bs * 256)
        if not buf:
            break
        for o in range(0, len(buf), bs):
            blk = buf[o:o + bs]
            if blk != z[:len(blk)]:
                if ranges and ranges[-1][1] == i - 1:
                    ranges[-1][1] = i
                else:
                    ranges.append([i, i])
            i += 1
rl = []
with open(p, "rb") as f:
    for a, b in ranges:
        f.seek(a * bs)
        d = f.read((b - a + 1) * bs)
        rl.append('    <Range chksum="%s"> %d-%d </Range>' % (hashlib.sha256(d).hexdigest(), a, b))
mapped = sum(b - a + 1 for a, b in ranges)
head = ['<?xml version="1.0" ?>', '<bmap version="2.0">', '  <ImageSize> %d </ImageSize>' % (i * bs),
        '  <BlockSize> %d </BlockSize>' % bs, '  <BlocksCount> %d </BlocksCount>' % i,
        '  <MappedBlocksCount> %d </MappedBlocksCount>' % mapped, '  <ChecksumType> sha256 </ChecksumType>']
fc = "<BmapFileChecksum> %s </BmapFileChecksum>"
body = ['  <BlockMap>'] + rl + ['  </BlockMap>', '</bmap>']
text = "\n".join(head + ["  " + fc % ("0" * 64)] + body) + "\n"
real = hashlib.sha256(text.encode()).hexdigest()
sys.stdout.write(text.replace(fc % ("0" * 64), fc % real))
PY
# mkwic FILE SUPERBLOCK: a sparse image with the wks geometry; GPT header, boot and (SUPERBLOCK=1)
# an ext4 superblock's magic, which lives in the root's block 0, so that block is mapped before the marker.
mkwic() {
	truncate -s "$imgsize" "$1"
	printf 'EFI PART' | dd of="$1" bs=1 seek=512 conv=notrunc 2>/dev/null
	printf 'boot' | dd of="$1" bs=1 seek="${starts[0]}" conv=notrunc 2>/dev/null
	printf 'data' | dd of="$1" bs=1 seek="${starts[2]}" conv=notrunc 2>/dev/null
	if [ "$2" = 1 ]; then
		printf '\123\357' | dd of="$1" bs=1 seek=$((rootoff + 1080)) conv=notrunc 2>/dev/null
	fi
}
# mktree DIR [SED-SCRIPT-FOR-BB [SED-SCRIPT-FOR-ROOT-MARKER]]: a copy of the recipe and its script.
mktree() {
	mkdir -p "$1/platform-image/recipes-core/images" "$1/platform-image/files"
	sed "${2:-}" "$img" >"$1/platform-image/recipes-core/images/trusted-imx95-image.bb"
	sed "${3:-}" "$ROOT/platform-image/files/root-marker.sh" >"$1/platform-image/files/root-marker.sh"
}
# scen NAME ORDER TREE SUPERBLOCK: one synthetic build. ORDER is the sequence of steps run:
# h = the hook (extracted from TREE's recipe), g = gzip of the wic, b = bmap of the wic.
# Sets hook_rc and chk_rc; the artifacts are in $wt/NAME/deploy.
scen() {
	local d=$wt/$1 order=$2 tree=$3 st n=trusted-imx95-image-frdm-imx95-pro.rootfs-20250101 l body=0 w
	rm -rf "$d"
	mkdir -p "$d/imgdeploy" "$d/deploy" "$d/bin" "$d/rootfs/etc"
	printf 'build-A\n' >"$d/rootfs/etc/trusted-imx95-rootfs-id"
	cp "$wt/geom-dump" "$d/dump"
	# a stand-in for sfdisk (absent here): it dumps the geometry, and fails on a file that is not there
	# shellcheck disable=SC2016 # the script's own $1 and $2
	printf '#!/bin/sh\n[ "$1" = -d ] && [ -f "$2" ] && cat "%s"\n' "$d/dump" >"$d/bin/sfdisk"
	chmod +x "$d/bin/sfdisk"
	: >"$d/hook.sh"
	while IFS= read -r l; do
		case $l in "$hookfn () {"*) body=1 ;; '}'*) body=0 ;; *) [ "$body" -eq 1 ] && printf '%s\n' "$l" >>"$d/hook.sh" ;; esac
	done <"$tree/platform-image/recipes-core/images/trusted-imx95-image.bb"
	w=$d/imgdeploy/$n.wic
	mkwic "$w" "$4"
	hook_rc=0
	for st in $(printf '%s' "$order" | tr ',' ' '); do
		case $st in
		h) env -i PATH="$d/bin:$PATH" THISDIR="$tree/platform-image/recipes-core/images" IMGDEPLOYDIR="$d/imgdeploy" \
			IMAGE_NAME="$n" IMAGE_ROOTFS="$d/rootfs" sysconfdir=/etc sh -e "$d/hook.sh" >"$d/hook.log" 2>&1 || hook_rc=$? ;;
		g) gzip -c "$w" >"$w.gz" ;;
		b) python3 -I "$wt/genbmap.py" "$w" >"$w.bmap" ;;
		esac
	done
	# do_image_complete: copy to the deploy directory, with the unversioned link names
	cp -a "$d/imgdeploy/." "$d/deploy/"
	for n in wic wic.gz wic.bmap; do
		[ -e "$d/deploy/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.$n" ] &&
			ln -s "trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.$n" "$d/deploy/trusted-imx95-image-frdm-imx95-pro.$n"
	done
	chk_rc=0
	PATH="$d/bin:$PATH" sh "$chk" "$d/deploy" >"$d/chk.log" 2>&1 || chk_rc=$?
	return 0
}
mktree "$wt/tree-good"
expect "scenario tree: the extracted recipe equals the real one" cmp -s "$img" "$wt/tree-good/platform-image/recipes-core/images/trusted-imx95-image.bb"
expect "scenario tree: the hook function body was cut out" test "$(grep -c . <(sed -n "/^$hookfn () {/,/^}/p" "$img"))" -gt 2

# The real order: hook, then gzip, then bmap.
scen good h,g,b "$wt/tree-good" 1
expect "hook: runs ok on the synthetic wic" test "$hook_rc" -eq 0
expect "good deploy: the wic, the gz and the bmap are there" test -f "$wt/good/deploy/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.wic" -a -f "$wt/good/deploy/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.wic.gz" -a -f "$wt/good/deploy/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.wic.bmap"
expect "good deploy: the checker passes" test "$chk_rc" -eq 0
sh "$rm_sh" sector build-A >"$wt/marker"
dw=$wt/good/deploy/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.wic
expect "good: the root sector of the plain wic is exactly the marker" test "$(dd if="$dw" bs=512 skip=$((rootoff / 512)) count=1 2>/dev/null | cmp -s - "$wt/marker"; echo $?)" -eq 0
gzip -dc "$dw.gz" | dd of="$wt/good/plain" bs=1M conv=sparse 2>/dev/null
expect "good: the root sector of the decompressed gz is exactly the marker" test "$(dd if="$wt/good/plain" bs=512 skip=$((rootoff / 512)) count=1 2>/dev/null | cmp -s - "$wt/marker"; echo $?)" -eq 0
expect "good: the symlinked variant is checked too" has "$wt/good/chk.log" 'trusted-imx95-image-frdm-imx95-pro.wic.gz: marker'
rm -f "$wt/good/plain"
expect "good: a bmap range covers the marker block" has "$wt/good/chk.log" 'OK ('
# The bmap's own file checksum: a copy of the good deploy with that field altered fails the checker.
cp -a "$wt/good/deploy" "$wt/bm-tamper"
sed -i 's|\(<BmapFileChecksum> \)[0-9a-f]|\1z|' "$wt/bm-tamper/trusted-imx95-image-frdm-imx95-pro.rootfs-20250101.wic.bmap"
expect "bmap: a bad file checksum fails the checker" test "$(PATH="$wt/good/bin:$PATH" sh "$chk" "$wt/bm-tamper" >"$wt/bm-tamper.log" 2>&1; echo $?)" -ne 0
expect "bmap: ... and the log names the file checksum" has "$wt/bm-tamper.log" 'file checksum'
rm -rf "$wt/bm-tamper"
expect "checker: a directory with no image fails" test "$(sh "$chk" "$wt/geom-none" >/dev/null 2>&1; echo $?)" -ne 0
mkdir "$wt/empty-deploy"
expect "checker: an empty deploy directory fails" test "$(sh "$chk" "$wt/empty-deploy" >/dev/null 2>&1; echo $?)" -ne 0

# Mutation 1: the hook names a file the wic task does not produce.
# shellcheck disable=SC2016 # sed scripts, the $ are literal
mktree "$wt/tree-m1" 's|\${IMAGE_NAME}\.wic |${IMAGE_NAME}.rootfs.wic |'
expect "mutation 1: the scratch recipe differs from the real one" test "$(cmp -s "$img" "$wt/tree-m1/platform-image/recipes-core/images/trusted-imx95-image.bb"; echo $?)" -ne 0
scen m1 h,g,b "$wt/tree-m1" 1
expect "mutation 1 (hook targets a nonexistent file): the hook fails" test "$hook_rc" -ne 0
expect "mutation 1: the checker fails" test "$chk_rc" -ne 0
expect "mutation 1: the checker says the root sector holds no marker" has "$wt/m1/chk.log" 'not 512 nonzero bytes'
# Mutation 2: wic mode writes nothing.
# shellcheck disable=SC2016 # a sed script, the $ are literal
mktree "$wt/tree-m2" '' 's|^\tput "\$2" "\$off" "\$3"$|\t:|'
expect "mutation 2: the scratch script differs from the real one" test "$(cmp -s "$rm_sh" "$wt/tree-m2/platform-image/files/root-marker.sh"; echo $?)" -ne 0
scen m2 h,g,b "$wt/tree-m2" 1
expect "mutation 2 (wic mode writes nothing): the hook itself exits ok" test "$hook_rc" -eq 0
expect "mutation 2: the checker fails" test "$chk_rc" -ne 0
expect "mutation 2: the checker says the root sector holds no marker" has "$wt/m2/chk.log" 'not 512 nonzero bytes'
# Mutation 3: the hook runs after the compression (the gz holds the old sector).
scen m3 g,h,b "$wt/tree-good" 1
expect "mutation 3 (hook after compression): the checker fails" test "$chk_rc" -ne 0
expect "mutation 3: it names the compressed variant" has "$wt/m3/chk.log" '.wic.gz: the root sector'
# Mutation 4: the hook runs after the bmap, and the root block was a hole when the bmap was made.
scen m4 b,h "$wt/tree-good" 0
expect "mutation 4 (hook after bmap, block unmapped): the checker fails" test "$chk_rc" -ne 0
expect "mutation 4: the bmap does not cover the marker" has "$wt/m4/chk.log" 'no mapped range covers the marker'
# Mutation 5: the same, with the block mapped (the superblock): the range checksum is stale.
scen m5 b,h "$wt/tree-good" 1
expect "mutation 5 (hook after bmap, block mapped): the checker fails" test "$chk_rc" -ne 0
expect "mutation 5: the range checksum does not match" has "$wt/m5/chk.log" 'does not match the image'
rm -rf "$wt"/good "$wt"/m[1-5] "$wt"/tree-* "$wt/empty-deploy" "$wt/genbmap.py"
mkroot "$rootdev" 2 # the whole partition rewritten from the very same image: same content id
expect "token: a full-partition identical rewrite runs ok" test "$(wipe_run)" -eq 0
expect "token: a full-partition identical rewrite wipes the NV" test ! -e "$wt/data/tee/obj"
printf 'seed\n' >"$wt/data/tee/obj"
printf 'id-C\n' >"$wt/rootfs-id"
expect "token: a different build runs ok" test "$(wipe_run)" -eq 0
expect "token: a different build wipes the NV" test ! -e "$wt/data/tee/obj"
printf 'seed\n' >"$wt/data/tee/obj"
r=0
TEE_NV_DATA="$wt/data" TEE_NV_ROOTFS_ID="$wt/rootfs-id" TEE_NV_ROOTDEV="$wt/no-such-device" bash "$wipe" 2>/dev/null || r=$?
expect "token: an unreadable token region fails closed (supplicant does not start)" test "$r" -ne 0
expect "token: an unreadable token region wipes the NV" test ! -e "$wt/data/tee/obj"
expect "token: an unreadable token region leaves no saved token" test ! -e "$wt/data/tee-root-token"
printf 'seed\n' >"$wt/data/tee/obj"
mkroot "$rootdev" 0 # 1 KiB blocks: block 0 is all zeros and a sparse copy may skip it
expect "token: a 1 KiB block size fails closed" test "$(wipe_run)" -ne 0
expect "token: ... and wipes the NV" test ! -e "$wt/data/tee/obj"
expect "token: ... and writes no token to the partition (the marker stays)" test "$(tokat | cut -c1-10)" = "TEEUNBND1 "
printf 'seed\n' >"$wt/data/tee/obj"
mkroot "$rootdev" 2
expect "token: a valid fixture runs ok again" test "$(wipe_run)" -eq 0
printf 'seed\n' >"$wt/data/tee/obj"
printf '\000\000' | dd of="$rootdev" bs=1 seek=1080 conv=notrunc 2>/dev/null
expect "token: a root partition with no ext4 magic fails closed (status)" test "$(wipe_run)" -ne 0
expect "token: ... and wipes the NV (no magic)" test ! -e "$wt/data/tee/obj"

# The layout the image really produces: size and mkfs options read from the wks itself, a sparse
# file system built with them (a regular file, no loop device), tee-nv-wipe run against it.
rsize=
ropts=
while IFS= read -r l; do
	case $l in 'part / '*)
		[[ $l =~ --fixed-size\ ([0-9]+)M ]] && rsize=${BASH_REMATCH[1]}
		[[ $l =~ --mkfs-extraopts\ \"([^\"]*)\" ]] && ropts=${BASH_REMATCH[1]}
		;;
	esac
done <"$wks"
expect "wks: the root partition has a fixed size in MiB" test -n "$rsize"
expect "wks: the root partition pins the block size to 4096" test "$ropts" = "-b 4096"
real=$wt/real-root
rm -f "$real"
truncate -s "${rsize:-1}M" "$real"
if mk=$(PATH="$PATH:/sbin:/usr/sbin" command -v mke2fs); then
	# wic fills the partition with the file system: the whole fixed size, the options from the wks.
	# shellcheck disable=SC2086 # the options are a word list from the wks
	"$mk" -t ext4 -F -q -E lazy_itable_init=1,lazy_journal_init=1 $ropts "$real" >/dev/null 2>&1 || echo "mke2fs failed" >&2
else
	echo "note: mke2fs is absent here; the fixture's superblock fields are written by hand"
	printf '\123\357' | dd of="$real" bs=1 seek=1080 conv=notrunc 2>/dev/null
	put32 "$real" 1028 $((rsize * 256))
	put32 "$real" 1048 2
fi
expect "real layout: the file system fills the partition" test "$(stat -c %s "$real")" -eq $((${rsize:-0} * 1024 * 1024))
rootdev_small=$rootdev
rootdev=$real
rm -rf "$wt/data/tee" "$wt/data/tee-rootfs-id" "$wt/data/tee-root-token"
mkdir -p "$wt/data/tee"
printf 'id-A\n' >"$wt/rootfs-id"
printf 'seed\n' >"$wt/data/tee/obj"
expect "real layout: a first boot runs ok (tee-supplicant would start)" test "$(wipe_run)" -eq 0
expect "real layout: a first boot writes the token" test "$(tokat | cut -c1-9)" = "TEEBIND1 "
printf 'seed\n' >"$wt/data/tee/obj"
expect "real layout: a reboot runs ok" test "$(wipe_run)" -eq 0
expect "real layout: a reboot keeps the NV" test "$(<"$wt/data/tee/obj")" = seed
# The same image rewritten over the first 8 MiB only (the rest of the partition left alone).
cp --sparse=always "$real" "$wt/image.real"
dd if=/dev/zero of="$wt/image.real" bs=512 count=1 conv=notrunc 2>/dev/null # the image holds zeros there
dd if="$wt/image.real" of="$real" bs=1M count=8 conv=notrunc 2>/dev/null
expect "real layout: a file-system-only rewrite runs ok" test "$(wipe_run)" -eq 0
expect "real layout: a file-system-only rewrite wipes the NV" test ! -e "$wt/data/tee/obj"
rootdev=$rootdev_small
rm -f "$real" "$wt/image.real"
expect "unit: Before tee-supplicant" ncstr "$unit" 'Before=tee-supplicant@teepriv0.service'
expect "unit: RequiredBy tee-supplicant" ncstr "$unit" 'RequiredBy=tee-supplicant@teepriv0.service'
expect "unit: runs after the /data mount service" ncstr "$unit" 'After=tee-data-mount.service'
expect "unit: oneshot" ncstr "$unit" 'Type=oneshot'
# The BSP supplicant is DefaultDependencies=no, Before=sysinit.target; default
# dependencies here would make an ordering cycle (Codex P1).
expect "unit: no default dependencies" ncstr "$unit" 'DefaultDependencies=no'
expect "unit: stopped before shutdown" ncstr "$unit" 'Conflicts=shutdown.target'
expect "unit: ordered before shutdown" ncstr "$unit" 'Before=shutdown.target'
expect "supplicant drop-in: hard dependency on the wipe" ncstr "$nvf/10-nv.conf" ' tee-nv-wipe.service'
expect "supplicant drop-in: Requires= names the wipe unit" nc "$nvf/10-nv.conf" '^Requires=.*tee-nv-wipe\.service'
expect "supplicant drop-in: ordered after the wipe" ncstr "$nvf/10-nv.conf" 'tee-nv-wipe.service'
expect "recipe: the supplicant requires the wipe unit" ncstr "$nv" 'tee-supplicant@teepriv0.service.requires'
expect "image writes the rootfs identity" ncstr "$img" 'ROOTFS_POSTPROCESS_COMMAND += "trusted_imx95_rootfs_id;"'
expect "the rootfs identity is random per build" ncstr "$ROOT/platform-image/files/rootfs-id.sh" '/dev/urandom'
expect "the image runs the identity script" ncstr "$img" 'rootfs-id.sh $'"{IMAGE_ROOTFS}"
expect "the identity script is a do_rootfs checksum input" ncstr "$img" 'do_rootfs[file-checksums] += "$'"{THISDIR}/../../files/rootfs-id.sh:True\""
expect "the rootfs identity is documented as random per build" has "$img" 'The identity is random, drawn once per build'
idfn=$(awk '/^trusted_imx95_rootfs_id \(\)/,/^}/' "$img")
expect "the rootfs identity function was found" test -n "$idfn"
expect "the rootfs identity uses no DATETIME, DATE or TIME" test "$(printf '%s' "$idfn" | tr -c 'A-Za-z_' '\n' | grep -cxE 'DATETIME|DATE|TIME|SOURCE_DATE_EPOCH')" -eq 0
expect "README says the wipe is a unit coupled to the rootfs" has "$ROOT/docs/ftpm/README.md" 'tee-nv-wipe'
expect "README says the supported reprovision is the whole .wic" has "$ROOT/docs/ftpm/README.md" 'Writing the whole'
expect "README says a different build is caught on boot by tee-nv-wipe" has "$ROOT/docs/ftpm/README.md" 'rewritten with a different build is caught on boot'
expect "README describes the root binding token" has "$ROOT/docs/ftpm/README.md" 'root binding token'
expect "README no longer carries the byte-identical open item" none 'Open item (a gap' "$ROOT/docs/ftpm/README.md"
expect "README makes no claim that every root-only rewrite is caught" none 'catches that on boot' "$ROOT/docs/ftpm/README.md"

# SPEC row 34 (ftpm): the REE-FS NV is wiped with the root file system.
expect "SPEC row ftpm keeps the approved NV erasure clause" ncstr "$ROOT/docs/SPEC.md" 'is wiped with the root file system'
expect "SPEC row ftpm lets no root rewrite keep the NV" none 'root rewrite keeps the NV' "$ROOT/docs/SPEC.md"
expect "README says the mechanism implements the SPEC requirement" has "$ROOT/docs/ftpm/README.md" 'it implements the SPEC row'
expect "README says the NV cannot live on the read-only root" ncstr "$ROOT/docs/ftpm/README.md" 'why the NV cannot live on it'
expect "README makes no claim that the NV survives a reflash" none 'partition is kept' "$ROOT/docs/ftpm/README.md"

# The EULA is the owner's: not accepted, and imx-boot (-> imx-m7-demos) is not an image dependency.
expect "the image drops imx-boot from the wks dependencies" ncstr "$img" 'WKS_FILE_DEPENDS:remove = "imx-boot"'
expect "the boot partition lists no imx-m7-demos binary" ncstr "$img" 'IMAGE_BOOT_FILES:remove = "mcore-demos/'
expect "the image depends on optee-os:do_deploy (the firmware with the fTPM TA)" ncstr "$img" 'do_image_complete[depends] += "optee-os:do_deploy"'
expect "optee-os depends on the fTPM TA deploy" ncstr "$os_app" 'do_compile[depends] += "optee-ftpm:do_deploy"'
expect "ACCEPT_FSL_EULA is not set in the layer" tree_none 'ACCEPT_FSL_EULA = ' 'platform-image/conf'
expect "REE FS on" ncstr "$flags" 'CFG_REE_FS=y'
expect "RPMB FS off" ncstr "$flags" 'CFG_RPMB_FS=n'
expect "optee-os takes the shared flags" ncstr "$os_app" 'optee-ftpm-flags.inc'
expect "the TA dev kit takes the shared flags" ncstr "$kit_app" 'optee-ftpm-flags.inc'
expect "the TA stores its NV in REE FS explicitly" ncstr "$ftpm_bb" 'CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE'
expect "measured boot stays off" none CFG_TA_MEASURED_BOOT=y "$ftpm_bb" "$os_app" "$flags"

# The RPMB key is never programmed or enabled by this layer or its docs. The
# option name is assembled so this file does not itself carry it.
opt="RPMB_WRITE""_KEY"
expect "no RPMB key option in platform-image" tree_none "$opt" platform-image
expect "no RPMB key option in docs/ftpm" tree_none "$opt" docs/ftpm
expect "CFG_RPMB_FS=y appears nowhere in platform-image" tree_none 'CFG_RPMB_FS=y' platform-image

# tpm2-tools: the debug image only.
expect "the debug image installs tpm2-tools" nc "$dbg" 'IMAGE_INSTALL.*tpm2-tools'
expect "the production image does not name tpm2-tools" none tpm2-tools "$img"

# The documentation: exists, marks its defaults provisional, no internal detail.
expect "docs/ftpm/build.md exists" test -s "$doc"
expect "docs/ftpm/build.md says provisional" has "$doc" 'rovisional'
expect "docs/ftpm/build.md links to the fTPM design" has "$doc" 'README.md'
expect "docs/ftpm/README.md points to build.md" has "$ROOT/docs/ftpm/README.md" '(build.md)'
expect "docs/platform-image/build.md points to docs/ftpm/build.md" has "$ROOT/docs/platform-image/build.md" 'ftpm/build.md'
expect "docs/ftpm/build.md names no /home path" none '/home/' "$doc"

finish
