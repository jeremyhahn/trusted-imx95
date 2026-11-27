# Reproducible System Manager firmware (#160): makefiles/build_info.mak writes
# the build date (lines 83, 84 and 117 of the pinned revision) with plain
# `date`, which ignores SOURCE_DATE_EPOCH. Those bytes sit inside
# m33_image-mx95frdm-pro.bin, so its SHA-384 in the imx-boot container changes
# on every build. The patch makes the three calls print SOURCE_DATE_EPOCH in UTC
# (see docs/platform-image/build.md).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-build-info-use-source-date-epoch.patch"
