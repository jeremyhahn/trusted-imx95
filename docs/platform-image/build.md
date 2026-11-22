# Platform image build configuration

Every choice here is a provisional default, pending the owner's answer on
#14. The owner has not answered; the defaults are the ones
[build-system-options.md](build-system-options.md) recommends (section 10 and
section 11), written down so the owner can read a working proposal.

## What is in the tree

- `platform-image/manifest.lock`: the pins. NXP's manifest repository at the
  commit tag `lf-6.18.37-2.1.0` peels to, the manifest file
  `imx-6.18.37-2.1.0.xml`, and every project the manifest lists (19 layers),
  each with its repository, path and 40-hex commit. Hashes were read from the
  manifest file, and by `git ls-remote` for the three layers the manifest
  names by tag. None is typed by hand and none is MISSING.
- `platform-image/conf/distro/trusted-imx95.conf`: the headless distro,
  requiring `poky.conf` (NXP's `fsl-imx-fb-minimal` sets an option wrynose
  rejects; see [build-host-check.md](build-host-check.md)), with the display,
  audio and wireless features removed. It signs nothing.
- `platform-image/conf/layer.conf`, `local.conf.template`,
  `bblayers.conf.template`: the layer, and the templates for machine
  `imx95-19x19-lpddr5-frdm-pro`.
- `scripts/platform-image-fetch.sh`, `make platform-image-fetch`: checks the
  layers out into a directory outside the clone and fails when a layer's
  commit differs from the lock. A fetched layer must also be clean: any staged,
  unstaged, untracked or ignored file fails the fetch, so remove the layer
  directory and fetch again. It needs the network, so it is in neither
  `make build` nor `make test`.
- `scripts/platform-image-parse.sh`, `make platform-image-parse`: the metadata
  check, run on a build host (bitbake and the network). It fetches the pinned
  layers, writes the build directory's conf from the templates, runs
  `bitbake -p`, then `bitbake -e` for `trusted-imx95-image` and
  `trusted-imx95-image-debug`. It checks that the effective `MACHINE` is the
  lock's, `DISTRO` is `local.conf.template`'s, `INIT_MANAGER` is the distro's,
  and that `IMAGE_FEATURES` holds none of `debug-tweaks`, `empty-root-password`,
  `allow-empty-password` or `allow-root-login`. It refuses to overwrite a
  `build/conf/local.conf` or `bblayers.conf` that differs from the templates,
  unless `PLATFORM_IMAGE_PARSE_FORCE=1`. It builds no image.
- `scripts/platform-image-kernel-config.sh`, `make platform-image-kernel-config`:
  the kernel configuration check, run on a build host after the parse check.
  In the same build directory it runs `bitbake linux-imx -c configure`, finds
  the generated `.config` (`B` from `bitbake -e linux-imx`) and checks it
  against `platform-image/kernel-required.txt`, the one table
  `test/platform_image_kernel_test.sh` also checks the fragment against.
  A required `n` holds when the symbol is "is not set" or absent.

- `scripts/platform-image-hosttools.sh`, `make platform-image-hosttools`: sets
  up a non-root build host in a cache directory: Yocto buildtools-extended 6.0.1
  (checked against its pinned and published sha256, failing closed) and the
  apt-fetched cpio, diffstat, file, gawk and socat, then writes an `env.sh` to
  source before the two targets below. Its stubbed test is
  `test/platform_image_hosttools_test.sh`.

The build-host run is recorded in [build-host-check.md](build-host-check.md),
with a "repeat this run" section.

Both build-host targets, `make platform-image-parse` (the metadata check) and
`make platform-image-kernel-config` (the kernel-config check), need bitbake
and the network, and **CI does not run them yet** (provisional, pending a
build-host CI runner). Their stub-driven tests, `test/platform_image_parse_test.sh`
and `test/platform_image_kernel_config_test.sh`, run in `make test`.
- `test/platform_image_test.sh`, in `make test`: offline checks of the lock,
  the machine name, the distro file, the templates against the lock, and the
  absence of root-login relaxations (`debug-tweaks` and the like) in the image
  metadata.

## The #14 questions and the answer assumed

| Question | Assumed (provisional) |
|---|---|
| Q1 build system | (a) Yocto with NXP meta-imx |
| Q2 BSP baseline | (a) manifest imx-6.18.37-2.1.0, every layer at the manifest's commit; the release `system-manager/sm.lock` already pins |
| Q3 distro | (b) our own headless distro, based on poky.conf with the fsl-imx-base settings it needs |
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
| `IMAGE_FEATURES += "tools-debug package-management"` | debug image | hardening-survey section 7 for the tools and package manager; no `debug-tweaks`: the login policy is not relaxed in the debug image (provisional, pending #14) |
| `IMAGE_INSTALL:append = " bash gdb strace imx-test"` | debug image | hardening-survey section 7 |
| `INIT_MANAGER = "systemd"` | distro | hardening-survey section 7 (systemd 259.5 on wrynose) |
| `DISTRO_FEATURES:remove`, `DISTRO_FEATURES_OPTED_OUT`, `IMAGE_FEATURES:remove` | distro | hardening-survey section 7 (no display stack or audio); removing bluetooth, wifi, nfc and 3g is MISSING |
| `DISTRO`, `DISTRO_NAME`, `DISTRO_VERSION` | distro | MISSING: naming choices of this layer |
| `BBFILES += recipes-*/*/*.bb` | layer.conf | MISSING: no survey covers it |

Reproducible builds and the SBOM stay at Yocto's defaults
(reproducible-build-survey sections 3 and 4, question 5 (a)): the fallback
`SOURCE_DATE_EPOCH`, the fixed `REPRODUCIBLE_TIMESTAMP_ROOTFS` and `create-spdx`
(SPDX 3.0) are on, and the test fails if any file under `platform-image/` sets
the first two or removes the third.

Open, MISSING, and deliberately not set: the `BBFILES += recipes-*/*/*.bbappend`
line in `conf/layer.conf` (no survey covers the search path), `BB_NO_NETWORK`, hash equivalence, the
`SPDX_INCLUDE_*`, `SPDX_INVOKED_BY` and `SPDX_ON_BEHALF_OF` fields
(reproducible-build-survey question 6 has no recommendation), the xkmsd
package (go-xkms has no recipe yet; hardening-survey question 7), and any
login-policy image feature in the production image.

## Kernel hardening fragment

Proposed, pending owner approval (hardening-survey question 1 (c) and question
5 (b)). `platform-image/recipes-kernel/linux/linux-imx_%.bbappend` adds
`files/hardening.cfg` as a kernel-yocto fragment to meta-imx-bsp's
`linux-imx_6.18.bb`, which accepts fragments and rejects
`DELTA_KERNEL_DEFCONFIG` (survey section 5). `test/platform_image_kernel_test.sh`
checks the fragment offline.

| Setting group | Source section | Status |
|---|---|---|
| The "cheap, no expected driver impact" KSPP options with a plain value (`HARDENED_USERCOPY`, the SLAB and page-allocator randomisation, `LIST_HARDENED`, `FORTIFY_SOURCE`, `INIT_ON_ALLOC_DEFAULT_ON`, `DEFAULT_MMAP_MIN_ADDR=65536`, `SLAB_MERGE_DEFAULT`, `LDISC_AUTOLOAD`, `LEGACY_PTYS`, `LEGACY_TIOCSTI` off, and the rest of that list) | hardening-survey section 3 | provisional |
| `DEVMEM`, `DEVPORT`, `KEXEC`, `KEXEC_FILE`, `CRASH_DUMP` off | section 4, question 5 (b) | provisional |
| `PANIC_ON_OOPS=y`, `PANIC_TIMEOUT=-1`, `MAGIC_SYSRQ_DEFAULT_ENABLE=0xb0` | section 3 "behaviour changes", question 5 (b) | provisional |

Dropped because the survey states no usable value: `STATIC_USERMODEHELPER`
(it also needs a helper path, which the survey does not give; an empty path
would block every usermode helper).

Deliberately not set, left to the owner: `MODULES=n` and `MODULE_SIG_FORCE`
with its signing key (questions 2 and 3: out-of-tree BSP modules, key custody
and reproducibility); lockdown (question 4: its debugfs conflict is
unconfirmed, section 6); `COMPAT=n` (vendor binaries may be 32-bit); the
"runtime cost" group; the symbols the survey says 6.18 removed; and every
toolchain-dependent option (`SHADOW_CALL_STACK`, `CFI_CLANG`,
`ARM64_BTI_KERNEL`, `ARM64_MTE`, `KASAN_HW_TAGS`, `UNWIND_PATCH_PAC_INTO_SCS`),
which need a real cross build (sections 3 and 9).

Not verified: no kernel build; no check that the options resolve in 6.18 or
that the BSP drivers survive them (survey section 6, question 2). The survey
gave the SysRq mask as 176 without a base; Kconfig reads that symbol as hex, so
the fragment writes `0xb0` (sync 0x10, remount read-only 0x20, reboot 0x80).

## Verified and not verified

Verified: the lock's hashes were read from their sources; the test runs
offline; the test checks the two image recipes, the BBFILES line, the absence
of overrides of the reproducible and SBOM defaults, and that the fetch script
fails with "checked out X, the lock pins Y" for a pin on an annotated tag
object, against a local stub repository; `meta-imx` at its tag has the machine `imx95-19x19-lpddr5-frdm-pro`
and the `fsl-imx-fb-minimal` distro the file requires.

Also verified, on a build host ([build-host-check.md](build-host-check.md)):
the fetch, `bitbake -p` and `bitbake -e` of both images, and the kernel
`.config` generated by `bitbake linux-imx -c configure`.

Not verified: no image or kernel build; the NXP EULA
(`ACCEPT_FSL_EULA`) is left to the owner.
