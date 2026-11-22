SUMMARY = "OP-TEE firmware TPM 2.0 TA (optee_ftpm 4.10.0 on ms-tpm-20-ref), built as an early TA"
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. Not parsed or built by bitbake yet.
#
# Both pins are those of docs/secure-world/build.md (and secure-world/bsp.lock):
# optee_ftpm at its tag 4.10.0, peeled, and the ms-tpm-20-ref commit its README
# names. Nothing here fetches an unpinned revision. ms-tpm-20-ref's wolfssl
# submodule is not fetched: the TA uses OP-TEE's crypto and libmbedtls.
LICENSE = "MIT"
# MISSING: the license file's checksum is read on the first parse on the build
# host; a wrong value fails loudly there. LICENSE is the project's stated one.
LIC_FILES_CHKSUM = "file://LICENSE;md5=00000000000000000000000000000000"

SRCREV_FORMAT = "ftpm_mstpm"
SRCREV_ftpm = "a09269b15de635e1816fe832e26adfbfb44c5455"
SRCREV_mstpm = "98b60a44aba79b15fcce1c0d1e46cf5918400f6a"
SRC_URI = "git://github.com/OP-TEE/optee_ftpm.git;protocol=https;nobranch=1;name=ftpm \
           git://github.com/microsoft/ms-tpm-20-ref.git;protocol=https;nobranch=1;name=mstpm;destsuffix=ms-tpm-20-ref \
          "
S = "${WORKDIR}/git"

DEPENDS = "optee-os-tadevkit python3-pycryptodomex-native"
inherit deploy

FTPM_TA_UUID = "bc50d971-d4c9-42c4-82cb-343fb7f37896"

# The NV is in REE FS storage, explicitly (provisional default, question 1).
# CFG_TA_MEASURED_BOOT stays off, the TA's default (docs/ftpm/README.md,
# "Measured boot").
EXTRA_OEMAKE = "TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta \
                CFG_MS_TPM_20_REF=${WORKDIR}/ms-tpm-20-ref \
                CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE \
                CFG_TEE_TA_LOG_LEVEL=0 \
                CROSS_COMPILE=${HOST_PREFIX} \
                O=${B}"

do_compile() {
    oe_runmake -C ${S}
}

do_install[noexec] = "1"

do_deploy() {
    install -d ${DEPLOYDIR}/optee-ftpm
    install -m 0644 ${B}/${FTPM_TA_UUID}.stripped.elf ${DEPLOYDIR}/optee-ftpm/
}
addtask deploy after do_compile before do_build
