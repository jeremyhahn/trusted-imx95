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
`configs/mx95frdm.cfg` (the FRDM-IMX95 configuration, the board of this repository), all at
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

## 6. AHAB: when the M7 image's signature is checked

## 7. Restarting the M7 with a new image at run time

## 8. Interface with trusted-firmware

## 9. Not confirmed

## 10. Questions for the owner
