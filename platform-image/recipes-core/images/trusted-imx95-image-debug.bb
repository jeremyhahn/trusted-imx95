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
# separate debug image. The root-login features are MISSING from the survey,
# which names debug tools, not login policy; debug-tweaks is OE-core's single
# switch for them and is used for bring-up only.
IMAGE_FEATURES += "debug-tweaks tools-debug package-management"

# hardening-survey section 7: the shells and debug tools the production image
# leaves out (bash, gdb, strace, imx-test).
IMAGE_INSTALL:append = " bash gdb strace imx-test"
