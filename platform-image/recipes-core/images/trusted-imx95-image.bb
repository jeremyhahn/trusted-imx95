# The production root filesystem of the FRDM-IMX95-PRO image.
# Provisional default, pending the owner's answer on #14 (hardening-survey
# question 7 (b)). Not parsed or built yet: no bitbake run has used this file.
#
# This recipe signs nothing and holds no key: AHAB signing is a separate step
# after the build (docs/boot-container/signing-pipeline.md).
#
# Not installed here, on purpose (hardening-survey section 7): shells, debug
# tools, test suites and a package manager. They live in
# trusted-imx95-image-debug.bb, which never holds production keys. No image
# feature that relaxes root login is set either; that is a policy the survey
# does not cover, so it is MISSING and left at OE-core's default.
#
# firmware-ele-imx is not named: the machine adds it for the i.MX95
# (hardening-survey section 7). xkmsd is MISSING: no go-xkms recipe exists yet,
# and what xkmsd needs at run time is go-xkms's to say (hardening-survey
# question 7).

# hardening-survey section 7 and question 7 (b): the project image is built from
# OE-core's core-image-minimal pattern, not an fsl-image-* or imx-image-* one.
require recipes-core/images/core-image-minimal.bb

# MISSING: no survey names a summary string; documentation only.
SUMMARY = "trusted-imx95 production image (provisional default, pending #14)"

# hardening-survey section 7: the root filesystem is mounted read-only
# (verified-boot-survey section 3.6 and question 5 (a): dm-verity comes later).
IMAGE_FEATURES += "read-only-rootfs"

# hardening-survey section 7: add only the boot packagegroup (kernel, systemd
# through INIT_MANAGER); the machine adds firmware-ele-imx.
IMAGE_INSTALL = "packagegroup-core-boot ${CORE_IMAGE_EXTRA_INSTALL}"

# SPEC row ftpm, issue #140 (provisional): the BSP's OP-TEE client with
# tee-supplicant, started at boot, and the persistent /data partition its
# REE-FS storage (the fTPM NV) lives on, mounted before it starts. The root file
# system stays read-only.
# MISSING: no survey covers OP-TEE; docs/ftpm/README.md records the fTPM choice.
IMAGE_INSTALL:append = " optee-client trusted-imx95-tee-nv"
# MISSING: no survey names the partition layout; the wks is provisional
# (docs/ftpm/README.md, "Where the NV lives").
WKS_FILE = "trusted-imx95.wks"
# MISSING: no survey names a disk image format; the wic is provisional, as above.
IMAGE_FSTYPES += "wic"
# The Freescale EULA is the owner's to accept (docs/ftpm/build.md), so the image
# does not accept it. NXP's wic flow pulls in imx-boot, and with it
# imx-m7-demos, which needs the EULA. This image's wks has no boot container
# (the boot-container flow of this repository writes it, with the M7 image), so
# imx-boot is not a dependency of the image. MISSING: no survey covers the EULA.
WKS_FILE_DEPENDS:remove = "imx-boot"
# Dropping imx-boot also dropped the image's only path to building optee-os, whose
# firmware (tee.bin) carries the fTPM early TA (optee-os bbappend: do_compile
# depends on optee-ftpm:do_deploy). The image needs it explicitly. MISSING: no survey covers it.
do_image_complete[depends] += "optee-os:do_deploy"
# The machine's boot partition also lists the M7 demo binaries of imx-m7-demos
# (EULA again); the M7 image comes from the boot-container flow. MISSING: no survey covers it.
IMAGE_BOOT_FILES:remove = "mcore-demos/imx95-19x19-frdm_m7_TCM_hello_world.bin mcore-demos/imx95-19x19-frdm_m7_TCM_power_mode_switch.bin mcore-demos/imx95-19x19-frdm_m7_TCM_rpmsg_lite_pingpong_rtos_linux_remote.bin mcore-demos/imx95-19x19-frdm_m7_TCM_rpmsg_lite_str_echo_rtos.bin"

# SPEC row ftpm: the fTPM NV is wiped with the root file system. The read-only
# rootfs carries a build identity; trusted-imx95-tee-nv's tee-nv-wipe unit wipes
# /data/tee when /data/tee-rootfs-id differs from it (docs/ftpm/README.md).
# A reflash of the very same build is not told apart; a full .wic flash is.
# The identity is derived from the rootfs tree itself (paths, types, modes, link
# targets and file contents, less the identity file), never from the clock, so
# identical inputs give identical bytes (reproducible builds).
trusted_imx95_rootfs_id () {
    idf=${IMAGE_ROOTFS}${sysconfdir}/trusted-imx95-rootfs-id
    rm -f $idf
    (
        cd ${IMAGE_ROOTFS}
        {
            find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
            find . -printf '%p %y %m %l\n' | LC_ALL=C sort
        } | sha256sum | cut -d' ' -f1
    ) > ${WORKDIR}/trusted-imx95-rootfs-id
    install -m 0644 ${WORKDIR}/trusted-imx95-rootfs-id $idf
}
# MISSING: no survey covers it; the rootfs identity for the NV wipe.
ROOTFS_POSTPROCESS_COMMAND += "trusted_imx95_rootfs_id;"
# A change to the function body must rebuild do_rootfs (the hook is run by name, so
# its body is not otherwise part of the task signature). MISSING: no survey covers it.
do_rootfs[vardeps] += "trusted_imx95_rootfs_id"
