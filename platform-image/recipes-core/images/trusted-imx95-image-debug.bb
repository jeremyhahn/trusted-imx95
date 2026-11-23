# The debug root filesystem: the production image plus shells and debug tools.
# Provisional default, pending the owner's answer on #14 (hardening-survey
# question 7 (b)). Not parsed or built yet: no bitbake run has used this file.
#
# This image NEVER holds production keys: it is for bring-up on a development
# board only, and nothing signed for production is ever put on it
# (hardening-survey section 7).

require trusted-imx95-image.bb

# MISSING: no survey names a summary string; documentation only.
SUMMARY = "trusted-imx95 debug image, never holds production keys (provisional default, pending #14)"

# hardening-survey section 7: debug tools and a package manager go in the
# separate debug image. Login policy is not relaxed in the debug image:
# debug-tweaks (empty-password root login) is deliberately left out
# (provisional default, pending #14).
IMAGE_FEATURES += "tools-debug package-management"

# hardening-survey section 7: the shells and debug tools the production image
# leaves out (bash, gdb, strace, imx-test).
IMAGE_INSTALL:append = " bash gdb strace imx-test"

# SPEC row ftpm, issue #140 (provisional; the ta-options-survey and the fTPM
# design, docs/ftpm/build.md): tpm2-tools to talk to /dev/tpmrm0 during
# bring-up. Debug image only; the production image does not carry it.
IMAGE_INSTALL:append = " tpm2-tools"

# Owner ruling 1234: the fTPM NV is in RPMB on production devices only. This
# image is for development boards and never holds production keys, so it
# refuses the rpmb selection of optee-ftpm-flags.inc.
python () {
    if d.getVar('TRUSTED_IMX95_FTPM_NV') == 'rpmb':
        bb.fatal('the debug image is for development boards only: TRUSTED_IMX95_FTPM_NV = "rpmb" (production) is refused')
}
