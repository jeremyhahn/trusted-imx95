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
  names `soc=MIMX95, board=mcimx95frdm, build=gcc_cross`, the debug UART (instance 2, 115200) and the
  PMIC I2C bus, then describes each domain (ELE, M7, A55 …) with its owner, its access rights and
  the resources it gets (S1 `configs/mx95frdm.cfg`). `config.mak` sets `BOARD ?= mcimx95frdm` and
  `USES_FUSA ?= 1` (S1 `configs/mx95frdm/config.mak`).
- imx-oei's FRDM board is `mx95lp5-15-frdm`, whose base board is "FRDM-IMX95": LPDDR5, 15x15
  package (S2 `boards/ReadMe.txt`). Its board makefile enables ELE support and dummy training data
  (S2 `boards/mx95lp5-15-frdm/Makefile`).
- **Not confirmed:** that the FRDM-IMX95-PRO uses the same SM config and OEI board as the
  FRDM-IMX95. Neither repository names a "PRO" variant at this tag. If the PRO board differs in
  memory, PMIC or debug UART, it needs its own `.cfg` and OEI board port.
- A second tool, imx-smct, can edit SM configurations (S1 `README.md`, S7); the lane did not
  survey it.

## 5. How meta-imx pins imx-sm and the OEI

## 6. From a changed configuration to flash.bin

## 7. How AHAB signs the boot container

## 8. How this repository should pin imx-sm and carry its configuration

## 9. Not confirmed

## 10. Questions for the owner
