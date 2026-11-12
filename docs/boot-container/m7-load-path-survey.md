# Cortex-M7 image packaging and load path on the i.MX 95: survey

Row: boot-container (issue #71). Documentation only; public sources only.

## 1. Scope and method

The question (issue #71): how the Cortex-M7 image of trusted-firmware's `imx95` row gets into the
i.MX 95 boot image and starts, which agent loads it, where it runs, when AHAB checks its signature,
whether the M7 can be restarted with a new image at run time without defeating that check, and what
this repository hands to trusted-firmware and takes from it.

Method: the public NXP GitHub repositories were cloned at a release tag and the relevant build
files and sources were read; nothing was built or run on hardware. Everything below is a summary in
this repository's words, with the file and tag it comes from. Where a claim rests on a source that
could not be read here, it is marked **unconfirmed** and repeated in §9.

## 2. Sources surveyed

| Id | Source | Version / tag | URL |
|----|--------|---------------|-----|
| S1 | imx-mkimage, `iMX95/soc.mak` | `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37-2.1.0/iMX95/soc.mak |
| S2 | imx-sm (System Manager) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3 |
| S3 | imx-oei (Optional Executable Image) | `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-oei/tree/lf-6.18.37-2.1.0 |

Further rows are added in the sections that use them.

## 3. Packaging: imx-mkimage options for the M7 image

From S1 (`iMX95/soc.mak`, tag `lf-6.18.37-2.1.0`):

- The M7 image enters the boot image through mkimage's `-m7 <file> <core-id> <load-addr> <entry-alias>`
  option, beside `-m33` (the System Manager, `m33_image.bin` by default, `MCU_IMG`) and `-ap` (the
  Cortex-A55 SPL). The default M7 file name is `m7_image.bin` (`M7_IMG`). The M7 image is one
  more image entry in the **same first container** as the System Manager and the A55 SPL; it is not
  a container of its own in the default flows.
- The container is built with `-soc IMX9 -cntr_version 2` on B0 silicon (`CTNR_VERSION`), and the
  EdgeLock firmware container (`mx95b0-ahab-container.img`, `AHAB_IMG`) is placed in front of it with
  `-append`. The `*_no_ahabfw` variants omit the EdgeLock firmware container.
- Load address choices for the M7, all as `soc.mak` defaults that a caller can override:
  - **TCM** (`flash_m7`, `flash_all`, `flash_singleboot_all`): load at `M7_TCM_ADDR=0x0` (the M7's
    own view of its ITCM) with the alias `M7_TCM_ADDR_ALIAS=0x303C0000` (the same TCM seen from the
    System bus, which is where the loader writes it).
  - **DDR** (`flash_m7_ddr`, `flash_all_ddr`, `flash_all_ddr_flexspi`): load and entry at
    `M7_DDR_ADDR=0x80000000`, the bottom of DDR. The DDR must be trained before this image is copied,
    which in these flows is done by the OEI (`-oei m33-oei-ddrfw.bin ...`, see §4).
  - **FlexSPI NOR execute-in-place** (`flash_m7_flexspi_xip`): the image stays in NOR at
    `M7_XIP_ADDR=0x28132000` (`-fileoff 0x131000`); nothing is copied.
- The `flash_lpboot_sm_*` names are aliases of the targets above (`flash_lpboot_sm_m7` is `flash_m7`,
  `flash_lpboot_sm_all` is `flash_all`, and `flash_evk` is `flash_lpboot_sm_all`). "lpboot" is the
  flow where the Cortex-M33 boots first and runs the System Manager.
- A separate target, `flash_bootaux_cntr`, wraps the M7 image alone in a container whose second
  address is the M7 TCM as seen from the A55 (`M7_TCM_ADDR_ACORE_VIEW=0x203C0000`); its XIP twin is
  `flash_bootaux_cntr_xip`. The name points to U-Boot's `bootaux` command (§7).
- `-sw_version` (the AHAB anti-rollback version) is passed only to the A55 `u-boot-atf-container.img`
  when `ROLLBACK_INDEX_IN_CONTAINER` is set; the first container (System Manager + M7 + SPL) gets no
  `-sw_version` in `soc.mak`, so its version field is mkimage's default.

## 4. Which agent loads the M7 and starts it

Sources: S1; S2 `sm/doc/arch.md`, `sm/doc/config.md` (section "Configtool Commands") and
`configs/mx95frdm.cfg` (the 15x15 FRDM-IMX95 configuration; **reference only**: this device, the
19x19 FRDM-IMX95-PRO, uses `configs/other/mx95frdm-pro.cfg` with the EVK board port, see
`docs/system-manager-config/public-source-survey.md` items 11-16; every LM1 value below taken from
`mx95frdm.cfg` is unconfirmed for the PRO unless that survey states it), all at
`rel_imx_sm_2026q3`.

There are three agents, each with one job:

1. **Boot ROM on the Cortex-M33, with the EdgeLock enclave (ELE).** In the lpboot flows of S1 the
   M33 is the boot core. The ROM reads the first container (System Manager, optional OEI, M7, A55
   SPL), runs the OEI first when one is present (it trains the DDR; S2 `arch.md` notes that the DDR
   controller and PHY are first set up by a DDR firmware the M33 ROM calls), and copies each image
   entry to the load address mkimage wrote for it. That the ROM copies **every** image entry of the
   container, including the M7 one, before the System Manager runs, and that it asks the ELE to
   authenticate them in the same pass, is how NXP's container format works on i.MX 8ULP/i.MX 93 and
   what the `-m7 ... <alias>` argument implies, but the i.MX 95 Reference Manual's boot chapter
   could not be read here: **unconfirmed** for the i.MX 95 (§9, U1).
2. **System Manager on the Cortex-M33.** The SM does not copy images. It starts *logical machines*
   (LMs) in a configured order once it has set up the TRDC isolation. In `mx95frdm.cfg` the M7 is
   `LM1 name="M7"`, `boot=2` (started second, after the SM itself and before the A55 LM, which has
   `boot=3`), `skip=1`, DID 4, safety type `seenv`. Its start sequence powers `PD_M7` and then
   starts `CPU_M7P`. Per `config.md`, `skip` set to non-zero tells the SM to ignore the error when
   the boot container holds no image for that LM, so the stock FRDM SM boots with or without an
   M7 image in the container.
3. **U-Boot (`bootaux`) or Linux (remoteproc).** These are the later, optional loaders (§7). In the
   NXP default flow they are not involved: the M7 is running before the A55 SPL starts.

The OEI is not an M7 loader: on B0 silicon `soc.mak` includes only the DDR OEI; the TCM-init OEI
(`oei-m33-tcm.bin`) is used on A0/A1 silicon only, where the comment says it is needed to load an M7
TCM image (S1, the `ifeq ($(LC_REVISION),a1)` blocks).

Other facts of the FRDM M7 LM that matter to trusted-firmware (S2 `mx95frdm.cfg`):

- The M7 talks SCMI to the SM over MU 9 (`SCMI_AGENT0 name="M7"`), with three SMT channels
  (a2p, notify, priority), CRC32 checked.
- It owns `MU_ELE5`, a messaging unit to the EdgeLock enclave of its own; S2 `arch.md` says security
  functions do not go through the SM and that clients talk to the ELE directly.
- It has `LMM_2 ALL`, i.e. the LMM protocol rights over LM 2 (the A55): the M7 can boot, reset and
  shut down the A55 LM. The reverse right is narrower: the A55 secure agent (`AP-S`, TF-A) has no `LMM_1` entry and
  the A55 non-secure agent (`AP-NS`, Linux) has `LMM_1 NOTIFY` only, so in the stock FRDM
  configuration Linux is told of M7 LM state changes but cannot boot or reset the M7 LM through
  the SM.
- Its TRDC memory grants are the M7MIX TCM ranges and `DDR EXEC 0x80000000-0x89FFFFFF`.
- Faults `FAULT_M7_LOCKUP`, `FAULT_M7_RESET`, `FAULT_WDOG5` have the reaction `lm_reset` (the SM
  resets the M7 LM, not the SoC).

## 5. Where the M7 image runs: TCM or DDR

Sources: S1, S2 `mx95frdm.cfg`.

| Option | mkimage target (S1) | Load / entry | What it needs | Notes |
|--------|---------------------|--------------|---------------|-------|
| TCM | `flash_m7`, `flash_all` (= `flash_lpboot_sm_all`, the EVK default) | `0x0` in the M7 view, written at `0x303C0000` | nothing before it | The size comes from the M7MIX ranges the SM grants the M7 (`0x20380000-0x2047FFFF` and `0x4A060000-0x4A09FFFF` in the 15x15 `mx95frdm.cfg`, reference only; the PRO file's ranges are **unconfirmed**); the split of those into ITCM and DTCM, and their exact sizes, are in IMX95RM, not read (**unconfirmed**, U2). |
| DDR | `flash_m7_ddr`, `flash_all_ddr` | `0x80000000` | the DDR OEI in the same container, so the DDR is up before the copy | The FRDM SM grants the M7 `DDR EXEC 0x80000000-0x89FFFFFF` (160 MiB). The same range overlaps the ELE domain's `DDR DATA` and the V2X domain's read-only range in that file; the A55 and Linux memory map must keep out of it. |
| NOR XIP | `flash_m7_flexspi_xip` | `0x28132000` | FlexSPI NOR boot | Executes from flash; the FRDM board's boot media are not surveyed here. |

TCM is NXP's default (the `flash_all` target and the `flash_evk` alias). For trusted-firmware's M7
core the choice is the linker script's: the image has to be linked for the address passed to `-m7`.

## 6. AHAB: when the M7 image's signature is checked

Sources: S4 and S5 below; S1; S2 `arch.md`.

| Id | Source | Version / tag | URL |
|----|--------|---------------|-----|
| S4 | U-Boot (NXP fork), `doc/imx/ahab/introduction_ahab.txt` | `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/doc/imx/ahab/introduction_ahab.txt |
| S5 | U-Boot (NXP fork), `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` | `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |

- **One signature for the whole first OEM container.** S5 shows the i.MX 95 image: an NXP-signed
  container with the ELE (and V2X) firmware, then the OEM container that holds the OEI, the
  "Cortex-M image" and the SPL, authenticated "at ELE ROM/FW level", then the ATF/U-Boot container
  that the SPL authenticates. On AHAB the signature block sits inside the container and signs the
  container header together with the SRK table; the header carries the image entries (S5 §1.3).
  The image data is bound through the per-image hash in the header (the AHAB container format),
  so the M7 image is covered by the same signature as the System Manager and the SPL. In S1 the
  M7 image is in that container (§3), so re-signing the M7 image means re-signing that container.
- **When.** S4 §1.4 describes the 8ULP/9x flow: the core that boots loads each image and asks the
  ELE to authenticate it before the image is started; the Cortex-M is started only after its
  firmware is authenticated. For the i.MX 95 lpboot flow this means the M33 boot ROM loads the M7
  image to its load address and the ELE checks it during the ROM phase, before the System Manager
  runs and long before the SM starts LM1. The exact i.MX 95 ROM sequence (whether the ROM checks
  the whole container before it copies, or image by image) is in the i.MX 95 Security Reference
  Manual, which is not public: **unconfirmed** (U1).
- **Signing tool.** S5 §1.1 says the i.MX 95 from B0 onwards uses AHAB 2.0 and needs SPSDK or CST
  4.0.1, and recommends SPSDK; CST is in maintenance. SPEC.md names CST 3.1.0; whether CST 3.1.0
  supports AHAB 2.0 is a question for the owner (Q4).
- **Anti-rollback.** S1 passes `-sw_version` only to the ATF/U-Boot container. Setting a version on
  the container that holds the M7 means adding `-sw_version` to the first-container mkimage call
  (an option mkimage already takes, as the U-Boot container shows). That field alone does not
  protect the M7: the ELE enforces only the fuse version, and the software check of `-sw_version`
  runs in A55 SPL, after the M7 has started (`anti-rollback-survey.md` §2.1, §2.2). The mechanism
  that enforces a floor before the M7 executes is **unconfirmed** (U3, Q5).
- **Isolation after the check.** S2 `arch.md` says the SM reloads the TRDC configuration through
  ELE messages when a mix powers up and that the configuration "can change ... if code is being
  reloaded and authenticated". The TRDC grants of §4 (M7 DID 4, its TCM and DDR ranges) are what
  keep other masters from rewriting the authenticated M7 image after the check.

## 7. Restarting the M7 with a new image at run time

Sources: S2 `mx95frdm.cfg`; S6 and S7 below (commit messages, read through the GitHub API; the
driver code itself was not read for this survey).

| Id | Source | Version / tag | URL |
|----|--------|---------------|-----|
| S6 | linux-imx, `drivers/remoteproc/imx_rproc.c` history: commits 690d4a4477 "Add support for System Manager API", bfc2f4ccc6 "Add support for i.MX95", a477285239 "Pass bootaddr to SM CPU/LMM reset vector" | in `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/linux-imx/commits/lf-6.18.37-2.1.0/drivers/remoteproc/imx_rproc.c |
| S7 | uboot-imx, `arch/arm/mach-imx/imx9/imx_bootaux.c` history: commits c2fecfb1f1 "support kick M7 from AP", a72131dad1 "imx9: bootaux: Update container header check in authentication" | in `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/commits/lf-6.18.37-2.1.0/arch/arm/mach-imx/imx9/imx_bootaux.c |

Three ways to put a new image on the M7 after boot, and what each does to the AHAB check:

1. **System Manager LM reset (no new image).** The SM resets LM1 on its own faults (`lm_reset`,
   §4) and on an LMM-protocol request from an agent that holds `LMM_1` rights. This restarts the
   M7 from what is already in TCM or DDR; it loads nothing. Whether an LM reset makes the SM reload
   and re-authenticate the M7 image from the boot container, or only restarts the CPU on the image
   in memory, could not be confirmed without reading the SM source (**unconfirmed**, U4); the
   `skip` option ("no image in boot container", §4) shows the SM at least consults the boot
   container's record at LM boot.
2. **U-Boot `bootaux`.** S7 shows two modes on i.MX 9. A raw binary copied into the M7 TCM
   (`0x203C0000`, the A55 view) and started with `bootaux` is not authenticated: the example in
   c2fecfb1f1 is a plain copy. A container built with S1's `flash_bootaux_cntr` target is
   authenticated: a72131dad1 describes the checks U-Boot makes on the container header before it
   asks for authentication, and limits the image destination and entry to DDR, TCM or FlexSPI. A
   signed M7 container loaded this way keeps the AHAB chain (same SRK, checked by the ELE).
3. **Linux remoteproc.** S6 describes three i.MX 95 cases: the M7 in its own LM that Linux cannot
   control; the M7 in its own LM that Linux controls with the SM's LMM protocol; and the M7 in the
   A55's LM, controlled with the CPU protocol. The driver passes the boot address to the SM on each
   start (a477285239), and relies on U-Boot for the M7 TCM ECC initialisation (690d4a4477).
   Nothing in these commit messages says Linux asks the ELE to authenticate the firmware it loads:
   remoteproc writes the ELF from the file system into TCM/DDR itself. A Linux reload is therefore
   **outside the AHAB chain** unless something else (for example a signed root file system) covers
   the firmware file; that the driver does no ELE authentication is **unconfirmed** at code level
   (U5). In the stock FRDM SM configuration Linux is in the first case: `AP-NS` has
   `LMM_1 NOTIFY` only (§4), so Linux cannot restart the M7 at all.

Answer to the issue's question: the M7 can be restarted at run time with a new image *and* keep
AHAB's guarantee only through a loader that hands a signed container to the ELE (U-Boot `bootaux`
with `flash_bootaux_cntr`). The Linux remoteproc path and a raw `bootaux` do not keep it. The
boot-time path (ROM + ELE, then SM) keeps it by construction.

## 8. Interface with trusted-firmware

What this repository (boot-container, with system-manager-config) must **hand to** trusted-firmware's
`imx95` row:

- The load address and size budget of the M7 image: `0x0` (TCM, M7 view) or `0x80000000` (DDR),
  from §5, and the TCM sizes once IMX95RM confirms them (U2). trusted-firmware links for it.
- The SM side of the M7 LM: SCMI agent on MU 9 with its three SMT channels, the resources and
  SCMI API rights the M7 holds (§4), its TRDC memory grants, and its fault reactions. These are
  this repository's (`system-manager-config`), and the M7 firmware's SCMI client must match them.
- `MU_ELE5`, the M7's own messaging unit to the EdgeLock enclave, if the M7 is the side that calls
  the HSM API (SPEC.md row `secure-key-handling` leaves that open).
- The signing and version rules: which container the image goes in, the `-sw_version` value it is
  signed with, and that the image is signed by this repository's signing flow, not by
  trusted-firmware.

What it must **take from** trusted-firmware:

- `m7_image.bin`, a raw binary linked for the agreed address (S1's `-m7` takes a binary). An ELF
  with a resource table is needed only if the Linux remoteproc path is chosen (S6).
- The image's version number, for the container's `-sw_version` (anti-rollback, U3).
- The list of SCMI resources, clocks, power domains and peripherals the M7 firmware uses, so that
  LM1 of this device's `mx95frdm-pro.cfg` can be trimmed to them.
- Whether the firmware expects the TCM ECC to be initialised by an earlier stage (S6 says Linux
  relies on U-Boot for this when it starts the M7).

## 9. Not confirmed

- **U1** The i.MX 95 boot ROM's exact order (load all images of the container, then authenticate;
  or image by image) and that it, not the SM, copies the M7 image. Needs the i.MX 95 Reference
  Manual boot chapter and the Security Reference Manual (SPEC.md lists both as missing). S4 gives
  the 8ULP/9x general flow only.
- **U2** The M7 ITCM/DTCM sizes and their split in the ranges S2 grants. Needs IMX95RM.
- **U3** Which mechanism enforces a version floor on the M7's container before the M7 executes
  on the i.MX 95, and what floor it protects. The ELE is documented to check only the fuse
  version; nothing read here shows it checking `-sw_version`. Needs the Security Reference Manual.
- **U4** Whether an SM LM reset of the M7 reloads and re-authenticates the image or only restarts
  the CPU. Needs a code-level read of imx-sm's `sm/lmm` and device boot code at
  `rel_imx_sm_2026q3`.
- **U5** That Linux's `imx_rproc` does no ELE authentication of the firmware it loads. Based on the
  commit messages in S6, not on the code.
- **Not reached:** NXP's *i.MX Linux User's Guide* PDF (`IMX_LINUX_USERS_GUIDE.pdf` on nxp.com)
  returned an error from the lane, so its M7 boot and remoteproc chapters were not read. The Linux
  device-tree binding `fsl,imx-rproc.yaml` was downloaded but not read in this lane.

## 10. Questions for the owner

1. **Where does the M7 image run?**
   Options: (a) TCM at `0x0`, NXP's default target `flash_all`; (b) DDR at `0x80000000`
   (`flash_all_ddr`), larger but shared with the DDR used by the ELE and V2X domains in the FRDM SM
   configuration; (c) FlexSPI NOR XIP.
   Recommendation: (a) TCM, if trusted-firmware's M7 core fits once U2 gives the size; it keeps the
   M7 out of DDR, which other masters share, and it is NXP's default (S1).
2. **Which agent loads the M7 image?**
   Options: (a) boot ROM + ELE in the first container, started by the SM as LM1 (S1 `flash_all`,
   S2 `mx95frdm.cfg`); (b) U-Boot `bootaux` with a signed `flash_bootaux_cntr` container; (c) Linux
   remoteproc.
   Recommendation: (a). It is the only path where the M7 runs before any A55 code, which an HSM's
   tamper side needs, and the AHAB check is the ROM's (S4, S5).
3. **May the M7 be reloaded with a new image at run time?**
   Options: (a) no: the M7 is updated only by replacing the boot image and rebooting, and an SM LM
   reset only restarts it; (b) yes, through U-Boot `bootaux` with a signed container only; (c) yes,
   through Linux remoteproc.
   Recommendation: (a), and keep `LMM_1` at `NOTIFY` for Linux as the stock FRDM configuration has
   it (S2), so that Linux cannot stop or restart the M7. (c) leaves the AHAB chain (§7, U5).
4. **Which signing tool?**
   Options: (a) SPSDK; (b) CST 4.0.1; (c) CST 3.1.0 as SPEC.md names it.
   Recommendation: (a) SPSDK, which S5 recommends for AHAB 2.0 on the i.MX 95 B0; (c) needs
   confirming against AHAB 2.0 before it is kept, because S5 names CST 4.0.1 as the CST version
   that supports it. SPEC.md's HSM custody model (AN14471) must then be checked against SPSDK's
   HSM signing support, which this survey did not read.
5. **Anti-rollback on the M7's container?**
   The ELE enforces only the container's fuse version against the fuse floor
   (`anti-rollback-survey.md` §2.1). The `-sw_version` field is a software-checked index that
   hardware does not enforce (`anti-rollback-survey.md` §2.2); NXP's check of it runs in A55 SPL.
   On option (a) of question 2 the M7 starts before A55 SPL runs, so that later check cannot
   protect the M7 image: an older signed M7 image that carries the same fuse version would still
   run. Setting `-sw_version` alone is therefore **not** an M7 rollback fix.
   Options: (a) a fuse version on the first container, so that the ELE's own fuse-floor check
   covers the M7 image; (b) `-sw_version` on the first container together with an explicitly
   implemented check that runs before the M7 executes, which no source read here names; (c) leave
   the first container at the default version, as S1 does, and rely on the ATF/U-Boot container's
   version only, which leaves the M7 unprotected.
   Status: **blocked**. The mechanism that enforces a version before the M7 executes on the
   i.MX 95, and the floor it protects, are **unconfirmed** (U3); the fuse capacity behind the floor
   is unconfirmed too (`anti-rollback-survey.md` §2.1). No option is recommended until a verified
   mechanism is named with its source. SPEC.md's anti-rollback requirement for the boot container
   stands; raising a fuse floor is an owner decision and is not a step of this survey.
6. **Who owns the SM configuration of LM1?**
   Options: (a) this repository's `system-manager-config` row derives it from `configs/other/mx95frdm-pro.cfg` (this device's file, not the 15x15 `mx95frdm.cfg`) and
   trusted-firmware declares the resources it needs (§8); (b) trusted-firmware owns LM1's section.
   Recommendation: (a), as SPEC.md's `system-manager-config` row already says the SM configuration
   is this repository's.
7. **Which image format does trusted-firmware deliver?**
   Options: (a) raw binary only (`m7_image.bin`); (b) raw binary and an ELF with a resource table.
   Recommendation: (a) if question 3 is answered (a) or (b); (b) only if the Linux remoteproc path
   is chosen.
