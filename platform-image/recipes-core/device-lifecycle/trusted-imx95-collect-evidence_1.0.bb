# The device-lifecycle evidence collector (docs/device-lifecycle/evidence-bundle.md,
# "Device collector"). Proposed, pending owner approval; refs #177. Not parsed
# or built yet: no bitbake run has used this file.
#
# Opt-in. No image recipe names it and CORE_IMAGE_EXTRA_INSTALL is empty by
# default, so no image installs it. A builder takes it with
#   CORE_IMAGE_EXTRA_INSTALL += "trusted-imx95-collect-evidence"
# Packaging waits on the ftpm image work (#140) and row 162 (the enclave
# client), so this recipe is not added to any image. Delete the file and
# nothing else changes.
SUMMARY = "Device-side evidence collector for endorse-01 (proposed)"
LICENSE = "CLOSED"

# The script comes from this repository, not from a copy: THISDIR is
# platform-image/recipes-core/device-lifecycle, so three levels up is the
# repository root. A file:// path only; no network fetch, no EULA.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../scripts/device-lifecycle:"
SRC_URI = "file://collect-evidence.sh"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${S}/collect-evidence.sh ${D}${sbindir}/collect-evidence.sh
}

# Run-time needs only. tpm2-tools is meta-security's meta-tpm sublayer
# (meta-tpm/recipes-tpm2/tpm2-tools/tpm2-tools_5.7.bb at the commit
# platform-image/manifest.lock pins); that sublayer must be in bblayers.
# The enclave client (row 162) is not a dependency: ELE_ATTEST_CMD has no
# default.
RDEPENDS:${PN} = "bash coreutils tpm2-tools"
