# Secure world: upstream survey of TF-A, OP-TEE and U-Boot on the i.MX 95

> **Status: SURVEY** · Row: secure-world (#16) · Issue: #32 · Surveyed: 2026-11-12
> This record lays out the options. The owner makes the decision.

This survey covers upstream and NXP-tree support for the i.MX 95 in TF-A (BL31), OP-TEE OS and U-Boot SPL. For
each tree it records the platform ports, the version or tag read, the core and TrustZone layout the tree assumes, and
the gaps for our device, the NXP FRDM-IMX95-PRO. It closes with the owner's questions for the `secure-world` row of
[SPEC.md](../SPEC.md).

The survey uses public sources only: the projects' public Git repositories at the tags named below. Nothing in it
is copied from vendor documents. It summarises what the build files and configuration in those trees say. When a
statement here is an inference rather than something a file states, the text says so. The NXP manuals in
[references/](../references/README.md) were not read for this survey.

## Sources

| # | Source | Version surveyed | URL |
|---|---|---|---|
| S1 | Trusted Firmware-A, upstream | tag `v2.15.0` (commit of 2026-05-28) | https://github.com/ARM-software/arm-trusted-firmware |
| S2 | NXP `imx-atf` (NXP's TF-A tree) | tag `lf-6.18.37-2.1.0` (2026-09-01); newest branch `lf_v2.14` | https://github.com/nxp-imx/imx-atf |
| S3 | OP-TEE OS, upstream | tag `4.11.0` (2026-10-16) | https://github.com/OP-TEE/optee_os |
| S4 | NXP `imx-optee-os` | tag `lf-6.18.37-2.1.0` (2026-09-07) | https://github.com/nxp-imx/imx-optee-os |
| S5 | U-Boot, upstream | tag `v2026.10` (2026-10-05) | https://source.denx.de/u-boot/u-boot (redirects to git.u-boot-project.org) |
| S6 | NXP `uboot-imx` | tag `lf-6.18.37-2.1.0` (2026-09-03) | https://github.com/nxp-imx/uboot-imx |
| S7 | NXP System Manager `imx-sm` | tag `rel_imx_sm_2026q3` (2026-09-03) | https://github.com/nxp-imx/imx-sm |
| S8 | NXP `imx-mkimage` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-mkimage |
| S9 | NXP Yocto layer `meta-imx` | tag `rel_imx_6.18.20_2.0.0` (branch `wrynose-6.18.20-2.0.0`, the repository's default branch) | https://github.com/nxp-imx/meta-imx |
| S10 | Linux device trees, as mirrored in U-Boot's `dts/upstream` | U-Boot `v2026.10` | https://source.denx.de/u-boot/u-boot |

Files read in each tree:

- S1, S2: `plat/imx/imx9/` (directory listing), `plat/imx/imx9/imx95/platform.mk`, `docs/plat/imx9.rst`. For S1
  only, the base and core-count defines in `plat/imx/imx9/imx95/include/platform_def.h`.
- S3, S4: `core/arch/arm/plat-imx/conf.mk` (S4 compared line by line with S3), and the directory listing of
  `core/drivers/crypto/ele/`.
- S5, S6: `doc/board/nxp/imx95_frdm.rst` (S5), `configs/imx95_19x19_frdm_pro_defconfig` (S6), and the board, config
  and device-tree listings.
- S7: `configs/mx95frdm.cfg` and the `boards/` and `configs/` listings.
- S8: `iMX95/soc.mak`.
- S9: `meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf` and the file names of the OP-TEE recipes.

## Findings

### Boot chain and image layout

- The upstream TF-A document for the i.MX 9 family gives the chain BootROM, SPL, BL31, BL33 (U-Boot), Linux. It
  says the image is assembled with `imx-mkimage` together with the EdgeLock (ELE) firmware. Its build instructions
  name only the i.MX 93 as a target, even though the tree has an i.MX 95 port (S1 `docs/plat/imx9.rst`). The same
  document in S2 is identical.
- Upstream U-Boot's i.MX 95 FRDM page lists the inputs to the boot image: the ELE AHAB container, the DDR PHY
  firmware, the OEI image (built from `nxp-imx/imx-oei`, the DDR initialisation that runs on the Cortex-M33), the
  System Manager image, and `bl31.bin`. For BL31 it points to NXP's `imx-atf` branch `lf_v2.12`, not to upstream
  TF-A (S5 `doc/board/nxp/imx95_frdm.rst`).
- In `imx-mkimage`, the A55 container holds `bl31.bin`, U-Boot and, if one is present, an OP-TEE image (`tee.bin`).
  Their default load addresses are 0x8A200000 for BL31, 0x90200000 for U-Boot and 0x8C000000 for OP-TEE. An
  optional `-sw_version` field carries a rollback index. The container version defaults to 2 for i.MX 95 B0 silicon
  (S8 `iMX95/soc.mak`). The rollback index ties this row to the `boot-container` row's anti-rollback floor.

### TF-A (BL31)

- Upstream TF-A `v2.15.0` has an i.MX 95 BL31 port, `PLAT=imx95`, under `plat/imx/imx9/imx95`. It shares
  `plat/imx/imx9/common` with the i.MX 94 (S1). Its build file sets the following (S1 `platform.mk`,
  `platform_def.h`):
  - RESET_TO_BL31, so BL31 is the first A55 image and there is no BL1 or BL2;
  - six cores in one cluster, with the GIC-600 driver;
  - an SCMI client to the System Manager (power domains, system power and NXP vendor extensions);
  - an ELE API client;
  - BL31 at 0x8A200000 to 0x8A240000;
  - a BL32 region of 32 MiB at 0x8C000000.
- NXP's `imx-atf` at `lf-6.18.37-2.1.0` has the same port with three additions (S2 `platform.mk`):
  - extra sources named `imx95_m7.c` and `imx95_lmm.c`. Going by their names, they handle the M7 and the System
    Manager's logical machines. This survey did not read them, so their behaviour is **unconfirmed**;
  - the SCMI base protocol;
  - a shared-memory source that is built when `SPD=trusty`.

  The tree also carries i.MX 937 and i.MX 952 ports, which upstream does not have.
- Gap: neither TF-A tree has a board-specific build for the FRDM-IMX95-PRO. BL31 is per SoC, not per board (S1, S2).
  This survey did not confirm whether upstream `v2.15.0` BL31 boots on the board as it is.

### OP-TEE OS (BL32)

- Upstream OP-TEE `4.11.0` supports the i.MX 95 as `PLATFORM_FLAVOR=mx95evk`, and only under that flavour (S3
  `conf.mk`). It assumes:
  - six cores, AArch64 and GICv3, running under TF-A;
  - no TZC380, CAAM, SNVS or OCOTP driver;
  - the ELE driver, reached through the messaging unit (`CFG_IMX_MU`, `CFG_IMX_ELE`);
  - 2 GiB of DDR at 0x80000000, with a second non-secure DDR bank from 0x100000000, and UART1 as the console.

  What upstream OP-TEE gets from the ELE on the i.MX 95 is the messaging unit, the hardware unique key (HUK) and
  random numbers. The upstream ELE directory also holds key-generation, ECDSA signing and verification code
  (S3 `core/drivers/crypto/ele/`), but at the same `4.11.0` release that ECC path is limited by its commit message to
  the i.MX 91 and i.MX 93 and does not build for the i.MX 95. It also returns the private key to caller memory in
  plain text, and no upstream use of the enclave's opaque key store on the i.MX 95 was found
  ([ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md) §5.1). Upstream OP-TEE therefore does
  **not** by itself give the enclave-held signing that [SPEC.md](../SPEC.md)'s `secure-key-handling` row requires.
  Enabling the plain-text path would break that row's rule that keys never leave the enclave in the clear.
  Opaque-key (enclave key store) integration in OP-TEE for the i.MX 95 is required work, not existing support.
  A comment in S3's `conf.mk` says the TZASC check is not yet supported on the i.MX 9 family.
- Upstream places OP-TEE's secure DRAM at the top of the DDR size it is given. For `mx95evk` that works out at about
  0xFE000000 (this survey's own arithmetic from the S3 defaults). TF-A and `imx-mkimage` expect BL32 at 0x8C000000
  (S1, S8). An upstream build therefore has to override `CFG_TZDRAM_START`; that is an inference, not tested.
- NXP's `imx-optee-os` at `lf-6.18.37-2.1.0` puts the i.MX 95 secure DRAM at DRAM base + 0x0C000000, that is
  0x8C000000, with 32 MiB for OP-TEE and 2 MiB of shared memory after it. This matches TF-A and `imx-mkimage` (S4
  `conf.mk`). For the i.MX 95 it also adds:
  - ELE-backed RSA, a key-store source and a fuse source (NXP-specific; whether the key-store source keeps private
    keys inside the enclave on the i.MX 95 was not read and is **unconfirmed**);
  - a trusted-keys early TA;
  - `CFG_IMX_TRUSTED_ARM_CE`;
  - the external DTB overlay (S4 `conf.mk`, `core/drivers/crypto/ele/`).
- NXP's Yocto layer builds OP-TEE `4.10.0` (`optee-os_4.10.0.imx.bb`) in the 6.18.20-2.0.0 release (S9). This
  survey did not read which `PLATFORM_FLAVOR` that recipe uses for the FRDM-IMX95-PRO, so it is **unconfirmed**.
  Neither OP-TEE tree has an FRDM flavour (S3, S4).

### U-Boot (SPL and BL33)

- Upstream U-Boot `v2026.10` has the boards `imx95_evk` and `imx95_frdm`, with the defconfigs
  `imx95_15x15_frdm_defconfig`, `imx95_15x15_evk_defconfig` and `imx95_19x19_evk_defconfig`. Its FRDM page describes
  the i.MX 95 **15x15** FRDM board with LPDDR4X (S5). Upstream has **no FRDM-IMX95-PRO defconfig and no device tree
  for it**. The Linux device trees mirrored in `dts/upstream` include `imx95-15x15-frdm.dts` but no
  `imx95-19x19-frdm-pro` (S10).
- NXP's `uboot-imx` at `lf-6.18.37-2.1.0` has the defconfigs `imx95_19x19_frdm_pro_defconfig` and
  `imx95_19x19_frdm_pro_fspi_defconfig`, and Android variants of them. Their device tree is `imx95-19x19-frdm-pro`,
  their target is `TARGET_IMX95_19X19_FRDM_PRO`, and they use the SPL's i.MX container loader (S6). The board code
  sits in `board/nxp/imx95_frdm`, which the 15x15 FRDM shares (S6).
- NXP's machine `imx95-19x19-lpddr5-frdm-pro` uses the following (S9):
  - the U-Boot config `imx95_19x19_frdm_pro`;
  - the System Manager config `mx95frdm-pro`;
  - the OEI board `mx95lp5` with LPDDR5;
  - the kernel device tree `imx95-19x19-frdm-pro`;
  - the M7 demo images.

### System Manager and the TrustZone layout it imposes

- On the i.MX 95, the System Manager on the Cortex-M33 assigns the processors, resources and memory regions to
  logical machines. Its board configuration sets the secure and non-secure access rights, and the SoC enforces them
  in hardware. This survey read that model from the configuration files only. The hardware semantics (TRDC) are in
  IMX95RM, which is missing ([references/](../references/README.md)).
- `configs/mx95frdm.cfg` at `rel_imx_sm_2026q3` defines three logical machines (S7):
  - **LM0** is the System Manager itself, on the M33, secure.
  - **LM1** is the Cortex-M7. It is given DDR from 0x80000000 to 0x89FFFFFF.
  - **LM2** is the Cortex-A55 cluster, the default machine. It has a secure execution environment and a non-secure
    one:
    - The secure environment owns ELE messaging units 1 and 2, OCRAM at 0x20480000 (256 KiB), and DDR from
      0x8A000000 to 0x8DFFFFFF. That DDR range covers BL31 at 0x8A200000 and the 32 MiB BL32 region at 0x8C000000.
    - The non-secure environment owns DDR from 0x88000000 to 0x89FFFFFF and from 0x8E000000 upward. NXP's OP-TEE
      shared memory, at 0x8E000000, falls in this range.
- The SM layout, TF-A, `imx-mkimage` and NXP's OP-TEE agree on the A55 secure carve-out (S2, S4, S7, S8). Upstream
  OP-TEE's default does not (S3).
- Gap: the `mx95frdm` configuration in S7 appears to be the 15x15 LPDDR4X FRDM board, not the PRO. U-Boot's FRDM page
  builds the OEI for `mx95lp4x-15` (S5). NXP's PRO machine names a System Manager config `mx95frdm-pro` (S9), and no
  such config exists in `imx-sm` at `rel_imx_sm_2026q3` (S7). Where that config comes from (a later tag, or a patch
  in the Yocto recipe) is **unconfirmed**.

## Not confirmed

- The FRDM-IMX95-PRO's DDR size and package, from UM12527. That document is in the private context repository and
  was not read for this survey. The 19x19 package and LPDDR5 come only from NXP's machine and defconfig names (S6,
  S9).
- The source of the System Manager config `mx95frdm-pro` (see the gap above).
- The OP-TEE `PLATFORM_FLAVOR` and `CFG_TZDRAM_*` values that NXP's Yocto recipe passes for the PRO.
- What `imx95_m7.c` and `imx95_lmm.c` do in NXP's TF-A.
- Whether upstream TF-A `v2.15.0`, upstream OP-TEE `4.11.0` or upstream U-Boot `v2026.10` boot on the PRO at all.
  No build or boot was attempted.
- Mainline Linux itself; only U-Boot's mirror of its device trees was read (S10).
- The TRDC and boot-ROM behaviour, and the secure life cycle's effect on the secure world. They are in IMX95RM and
  the i.MX 95 Security Reference Manual, both missing.
- The ELE firmware version that the 6.18.37 release pairs with. U-Boot's page names `firmware-ele-imx-2.0.2` (S5);
  this survey did not check it against the release.

## Questions for the owner

1. **What does the secure world cover?**
   - (a) The A55's TrustZone only (BL31, plus BL32 if Q2 adds one). The M33 stays NXP's System Manager, and the M7
     stays trusted-firmware's `imx95` row.
   - (b) (a), plus a secure-world role on the M7.
   - (c) (a), plus changes to the System Manager's logical-machine layout beyond configuration.

   *Recommendation: (a).* The System Manager already isolates the M33, the M7 and the A55 secure environment as
   separate logical machines (S7), and SPEC.md's Boundaries keep the M33 and the M7 out of this repository's code.
2. **Which BL32, if any, runs on the A55?**
   - (a) None: BL31 only.
   - (b) OP-TEE.
   - (c) Trusty, which NXP's TF-A supports with `SPD=trusty` for its Android builds (S2).

   *Recommendation: (b).* NXP's container build places an OP-TEE image beside BL31 (S8). Upstream OP-TEE takes the HUK
   and random numbers from the ELE on the i.MX 95 ([ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md)
   §5.1). It does not provide enclave-held key management or signing
   there: its ELE ECC path is limited to the i.MX 91/93 and returns plain-text private keys (see the OP-TEE section
   above). NXP's fork adds ELE-backed RSA and a key-store source whose key handling is unconfirmed (S4). The SM gives
   the A55 secure environment the ELE messaging units (S7). So (b) is recommended for the HUK, RNG and secure
   storage; enclave-held signing from OP-TEE needs opaque-key integration as separate work, and the plain-text ECC
   path must stay disabled.
3. **Which trees does the build use?**
   - (a) NXP's `lf-6.18.37-2.1.0` trees (S2, S4, S6, S8) and `meta-imx`.
   - (b) Upstream TF-A `v2.15.0`, OP-TEE `4.11.0` and U-Boot `v2026.10`, adding the PRO's board support ourselves.
   - (c) NXP's trees for the first boot, with a tracked plan to move each component upstream as the PRO lands there.

   *Recommendation: (c).* Only NXP's trees have the PRO's U-Boot defconfig and device tree (S6, S10). Upstream TF-A
   and OP-TEE already have i.MX 95 ports (S1, S3). Upstream U-Boot's i.MX 95 FRDM page itself points to NXP's TF-A
   (S5). This question depends on the `platform-image` row's build-system question.
4. **Is NXP's A55 secure memory layout accepted?** The layout is BL31 at 0x8A200000, BL32 at 0x8C000000 (32 MiB), and
   shared memory at 0x8E000000.
   - (a) Accept it.
   - (b) Define our own layout in the SM config, the TF-A build and the OP-TEE build together.

   *Recommendation: (a).* The SM layout, TF-A, `imx-mkimage` and NXP's OP-TEE agree on it (S2, S4, S7, S8). An
   upstream OP-TEE build must then set `CFG_TZDRAM_START` to match (S3).
5. **Which side calls the ELE HSM API?** SPEC.md's `secure-key-handling` row asks the same question.
   - (a) OP-TEE in the A55 secure world.
   - (b) Linux on the A55, in the non-secure world.
   - (c) The Cortex-M7.

   *No recommendation from these sources.* The SM config gives ELE messaging units 1 and 2 to the A55 secure
   environment (S7). This survey did not check which units, if any, Linux or the M7 is given.
6. **Where does the PRO's System Manager config come from?**
   - (a) A later `imx-sm` tag.
   - (b) NXP's Yocto recipe or its patches.
   - (c) A config of our own, derived from `mx95frdm`, held under `system-manager-config`.

   *No recommendation until the source of `mx95frdm-pro` is confirmed* (S7, S9).
7. **Does the A55 container carry a rollback index?**
   - (a) Yes, through `imx-mkimage`'s `-sw_version`, tied to the `boot-container` anti-rollback floor.
   - (b) Not yet.

   *No recommendation.* The field exists (S8), but its effect is in the missing i.MX 95 Security Reference Manual.
