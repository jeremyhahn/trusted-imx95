# System Manager configuration: public source survey

Row: `system-manager-config` ([SPEC.md](../SPEC.md)). Issue #33.

This survey covers NXP's System Manager (SM) for the i.MX 95 and how a
board configuration for the FRDM-IMX95-PRO is built and packaged. It uses
public sources only. Everything below is summarised in this repository's own
words. Nothing here was built, flashed, fused or provisioned.

Survey date: 2026-11-12.

## Sources

Each source is cited below by its tag in square brackets.

| Tag | Title | Version surveyed | URL | Reached |
|-----|-------|------------------|-----|---------|
| [SM-REPO] | nxp-imx/imx-sm, "System Manager firmware for i.MX processors" (BSD-3-Clause) | tag `rel_imx_sm_2026q3`, commit `eec232878ab7` (2026-09-03) | https://github.com/nxp-imx/imx-sm | yes, shallow clone |
| [SM-README] | imx-sm `README.md` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/README.md | yes |
| [SM-ARCH] | imx-sm reference manual source, Architecture chapter, `sm/doc/arch.md` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md | yes (first section only) |
| [SM-CFGDOC] | imx-sm reference manual source, Configuration chapter, `sm/doc/config.md` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md | yes (first sections only) |
| [SM-RN] | imx-sm release notes source, additional notes, `sm/doc/rn_add.md` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/rn_add.md | yes |
| [SM-MK] | imx-sm top-level `Makefile` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/Makefile | yes (option handling only) |
| [SM-FRDM] | imx-sm `configs/mx95frdm.cfg` (i.MX95 15x15 FRDM board) | `rel_imx_sm_2026q3`; first added by commit `c4e5f46c16f7` (2026-07-21, "Adds support for iMX95-FRDM-LP5") | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg | yes |
| [SM-PRO] | imx-sm `configs/other/mx95frdm-pro.cfg` (i.MX95 19x19 FRDM PRO) | `rel_imx_sm_2026q3`; also present at `rel_imx_sm_2026q1`, `rel_imx_sm_2026q2`, `lf-6.18.20-2.0.0`; absent at `rel_imx_sm_2025q4` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg | yes |
| [SMCT] | nxp-imx/imx-smct, "System Manager Config Tool CLI" | latest tag `SMCT_26.09.00` | https://github.com/nxp-imx/imx-smct | repository metadata only; contents not read |
| [UBOOT-DOC] | U-Boot, `doc/board/nxp/imx95_frdm.rst`, "U-Boot for the NXP i.MX95 15x15 FRDM board & i.MX95 19x19 FRDM PRO board" | branch `main`, last change 2026-10-24 | https://github.com/u-boot/u-boot/blob/main/doc/board/nxp/imx95_frdm.rst | yes |
| [UBOOT-DEFCONFIG] | U-Boot, `configs/imx95_19x19_frdm_pro_defconfig` | branch `main` (2026-11-12) | https://github.com/u-boot/u-boot/blob/main/configs/imx95_19x19_frdm_pro_defconfig | yes |
| [LINUX-DTS] | Linux, `arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts` | branch `master`, last change 2026-09-03 | https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts | file exists; contents not read |
| [META-SM] | nxp-imx/meta-imx, `meta-imx-bsp/recipes-bsp/imx-system-manager/` (`imx-system-manager.inc`, `imx-system-manager_2026q3.bb`) | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/tree/rel_imx_6.18.37_2.1.0/meta-imx-bsp/recipes-bsp/imx-system-manager | yes |
| [META-MACHINE] | nxp-imx/meta-imx, `meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf` | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf | yes |
| [MKIMAGE] | nxp-imx/imx-mkimage, `iMX95/` directory | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-mkimage/tree/lf-6.18.37-2.1.0/iMX95 | directory exists; contents not read |
| [OEI] | nxp-imx/imx-oei, "Optional Executable Image assembler for i.MX processors" | branch `master` | https://github.com/nxp-imx/imx-oei | repository metadata only |
| [SCMI] | Arm, System Control and Management Interface (DEN0056) | "latest" | https://developer.arm.com/documentation/den0056/latest/ | page answered; contents not read |
| [NXP-PRO] | NXP, FRDM-IMX95-PRO product page | n/a | https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX95-PRO | page answered; contents not read |

Not reached, listed as unconfirmed:

- Issue #33's own text: the lane has no forge credentials, so this survey
  works from the `system-manager-config` row in [SPEC.md](../SPEC.md).
- The rendered *SM Reference Manual* (HTML or PDF). It is built from the
  doxygen sources in [SM-REPO]; it was not built here. Only the chapters named
  above were read, and only in part.
- The NXP-hosted i.MX 95 System Manager user's guide and IMX95RM. NXP's
  documentation portal needs a login; neither was tried.
- The contents of [SMCT], [MKIMAGE], [OEI], [SCMI], [NXP-PRO] and
  [LINUX-DTS] beyond the facts in the table.

## Findings

### What the System Manager is

1. On the i.MX 95 the boot ROM runs on the Cortex-M33. It loads the SM, the
   SM sets up isolation, starts the other cores, and then serves clock,
   power, sensor and pin requests over an SCMI-based RPC interface
   [SM-README], [SM-ARCH].
2. The SM owns the M33. NXP does not support adding customer workloads to
   that core, apart from the optional FuSa components [SM-ARCH]. This matches
   the SPEC rule that the SM stays NXP's code and this repository holds only
   its configuration.
3. The SM splits the SoC into *logical machines* (LMs). Each LM can be booted,
   reset, suspended and powered off on its own. The SM programs the resource
   domain controllers (TRDC) before it starts any other core. Each SCMI agent
   gets per-protocol and per-resource rights, which are compiled into the SM
   binary [SM-ARCH].
4. The SM also owns the PMIC, board sensors and the fault collection unit, and
   applies a configured reaction to each fault [SM-ARCH].
5. Licence: BSD-3-Clause [SM-REPO], [META-SM].

### How a configuration is expressed

6. The configuration is **static**. It is a set of C headers in
   `configs/<CONFIG>/` (`config_lmm.h`, `config_scmi.h`, `config_trdc.h`,
   `config_board.h`, `config_dev.h` and others), selected at build time with
   `config=<CONFIG>`. One board can have several configurations, for example
   one per operating system [SM-CFGDOC].
7. The headers are meant to be generated from a single `.cfg` file by the
   configtool in the repository (`make config=<X> cfg`), not edited by hand
   [SM-README], [SM-CFGDOC]. `config_user.h` is the exception: the tool does
   not overwrite it, and it holds hand-written register sequences for power
   domains that come back up [SM-CFGDOC].
8. NXP also publishes a separate, more complete configuration tool,
   imx-smct [SM-README], [SMCT]. Its contents were not read.
9. LM0 is always the SM itself, and many resources must stay with it
   [SM-CFGDOC].
10. NXP's README says customers usually write their own configuration to split
    resources between the Cortex-A55 and the Cortex-M7 [SM-README].

### What exists for the FRDM-IMX95-PRO

11. The FRDM-IMX95-PRO is the 19x19 i.MX 95 with LPDDR5. U-Boot builds it with
    `imx95_19x19_frdm_pro_defconfig` and the `imx95-19x19-frdm-pro` device
    tree [UBOOT-DOC], [UBOOT-DEFCONFIG], [LINUX-DTS].
12. The SM configuration for this board is `configs/other/mx95frdm-pro.cfg`.
    U-Boot's board document builds it with `make config=other/mx95frdm-pro all`
    [UBOOT-DOC], [SM-PRO]. meta-imx's machine file for the board sets
    `SYSTEM_MANAGER_CONFIG = "mx95frdm-pro"` [META-MACHINE].
13. The `mx95frdm.cfg` at the top of `configs/` is a **different board**, the
    15x15 FRDM. It has its own board port, `boards/mcimx95frdm` [SM-FRDM],
    [SM-RN]. The PRO configuration instead uses the **EVK board port**
    (`board=mcimx95evk`), and its header comment still says "MX95 EVK"
    [SM-PRO].
14. `mx95frdm-pro.cfg` defines these domains and LMs [SM-PRO]:
    - ELE domain (DID 0) and the ISP and V2X domains;
    - LM0 "SM" on the M33;
    - LM1 "M7", with SCMI agent "M7" on MU 9 (CRC32-checked shared-memory
      channels) and its own fault reactions (M7 lockup, M7 reset, WDOG5, and
      SW0 routed to the FuSa reaction);
    - LM2 "AP", the default LM, with SCMI agent "AP-S" (secure) on MU 1 and
      agent "AP-NS" (non-secure) on MU 3.
15. In that file, LM1 (M7) holds the `LMM_2` API with full rights, so the M7
    can control the AP's logical machine through SCMI [SM-PRO]. Nothing read
    here explains what each LMM operation does. The `hsm-self-defence` row
    depends on this, so it needs confirming against the SM manual.
16. Compared with the 15x15 FRDM file at the same tag, the PRO file gives the
    M7 LPUART7 and pins GPIO_IO36/37 and has the PF5301 temperature sensor. It
    also **lacks** the NoC fault entries (`FAULT_MAIN_NOC`, `FAULT_MEGA_NOC`,
    `FAULT_CENTRAL_NOC`, reaction system reset) that the newer FRDM file has.
    Its copyright line is 2023-2025, while the FRDM file's is 2026 [SM-PRO],
    [SM-FRDM]. Whether the missing NoC entries are deliberate is unconfirmed.

### How it is built and packaged

17. The SM builds with the Arm GNU `arm-none-eabi` toolchain. Its output,
    `build/<CONFIG>/m33_image.bin`, goes into imx-mkimage's `iMX95` directory
    and from there into the boot container [SM-README], [MKIMAGE]. U-Boot's
    document uses Arm GNU toolchain 13.3.rel1 [UBOOT-DOC]. The release notes
    name the tested toolchain only as a build-time variable, so the version
    for this tag is unconfirmed [SM-RN].
18. The boot image for this board also needs an ELE (AHAB) container from
    NXP's `firmware-ele-imx` package, LPDDR5 PHY firmware, an OEI DDR image
    built for `mx95lp5-19` from imx-oei, and TF-A `bl31` [UBOOT-DOC].
    U-Boot's document fetches imx-sm and imx-oei from `master`, not from a
    tag [UBOOT-DOC].
19. meta-imx `rel_imx_6.18.37_2.1.0` pins imx-sm to commit `eec232878ab7`,
    the same commit as `rel_imx_sm_2026q3` [META-SM], [SM-REPO].
20. The recipe runs `make clean`, then `make cfg`, then the build, with
    `CONFIG=${SYSTEM_MANAGER_CONFIG}`. It deploys the binary as
    `<basename>-<CONFIG>.bin` [META-SM].
21. The SM Makefile reads `configs/$(CONFIG)/config.mak` [SM-MK]. At
    `rel_imx_sm_2026q3` the PRO configuration exists only as
    `configs/other/mx95frdm-pro.cfg`, with no `configs/mx95frdm-pro/`
    directory. So how meta-imx's `SYSTEM_MANAGER_CONFIG = "mx95frdm-pro"`
    finds it (a bbappend, a copy step, or a configtool rule) is
    **unconfirmed** [META-MACHINE], [SM-PRO], [SM-MK].
22. **Debug monitor.** NXP's release notes say a production SM must be built
    with the debug monitor off (`M=0`). The default is on [SM-RN], [SM-MK].
    The meta-imx recipe defaults `SYSTEM_MANAGER_MONITOR_MODE` to `2`
    [META-SM]. Any non-zero value enables the monitor and links the C library
    [SM-MK], so the stock BSP build is not a production build in NXP's terms.
    What mode 2 does differently from mode 1 is unconfirmed.
23. The Makefile enables RDC (TRDC) programming by default (`R=1`) [SM-MK].
24. The SM releases each quarter (`rel_imx_sm_YYYYqN`), and the Linux BSP
    releases are tagged `lf-*` [SM-REPO]. The release notes say an upgrade
    can require changes to customer configuration files and board ports, and
    always requires regenerating the headers [SM-RN]. A configuration kept
    here therefore has to be rebased on each SM upgrade.

### Not confirmed

- That `other/mx95frdm-pro.cfg` is NXP's supported configuration for
  production use, rather than a demo. It sits in `other/` and runs on the EVK
  board port (finding 13).
- Whether the EVK board port matches the FRDM-IMX95-PRO's PMIC, I2C and
  sensors. The file references PF09, PF5301 and PF5302 sensors and a PCA2131
  RTC, but the board schematics were not checked here.
- The meaning of each LMM operation that `LMM_2` grants to the M7
  (finding 15).
- How meta-imx resolves `mx95frdm-pro` (finding 21) and what monitor mode 2
  does (finding 22).
- Whether the SM image is authenticated as part of the AHAB container on a
  closed device. The SM documentation read here does not say; IMX95RM and the
  security reference manual would.
- Anything specific to IMX95RM, the i.MX 95 Security Reference Manual, or the
  rendered SM manual. None of them were read.

## Questions for the owner

1. **Starting point for this repository's SM configuration.**
   - (a) Copy `configs/other/mx95frdm-pro.cfg` from a pinned imx-sm tag into
     this repository and keep a reviewed diff against it.
   - (b) Use NXP's file as is, through the BSP's `SYSTEM_MANAGER_CONFIG`.
   - (c) Write a new configuration from the 15x15 `mx95frdm.cfg` or with
     imx-smct.

   Recommendation: (a). NXP expects customers to own their configuration
   (finding 10). The PRO file is the only one that targets this board
   (finding 12). A copy here keeps the configuration under this repository's
   review, as SPEC requires, while the SM code stays NXP's.
2. **Which imx-sm version to pin.**
   - (a) `rel_imx_sm_2026q3`, commit `eec232878ab7`, the version meta-imx
     `rel_imx_6.18.37_2.1.0` uses.
   - (b) Track `master`, as U-Boot's board document does.
   - (c) Another tag.

   Recommendation: (a). It is a release tag and matches the current BSP
   (finding 19). `master` is not reproducible.
3. **Which tool generates the headers.**
   - (a) The in-tree configtool (`make cfg`), as meta-imx does.
   - (b) imx-smct.

   Recommendation: (a) until imx-smct has been surveyed. (a) is what the BSP
   runs (finding 20); imx-smct's contents were not read here (finding 8).
4. **Debug monitor in the board image.**
   - (a) Always `M=0`.
   - (b) `M=0` for release images, the BSP default for development images.

   Recommendation: (a) for anything that holds keys, as NXP's release notes
   require for production (finding 22). (b) only if the owner wants a
   development image, and then it must be marked as never shipping.
5. **The M7's control of the AP.** Should LM1 (M7) keep full `LMM_2` rights
   over the AP's logical machine?
   - (a) Keep them; `hsm-self-defence` needs the M7 to stop or reset the
     Cortex-A55.
   - (b) Narrow them to the operations that row needs.
   - (c) Remove them.

   No recommendation until the LMM operations are confirmed in the SM manual
   (finding 15). The sources lean to (a) or (b): the row says the M7 acts
   through the SM.
6. **NoC fault reactions.** Should this repository's configuration add the
   `FAULT_MAIN_NOC`, `FAULT_MEGA_NOC` and `FAULT_CENTRAL_NOC` system-reset
   reactions that the newer 15x15 FRDM file has and the PRO file lacks?
   - (a) Add them.
   - (b) Leave them out, matching NXP's PRO file.

   Recommendation: (a), but only after the owner or NXP confirms the omission
   is not deliberate (finding 16).
7. **Board port.** The PRO file uses the EVK board port. Should the
   repository:
   - (a) accept the EVK port after checking the PRO schematics against it;
   - (b) ask NXP whether a FRDM-PRO port is planned;
   - (c) keep a board port of its own? That would be SM code, which SPEC keeps
     NXP's.

   Recommendation: (a), then (b). (c) conflicts with the SPEC non-goal of not
   replacing NXP's SM.
8. **Missing documents.** May the lane or the owner add the SM Reference
   Manual (built from the pinned tag), IMX95RM and the i.MX 95 Security
   Reference Manual to `references/` or the private vendor context? Several
   open points above need them, including SM image authentication and the
   LMM semantics.

   Recommendation: yes. Building the SM manual from the pinned tag needs only
   public sources (finding 7, [SM-README]).
