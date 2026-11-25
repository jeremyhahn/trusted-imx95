# OP-TEE OS with the fTPM TA linked in as an early TA, NV on the REE file system
# (SPEC row ftpm, issue #140; provisional, pending the owner's answers in
# docs/ftpm/README.md). Not parsed by bitbake yet: the recipe is meta-imx's
# optee-os_4.10.0.imx.bb, and a parse on the build host proves this file.
require recipes-security/optee/optee-ftpm-flags.inc

# The fTPM TA's UUID, as docs/secure-world/build.md gives it.
FTPM_TA_UUID = "bc50d971-d4c9-42c4-82cb-343fb7f37896"

# The TA is built by optee-ftpm and deployed; its stripped ELF is linked into
# tee.bin, so the TA needs no file system to load.
do_compile[depends] += "optee-ftpm:do_deploy"
EXTRA_OEMAKE += "CFG_EARLY_TA=y"
# The PKCS#11 TA is an early TA as well, in tree, as scripts/secure-world-build.sh
# embeds it next to the fTPM one (docs/secure-world/build.md).
EXTRA_OEMAKE += "CFG_IN_TREE_EARLY_TAS=pkcs11/fd02c9da-306c-48c7-a49c-bbd827ae86ee"
EXTRA_OEMAKE += "EARLY_TA_PATHS=${DEPLOY_DIR_IMAGE}/optee-ftpm/${FTPM_TA_UUID}.stripped.elf"
