# The TA dev kit the fTPM TA builds against: the same flags as optee-os
# (SPEC row ftpm, issue #140; provisional). Not parsed by bitbake yet; the
# recipe name optee-os-tadevkit is meta-imx's, to be confirmed on a parse.
require recipes-security/optee/optee-ftpm-flags.inc
