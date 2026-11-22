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
IMAGE_INSTALL:append = " optee-client trusted-imx95-tee-nv"
WKS_FILE = "trusted-imx95.wks"
IMAGE_FSTYPES += "wic"
# The Freescale EULA is the owner's to accept (docs/ftpm/build.md), so the image
# does not accept it. NXP's wic flow pulls in imx-boot, and with it
# imx-m7-demos, which needs the EULA. This image's wks has no boot container
# (the boot-container flow of this repository writes it, with the M7 image), so
# imx-boot is not a dependency of the image.
WKS_FILE_DEPENDS:remove = "imx-boot"
