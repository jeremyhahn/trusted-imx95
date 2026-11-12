# Platform image: boot media and flash.bin layout

Status: survey for the owner's decision on #14. Nothing here has been decided.
Row: platform-image (see [SPEC.md](../SPEC.md)). Issue: #42.

This record covers two things for the NXP FRDM-IMX95-PRO:

1. **Boot media.** The SPEC row names the eMMC on uSDHC1 as the default boot
   device, with the microSD and the FlexSPI NOR as the alternatives that the
   SW4 switch selects.
2. **The i.MX 95 `flash.bin`.** This covers which containers `imx-mkimage`
   puts in it (EdgeLock firmware, OEI, System Manager, Cortex-M7, TF-A,
   U-Boot), at which offsets, and how the image reaches each medium with
   `uuu`.

Every source is public. Sources were read on 2026-11-12, and each one is
pinned to the tag, branch or commit that was read. Vendor text is summarised
here, never copied. Claims that could not be confirmed are marked
**Unconfirmed**. This is documentation only: no fuse, life-cycle or
provisioning step is run or scripted.

## 1. Sources

"Reached" means the lane fetched the source and read it.

| # | Source | Version / ref | URL | Reached |
|---|--------|---------------|-----|---------|
| S1 | NXP i.MX Mkimage tool (`imx-mkimage`): `Readme.imx95` and `iMX95/soc.mak` | branch `lf-6.18.37_2.1.0` | https://github.com/nxp-imx/imx-mkimage/tree/lf-6.18.37_2.1.0 | yes |
| S2 | `imx-mkimage` container builder sources: `src/imx8qxb0.c`, `src/mkimage_imx8.c`, `src/mkimage_common.h` | branch `lf-6.18.37_2.1.0` | https://github.com/nxp-imx/imx-mkimage/tree/lf-6.18.37_2.1.0/src | yes (searched for specific symbols, not read in full) |
| S3 | `meta-imx` machine configuration `imx95-19x19-lpddr5-frdm-pro.conf` | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf | yes |
| S4 | `meta-freescale` include `conf/machine/include/imx95-evk.inc` (the include that S3 requires) | branch `wrynose` tip as of 2026-11-12 | https://github.com/Freescale/meta-freescale/blob/wrynose/conf/machine/include/imx95-evk.inc | yes |
| S5 | U-Boot board document `doc/board/nxp/imx95_frdm.rst` | tag `v2027.01-rc1` | https://github.com/u-boot/u-boot/blob/v2027.01-rc1/doc/board/nxp/imx95_frdm.rst | yes |
| S6 | NXP U-Boot fork (`uboot-imx`): `drivers/fastboot/fb_fsl/fb_fsl_partitions.c` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/tree/lf-6.18.37-2.1.0/drivers/fastboot/fb_fsl | yes |
| S7 | `uboot-imx` board files: `configs/imx95_19x19_frdm_pro_defconfig`, `configs/imx95_19x19_frdm_pro_fspi_defconfig`, `arch/arm/dts/imx95-19x19-frdm-pro.dts`, `arch/arm/dts/imx95-19x19-frdm-pro-u-boot.dtsi` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/tree/lf-6.18.37-2.1.0 | yes |
| S8 | NXP Universal Update Utility (`mfgtools` / `uuu`): `README.md`, built-in scripts `uuu/emmc_burn_loader.lst`, `uuu/emmc_burn_all.lst`, `uuu/sd_burn_loader.lst`, `uuu/qspi_burn_loader.lst`, and `libuuu/config.cpp` | `master` at commit `450ef66` (2026-10-29); newest tag `uuu_1.5.243` | https://github.com/nxp-imx/mfgtools | yes |
| S9 | Linux device tree `arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts` | tag `v7.3` | https://github.com/torvalds/linux/blob/v7.3/arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts | yes |
| S10 | NXP Linux fork (`linux-imx`), same device tree file | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/linux-imx/blob/lf-6.18.37-2.1.0/arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts | yes |
| S11 | Sibling record `docs/platform-image/build-system-options.md`, not yet on `main` (`meta-imx` and the `imx-6.18.37-2.1.0` manifest) | this repository, issue #31 | — | yes |
| U1 | UM12527, FRDM-IMX95-PRO board user manual (SW4 boot switch table, boot device list) | n/a | https://www.nxp.com/docs/en/user-manual/UM12527.pdf | **no** (HTTP 404 from the lane) |
| U2 | NXP FRDM-IMX95-PRO product page | n/a | https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX95-PRO | **no** (HTTP 404 from the lane) |
| U3 | i.MX Linux User's Guide (flashing and boot-switch chapters) | n/a | https://www.nxp.com/docs/en/user-guide/IMX_LINUX_USERS_GUIDE.pdf | **no** (HTTP 404 from the lane) |
| U4 | IMX95RM, i.MX 95 Reference Manual (boot ROM, boot media offsets, fallback) | n/a | https://www.nxp.com/docs/en/reference-manual/IMX95RM.pdf | **no** (HTTP 404 from the lane) |
| U5 | i.MX 95 Security Reference Manual | n/a | not public (NXP secure-files access) | **no** |

The NXP web pages (U1 to U4) answered every request from the lane with the
same short 404 page. That may be bot filtering and not a missing document.
Everything that depends on the board manual or the reference manual is
therefore **Unconfirmed** below.

## 2. Boot media on the FRDM-IMX95-PRO

### 2.1 What the device trees show

- **eMMC on uSDHC1.** In both the mainline and the NXP kernel device trees,
  `usdhc1` is an 8-bit, non-removable controller that is barred from SD and
  SDIO use. It is aliased `mmc0` (S9, S10).
- **microSD on uSDHC2.** `usdhc2` is a 4-bit controller with a card-detect
  GPIO. It is aliased `mmc1` (S9).
- **uSDHC3** is a further 4-bit, non-removable controller with a power
  sequence. The pattern suggests an SDIO module (wireless), not a boot
  medium. **Unconfirmed:** what is attached to it.
- **FlexSPI NOR.** The NXP U-Boot device tree enables `flexspi1` with one
  flash at chip select 0, aliases it `spi0`, and marks both nodes for the
  pre-RAM (SPL) stage (S7). Neither kernel device tree, mainline `v7.3` or
  NXP `lf-6.18.37-2.1.0`, describes a FlexSPI node for this board (S9, S10).
  So Linux would not see the NOR without a device-tree change.
  **Unconfirmed:** the NOR part number and size. `imx-mkimage` carries
  FlexSPI header variants for 200 MHz and 133 MHz, plus one named for a
  Winbond W25Q512NW part (S1). Which one matches this board is not stated in
  any source that was reached.

### 2.2 SW4 boot switch

**Unconfirmed in full.** The SPEC row cites UM12527 §2.3 Table 7 for the SW4
settings (eMMC, microSD, FlexSPI NOR, serial download). That manual (U1) was
not reachable, so this record gives no switch positions. Serial download over
USB is the mode `uuu` needs (section 4). The positions must come from
UM12527 before anyone writes a flashing procedure.

### 2.3 U-Boot configurations NXP ships for the board

- `imx95_19x19_frdm_pro_defconfig` boots SPL from MMC. It keeps the U-Boot
  environment in MMC at offset 7 MiB (`0x700000`), 16 KiB long. Its boot
  command runs `bootflow scan` first and falls back to the BSP's own boot
  script (S7).
- `imx95_19x19_frdm_pro_fspi_defconfig` adds SPL loading from SPI flash and
  allows the environment in either SPI flash or MMC, with the same offset
  and size (S7).
- Both set a fastboot buffer in DRAM, so fastboot (and therefore `uuu`) is
  built in (S7).
- **Unconfirmed:** which MMC device and hardware partition the environment
  uses. The setting is not in the defconfig; it is probably in the board
  header, which was not read.

## 3. The i.MX 95 `flash.bin` from `imx-mkimage`

### 3.1 Which target the Yocto build uses

- The FRDM-PRO machine (S3) sets the U-Boot configuration base
  `imx95_19x19_frdm_pro`, the System Manager configuration `mx95frdm-pro`,
  the OEI board `mx95lp5` and LPDDR5 DDR firmware `v202409`.
- If `UBOOT_CONFIG` contains `fspi`, the machine builds `flash_a55_flexspi`.
  Otherwise it uses the SD target set from the include (S3).
- For the default `sd` configuration, the include (S4) builds two targets:
  `flash_all` and `flash_a55`. `sd-ecc` builds `flash_all` only. The
  variants `alt`, `jailhouse`, `netc`, `rpmsg` and `sof` select other
  targets and other System Manager configurations.
- The include sets `IMX_BOOT_SEEK = 32`, the offset in KiB at which the
  image goes on an SD-style medium (S4).
- **Unconfirmed:** S4 was read at the `wrynose` branch tip. The
  `imx-6.18.37-2.1.0` manifest pins `meta-freescale` to a fixed commit (S11),
  and that commit was not compared with the tip.
- A small inconsistency: the header comment of the FRDM-PRO machine file
  still describes the 19x19 EVK (S3). The settings themselves are the
  FRDM-PRO ones.

### 3.2 Build defaults for the i.MX 95 (S1)

- The silicon revision defaults to B0. For B0 the container format version
  is 2 (`CTNR_VERSION`); A0/A1 use version 0.
- OEI defaults to on (`OEI ?= YES` in `soc.mak`). `Readme.imx95` still says
  OEI is off by default, so the readme and the makefile disagree; the
  makefile is what runs.
- The DDR firmware defaults to LPDDR5 and the FW2024.09 training binaries.
- `MSEL` (default 0) is a mode-select value passed to the System Manager. It
  picks a boot configuration at run time, for example which cores to start.
- The container flags `GDET`, `VDET`, `AGDET` and `TMPSNS` (all default 0)
  set the glitch, voltage and temperature detector behaviour of the
  EdgeLock Enclave. `FAST_HASH=YES` sets a fast-hash flag per medium.
- `ROLLBACK_INDEX_IN_CONTAINER`, when set, writes a software version into
  the TF-A/U-Boot container (`-sw_version`). This is not the hardware
  anti-rollback floor. The ELE enforces the container's `fuse_version`
  against fuses. `sw_version` only lets software choose between images that
  share a fuse version, and it refuses nothing unless a software check is
  explicitly implemented
  ([verified-boot survey §3.8](verified-boot-survey.md)).

### 3.3 What the containers hold

Each `flash_*` target is one `mkimage_imx8` run that builds the **boot image
container**, optionally followed by an appended **TF-A/U-Boot container**
(S1).

1. **EdgeLock Enclave firmware container.** `-append` places
   `mx95b0-ahab-container.img` (`mx95a0-…` for A0/A1) ahead of the boot
   image container. The `*_no_ahabfw` targets leave it out. U-Boot's board
   document fetches this file from NXP's `firmware-ele-imx` package (S5).
2. **Boot image container** (`-c`). In the order the targets list them:
   - **OEI** for the Cortex-M33 (`-oei`): the DDR-initialisation image with
     the LPDDR training firmware joined to it. It is loaded at `0x1FFC0000`,
     entered at `0x1FFC0001`, and followed by a 64 KiB hold region. With OEI
     on, a V2X placeholder is also added at `0x8B000000`. B0 adds a DDR dummy
     entry.
   - **System Manager** (`-m33 m33_image.bin`), loaded to the M33 TCM at
     `0x1FFC0000`. U-Boot's document builds it from `imx-sm` with the
     configuration `other/mx95frdm-pro` (S5).
   - **Cortex-M7 image** (`-m7`), in the `flash_m7*` and `flash_all*`
     targets only. It goes to TCM (address 0, A-core alias `0x303C0000`) or,
     in the `_ddr` targets, to DDR at `0x80000000`. A FlexSPI XIP variant
     places it at a fixed offset in NOR (`0x132000`). This is where the
     Cortex-M7 image of trusted-firmware's `imx95` row would sit.
   - **Cortex-A55 U-Boot SPL** (`-ap u-boot-spl.bin`), loaded at
     `0x20480000` (the M33's view of the address) in the System Manager
     ("lpboot") targets. The "singleboot" targets, where the A55 boots
     without the System Manager, load it at `0x4AA00000` instead.
3. **TF-A/U-Boot container** (`u-boot-atf-container.img`), appended to
   `flash.bin` at the next 1 KiB boundary (the `append_container` macro with
   page size 1). It holds `bl31.bin` at `0x8A200000` and U-Boot (with a
   commit-hash trailer) at `0x90200000`, plus OP-TEE at `0x8C000000` when a
   `tee.bin` is present.

The two default SD targets on the FRDM-PRO therefore differ in one way:
`flash_all` carries a Cortex-M7 image in TCM and `flash_a55` does not (S1,
S4).

### 3.4 Offsets inside `flash.bin` (S2)

- With container version 2 (B0), `imx-mkimage` aligns container headers to
  16 KiB (`0x4000`) and starts the first image payload 48 KiB (`0xC000`)
  into the container set. Version 0 uses 1 KiB alignment and starts payloads
  at 8 KiB (`0x2000`).
- The builder's notional header offset is 1 KiB for SD, eMMC and NAND and
  4 KiB for FlexSPI. The `emmc_fast` device mode sets it to 0.
- `soc.mak` also has `parse_container` and `extract` targets. These print or
  unpack the containers of a built `flash.bin`, and are the way to check the
  real offsets of a build.
- **Unconfirmed:** these offsets were read from source, not measured on a
  built image. Run the `parse_container` target on the first build and
  record its output.

### 3.5 Where `flash.bin` goes on each medium

| Medium | Offset of `flash.bin` | Source |
|--------|----------------------|--------|
| microSD (uSDHC2), or the eMMC user area | 32 KiB (`0x8000`) from the start of the device | `IMX_BOOT_SEEK = 32` (S4); the `dd … bs=1k seek=32` example (S5); NXP fastboot returns `0x8000` for an i.MX 9 MMC target that is not the eMMC device (S6) |
| eMMC (uSDHC1) boot partition | offset 0 of hardware boot partition `boot0` | NXP fastboot's offset rule for i.MX 9 when the target is the eMMC device (S6). `uuu` then enables boot partition 1 for boot with `mmc partconf` (S8) |
| FlexSPI NOR | `flash.bin` begins with a FlexSPI configuration block at 1 KiB, and the containers start at 4 KiB | the `append_fcb` macro and `-dev flexspi` (S1, S2) |

- NXP's fastboot code reads `emmc_dev` from the U-Boot environment and
  defaults it to 2 when it is not set (S6). **Unconfirmed:** the value the
  FRDM-PRO environment sets (the kernel aliases the eMMC as `mmc0`, S9).
- **Unconfirmed:** whether the i.MX 95 boot ROM also looks for the image at
  32 KiB in the eMMC user area when booting from eMMC, and whether it has a
  secondary or fallback container set (U4). No reached source describes a
  secondary image for the i.MX 95; the `gen_sit.sh` script in
  `imx-mkimage` is for older parts.

### 3.6 Mainline U-Boot as an alternative builder

- Mainline U-Boot `v2027.01-rc1` documents the FRDM-PRO under the
  `imx95_frdm` board (S5). It produces `flash.bin` from its own build once
  these files are placed in its source tree: the ELE container
  (`firmware-ele-imx` 2.0.2), the LPDDR firmware (`firmware-imx` 8.28), the
  OEI (`imx-oei`, board `mx95lp5-19`), the System Manager (`imx-sm`,
  configuration `other/mx95frdm-pro`) and TF-A (`imx-atf` branch
  `lf_v2.12`). It then writes the image to microSD at 32 KiB (S5).
- The document builds the OEI and the System Manager from their `master`
  branches. Those are not pinned, so the result is not reproducible.
- **Unconfirmed:** how the mainline build packs the containers. Its packing
  description was not read. Whether it can include a Cortex-M7 image as
  `imx-mkimage`'s `flash_all` does is also unconfirmed.

## 4. Flashing with `uuu`

- `uuu` recognises the i.MX 95 boot ROM in serial-download mode by NXP's
  USB vendor ID and product IDs `0x015C` and `0x015D`, and talks to it with
  the stream protocol (SDPS) (S8 `config.cpp`). The board must be strapped
  to serial download through SW4 (section 2.2, **Unconfirmed** positions).
- Built-in scripts, chosen with `-b` (S8):
  - `uuu -b emmc flash.bin`: boot `flash.bin` over USB, then use U-Boot
    fastboot to write it to the eMMC bootloader partition (boot partition,
    offset 0, section 3.5). Then set the eMMC boot-partition configuration
    to boot from partition 1.
  - `uuu -b emmc_all flash.bin image.wic.zst`: the same, but first write
    the whole disk image (`.wic`, compressed or not) to the eMMC user area,
    sparse-converted. Then write `flash.bin` to the boot partition.
  - `uuu -b sd …`: the SD-card version of the loader script, with the
    32 KiB offset from S6.
  - `uuu -b qspi flexspi.bin`: write a FlexSPI image through U-Boot. It
    checks the image for a FlexSPI header with U-Boot's `qspihdr` command,
    and uses `sf erase`/`sf write` without one or for images over 16 MiB.
- These scripts are generic across i.MX parts. All of them depend on the
  `flash.bin` U-Boot having fastboot enabled, which both FRDM-PRO defconfigs
  have (S7).
- **Unconfirmed:**
  - whether `qspi_burn_loader` works unchanged on the i.MX 95 FlexSPI NOR of
    this board, since `qspihdr` support in the FRDM-PRO U-Boot was not
    checked;
  - which `uuu` release first supports the i.MX 95. `master` at `450ef66`
    supports it; `uuu_1.5.243` is the newest tag, but its date and content
    were not checked.
- Writing the eMMC boot-partition configuration (`mmc partconf`) changes a
  setting held on the eMMC device, not a fuse. It can be changed back. No
  `uuu` script surveyed here touches fuses or life-cycle state.

## 5. How this meets the other rows

- **boot-container.** AHAB verifies every container in section 3.3. To
  verify the Cortex-M7 image as a signed container before it runs, the
  image must be in the boot image container (`flash_all`/`flash_m7`
  family), not loaded later by U-Boot or Linux. Signing applies to the boot
  image container and the TF-A/U-Boot container separately. The Linux
  kernel and root filesystem are not in these containers, so AHAB does not
  verify them; their verification is **unresolved**
  ([verified-boot survey §3.5-§3.6](verified-boot-survey.md#35-u-boot-to-the-kernel-fit-signature-verification),
  TH1 in the [threat model](../threat-model.md)). The hardware
  anti-rollback floor is each container's `fuse_version` and the ELE commit
  policy, which belong to the boot-container row. The `-sw_version` hook
  (section 3.2) only gives a software version, which needs its own,
  explicitly implemented check.
- **system-manager-config.** The System Manager binary and `MSEL` are
  chosen at `flash.bin` build time (S1, S3, S5).
- **build system (#31).** Both `meta-imx` (S3) and mainline U-Boot (S5) can
  produce `flash.bin`. The sibling record's recommendation (S11) would make
  `imx-mkimage` through `meta-imx` the builder.

## 6. Questions for the owner

1. **Production boot medium.**
   - (a) eMMC boot partition `boot0` (the SPEC default);
   - (b) microSD at 32 KiB;
   - (c) FlexSPI NOR.

   *Recommendation: (a).* It is the SPEC default and has non-removable
   hardware (S9). It also has dedicated `uuu` scripts that write the boot
   partition and select it (S8). Keep (b) for development boards only. (c)
   needs a kernel device-tree change before Linux can use the NOR (S9,
   S10), and its part is unconfirmed.
2. **Which tool builds `flash.bin`.**
   - (a) `imx-mkimage` at `lf-6.18.37_2.1.0` through `meta-imx`;
   - (b) mainline U-Boot's own build (S5).

   *Recommendation: (a)*, to match #31. It pins every input to the release
   (S3, S11), and `flash_all` already places a Cortex-M7 image in the boot
   container (S1). For (b), the M7 placement is unconfirmed, and its
   document builds the OEI and System Manager from unpinned branches (S5).
3. **`flash.bin` target.**
   - (a) `flash_all` (System Manager, M7 in TCM, A55);
   - (b) `flash_all_ddr` (M7 in DDR);
   - (c) `flash_a55`, with the M7 started later from U-Boot or Linux.

   *Recommendation: (a) or (b)*, so that AHAB checks the M7 image before it
   runs (SPEC boot-container row). The choice between TCM and DDR depends on
   the size and memory needs of trusted-firmware's `imx95` image. The
   sources do not settle it.
4. **Redundant boot copy.**
   - (a) a single `flash.bin` in `boot0`;
   - (b) a second copy in `boot1`, switched with `mmc partconf` during
     updates;
   - (c) a single copy, with USB serial download as the recovery path.

   No recommendation. Whether the i.MX 95 ROM falls back by itself to the
   other boot partition, or to a secondary container set, is unconfirmed
   without IMX95RM (U4).
5. **Anti-rollback version in the TF-A/U-Boot container.**
   - (a) set `ROLLBACK_INDEX_IN_CONTAINER` from the release version;
   - (b) leave it unset for now.

   *Recommendation: (b) until the boot-container row fixes its version
   scheme.* The hook exists (S1). Setting it alone does not give
   anti-rollback: `sw_version` needs a software check, and the hardware floor
   is the `fuse_version` (section 5). The fuse side is out of scope here and
   documented only in the missing manuals.
6. **Factory flashing tool.**
   - (a) `uuu` pinned to a tag, with `-b emmc_all`;
   - (b) `dd` of the disk image onto removable media, and the eMMC written
     from a running system;
   - (c) U-Boot fastboot driven by a project script.

   *Recommendation: (a).* `uuu` is NXP's maintained path. It recognises the
   i.MX 95 ROM and writes both the user area and the boot partition in one
   run (S8). Which tag to pin is open (section 4).
7. **U-Boot environment.**
   - (a) keep NXP's writable environment at 7 MiB in MMC (S7);
   - (b) move it;
   - (c) build U-Boot without a writable environment for production.

   No recommendation from the sources. The question matters for secure
   boot, because a writable environment can change the boot command. Raise
   it again with the boot-container row.
8. **Missing manuals.** Can the owner supply UM12527 (SW4 positions, NOR
   part) and IMX95RM (ROM offsets, fallback), or open access to them? Until
   then, sections 2.2 and 3.5 stay **Unconfirmed**. Options:
   - (a) add them to the private vendor context repository;
   - (b) give the lanes a reachable copy;
   - (c) accept the gaps for now.
