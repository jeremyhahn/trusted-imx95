# OP-TEE flags the firmware TPM needs, shared by the optee-os and
# optee-os-tadevkit bbappends so the TA dev kit and tee.bin are built with the
# same flags (docs/secure-world/build.md, "The flags"; docs/ftpm/build.md).
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. Parsed by bitbake (docs/ftpm/build.md).
#
# NV storage is chosen by one selector, per owner ruling 1234 (question 1):
#   reefs  development boards (default): the NV is in the REE file system. No
#          rollback protection, and the NV is lost on a rootfs reflash.
#   rpmb   production: the NV is in the eMMC RPMB, written only after OEM close.
# Neither set lets OP-TEE program the RPMB key: the key options are off, so RPMB
# writes fail until the provisioning station has programmed the key after OEM
# close (docs/secure-key-handling/rpmb-survey.md, sections 5 and 10). The
# debug image refuses rpmb. The TA recipe takes its storage ID from the same
# selector. Nothing was parsed or built with rpmb.
TRUSTED_IMX95_FTPM_NV ?= "reefs"
TRUSTED_IMX95_FTPM_NV_FLAGS[reefs] = "CFG_REE_FS=y CFG_RPMB_FS=n"
TRUSTED_IMX95_FTPM_NV_FLAGS[rpmb] = "CFG_REE_FS=y CFG_RPMB_FS=y CFG_RPMB_WRITE_KEY=n CFG_RPMB_TESTKEY=n"
EXTRA_OEMAKE += "${@d.getVarFlag('TRUSTED_IMX95_FTPM_NV_FLAGS', d.getVar('TRUSTED_IMX95_FTPM_NV')) or bb.fatal('TRUSTED_IMX95_FTPM_NV must be reefs or rpmb, not %s' % d.getVar('TRUSTED_IMX95_FTPM_NV'))}"
# No TA is loaded from the file system; the PTA that installs TAs into REE FS
# storage would not link without REE FS TA support.
EXTRA_OEMAKE += "CFG_REE_FS_TA=n CFG_SECSTOR_TA_MGMT_PTA=n"
