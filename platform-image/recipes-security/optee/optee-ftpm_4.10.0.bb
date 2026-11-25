SUMMARY = "OP-TEE firmware TPM 2.0 TA (optee_ftpm 4.10.0 on ms-tpm-20-ref), built as an early TA"
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. Parsed and fetched by bitbake (docs/ftpm/build.md); not built.
#
# Both pins are those of docs/secure-world/build.md (and secure-world/bsp.lock):
# optee_ftpm at its tag 4.10.0, peeled, and the ms-tpm-20-ref commit its README
# names. Nothing here fetches an unpinned revision. ms-tpm-20-ref's wolfssl
# submodule is not fetched: the TA uses OP-TEE's crypto and libmbedtls.
# The pinned source's LICENSE file is Microsoft's two-clause BSD license.
LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=5a3925ece0806073ae9ebbb08ff6f11e"

SRCREV_FORMAT = "ftpm_mstpm"
SRCREV_ftpm = "a09269b15de635e1816fe832e26adfbfb44c5455"
SRCREV_mstpm = "98b60a44aba79b15fcce1c0d1e46cf5918400f6a"
SRC_URI = "git://github.com/OP-TEE/optee_ftpm.git;protocol=https;nobranch=1;name=ftpm \
           git://github.com/microsoft/ms-tpm-20-ref.git;protocol=https;nobranch=1;name=mstpm;destsuffix=ms-tpm-20-ref \
          "

DEPENDS = "optee-os-tadevkit python3-pycryptodomex-native"
inherit deploy

FTPM_TA_UUID = "bc50d971-d4c9-42c4-82cb-343fb7f37896"

# The NV storage follows the selector of optee-ftpm-flags.inc, owner ruling 1234
# (question 1): reefs (development boards, default) is REE FS storage, rpmb
# (production) is RPMB storage. Any other value stops the parse.
# CFG_TA_MEASURED_BOOT stays off, the TA's default (docs/ftpm/README.md,
# "Measured boot").
TRUSTED_IMX95_FTPM_NV ?= "reefs"
FTPM_TA_STORAGE_ID[reefs] = "TEE_STORAGE_PRIVATE_REE"
FTPM_TA_STORAGE_ID[rpmb] = "TEE_STORAGE_PRIVATE_RPMB"
EXTRA_OEMAKE = "TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta \
                CFG_MS_TPM_20_REF=${UNPACKDIR}/ms-tpm-20-ref \
                CFG_FTPM_TA_TEE_STORAGE_ID=${@d.getVarFlag('FTPM_TA_STORAGE_ID', d.getVar('TRUSTED_IMX95_FTPM_NV')) or bb.fatal('TRUSTED_IMX95_FTPM_NV must be reefs or rpmb, not %s' % d.getVar('TRUSTED_IMX95_FTPM_NV'))} \
                CFG_TEE_TA_LOG_LEVEL=0 \
                CROSS_COMPILE=${HOST_PREFIX} \
                LIBGCC_LOCATE_CFLAGS=--sysroot=${STAGING_DIR_HOST} \
                O=${B}"

do_compile() {
    # Only the stripped ELF: an early TA is linked into tee.bin and needs no
    # signature, so the .ta target (which signs) is not built and no key is used.
    oe_runmake -C ${S} ${S}/${FTPM_TA_UUID}.stripped.elf
}

do_install[noexec] = "1"

do_deploy() {
    install -d ${DEPLOYDIR}/optee-ftpm
    install -m 0644 ${S}/${FTPM_TA_UUID}.stripped.elf ${DEPLOYDIR}/optee-ftpm/
}
addtask deploy after do_compile before do_build
