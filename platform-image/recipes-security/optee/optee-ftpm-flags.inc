# OP-TEE flags the firmware TPM needs, shared by the optee-os and
# optee-os-tadevkit bbappends so the TA dev kit and tee.bin are built with the
# same flags (docs/secure-world/build.md, "The flags"; docs/ftpm/build.md).
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. Parsed by bitbake (docs/ftpm/build.md).
#
# NV storage is the REE file system (provisional default, question 1): RPMB
# stays off, and no RPMB key option is set anywhere in this layer. Limits: no
# rollback protection, and the NV is lost on a rootfs reflash.
EXTRA_OEMAKE += "CFG_REE_FS=y CFG_RPMB_FS=n"
# No TA is loaded from the file system; the PTA that installs TAs into REE FS
# storage would not link without REE FS TA support.
EXTRA_OEMAKE += "CFG_REE_FS_TA=n CFG_SECSTOR_TA_MGMT_PTA=n"
