# Platform image build configuration

Every choice here is a provisional default, pending the owner's answer on
#14. The owner has not answered; the defaults are the ones
[build-system-options.md](build-system-options.md) recommends (section 10 and
section 11), written down so the owner can read a working proposal.

## What is in the tree

- `platform-image/manifest.lock`: the pins. NXP's manifest repository at the
  commit tag `lf-6.18.37-2.1.0` peels to, the manifest file
  `imx-6.18.37-2.1.0.xml`, and every project the manifest lists (20 layers),
  each with its repository, path and 40-hex commit. Hashes were read from the
  manifest file, and by `git ls-remote` for the three layers the manifest
  names by tag. None is typed by hand and none is MISSING.
- `platform-image/conf/distro/trusted-imx95.conf`: the headless distro,
  requiring NXP's `fsl-imx-fb-minimal`, with the display, audio and wireless
  features removed. It signs nothing.
- `platform-image/conf/layer.conf`, `local.conf.template`,
  `bblayers.conf.template`: the layer, and the templates for machine
  `imx95-19x19-lpddr5-frdm-pro`.
- `scripts/platform-image-fetch.sh`, `make platform-image-fetch`: checks the
  layers out into a directory outside the clone and fails when a layer's
  commit differs from the lock. It needs the network, so it is in neither
  `make build` nor `make test`.
- `test/platform_image_test.sh`, in `make test`: offline checks of the lock,
  the machine name and the distro file.

## The #14 questions and the answer assumed

| Question | Assumed (provisional) |
|---|---|
| Q1 build system | (a) Yocto with NXP meta-imx |
| Q2 BSP baseline | (a) manifest imx-6.18.37-2.1.0, every layer at the manifest's commit; the release `system-manager/sm.lock` already pins |
| Q3 distro | (b) our own headless distro, derived from an fsl-imx-* one |
| Q4 signing | (b) AHAB signing a separate step after the build, not inside it |

## The image recipes

Every setting below is a provisional default, pending the owner's answer on
#14 (hardening-survey question 7, recommendation (b)). Files:
`platform-image/recipes-core/images/trusted-imx95-image.bb` (production) and
`trusted-imx95-image-debug.bb` (debug, requires the production one and never
holds production keys). `conf/layer.conf` adds the `recipes-*/*/*.bb` BBFILES
line.

| Setting | Where | Source |
|---|---|---|
| `require recipes-core/images/core-image-minimal.bb` | production image | hardening-survey section 7, question 7 (b) |
| `IMAGE_FEATURES += "read-only-rootfs"` | production image | hardening-survey section 7; verified-boot-survey section 3.6, question 5 (a) (dm-verity comes later) |
| `IMAGE_INSTALL = "packagegroup-core-boot ..."` | production image | hardening-survey section 7 (only what exists today; `firmware-ele-imx` comes from the machine) |
| `SUMMARY` | both images | MISSING: no survey names it |
| `IMAGE_FEATURES += "debug-tweaks tools-debug package-management"` | debug image | hardening-survey section 7 for the tools and package manager; the root-login behaviour of `debug-tweaks` is MISSING (the survey names debug tools, not login policy) |
| `IMAGE_INSTALL:append = " bash gdb strace imx-test"` | debug image | hardening-survey section 7 |
| `INIT_MANAGER = "systemd"` | distro | hardening-survey section 7 (systemd 259.5 on wrynose) |
| `DISTRO_FEATURES:remove`, `DISTRO_FEATURES_BACKFILL_CONSIDERED`, `IMAGE_FEATURES:remove` | distro | hardening-survey section 7 (no display stack or audio); removing bluetooth, wifi, nfc and 3g is MISSING |
| `DISTRO`, `DISTRO_NAME`, `DISTRO_VERSION` | distro | MISSING: naming choices of this layer |
| `BBFILES += recipes-*/*/*.bb` | layer.conf | MISSING: no survey covers it |

Reproducible builds and the SBOM stay at Yocto's defaults
(reproducible-build-survey sections 3 and 4, question 5 (a)): the fallback
`SOURCE_DATE_EPOCH`, the fixed `REPRODUCIBLE_TIMESTAMP_ROOTFS` and `create-spdx`
(SPDX 3.0) are on, and the test fails if any file under `platform-image/` sets
the first two or removes the third.

Open, MISSING, and deliberately not set: `BB_NO_NETWORK`, hash equivalence, the
`SPDX_INCLUDE_*`, `SPDX_INVOKED_BY` and `SPDX_ON_BEHALF_OF` fields
(reproducible-build-survey question 6 has no recommendation), the xkmsd
package (go-xkms has no recipe yet; hardening-survey question 7), and any
login-policy image feature in the production image.

## Verified and not verified

Verified: the lock's hashes were read from their sources; the test runs
offline; the test checks the two image recipes, the BBFILES line, the absence
of overrides of the reproducible and SBOM defaults, and that the fetch script
fails with "checked out X, the lock pins Y" for a pin on an annotated tag
object, against a local stub repository; `meta-imx` at its tag has the machine `imx95-19x19-lpddr5-frdm-pro`
and the `fsl-imx-fb-minimal` distro the file requires.

Not verified: no bitbake parse or build, so the image recipes, the distro, the layer set in
`bblayers.conf.template` and the removed features are untested proposals;
`make platform-image-fetch` has not been run end to end; the NXP EULA
(`ACCEPT_FSL_EULA`) is left to the owner.
