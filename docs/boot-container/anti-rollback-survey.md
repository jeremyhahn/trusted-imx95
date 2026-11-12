# Boot container anti-rollback and AHAB version survey

Row: `boot-container` (#12). Issue: #41. Status: survey for the owner's decision. This record is documentation only. No fuse, life-cycle or provisioning step is run or scripted here, and none is proposed for a script.

This survey covers the public material on anti-rollback for AHAB containers on the i.MX 9 series, with the i.MX 95 as the target: the version fields in the container header, the fuses behind them, how NXP's U-Boot, imx-mkimage and SPSDK set and check those fields, and what public sources say about the boot ROM. All text is a summary in this repository's own words. Source tags such as **[S2]** refer to the source list in §1.

## 1. Sources

### 1.1 Reached and read

| Tag | Title | Version surveyed | URL |
|-----|-------|------------------|-----|
| S1 | U-Boot (upstream), `include/imx_container.h` | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/include/imx_container.h |
| S2 | NXP U-Boot fork `uboot-imx`, `doc/imx/imx95_container.txt` ("i.MX95 Image Container Format") | branch `lf_v2026.04`, commit `bb41975aeb4cbd153b49c9fd62da1d64cd65968d` | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/doc/imx/imx95_container.txt |
| S3 | `uboot-imx`, `doc/imx/ahab/introduction_ahab.txt` ("i.MX Secure and Encrypted Boot using AHAB") | same commit as S2 | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/doc/imx/ahab/introduction_ahab.txt |
| S4 | `uboot-imx`, `arch/arm/mach-imx/ele_ahab.c` (the `ahab_commit` command and the ELE event names) | same commit as S2; the same command is also in upstream U-Boot `v2026.10` | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/arch/arm/mach-imx/ele_ahab.c |
| S5 | `uboot-imx`, `drivers/misc/imx_ele/ele_api.c` and `arch/arm/include/asm/mach-imx/ele_api.h` (`ele_commit`, `ELE_COMMIT_REQ`) | same commit as S2; also upstream `v2026.10` | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/drivers/misc/imx_ele/ele_api.c |
| S6 | `uboot-imx`, `common/spl/spl_imx_container.c` | same commit as S2 | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/common/spl/spl_imx_container.c |
| S7 | `uboot-imx`, `lib/avb/fsl/fsl_bootctrl.c` (`check_rollback_index`) and `arch/arm/mach-imx/Kconfig` (`IMX_ROLLBACK_BLOB`) | same commit as S2 | https://github.com/nxp-imx/uboot-imx/blob/bb41975aeb4cbd153b49c9fd62da1d64cd65968d/lib/avb/fsl/fsl_bootctrl.c |
| S8 | NXP `imx-mkimage`, `src/mkimage_imx8.c` and `src/imx8qxb0.c` | branch `lf-6.18.20_2.0.0`, commit `1b577853ae1afe1f26cdef27548da52fb424af48` | https://github.com/nxp-imx/imx-mkimage/blob/1b577853ae1afe1f26cdef27548da52fb424af48/src/mkimage_imx8.c |
| S9 | `imx-mkimage`, `iMX95/soc.mak` | same commit as S8 | https://github.com/nxp-imx/imx-mkimage/blob/1b577853ae1afe1f26cdef27548da52fb424af48/iMX95/soc.mak |
| S10 | NXP SPSDK, `spsdk/image/ahab/ahab_container.py` and `ahab_image.py` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/image/ahab/ahab_container.py |
| S11 | SPSDK, `spsdk/image/ahab/signed_msg.py` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/image/ahab/signed_msg.py |
| S12 | SPSDK, `spsdk/data/devices/mimx9596/fuses.json` (SPSDK's fuse description for the i.MX 95) | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/data/devices/mimx9596/fuses.json |

### 1.2 Not reached, or not public (unconfirmed)

Requests from the lane to `www.nxp.com/docs/...` returned HTTP 404 for every document tried, including documents that NXP publishes. Nothing below was read. Claims that depend on these documents are marked **unconfirmed** in the text.

| Title | Why it matters | State |
|-------|----------------|-------|
| AN12312, *Secure Boot on i.MX 8 and i.MX 8X Families using AHAB* | The public explanation of AHAB versions and SRK revocation (for i.MX 8, not i.MX 95) | Not reached (HTTP 404 from the lane) |
| RM00284, *EdgeLock Secure Enclave firmware API reference* (cited by `docs/SPEC.md` §3.24 for the monotonic counter) | The meaning of the `ELE_COMMIT_REQ` index bits, and the monotonic counter | Not reached; public availability not confirmed |
| IMX95RM, *i.MX 95 Applications Processor Reference Manual* | The fuse map: which fuse words hold the OEM version floor, and how many increments they allow | Listed as missing in `docs/SPEC.md`; not reached |
| *i.MX 95 Security Reference Manual* | Boot ROM and ELE behaviour on a version mismatch | Listed as missing in `docs/SPEC.md`; NDA document, not public |
| *i.MX Linux User's Guide* (NXP BSP documentation) | The BSP's documented `ahab_commit` flow | Not reached (HTTP 404 from the lane) |
| SPSDK documentation site, https://spsdk.readthedocs.io/ | User documentation for the AHAB configuration keys | Reachable, but not read in this slice; the survey relies on the SPSDK source (S10) |

## 2. The two version fields in the container header

- Every AHAB container header carries an 8-bit **fuse version** and a 16-bit **SW version**, next to the image count and the signature block offset **[S1] [S2]**. U-Boot's header structure declares them as `fuse_version` (`u8`) and `sw_version` (`u16`) **[S1]**.
- On the i.MX 95, the Cortex-M33 ROM processes the container sets. If an ELE (EdgeLock firmware) container is present, its header comes first, before the OEM containers **[S2]**. Each container has its own pair of version fields, so the NXP ELE container and the OEM containers are versioned separately **[S2] [S4]**.
- The i.MX 95 B0 uses AHAB 2.0, which has container header version 2 and two 512-bit SRK hash fuse regions **[S3]**. Whether the two version fields sit at the same place and mean the same thing in container version 2 is **unconfirmed**. The U-Boot (S1) and mkimage (S8) structures read in this survey show one layout for both.

### 2.1 Fuse version: the hardware floor

- SPSDK describes the container's fuse version as a minimum. The container loads only if its fuse version is equal to or greater than the version held in the device's fuses **[S10]**. This is the only public statement of the check found in this survey. The check is made by the boot ROM and ELE, not by software the OEM controls. The exact ROM and ELE behaviour on the i.MX 95 (fail closed, or fall back to a second boot image) is **unconfirmed**, because the Security Reference Manual is missing.
- The fused value moves forward through a separate *commit* request to ELE. U-Boot's `ahab_commit` command sends `ELE_COMMIT_REQ` (0xA8) with a caller-chosen index. The command's help text says it burns into fuses any new SRK revocation and firmware version information that ELE found in the NXP and OEM containers **[S4] [S5]**. ELE has a dedicated failure event for a bad monotonic counter (`ELE_BAD_MONOTONIC_COUNTER_FAILURE_IND`, 0xFE), which U-Boot decodes when it reports ELE events **[S4] [S5]**.
- The meaning of each bit in the commit index, and whether OEM container versions are committed separately from the ELE firmware version, come from RM00284 and are **unconfirmed**.
- How many fuse bits back the OEM version floor on the i.MX 95, and therefore how many times it can be raised, is **unconfirmed**. SPSDK's i.MX 95 fuse description (S12) names no fuse as a version or rollback floor. Searching it for rollback and monotonic-counter names found only a V2X SHE monotonic counter lock **[S12]**. The fuse map is in IMX95RM, which is missing.
- A fuse cannot be cleared. Each raise of the floor is permanent, and it is limited by the fuse capacity, which is unconfirmed. This follows from the commit being a fuse write **[S4]**.

### 2.2 SW version: a software-checked rollback index

- SPSDK says the SW version is used by a privileged host boot companion to choose between several images that share the same fuse version **[S10]**. Hardware does not enforce it.
- NXP's U-Boot SPL copies the container's SW version into the boot image's rollback index (`rbindex`) **[S6]**. In NXP's Android-oriented boot control (`CONFIG_IMX_TRUSTY_OS`, `CONFIG_DUAL_BOOTLOADER`), SPL compares that index with one stored in the eMMC RPMB partition and rejects a lower index. It writes a higher index back to RPMB only after the slot has booted successfully. The check runs only when an RPMB key is set **[S7]**. A Kconfig option (`IMX_ROLLBACK_BLOB`) keeps the stored index in RPMB as a sealed blob instead of plain text **[S7]**.
- This path needs eMMC RPMB, an RPMB key and the Trusty or dual-bootloader configuration **[S7]**. Whether the FRDM-IMX95 platform image will use any of these is not decided (see `docs/SPEC.md`, owner decides the image build).

## 3. How the tools set the fields

- **imx-mkimage.** `-fuse_version` takes an 8-bit value and `-sw_version` a 16-bit value. Both default to 0 and are written into the container header, and the tool prints both back when it parses a container **[S8]**. The i.MX 95 makefile passes `-sw_version` only for the Cortex-A55 container (ATF, U-Boot, optional TEE), and only when `ROLLBACK_INDEX_IN_CONTAINER` is set. It does not pass `-fuse_version`, so the default build leaves the fuse version at 0 **[S9]**.
- **SPSDK.** The AHAB container configuration has `fuse_version` and `sw_version` keys. Both default to 0, or to the family's template value, when the configuration is generated **[S10]**. SPSDK also models the ELE signed messages. One of them, the key store reprovisioning enable message, carries its own monotonic counter field **[S11]**. That counter protects the key store and is separate from the container's version floor (see the `secure-key-handling` row in `docs/SPEC.md`).
- **NXP CST.** CST builds the signature block and SRK table **[S3]**. Whether CST 3.1.0 also sets the version fields, or leaves them to mkimage, is **unconfirmed**. The CST user guide was not read in this survey.

## 4. Summary of what is known

| Mechanism | Field | Enforced by | Storage | Reversible | Source |
|-----------|-------|-------------|---------|------------|--------|
| AHAB fuse version floor | `fuse_version` (8 bits) | ROM and ELE | OTP fuses, raised by an ELE commit | No | S1, S4, S5, S10 |
| Bootloader rollback index | `sw_version` (16 bits) | U-Boot SPL (NXP fork, Trusty or dual-bootloader build) | eMMC RPMB | Only by whoever holds the RPMB key | S6, S7, S9 |
| ELE firmware version | NXP's ELE container fields | ELE | Fuses, through the same commit | No | S2, S4 |

Unconfirmed: the i.MX 95 fuse words and their capacity, the commit index bits, ROM fallback on failure, the container version 2 layout of the fields, and CST's role in setting them.

## 5. Questions for the owner

1. **What enforces the anti-rollback floor for the boot container?**
   - (a) The AHAB fuse version alone: hardware enforced and permanent, with a limited number of raises.
   - (b) The SW version checked by SPL against RPMB alone: software enforced, needs eMMC RPMB, an RPMB key and NXP's Trusty or dual-bootloader build.
   - (c) Both: the fuse version as a coarse "security epoch", raised only for security fixes, and the SW version as the per-release number.
   - *Recommendation:* (c), with the fuse version left at 0 until the fuse capacity is confirmed from IMX95RM. The sources support the two-tier design: SPSDK describes the fuse version as the floor and the SW version as the selector between images within one floor **[S10]**, and NXP's SPL already checks the SW version **[S6] [S7]**. Whether (b) applies at all depends on the platform image decision.

2. **When, and by whom, is the fused floor raised (the ELE commit)?**
   - (a) Never. The floor stays at 0 and the only protection is the SW version and the SRK.
   - (b) A manual, owner-authorised step after a new image has booted and been confirmed good, run outside this repository's scripts.
   - (c) Automatically by the boot firmware after a successful boot.
   - *Recommendation:* (b). The commit burns fuses irreversibly **[S4]**, and this repository's rules forbid scripted fuse steps. Option (c) would brick a device whose recovery image is older than the new floor. The ROM fallback behaviour that would decide this is unconfirmed.

3. **What numbering scheme do the fields follow?**
   - (a) Fuse version = security epoch (0, 1, 2, ...), raised only for a vulnerability that rollback would expose. SW version = a monotonic build or release counter.
   - (b) Both fields equal to the release number.
   - *Recommendation:* (a). The fuse field is 8 bits wide **[S1]**, but the fused capacity behind it is unconfirmed and is probably smaller. A per-release raise would exhaust it.

4. **Which tool writes the version fields: imx-mkimage or SPSDK?** This depends on the CST versus SPSDK decision (#9).
   - (a) imx-mkimage with `-fuse_version` and `-sw_version` **[S8]**. NXP's i.MX 95 makefile wires up only `-sw_version` **[S9]**.
   - (b) SPSDK's AHAB configuration keys **[S10]**.
   - *Recommendation:* follow #9. Either tool sets both fields. Whichever is chosen, the build must set the fields explicitly and not rely on the default of 0 **[S8] [S10]**.

5. **Do the Cortex-M7 container and the Cortex-A55 container share one version policy?** NXP's makefile versions only the A55 container **[S9]**, while this row's subject is the M7 image of trusted-firmware's `imx95` row (`docs/SPEC.md`).
   - (a) One policy and one number for every OEM container in the set.
   - (b) Separate numbers for each container.
   - *Recommendation:* (a), until it is confirmed whether ELE keeps one OEM floor or one per container (unconfirmed, RM00284).

6. **Should the unconfirmed items be closed before any version policy is fixed?** The items are the IMX95RM fuse map, the Security Reference Manual on ROM fallback, and RM00284 on the commit index.
   - (a) Yes: get the documents (some are under NDA) into the private reference repository first.
   - (b) No: adopt the reversible part now (the SW version numbering) and defer every fuse decision.
   - *Recommendation:* (b) now, and (a) before the first fuse commit on any device.
