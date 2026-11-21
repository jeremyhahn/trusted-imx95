# System Manager build, version pinning and signing: survey

Row: `system-manager-config` ([SPEC.md](../SPEC.md)). Issue #87. Input to #31 and #33.

Status: survey from public sources only. Each claim cites its source. "Not confirmed" marks what the
lane could not check.

## 1. Sources surveyed

All sources were read on 2026-11-12 by a shallow clone of the public repository at the tag named.

| # | Source | Version | URL |
|---|--------|---------|-----|
| S1 | NXP `imx-sm`, the System Manager: `README.md`, `SCR.txt`, `Makefile`, `sm/makefiles/*.mak`, `configs/mx95frdm.cfg`, `configs/mx95frdm/` | tag `lf-6.18.37-2.1.0`, the same commit as `rel_imx_sm_2026q3` (`eec2328`) | https://github.com/nxp-imx/imx-sm |
| S2 | NXP `imx-oei`, the Optional Executable Image: `README.md`, `oei/makefiles/common.mak`, `boards/ReadMe.txt`, `boards/mx95lp5-15-frdm/` | tag `lf-6.18.37-2.1.0` (`9aea335`) | https://github.com/nxp-imx/imx-oei |
| S3 | NXP `imx-mkimage`: `iMX95/soc.mak` | tag `lf-6.18.37-2.1.0` (`b1f801d`) | https://github.com/nxp-imx/imx-mkimage |
| S4 | NXP `meta-imx`, the i.MX Yocto layer | see section 5 | https://github.com/nxp-imx/meta-imx |
| S5 | The list of tags of S1 and S2 (`git ls-remote`) | as of 2026-11-12 | as S1, S2 |
| S6 | Arm GNU Toolchain downloads (named by S1 and S2; not opened) | 15.2.rel1 | https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads |
| S7 | NXP `imx-smct`, the SM configuration tool (named by S1; not opened) | not checked | https://github.com/nxp-imx/imx-smct |
| S8 | Community `meta-freescale`: `conf/machine/include/imx95-evk.inc`, `recipes-bsp/imx-mkimage/imx-boot_1.0.bb`, `dynamic-layers/arm-toolchain/recipes-bsp/imx-system-manager/` | branch `wrynose` (`2d08c05`) | https://github.com/Freescale/meta-freescale |
| S9 | NXP `uboot-imx`: `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt`, `doc/imx/ahab/csf_examples/csf_boot_image_ahab_v2.0.txt` | tag `lf-6.18.37-2.1.0` (`bb41975`) | https://github.com/nxp-imx/uboot-imx |
| S10 | SPSDK, i.MX95 AHAB signing example (named by S9; not opened) | not checked | https://spsdk.readthedocs.io/en/latest/examples/ahab/imx95/imx95_ahab_sign.html |

S4 in detail: NXP `meta-imx` at tag `rel_imx_6.18.37_2.1.0` (`2eb758f`):
`meta-imx-bsp/recipes-bsp/imx-system-manager/`, `recipes-bsp/imx-oei/imx-oei_1.0.0.bb`,
`recipes-bsp/imx-mkimage/imx-boot_1.0.bbappend`, `conf/machine/imx95-19x19-lpddr5-frdm-pro.conf`,
`recipes-devtools/external-arm-toolchain/`.

## 2. How imx-sm is built

- imx-sm is NXP's System Manager: the firmware the Cortex-M33 boot core runs after the boot ROM. It
  sets up isolation, starts the other cores, and then serves clock, power, sensor and pin requests
  over SCMI. It splits the SoC into logical machines (LMs) whose rights are fixed in the
  configuration (S1 `README.md`).
- Releases: two tag series name the same commits. `rel_imx_sm_<year>q<n>` is the SM's own quarterly
  release (from `rel_imx_sm_2023q4_er1` to `rel_imx_sm_2026q3`), and `lf-<kernel>-<bsp>` is the
  NXP Linux BSP release that ships it. The latest of each, `rel_imx_sm_2026q3` and
  `lf-6.18.37-2.1.0`, point at the same commit (S5; S1 `SCR.txt` names the release
  `rel_imx_sm_2026q3`). Licence: BSD-3-Clause, with CMSIS 5.4.0 (Apache-2.0) and two newlib files
  (S1 `SCR.txt`).
- Toolchain: the Arm GNU bare-metal cross compiler `arm-none-eabi`, x86_64 Linux host. The makefiles
  default to version `15.2.rel1` (`TC_VERSION` in `sm/makefiles/common.mak`) and look for it under
  `$(TOOLS)/arm-gnu-toolchain-$(TC_VERSION)-x86_64-arm-none-eabi/`; `SM_CROSS_COMPILE` overrides
  the whole prefix (`sm/makefiles/gcc_cross.mak`). Host packages: `make gcc g++-multilib srecord`;
  hosts named as supported are Ubuntu 20.04, 22.04 and 24.04 (S1 `README.md`). The README says the
  release notes give the exact tested toolchain; the lane did not build the release notes
  (they need doxygen and LaTeX).
- Build: `make config=<name> cfg` regenerates the C headers in `configs/<name>/` from
  `configs/<name>.cfg` (only needed after the `.cfg` changes), and `make config=<name> all` builds
  `build/<name>/m33_image.bin` (S1 `README.md`). The `cfg` step runs the Perl script
  `configs/configtool.pl` (S1 `configs/`), so Perl is a build dependency when the `.cfg` changes.
- NXP says customers normally write their own configuration that splits resources between the
  Cortex-A55 side and the Cortex-M7 (S1 `README.md`).

## 3. How the OEI is built

- The OEI is a small Cortex-M33 image that the boot ROM loads and runs *before* the SM, and which
  returns to the ROM. On i.MX95 it trains the DDR (`oei=ddr`) and can initialise TCM ECC
  (`oei=tcm`). A container can hold more than one (S2 `README.md`).
- Same toolchain and same default version as the SM: `arm-none-eabi`, `TC_VERSION ?= 15.2.rel1`,
  overridable on the make line (S2 `README.md`, `oei/makefiles/common.mak`).
- Build: `make board=<board> oei=ddr` gives `build/<board>/ddr/oei-m33-ddr.bin`, which goes into the
  mkimage `iMX95/` directory (S2 `README.md`). `DEBUG=1` adds the pin mux and debug UART output
  (S2 `README.md`, `boards/mx95lp5-15-frdm/Makefile`).
- The DDR firmware (the LPDDR PHY training blobs, `lpddr5_imem_v202409.bin` and friends) is not in
  imx-oei. mkimage appends it to the OEI image to make `m33-oei-ddrfw.bin` (S3 `iMX95/soc.mak`,
  variables `LPDDR_TYPE`, `LPDDR_FW_VERSION`, target `m33-oei-ddrfw.bin`). Where the blobs come from
  in the BSP (NXP's `firmware-imx` package, under its EULA) was not confirmed by this lane.

## 4. The board configuration for the FRDM-IMX95-PRO

- imx-sm has a FRDM configuration for i.MX95: `configs/mx95frdm.cfg` (about 1000 lines) with its
  generated headers in `configs/mx95frdm/`, and a board port `boards/mcimx95frdm/` (S1). The `.cfg`
  names `soc=MIMX95, board=mcimx95frdm, build=gcc_cross`, the debug UART (instance 2, 115200) and an
  I2C instance, then describes each domain (ELE, M7, A55 …) with its owner, its access rights and
  the resources it gets (S1 `configs/mx95frdm.cfg`). `config.mak` sets `BOARD ?= mcimx95frdm` and
  `USES_FUSA ?= 1` (S1 `configs/mx95frdm/config.mak`).
- imx-oei's FRDM board is `mx95lp5-15-frdm`, whose base board is "FRDM-IMX95": LPDDR5, 15x15
  package (S2 `boards/ReadMe.txt`). Its board makefile enables ELE support and dummy training data
  (S2 `boards/mx95lp5-15-frdm/Makefile`).
- The FRDM-IMX95-PRO is a different board from the FRDM-IMX95. meta-imx describes it as the machine
  `imx95-19x19-lpddr5-frdm-pro`: the 19x19 package with LPDDR5, not the 15x15 FRDM (S4
  `conf/machine/imx95-19x19-lpddr5-frdm-pro.conf`). So the `mx95frdm` SM config and the
  `mx95lp5-15-frdm` OEI board above are **not** the PRO's.
- The PRO's SM configuration is `configs/other/mx95frdm-pro.cfg` (there is also an Android variant,
  `configs/other/mx95frdm-pro-android.cfg`). It names `board=mcimx95evk`, so it reuses the 19x19 EVK
  board port, not the FRDM one, and it has no pre-generated header directory, unlike the configs
  at the top of `configs/` (S1 `configs/other/`). `make config=mx95frdm-pro cfg` still finds it:
  `configs/configtool.pl` falls back to `configs/other/<name>.cfg` when `configs/<name>.cfg` does
  not exist, and writes the headers to `configs/mx95frdm-pro/` (S1 `configs/configtool.pl`,
  `sm/makefiles/configtool.mak`). Its debug UART and I2C settings match
  the FRDM's (instance 2 at 115200; I2C instance 1) (S1).
- The PRO's OEI board is `mx95lp5`, the 19x19 EVK LPDDR5 board, with the DDR timing
  `MIMX95_LPDDR5_EVK_19X19_6400MTS_FW2024.09_timing` (or the `_ECC_enabled_` one) and the 2024.09
  LPDDR5 training firmware (S4 machine conf, `OEI_BOARD`, `OEI_DDR_CONFIG`, `DDR_FIRMWARE_NAME`).
  So, in NXP's BSP, the PRO's DDR is set up as the 19x19 EVK's.
- A second tool, imx-smct, can edit SM configurations (S1 `README.md`, S7); the lane did not
  survey it.

## 5. How meta-imx pins imx-sm and the OEI

Sources: S4, NXP `meta-imx` at tag `rel_imx_6.18.37_2.1.0` (`2eb758f`, branch
`wrynose-6.18.37-2.1.0`), and S8, the community `meta-freescale` at branch `wrynose` (`2d08c05`),
https://github.com/Freescale/meta-freescale. meta-imx's machine file requires
`imx95-evk.inc` from meta-freescale.

- **Pinning is by commit, not by tag.** The recipe `imx-system-manager_2026q3.bb` fetches
  `github.com/nxp-imx/imx-sm` on branch `master` and sets `SRCREV = eec2328…`, which is the commit of
  both `rel_imx_sm_2026q3` and `lf-6.18.37-2.1.0` (S4, S5). `imx-oei_1.0.0.bb` does the same for
  imx-oei with `SRCREV = 9aea335…`, the commit of `lf-6.18.37-2.1.0` (S4, S5). The recipe file name
  carries the SM quarter (`_2026q3`); the OEI recipe's `1.0.0` does not track releases.
- meta-freescale `wrynose` carries an older SM recipe, `imx-system-manager_2026q1.bb`, pinned to
  `c450f53…` (`rel_imx_sm_2026q1`) (S8). With both layers, BitBake takes the higher version, the
  2026q3 recipe from meta-imx (standard BitBake version selection; not checked against layer
  priorities here).
- Toolchain: both recipes build with `gcc-arm-none-eabi-native` and pass
  `SM_CROSS_COMPILE=arm-none-eabi-` / `OEI_CROSS_COMPILE=arm-none-eabi-`, overriding the makefiles'
  `$(TOOLS)` path (S4). meta-imx packages that toolchain as
  `recipes-devtools/external-arm-toolchain/gcc-arm-none-eabi_15.2.rel1.bb`, the same version as the
  makefiles' default (S4, S1).
- Which config: the variable `SYSTEM_MANAGER_CONFIG`. `imx95-evk.inc` derives it from
  `IMXBOOT_VARIANT` (`mx95evk` by default, or `mx95alt`, `mx95evkjailhouse`, `mx95netc`,
  `mx95evkrpmsg`, `mx95evksof`) (S8 `conf/machine/include/imx95-evk.inc`). The PRO machine file then
  sets it outright to `mx95frdm-pro` (S4 machine conf). The recipe runs `make clean`, `make cfg`, then
  the build, and deploys `build/<config>/<basename>.bin` as `<basename>-<config>.bin`
  (S4 `imx-system-manager.inc`). It passes `M=2` for the debug monitor mode by default
  (`SYSTEM_MANAGER_MONITOR_MODE ??= "2"`, S4); the SM Makefile's own default is `M=1` (S1 `Makefile`).
  The monitor is a debug console on the M33 UART; whether a production image should keep it is
  question 4 below.
- The OEI recipe builds `oei=ddr` (and `tcm` if asked) for `OEI_BOARD`, passes the DDR timing named
  by `OEI_DDR_CONFIG`, and **always passes `DEBUG=1`** (S4 `imx-oei_1.0.0.bb`).
- Because `make cfg` always runs, the generated headers in imx-sm are always rebuilt from the `.cfg`
  in a Yocto build; the `.cfg` is the one source of truth (S4, S1).

## 6. From a changed configuration to flash.bin

Sources: S1, S3, S4, S8 (`recipes-bsp/imx-mkimage/imx-boot_1.0.bb`).

1. Edit the `.cfg` (for the PRO, `mx95frdm-pro.cfg`). Run `make config=<name> cfg` to regenerate the
   headers, then `make config=<name> all` to build `m33_image.bin` (S1). In Yocto, the
   `imx-system-manager` recipe does both on every build and deploys
   `<basename>-<config>.bin` (S4).
2. Build the OEI for the board's DDR (`oei-m33-ddr.bin`) (S2; S4 `imx-oei`).
3. `imx-boot` copies the deployed SM binary into mkimage's `iMX95/` directory as `m33_image.bin`,
   with the OEI images, the ELE firmware container, the DDR training firmware, SPL, TF-A and
   U-Boot (S8 `compile_mx95`, `compile_mx93`). It runs mkimage with `OEI=YES`,
   `LPDDR_TYPE=<DDR_TYPE>`, and for the PRO also the FlexSPI header for the W25Q512NWEIQ NOR flash
   (S8 `MKIMAGE_EXTRA_ARGS:imx95-19x19-lpddr5-frdm-pro`).
4. mkimage builds `flash.bin`. For the PRO's default SD/eMMC boot the targets are `flash_all` and
   `flash_a55`; with `UBOOT_CONFIG = "fspi"` it is `flash_a55_flexspi` (S8 `imx95-evk.inc`; S4
   machine conf). `flash_a55`, for example, does this (S3 `iMX95/soc.mak`):
   - appends NXP's prebuilt ELE firmware container `mx95b0-ahab-container.img` (`-append`);
   - builds a new container (`-c`) holding the OEI with its DDR firmware appended
     (`m33-oei-ddrfw.bin`), the SM (`-m33 m33_image.bin` loaded at the M33 TCM, `0x1FFC0000`) and
     the Cortex-A55 SPL (and a V2X placeholder);
   - appends the `u-boot-atf-container.img` container (TF-A, U-Boot, and OP-TEE if present) on the
     next 1 KiB boundary.
   Other targets differ in what they put beside the SM: `flash_lpboot` only the M33 image;
   `flash_m7` adds the Cortex-M7 image from TCM (S3). `flash_a55` and `flash_a55_flexspi` carry
   **no** Cortex-M7 image, so an image built with them boots the A55 without the M7 tamper
   responder (docs/SPEC.md, `hsm-self-defence`) while still passing any signature check. This
   project's release image must use a target that includes the M7 image (for SD/eMMC, `flash_all`),
   and host acceptance rejects an OEM boot container without it
   ([dev-boot-workflow-survey.md](../boot-container/dev-boot-workflow-survey.md), "Container
   roles", fixture N12).
5. So a changed SM configuration goes into flash only by rebuilding `m33_image.bin` and then
   rebuilding the whole boot container. There is no separate SM configuration blob: the
   configuration is compiled into the SM (S1: the `.cfg` becomes C headers).

## 7. How AHAB signs the boot container

Sources: S9, NXP `uboot-imx` at tag `lf-6.18.37-2.1.0` (`bb41975`),
https://github.com/nxp-imx/uboot-imx: `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt`,
`doc/imx/ahab/csf_examples/csf_boot_image_ahab_v2.0.txt`. S10, the SPSDK i.MX95 AHAB example named
by S9 (not opened): https://spsdk.readthedocs.io/en/latest/examples/ahab/imx95/imx95_ahab_sign.html.

- Container layout on i.MX95, as S9 draws it: the first part of `flash.bin` is authenticated by the
  ELE ROM and firmware. It holds the NXP containers (ELE firmware, and the V2X firmware) and then the
  boot container with the **OEI, the Cortex-M image (the SM) and SPL**. The last container, TF-A
  and U-Boot, is authenticated later by SPL through ELE (S9 section 1.3).
- Which key: the ELE firmware container is signed with NXP's keys. The container that holds the OEI,
  the SM and SPL is signed with the **OEM's keys**: its signature block carries the OEM's SRK table
  (four public keys, one chosen by index) and the signature, optionally through a subordinate
  signing key (SGK) certificate (S9 sections 1.3, 1.4). This is the container a changed SM
  configuration lives in, so **every SM change needs a re-signature of that container with the
  OEM SRK** (or its SGK), and then of nothing else: the U-Boot/TF-A container is signed on its own
  (S9 section 1.4.1).
- i.MX95 B0 and later use AHAB 2.0. Its CSF example declares `Version = 2.0` (a hybrid container),
  an SRK certificate whose file name says SHA-384, P-384 and ML-DSA-65, `Source set = OEM`, and the container and signature
  block offsets that mkimage prints (S9 `csf_boot_image_ahab_v2.0.txt`). The signing tool is SPSDK
  (NXP's recommended tool for i.MX9x) or CST 4.0.1, which NXP keeps on bug fixes only (S9
  section 1.1).
- Order: sign `u-boot-atf-container.img` first, then build `flash.bin` with it, then sign the boot
  container in `flash.bin` (S9 section 1.4.1).
- This survey does not describe fusing the SRK hash or closing the life cycle; both are out of
  scope for this row and this document.

## 8. How this repository should pin imx-sm and carry its configuration

Proposal for #31 and #33, from sections 2 to 7. Each point is a recommendation, not a decision.

1. **Pin imx-sm by commit, named by its tag.** Follow meta-imx: `SRCREV` set to the commit, with
   the `rel_imx_sm_<quarter>` and `lf-…` tag in a comment. Start from `rel_imx_sm_2026q3` /
   `lf-6.18.37-2.1.0` (`eec2328`), which is what NXP's current BSP ships (S4, S5). Pin imx-oei
   (`9aea335`) and imx-mkimage (`b1f801d`) from the same BSP release, since mkimage's container
   layout and the OEI/SM interfaces move together.
2. **Carry the configuration as one `.cfg` file, derived from `mx95frdm-pro.cfg`.** The `.cfg` is
   the source; the generated headers are not (the recipe regenerates them on every build, S4).
   Keep NXP's file unmodified as a baseline copy beside ours, so a diff shows exactly what this
   repository changed, and so a new NXP release can be compared and merged.
3. **Bring it into the build without forking imx-sm:** a `bbappend` for `imx-system-manager` that
   adds the `.cfg` to `SRC_URI`, copies it into `configs/` before `do_configure`, and sets
   `SYSTEM_MANAGER_CONFIG` to its name. Because `configtool.pl` looks in `configs/` before
   `configs/other/` (S1), a file of a new name never collides with NXP's. This keeps SPEC's rule
   that the SM stays NXP's code and the repository holds only its configuration.
4. **Pin the toolchain** to Arm GNU `15.2.rel1`, the version the makefiles and meta-imx name (S1,
   S4), and record its checksum.
5. **Re-sign on every configuration change.** The SM is in the OEM-signed boot container (section
   7), so the signing step (#33) must run after any SM rebuild, with SPSDK and AHAB 2.0.
6. **Decide the debug settings for production** (monitor mode, OEI `DEBUG=1`): see questions 4, 5.

## 9. Not confirmed

- That `make config=mx95frdm-pro` builds cleanly at `eec2328` with `board=mcimx95evk`: the lane read
  the sources but built nothing.
- The exact tested toolchain in the SM release notes (the README defers to them; the lane did not
  build them). The makefiles' default `15.2.rel1` is confirmed.
- Whether V2X firmware sits in its own NXP-signed container in `flash.bin` on the PRO; S9's figure
  shows it beside the ELE firmware, but the lane did not read the AHAB container itself.
- The exact CSF offsets for an i.MX95 `flash.bin`: they come from mkimage's output at build time.
- The SPSDK example (S10), the imx-smct tool (S7), the SM reference manual (built from imx-sm with
  doxygen) and NXP's i.MX Linux User's Guide and Security Reference Manual were not opened.
- Where the LPDDR5 training firmware and `mx95b0-ahab-container.img` come from in the BSP (likely
  `firmware-imx` and `firmware-ele-imx`, under NXP's EULA), and their versions.
- Which FRDM-IMX95-PRO hardware revision the `mx95frdm-pro.cfg` targets, and whether the owner's
  board matches it.

## 10. Questions for the owner

1. **Which imx-sm release to pin?**
   (a) `rel_imx_sm_2026q3` = `lf-6.18.37-2.1.0` (`eec2328`), the current BSP's;
   (b) an older BSP's (`lf-6.12.49-2.2.0`, for example) to match an existing Yocto base;
   (c) follow `master`.
   Recommendation: (a), pinned by commit; move only with a whole BSP release (sources S4, S5).
2. **How to carry the configuration?**
   (a) a `.cfg` plus a `bbappend` that drops it into `configs/` (section 8.3);
   (b) a fork of imx-sm with our config committed;
   (c) a patch file against NXP's `mx95frdm-pro.cfg`.
   Recommendation: (a); it keeps the SM NXP's code, as SPEC requires. (c) is a fallback if the
   owner wants the delta in patch form.
3. **Which base for our `.cfg`?**
   (a) `configs/other/mx95frdm-pro.cfg`, what NXP's BSP builds for this board;
   (b) `mx95evk.cfg`; (c) `mx95frdm.cfg` (15x15 FRDM, a different board).
   Recommendation: (a) (S4 machine conf).
4. **SM debug monitor in production?** NXP's Yocto build passes `M=2` (S4).
   (a) keep it; (b) `M=0`, no monitor; (c) keep it in development images only.
   Recommendation: (c), with `M=0` in signed release images. This is the lane's inference, not a
   source's: a debug console on the M33, which owns clocks, power and resources (S1 `README.md`),
   looks at odds with `hsm-self-defence`. The sources do not say what each mode
   exposes beyond "debug monitor"; the SM reference manual should be read first.
5. **OEI `DEBUG=1` in production?** The meta-imx recipe always sets it (S4).
   (a) keep NXP's recipe; (b) override to `DEBUG=0` in a `bbappend`.
   Recommendation: (b) for release images, once a non-debug OEI is shown to train the DDR.
6. **Signing tool?** (a) SPSDK; (b) CST 4.0.1.
   Recommendation: (a), NXP's recommended tool for i.MX9x and AHAB 2.0 (S9).
7. **Boot device?** (a) SD/eMMC; (b) FlexSPI NOR (W25Q512NWEIQ header). NXP's PRO machine
   builds `flash_a55` and `flash_a55_flexspi` for these, but both leave out the Cortex-M7 image
   (§6 step 4), so neither is acceptable as the release target: (a) uses `flash_all`, and for (b)
   a FlexSPI target that includes the M7 image is **unconfirmed** (S3 not read for one) and must be
   found or added before (b) can be chosen. The SM and its signature are the same in both; only
   the container placement differs (S3, S8). No recommendation from the sources; it is a product
   decision for #31.
8. **Is the Cortex-M7 image in the boot container (`flash_m7`-style) or loaded later?** It decides
   which container the M7 firmware of trusted-firmware's `imx95` row is signed in. No recommendation
   from the sources.
