# Reproducible OEI firmware (#160): makefiles/build_info.mak writes the build
# date (lines 71, 72 and 98 of the pinned revision) with plain `date`, which
# ignores SOURCE_DATE_EPOCH. Those bytes sit inside oei-m33-ddr.bin, so its
# SHA-384 in the imx-boot container changes on every build. The patch makes
# the three calls print SOURCE_DATE_EPOCH in UTC (see docs/platform-image/build.md).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-build-info-use-source-date-epoch.patch"
