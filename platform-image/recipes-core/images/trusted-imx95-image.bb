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
# (hardening-survey section 7). xkmsd is installed from the xkmsd recipe
# (recipes-security/xkmsd, a tagged go-xkms release; docs/SPEC.md,
# `platform-image`: "It runs xkmsd from go-xkms on its Linux side"), with its
# system user, its enabled systemd unit and its default configuration. The
# enclave access policy recipe (a proposal, not installed here)
# would only restrict the enclave node to the xkmsd group; it is not xkmsd.

# hardening-survey section 7 and question 7 (b): the project image is built from
# OE-core's core-image-minimal pattern, not an fsl-image-* or imx-image-* one.
require recipes-core/images/core-image-minimal.bb

# MISSING: no survey names a summary string; documentation only.
SUMMARY = "trusted-imx95 production image (provisional default, pending #14)"

# hardening-survey section 7: the root filesystem is mounted read-only
# (verified-boot-survey section 3.6 and question 5 (a): dm-verity comes later).
IMAGE_FEATURES += "read-only-rootfs"

# MISSING: no survey names the disk layout (boot-device layout is open). The
# read-only root (survey section above) needs one persistent writable
# partition, xkms-state, for xkmsd's state: the wic image builds it.
IMAGE_FSTYPES += "wic"
# MISSING: the layout file itself, platform-image/wic/trusted-imx95.wks.in, is
# this row's smallest layout, not a survey's.
WKS_FILE = "trusted-imx95.wks.in"

# hardening-survey section 7: add only the boot packagegroup (kernel, systemd
# through INIT_MANAGER); the machine adds firmware-ele-imx. docs/SPEC.md,
# `platform-image`: xkmsd runs on the Linux side.
# R6 (xkmsd-node.md section 3) is proposed, pending owner approval: the access
# policy recipe stays out of the image until the owner decides.
IMAGE_INSTALL = "packagegroup-core-boot xkmsd ${CORE_IMAGE_EXTRA_INSTALL}"
