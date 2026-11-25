# Proposed, pending owner approval (hardening-survey section 10, Q1 (c)): applies
# the kernel hardening fragment. The recipe is meta-imx-bsp's linux-imx_6.18.bb,
# which accepts kernel-yocto fragments and rejects DELTA_KERNEL_DEFCONFIG
# (hardening-survey section 5). Not parsed by bitbake yet.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# ftpm.cfg: the firmware TPM driver (SPEC row ftpm, issue #140; provisional).
SRC_URI += "file://hardening.cfg file://ftpm.cfg"
