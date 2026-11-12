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

## 5. Where the M7 image runs: TCM or DDR

## 6. AHAB: when the M7 image's signature is checked

## 7. Restarting the M7 with a new image at run time

## 8. Interface with trusted-firmware

## 9. Not confirmed

## 10. Questions for the owner
