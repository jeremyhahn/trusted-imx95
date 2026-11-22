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
