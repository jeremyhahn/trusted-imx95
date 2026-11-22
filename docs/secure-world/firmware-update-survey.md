# Secure-world firmware update on the i.MX 95: survey

Row: secure-world ([SPEC.md](../SPEC.md)). Issue #104. Documentation only.

Status: draft survey, public sources only.

## 1. Scope

This survey covers how the secure-world firmware on the A55 cluster of the
i.MX 95 is versioned, protected against rollback and replaced in the field:
TF-A (BL31) and OP-TEE (BL32). It also asks whether TF-A's FWU support or
the PSA firmware update model applies to this SoC. The image-level update
mechanism (how a new image reaches the board and is written) belongs to the
platform-image row (#14) and is out of scope here.

All sources are public. Every summary is in this document's own words.
This document runs no fuse, life-cycle or provisioning step and gives none
as a procedure.

## 2. Sources and versions

Read on 2026-11-12.

| Id | Source | Version surveyed | URL |
| --- | --- | --- | --- |
| S1 | NXP TF-A fork `imx-atf`: `plat/imx/imx9/imx95/platform.mk` | branch `lf_v2.14`, commit af9eb2c1 (2026-09-01) | https://github.com/nxp-imx/imx-atf |
| S2 | NXP `imx-mkimage`: `iMX95/soc.mak`, `Readme.imx95`, `src/mkimage_imx8.c` | branch `lf-6.18.37_2.1.0`, commit b1f801d3 (2026-08-27) | https://github.com/nxp-imx/imx-mkimage |
| S3 | NXP U-Boot `uboot-imx`: `doc/imx/imx95_container.txt`, `arch/arm/mach-imx/{ele_ahab.c,spl.c,spl_imx_romapi.c,Kconfig}`, `arch/arm/mach-imx/imx9/Kconfig`, `common/spl/spl_imx_container.c`, `lib/avb/fsl/fsl_bootctrl.c`, `doc/develop/uefi/fwu_updates.rst`, `configs/imx95_19x19_*` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx |
| S4 | Trusted Firmware-A: `docs/components/firmware-update.rst`, `docs/getting_started/build-options.rst`, `plat/imx/imx9/imx95/platform.mk` | tag `v2.15.0` | https://github.com/TrustedFirmware-A/trusted-firmware-a |
| S5 | OP-TEE documentation: "Trusted Applications" (REE-FS TA rollback protection), "Secure storage" | readthedocs `latest` as read on 2026-11-12 (latest `optee_os` tag then: 4.9.0) | https://optee.readthedocs.io/en/latest/architecture/trusted_applications.html |

Sources that were not reached or not read are listed in §8.

## 3. Where TF-A and OP-TEE sit in the i.MX 95 boot flow

- NXP's TF-A fork builds the i.MX 95 port with `RESET_TO_BL31 := 1` and
  `PROGRAMMABLE_RESET_ADDRESS := 1` [S1, `plat/imx/imx9/imx95/platform.mk`].
  So TF-A on this SoC is BL31 only: it has no BL1 or BL2 stage. Something
  outside TF-A loads BL31 and starts it.
- The same file sets the default OP-TEE (BL32) load window to 0x8C000000,
  32 MiB [S1]. BL31 does not load OP-TEE. The boot container does (next
  bullets), and BL31 only hands control to it.
- The i.MX 95 platform makefile adds no source for trusted board boot, FWU or
  non-volatile counters [S1]. The only optional addition is FF-A shared memory
  when the secure payload dispatcher is Trusty.
- NXP's image packer builds the A55 boot image as two AHAB containers that
  sit one after the other in a single `flash.bin` [S2, `iMX95/soc.mak`]:
  1. the first container holds the EdgeLock (ELE) firmware container that is
     appended in front of it, the optional OEI/DDR images, the M33 System
     Manager, an optional M7 image and U-Boot SPL for the A55;
  2. the second container, `u-boot-atf-container.img`, holds `bl31.bin`
     (TF-A), `u-boot-hash.bin` (U-Boot proper) and, when `tee.bin` exists,
     OP-TEE. Each one has its own A55 load address (TF-A 0x8A200000, U-Boot
     0x90200000, OP-TEE 0x8C000000). The makefile appends this container at
     the next 1 KiB boundary after the first one (4 KiB for SPI NAND).
- So TF-A and OP-TEE do travel in a boot container. It is the *second*
  container, which SPL loads, and not the first one, which the boot ROM
  loads. TF-A, OP-TEE and U-Boot proper are one signed unit. None of them
  can be replaced without re-signing and rewriting the whole second
  container [S2].
- The packer also has a FIT path (`u-boot-atf.itb`, made with
  `mkimage_fit_atf.sh`) [S2]. No i.MX 95 `flash_*` target uses it. All of
  them append the AHAB container.

## 4. How the images are versioned

The AHAB container header has two version fields, an 8-bit *fuse version*
and a 16-bit *SW version* [S3, `doc/imx/imx95_container.txt`]. The packer
sets them with `-fuse_version` and `-sw_version` [S2,
`src/mkimage_imx8.c`]. With these, there are three separate version numbers, and they should not be confused:

- **Container software version.** The packer's `-sw_version` option writes a
  software version into the second container's header. `soc.mak` fills it in
  only when the build variable `ROLLBACK_INDEX_IN_CONTAINER` is set, and only
  when OP-TEE is in the container [S2]. The variable's name shows that NXP
  uses this field as the rollback index for the TF-A + U-Boot + OP-TEE unit.
  The build sets no value by default.
- **Container format version.** `CTNR_VERSION` (2 for i.MX 95 B0, 0 for A0/A1)
  selects the AHAB header format [S2]. It is a format number, not a firmware
  version.
- **Component versions.** TF-A and OP-TEE each carry a build version string
  (TF-A from its release tag; OP-TEE from its own release). Nothing in the
  i.MX 95 TF-A platform code ties that string to a counter [S1].

The image a field update replaces is therefore the second container, not
a single TF-A or OP-TEE image. Its rollback identity is the container's
software version.

## 5. Anti-rollback checks

The public sources show two separate mechanisms. Neither one is TF-A's or
OP-TEE's own.

### 5.1 Hardware: the container fuse version, enforced by the ELE

- NXP U-Boot has an `ahab_commit` command. Its help text says it commits
  to the fuses any new SRK revocation and firmware version information that
  the ELE has found in the NXP and OEM containers [S3,
  `arch/arm/mach-imx/ele_ahab.c`]. So the fuse version in an OEM container
  is a monotonic, fuse-backed version, and it is advanced by an explicit
  commit request to the ELE.
- When U-Boot SPL is built with `CONFIG_AHAB_BOOT`, it passes the second
  container's header to the ELE for authentication. It then checks each
  image (TF-A, OP-TEE, U-Boot) against the hash in the authenticated header
  [S3, `common/spl/spl_imx_container.c`]. So the second container's fuse
  version reaches the same ELE check as the first container's. Without
  `CONFIG_AHAB_BOOT`, SPL authenticates nothing.
- **Not confirmed from public sources:** the exact comparison the ELE makes
  (whether it rejects a container whose fuse version is below the fused
  value, and how this interacts with the life cycle), and how many fuse
  bits the i.MX 95 gives to the OEM version. These details are in the i.MX 95
  Security Reference Manual, which is not public and is listed as missing in
  [references/](../references/README.md). The EdgeLock API reference manual
  in that directory (RM00284) describes the monotonic counters, but not
  their link to the container header.
- Committing burns fuses, so it is irreversible. This survey does not give
  the command sequence, and no lane may script it.

### 5.2 Software: the container SW version, checked by SPL against eMMC RPMB

- After authentication, SPL copies the container's SW version into the
  image's rollback index [S3, `common/spl/spl_imx_container.c`].
- The check is compiled only with `CONFIG_IMX_TRUSTY_OS`, NXP's
  Android/Trusty configuration (and not with its Matter variant) [S3,
  `arch/arm/mach-imx/spl.c`]. SPL reads a bootloader rollback index from the
  eMMC RPMB partition. It refuses to boot a container whose SW version is
  lower than the stored index. It raises the stored index only once the A/B
  metadata marks the current slot as having booted successfully [S3,
  `lib/avb/fsl/fsl_bootctrl.c`, `spl_verify_rbidx`].
- With `CONFIG_IMX_ROLLBACK_BLOB`, the RPMB copy is wrapped as a hardware
  blob, so that it is not stored in clear text [S3, `arch/arm/mach-imx/Kconfig`].
- The check is skipped when the RPMB key has not been set [S3,
  `check_rollback_index`].
- This is the scheme that `ROLLBACK_INDEX_IN_CONTAINER` in the packer feeds
  (§4). Outside the Trusty build, the public sources show nothing that reads
  the SW version, so on a plain Linux BSP build it is not enforced.
- **RPMB ownership.** SPL runs this check before it starts BL31 and BL32,
  so it cannot reach OP-TEE's RPMB file system or the OP-TEE AVB trusted
  application that U-Boot proper uses for its rollback indexes
  ([rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §4.3). It reads
  and writes the partition itself, as a second raw RPMB user. OP-TEE's RPMB
  file system takes the whole partition, and another raw writer is expected
  to corrupt it or be corrupted by it (rpmb-survey.md §7.2). The two would
  also have to derive the same authentication key, since the partition has
  only one. So this SPL check and OP-TEE RPMB storage
  (`CFG_RPMB_FS=y`) are **not supported together** on this board until a
  shared partition layout and a compatible key derivation are shown and
  validated. No public source read here does that for the i.MX 95.

### 5.3 Inside TF-A and OP-TEE

- The i.MX 95 TF-A port has no BL2, so TF-A's trusted-board-boot
  non-volatile counter checks (which BL1 and BL2 run) never run on this SoC
  [S1].
- OP-TEE: see §7.3.

## 6. A/B boot container slots

### 6.1 Android dual bootloader (NXP U-Boot)

- `CONFIG_DUAL_BOOTLOADER` turns on A/B selection of the bootloader in SPL
  [S3, `arch/arm/mach-imx/Kconfig`]. SPL reads the Android A/B metadata
  from the `misc` partition and picks the slot with the higher priority. It
  then loads the second container (TF-A, OP-TEE, U-Boot) from GPT partition
  `bootloader_a` or `bootloader_b`. Each slot has a tries-remaining count,
  and a slot is marked unbootable when its count runs out [S3,
  `lib/avb/fsl/fsl_bootctrl.c`, `mmc_load_image_raw_sector_dual_uboot`].
- This gives A/B for the TF-A + OP-TEE + U-Boot unit together, but not for
  the first container (ELE firmware, System Manager, SPL). It needs eMMC
  (GPT and RPMB), and it is the Android code path.

### 6.2 Boot ROM primary/secondary image set

- NXP U-Boot's ROM API code can report a boot stage of *secondary* or
  *recovery* [S3, `arch/arm/mach-imx/spl_imx_romapi.c`]. This shows that the
  i.MX 9 boot ROM can boot a second copy of the first container set.
- **Not confirmed from public sources:** how the i.MX 95 ROM chooses the
  secondary set (fuse-selected offset, a fall-back on authentication
  failure, or both), and where the set sits on each boot device. This is in
  the i.MX 95 Reference Manual (IMX95RM), which is listed as missing.

### 6.3 What public guidance does not cover

No NXP public document found by this survey gives an i.MX 95 A/B scheme for a
plain Linux (non-Android) BSP. That covers both the ROM-level set and the
SPL-level second container.

## 7. PSA firmware update and TF-A FWU on this SoC

### 7.1 TF-A's own FWU support

- TF-A v2.15.0 documents two FWU mechanisms [S4,
  `docs/components/firmware-update.rst`]:
  - **PSA FWU** (`PSA_FWU_SUPPORT`) implements Arm's PSA Firmware Update
    specification (IHI 0093). It keeps active and update banks with FWU
    metadata. BL2 reads the metadata, boots the active bank in a trial
    state, and holds back the platform NV counter until the update is
    accepted. BL2 itself cannot be updated through it [S4,
    `docs/getting_started/build-options.rst`].
  - **TBBR FWU** is a recovery flow that BL1 runs, with an SMC interface for
    copying, authenticating and running images.
- Both mechanisms run in BL1 or BL2. On the i.MX 95, upstream TF-A v2.15.0
  sets `RESET_TO_BL31 := 1`, just as NXP's fork does [S4,
  `plat/imx/imx9/imx95/platform.mk`; S1]. **So neither TF-A FWU mechanism
  applies to the i.MX 95 as ported.** Using them would mean adding a BL2 to
  the platform port and placing it after the ROM, ELE and SPL stages. No
  public source does this for the i.MX 95.

### 7.2 PSA FWU through U-Boot

- U-Boot has an "FWU Multi Bank Update" feature
  (`CONFIG_FWU_MULTI_BANK_UPDATE`). It implements the same PSA Firmware
  Update for A-profile specification in U-Boot: banks recorded in FWU
  metadata on GPT storage, written by UEFI capsule-on-disk updates, with the
  platform booting the updated bank next time [S3,
  `doc/develop/uefi/fwu_updates.rst`].
- None of the i.MX 95 defconfigs in NXP U-Boot lf-6.18.37-2.1.0 enable it.
  Several i.MX 95 EVK defconfigs do enable authenticated raw UEFI capsule
  updates (`EFI_CAPSULE_ON_DISK`, `EFI_CAPSULE_FIRMWARE_RAW`,
  `EFI_CAPSULE_AUTHENTICATE`) [S3, `configs/imx95_19x19_evk_defconfig`]. The
  FRDM-IMX95-PRO defconfigs (`imx95_19x19_frdm_pro_*`) enable neither [S3].
- NXP's packer has a target that wraps the whole `flash.bin` (both
  containers) in a signed UEFI capsule for the SystemReady build, which uses
  an OP-TEE built with StandaloneMM (`tee.bin-stmm`) [S2, `iMX95/soc.mak`].
  The update unit there is the whole boot image, and not TF-A or OP-TEE alone.
- **Not confirmed:** whether U-Boot's FWU metadata can drive the choice of
  the second container on the i.MX 95. That choice is made by SPL (§6.1),
  before U-Boot proper runs. No public i.MX 95 source wires the two together.

### 7.3 OP-TEE

- OP-TEE on the i.MX 95 is an image inside the second container (§3). The
  sources found show no anti-rollback check that OP-TEE makes on its own
  image. Its rollback protection comes from the container (§5).
- OP-TEE does protect the Trusted Applications it loads from the normal
  world's file system against downgrade. It keeps a TA version database in
  secure storage, and this works only when the RPMB file system is enabled
  (`CFG_RPMB_FS=y`) [S5, "Trusted Applications", REE-FS TA rollback
  protection].
- **Not confirmed:** whether NXP's i.MX 95 OP-TEE build enables
  `CFG_RPMB_FS` by default. The `imx-optee-os` platform configuration was not
  read for this survey.

## 8. What could not be confirmed

| Item | Why | Where it would be |
| --- | --- | --- |
| The ELE's exact rule for the container fuse version, and the number of OEM version fuse bits on the i.MX 95 | Not in any public source found | i.MX 95 Security Reference Manual (not public; missing from [references/](../references/README.md)) |
| How the i.MX 95 ROM picks a secondary image set, and where that set sits | Not in any public source found | IMX95RM (missing) |
| NXP's prose guidance on the dual bootloader and the bootloader rollback index | The i.MX Android security user's guide was not fetched; the code was read instead | NXP Android documentation on nxp.com (may need a login) |
| Whether U-Boot FWU metadata can drive SPL's second-container choice on the i.MX 95 | No public i.MX 95 code does it | Would need a port |
| Whether NXP's i.MX 95 OP-TEE build enables `CFG_RPMB_FS` | Not read | `imx-optee-os` `core/arch/arm/plat-imx` |
| A non-Android NXP A/B guide for the i.MX 95 | None found | Not known to exist |

## 9. Questions for the owner

1. **What is the update unit for the secure world?**
   Options: (a) the second container as a whole (TF-A, OP-TEE and U-Boot
   proper together), as NXP packs it; (b) separate TF-A and OP-TEE images,
   for example a FIT with its own signature.
   Recommendation: (a). It is the only layout any i.MX 95 `flash_*` target
   builds, and it keeps one AHAB signature and one version per unit (§3).

2. **Which anti-rollback version does a release raise?**
   Options: (a) the container SW version only, kept in eMMC RPMB and checked
   by SPL; (b) the container fuse version only, enforced by the ELE and
   committed to fuses; (c) both: the SW version on every release, the fuse
   version only for security-critical fixes; (d) neither until the life
   cycle is decided.
   Recommendation: (c) as the target, with (d) until the oem-key-provisioning
   row settles the life cycle. A fuse commit cannot be undone and the fuse
   width is not confirmed (§5.1, §8). The SW version check exists only in
   NXP's Trusty build (§5.2), so it would have to be enabled or ported for
   this board's build. It makes SPL a raw RPMB user, so (a) and the SW-version
   part of (c) exclude OP-TEE RPMB storage (question 5 (a)) until a shared
   layout and key derivation are validated (§5.2).

3. **Which A/B scheme carries the secure-world images?**
   Options: (a) NXP's SPL dual bootloader (`bootloader_a`/`bootloader_b`
   with Android A/B metadata, needs eMMC); (b) U-Boot FWU multi-bank (PSA
   FWU metadata) with UEFI capsules; (c) the ROM's primary/secondary image
   set; (d) a single slot with recovery over USB serial download.
   Recommendation: (a) is the only public i.MX 95 code that switches between
   copies of the container holding TF-A and OP-TEE, and a FRDM-IMX95-PRO
   defconfig enables it (`imx95_19x19_frdm_pro_android_trusty_dual`) (§6.1).
   But (a) leaves the first container (ELE firmware, System Manager, SPL)
   single-slot, and its rollback index is the SPL one of §5.2, a raw RPMB
   user that cannot share the partition with OP-TEE RPMB storage until that
   is validated. (b) and (c) are not confirmed for this SoC (§7.2, §8). Decide
   this together with the platform-image row (#14). This row only needs the
   answer to be one container per slot.

4. **Should the i.MX 95 TF-A port gain a BL2 so that TF-A's PSA FWU or TBBR
   FWU can be used?**
   Options: (a) no: rely on AHAB authentication and the container versions;
   (b) yes: add BL2 and FWU to the port.
   Recommendation: (a). Neither NXP's nor upstream TF-A has a BL2 for this
   SoC, and the ROM, ELE and SPL stages already authenticate and select the
   images (§7.1).

5. **Should OP-TEE use RPMB secure storage, which also gives TA downgrade
   protection?**
   Options: (a) yes, `CFG_RPMB_FS=y`; (b) no, REE-FS storage only.
   Recommendation: (a) if the board boots from eMMC and OP-TEE holds state
   of its own, with OP-TEE as the **only** RPMB owner, as
   [rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §7.3 recommends.
   That excludes the SPL rollback index of §5.2, which writes RPMB directly
   before OP-TEE runs: the two are not supported together until a shared
   layout and a compatible key derivation are validated (§5.2). Under (a),
   the container's anti-rollback rests on the fuse version (§5.1, question 2
   (b)) and any later check that goes through OP-TEE. If the owner prefers
   the SPL index, then (b), and SPL is the only RPMB owner. RPMB key
   programming is a provisioning step that belongs to the oem-key-provisioning
   row and is not covered here.

6. **Which boot device does the product use?**
   Options: (a) eMMC; (b) FlexSPI NOR (`imx95_19x19_frdm_pro_fspi_defconfig`
   exists [S3]).
   Recommendation: none from the sources. Questions 2 (a), 3 (a) and 5 (a)
   all need eMMC RPMB or GPT, so a NOR-only design would rule them out. Even
   on eMMC, the SPL rollback index (2 (a), and 3 (a), which raises it) and
   OP-TEE RPMB storage (5 (a)) cannot both own RPMB (§5.2).
