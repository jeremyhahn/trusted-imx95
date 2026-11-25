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
# has_in TEXT STRING: TEXT contains STRING.
has_in() { [[ $1 == *"$2"* ]]; }
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
expect "no by-partlabel path in the NV files" none 'by-partlabel' "$nvf/tee-data-mount" "$nvf/tee-data-mount.service" "$nvf/10-nv.conf"
expect "the mount service runs the resolver" ncstr "$nvf/tee-data-mount.service" 'ExecStart=/usr/sbin/tee-data-mount'
expect "the mount service has no default dependencies" ncstr "$nvf/tee-data-mount.service" 'DefaultDependencies=no'
expect "the mount service is before tee-supplicant" ncstr "$nvf/tee-data-mount.service" 'Before=tee-supplicant@teepriv0.service'
expect "the mount service is stopped before shutdown" ncstr "$nvf/tee-data-mount.service" 'Conflicts=shutdown.target'
expect "tee-supplicant requires the mount service, and only it" nc "$nvf/10-nv.conf" '^Requires=tee-data-mount\.service$'
expect "tee-supplicant is ordered after the mount service, and only it" nc "$nvf/10-nv.conf" '^After=tee-data-mount\.service$'
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
# No automatic NV wipe (owner, 2026-11-25): the NV is kept on tee-data when the root
# partition is rewritten, and a full-image flash, which recreates tee-data empty, erases it.
# The removed names are assembled so this file does not itself carry them.
trap 'rm -rf "$fk"' EXIT
wname="tee-nv-""wipe"
mname="root-""marker"
expect "no wipe script in the NV recipe's files" test ! -e "$nvf/$wname"
expect "no wipe unit in the NV recipe's files" test ! -e "$nvf/$wname.service"
expect "the NV recipe installs no wipe" none "$wname" "$nv"
expect "the NV recipe adds no other requirement to tee-supplicant" none 'service.requires' "$nv"
expect "the supplicant drop-in names no wipe" none "$wname" "$nvf/10-nv.conf"
expect "no marker script in the layer" test ! -e "$ROOT/platform-image/files/$mname.sh"
expect "no rootfs identity script in the layer" test ! -e "$ROOT/platform-image/files/rootfs-id.sh"
expect "no marker check script" test ! -e "$ROOT/scripts/platform-image-check-$mname.sh"
expect "the image writes no rootfs identity" none 'rootfs_id' "$img"
expect "the image appends nothing to the wic command" none 'IMAGE_CMD:wic' "$img"
expect "the wks passes no mkfs option to the root" none 'mkfs-extraopts' "$wks"
expect "the layer names no wipe" tree_none "$wname" platform-image
expect "the layer names no marker" tree_none "$mname" platform-image
expect "README: a root-partition rewrite keeps the NV" has "$ROOT/docs/ftpm/README.md" 'A rewrite of the root partition keeps the NV'
expect "README: a full .wic flash is the reprovisioning path" has "$ROOT/docs/ftpm/README.md" 'the reprovisioning path'
expect "README keeps the no-rollback-protection caveat" has "$ROOT/docs/ftpm/README.md" 'no rollback protection'
expect "README has no automatic wipe" none "$wname" "$ROOT/docs/ftpm/README.md"
expect "build.md has no automatic wipe" none "$wname" "$doc"

# The boot ordering point for TPM users (docs/secure-world/ta-options-survey.md item 6).
tpmt=$nvf/trusted-imx95-tpm.target
expect "the TPM target requires dev-tpmrm0.device" ncstr "$tpmt" 'Requires=dev-tpmrm0.device'
expect "the TPM target is ordered after dev-tpmrm0.device" ncstr "$tpmt" 'After=dev-tpmrm0.device'
expect "the TPM target is ordered after the supplicant" ncstr "$tpmt" 'After=tee-supplicant@teepriv0.service'
expect "the recipe fetches the TPM target" ncstr "$nv" 'file://trusted-imx95-tpm.target'
# shellcheck disable=SC2016 # bitbake variables, literal
expect "the recipe installs the TPM target" ncstr "$nv" 'trusted-imx95-tpm.target ${D}${systemd_system_unitdir}/trusted-imx95-tpm.target'
expect "the recipe enables the TPM target from multi-user.target" ncstr "$nv" 'multi-user.target.wants/trusted-imx95-tpm.target'
expect "the TPM target is wanted by multi-user.target" ncstr "$tpmt" 'WantedBy=multi-user.target'

# SPEC row ftpm (owner, 2026-11-25): the NV is kept on tee-data and erased by a full-image flash.
# shellcheck disable=SC2016 # the backquotes are SPEC text, not an expansion
expect "SPEC row ftpm carries the owner's NV lifecycle clause" ncstr "$ROOT/docs/SPEC.md" 'the NV is kept on the `tee-data` partition and erased by a full-image flash (owner, 2026-11-25);'
expect "SPEC row ftpm no longer says a reflash loses the NV" none 'loses the NV when the root file system is reflashed' "$ROOT/docs/SPEC.md"
expect "README says the NV cannot live on the read-only root" ncstr "$ROOT/docs/ftpm/README.md" 'why the NV cannot live on it'

# The EULA is the owner's: not accepted, and imx-boot (-> imx-m7-demos) is not an image dependency.
expect "the image drops imx-boot from the wks dependencies" ncstr "$img" 'WKS_FILE_DEPENDS:remove = "imx-boot"'
expect "the boot partition lists no imx-m7-demos binary" ncstr "$img" 'IMAGE_BOOT_FILES:remove = "mcore-demos/'
expect "the image depends on optee-os:do_deploy (the firmware with the fTPM TA)" ncstr "$img" 'do_image_complete[depends] += "optee-os:do_deploy"'
expect "optee-os depends on the fTPM TA deploy" ncstr "$os_app" 'do_compile[depends] += "optee-ftpm:do_deploy"'
expect "ACCEPT_FSL_EULA is not set in the layer" tree_none 'ACCEPT_FSL_EULA = ' 'platform-image/conf'
# NV storage selector (owner ruling 1234): reefs by default, rpmb for production.
sel=TRUSTED_IMX95_FTPM_NV
expect "the selector defaults to reefs" ncstr "$flags" "$sel ?= \"reefs\""
expect "the reefs set holds REE FS on" ncstr "$flags" "${sel}_FLAGS[reefs] = \"CFG_REE_FS=y CFG_RPMB_FS=n\""
rpset=$(git -C "$ROOT" grep -h "^${sel}_FLAGS\[rpmb\]" -- platform-image || true)
expect "the rpmb set holds RPMB FS on" has_in "$rpset" 'CFG_RPMB_FS=y'
expect "the rpmb set keeps REE FS on" has_in "$rpset" 'CFG_REE_FS=y'
# The key option names are assembled so this file does not itself carry them.
wk="CFG_RPMB_WRITE""_KEY"
tk="CFG_RPMB_TEST""KEY"
expect "the rpmb set turns the write-key option off explicitly" has_in "$rpset" "$wk=n"
expect "the rpmb set turns the test-key option off explicitly" has_in "$rpset" "$tk=n"
expect "an unknown selector value reaches bb.fatal" ncstr "$flags" "or bb.fatal('$sel must be reefs or rpmb"
expect "the TA maps reefs to the REE storage ID" ncstr "$ftpm_bb" 'FTPM_TA_STORAGE_ID[reefs] = "TEE_STORAGE_PRIVATE_REE"'
expect "the TA maps rpmb to the RPMB storage ID" ncstr "$ftpm_bb" 'FTPM_TA_STORAGE_ID[rpmb] = "TEE_STORAGE_PRIVATE_RPMB"'
expect "the TA storage ID comes from the selector" ncstr "$ftpm_bb" "CFG_FTPM_TA_TEE_STORAGE_ID=\${@d.getVarFlag('FTPM_TA_STORAGE_ID', d.getVar('$sel'))"
expect "the TA recipe's unknown value reaches bb.fatal" ncstr "$ftpm_bb" "or bb.fatal('$sel must be reefs or rpmb"
expect "the TA recipe defaults the selector to reefs" ncstr "$ftpm_bb" "$sel ?= \"reefs\""
expect "the debug image skips itself under rpmb with SkipRecipe" nc "$dbg" "raise bb\\.parse\\.SkipRecipe\\(.*$sel = \"rpmb\""
no_fatal() { ! nc "$1" 'bb\.fatal'; }
expect "the debug image never calls bb.fatal (production must still parse)" no_fatal "$dbg"
expect "the debug image tests the selector for rpmb" ncstr "$dbg" "d.getVar('$sel') == 'rpmb'"
expect "optee-os takes the shared flags" ncstr "$os_app" 'optee-ftpm-flags.inc'
expect "the TA dev kit takes the shared flags" ncstr "$kit_app" 'optee-ftpm-flags.inc'
expect "measured boot stays off" none CFG_TA_MEASURED_BOOT=y "$ftpm_bb" "$os_app" "$flags"

# No RPMB key option is assigned anything but n, in the layer or its docs: OP-TEE
# never programs the key, so RPMB writes fail until the provisioning station has.
for o in "$wk" "$tk"; do
	for v in y 1 Y; do
		expect "no $v assignment of a RPMB key option in platform-image" tree_none "$o=$v" platform-image
		expect "no $v assignment of a RPMB key option in docs/ftpm" tree_none "$o=$v" docs/ftpm
	done
	expect "no ?= or += of a RPMB key option in platform-image" tree_none "$o ?=" platform-image
done
# CFG_RPMB_FS=y only inside the rpmb set (exactly one line carries it).
rpfs=$(git -C "$ROOT" grep -h 'CFG_RPMB_FS=y' -- platform-image || true)
expect "CFG_RPMB_FS=y occurs only in the rpmb set" test "$rpfs" = "$rpset"

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
expect "docs/ftpm/build.md names the NV selector" has "$doc" "$sel"
# shellcheck disable=SC2016 # markdown backticks, literal
expect "docs/ftpm/build.md names the reefs value" has "$doc" '`reefs`'
# shellcheck disable=SC2016 # markdown backticks, literal
expect "docs/ftpm/build.md names the rpmb value" has "$doc" '`rpmb`'
expect "docs/ftpm/build.md cites ruling 1234" has "$doc" 'ruling 1234'
# shellcheck disable=SC2016 # markdown backticks, literal
expect "docs/ftpm/build.md says nothing was built with rpmb" has "$doc" 'Nothing was parsed or built with `rpmb`'
expect "docs/ftpm/README.md names the NV selector" has "$ROOT/docs/ftpm/README.md" "$sel"
expect "docs/ftpm/README.md marks the RPMB frame route unconfirmed" has "$ROOT/docs/ftpm/README.md" 'Open, all **unconfirmed**'

finish
