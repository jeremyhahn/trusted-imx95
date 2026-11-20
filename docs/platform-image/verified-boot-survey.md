# Platform image: verified boot chain survey

> **Status: SURVEY, draft for the owner** · Row: `platform-image` (issue #14) · Issue: #52
> Public sources only. Vendor text is summarised, never copied. No fuse, life-cycle or provisioning step is run or scripted here.

## 1. Scope

This survey traces the chain of trust that the FRDM-IMX95-PRO would follow from power-on to the root filesystem, using only public NXP repositories and upstream project documentation. It answers, stage by stage: who verifies the next image, with which key, using which public tool, and what is still unknown without the i.MX 95 reference and security manuals (which `docs/SPEC.md` lists as missing). It decides nothing; section 5 lists the decisions for the owner.

Out of scope: the content of the Cortex-M7 firmware (trusted-firmware's `imx95` row), key custody design (the `boot-container` row and AN14471), and any fuse, life-cycle or provisioning step. Where a source shows fuse commands, this survey only notes that it does and does not reproduce them.

## 2. Sources and versions surveyed

All sources were read on 2026-11-12 from the public internet. "Ref" is the git ref read; a branch head is named with the tag it carried at that date.

| # | Source | Version / ref | URL |
|---|---|---|---|
| S1 | U-Boot, board doc `doc/board/nxp/imx95_frdm.rst` (i.MX95 15x15 FRDM and 19x19 FRDM PRO) | upstream `main` at commit 3cb2cbb (2026-11-11) | https://github.com/u-boot/u-boot/blob/master/doc/board/nxp/imx95_frdm.rst |
| S2 | NXP uboot-imx, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` (i.MX 8ULP/9x AHAB secure boot guide) | branch `lf_v2026.04`, tag `lf-6.18.37-2.1.0` (commit bb41975) | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |
| S3 | NXP imx-mkimage, `Readme.imx95` and `iMX95/soc.mak` | branch `lf-6.18.20_2.0.0`, tag `lf-6.18.20-2.0.0` (commit 1b57785) | https://github.com/nxp-imx/imx-mkimage/tree/lf-6.18.20-2.0.0 |
| S4 | NXP uboot-imx, `doc/imx/ahab/guides/sign_os_cntr.txt` (extending the root of trust to the OS container) | as S2 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/doc/imx/ahab/guides/sign_os_cntr.txt |
| S5 | NXP uboot-imx, `configs/imx95_19x19_frdm_pro_defconfig` | as S2 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/configs/imx95_19x19_frdm_pro_defconfig |
| S6 | Trusted Firmware-A, `docs/plat/imx9.rst` (NXP i.MX 9 series) | upstream `main` at commit d70b52d (2026-11-11) | https://github.com/TrustedFirmware-A/trusted-firmware-a/blob/master/docs/plat/imx9.rst |
| S7 | OP-TEE OS, `core/arch/arm/plat-imx/conf.mk` | upstream `master` at commit 3a19c71 (2026-11-11) | https://github.com/OP-TEE/optee_os/blob/master/core/arch/arm/plat-imx/conf.mk |
| S8 | U-Boot, `doc/usage/fit/verified-boot.rst` and `signature.rst` (FIT signature verification) | as S1 | https://docs.u-boot.org/en/latest/usage/fit/verified-boot.html, https://docs.u-boot.org/en/latest/usage/fit/signature.html |
| S9 | SPSDK documentation, example "AHAB SIGN" (i.MX 95 B0, ML-DSA plus ECC) | docs `latest`, SPSDK 3.13.0 on PyPI (2026-11-03) | https://spsdk.readthedocs.io/en/latest/examples/ahab/imx95/imx95_ahab_sign.html |
| S10 | SPSDK documentation, example "i.MX 95 signed AHAB with U-BOOT" (`nxpimage ahab` template for `mimx9596`) | as S9 | https://spsdk.readthedocs.io/en/latest/examples/ahab/imx95/imx95_signed_ahab_uboot.html |
| S11 | SPSDK documentation, example "i.MX95 Anti-rollback Protection Example" | as S9 | https://spsdk.readthedocs.io/en/latest/examples/ahab/imx95/imx95_anti_rollback_protection.html |
| S12 | Linux kernel documentation, "dm-verity" (admin guide, device-mapper) | docs.kernel.org `latest` (built from 7.4.0-rc2), read 2026-11-12 | https://docs.kernel.org/admin-guide/device-mapper/verity.html |
| S13 | U-Boot, `doc/usage/fit/dm-verity.rst` (FIT dm-verity boot parameters) | as S1 | https://docs.u-boot.org/en/latest/usage/fit/dm-verity.html |

Unreachable or not read: NXP CST download page and CST 4.0.1 release notes (404 from this lane; NXP account required); AN14533 (https://www.nxp.com/doc/AN14533, not fetched); the i.MX 95 Security Reference Manual and IMX95RM (not public); the NXP i.MX Linux User's Guide. See §4.

## 3. The chain, stage by stage

### 3.1 Boot ROM and EdgeLock (AHAB) containers

- The i.MX 95 boot image is a sequence of AHAB containers, each with a header and a signature block. The ROM of the EdgeLock secure enclave (ELE) authenticates the first container, which carries the ELE firmware signed by NXP; the ELE firmware then authenticates the next containers, which are signed with the OEM's keys (S2 §1.3).
- On the i.MX 95 the ELE-authenticated part of the image holds, in order, the ELE firmware, the V2X firmware, an optional executable image (the OEI, used for DDR training), the Cortex-M image and the SPL. A further container with TF-A (BL31) and U-Boot proper follows and is authenticated later, at the SPL stage (S2 §1.3, the i.MX 95 layout).
- A container's signature block holds the SRK table (the public keys whose hash is fused), the signature and an optional subordinate key (SGK) certificate. With an SGK the certificate is checked against the SRK, and the container against the SGK; without one, the container is checked directly against the SRK (S2 §1.3).
- From i.MX 95 B0 onward the series uses **AHAB 2.0**. The CSF header for CST must say version 2.0; hybrid classic plus post-quantum signatures are possible, and a CSF option chooses whether every signature is checked or the fuse policy decides (S2 §1.1, §1.4.1.2).
- The root of trust is a hash of the SRK table in fuses. On i.MX 95 B0 the guide names two 512-bit SRK hash regions, one for classic (RSA/ECC) keys and one for PQC keys (S2 §1.6). This survey does not reproduce the fuse words or commands; they are provisioning steps, out of scope.
- After fusing, `ahab_status` in U-Boot reports the life cycle and any AHAB events; moving the part from OEM open to OEM closed is irreversible (S2 §1.7, §1.8). The guide checks a signed image on an open part by looking for events, not by a failed boot. For the version check, SPSDK's i.MX 95 example says plainly that an open part boots with an event and a closed part refuses to boot (S11). The same rule for a bad *signature* is not stated in any public i.MX 95 source found; it is in the Security Reference Manual, which is missing (§4).

### 3.2 imx-mkimage: what goes in the boot container

- The i.MX 95 has its own mkimage SoC type, `SOC=iMX95` (S3 `Readme.imx95` item 1).
- Targets are grouped by which core starts the Cortex-A55 side. `flash_singleboot` boots the A55 from the ELE-authenticated container; the `flash_lpboot_sm*` targets bring up the System Manager on the Cortex-M33, optionally with the Cortex-M7 (in TCM or DDR) and the A55 from SD/eMMC or FlexSPI NOR (S3 `Readme.imx95` items 2-3).
- Several targets have a `_no_ahabfw` variant that leaves the ELE firmware out of the image. For a secured product the ELE firmware container is the first link of the chain, so these variants are development aids only; whether a closed part boots without it could not be confirmed (§4).
- The OEI (DDR training on the M33 or A55) is optional and enabled with `OEI=YES` (S3 item 2). The upstream FRDM PRO build uses an OEI for its LPDDR5 (S1, "Get and Build OEI Images").
- Container flags for the ELE glitch, voltage, clock and temperature detectors (`GDET`, `VDET`, `AGDET`, `FDET`, `TMPSNS`) are set at mkimage time (S3 item 5). They matter to the `hsm-self-defence` row as well, because the signed container carries them.
- mkimage prints the container and signature-block offsets that the CST CSF file needs, so mkimage and the signer must run in the same pipeline (S2 §1.4.1.1, §1.4.1.3).

### 3.3 U-Boot SPL and U-Boot proper (AHAB authentication of later images)

- Upstream U-Boot supports the FRDM PRO with `imx95_19x19_frdm_pro_defconfig`. The build needs, besides U-Boot: the NXP-signed ELE firmware container (from NXP's `firmware-ele-imx` package, with separate A0 and B0 images), the LPDDR PHY firmware, an OEI built from `nxp-imx/imx-oei`, the System Manager built from `nxp-imx/imx-sm` with an FRDM PRO configuration, and BL31 from NXP's TF-A fork `nxp-imx/imx-atf` branch `lf_v2.12` (S1). That is five binaries from four NXP sources, each a link of the chain that must be built reproducibly and pinned.
- With `CONFIG_AHAB_BOOT`, SPL and U-Boot call the ELE through the AHAB API to authenticate further containers, report events and read the life cycle. This is how the chain is extended beyond the ELE-authenticated container: SPL loads the TF-A plus U-Boot container and asks the ELE to authenticate it (S2 §1.2, §1.3).
- The TF-A plus U-Boot container (`u-boot-atf-container.img`, optionally with OP-TEE) is built and signed first, then the outer image (`flash.bin`) containing the SPL container is built and signed (S2 §1.4.1).
- U-Boot can also authenticate an AHAB-signed "OS container" holding the kernel, which is NXP's root-of-trust extension (S2 §1.1 "Root of trust extension", §2).
- That OS container is built with mkimage's `flash_kernel` target and signed like the boot image. U-Boot checks it when the environment variable `sec_boot` says so, and the `auth_cntr` command checks one by hand; setting `sec_boot=no` skips the check (S4 §2). A check that one environment variable can turn off is only as strong as the protection of the U-Boot environment.
- The NXP FRDM PRO defconfig at S5 does **not** set `CONFIG_AHAB_BOOT`, `CONFIG_FIT_SIGNATURE` or a read-only environment. It keeps the environment in eMMC with `CONFIG_ENV_OVERWRITE`, and enables fastboot, the USB serial download protocol in SPL, `fuse` and the memory and filesystem write commands (S5). All of this suits a development board. A product image needs its own defconfig or fragment that turns on AHAB authentication and FIT signature checking, makes the environment fixed or signed, and removes the download and write paths. Whether `ARCH_IMX9` selects `AHAB_BOOT` implicitly was not checked in Kconfig (§4).

### 3.4 TF-A (BL31) and OP-TEE

- Upstream TF-A documents the i.MX 9 boot flow as boot ROM, then SPL, then BL31, then U-Boot (BL33), then Linux, with `imx95` as a supported `PLAT` value (S6). TF-A's own trusted-board-boot (BL1/BL2 with a chain of trust) is not used on i.MX 9: there is no BL2 in this flow, and BL31 is verified as part of the AHAB container that SPL authenticates through the ELE (S2 §1.3, S6).
- The upstream FRDM PRO build takes BL31 from NXP's fork `nxp-imx/imx-atf` (`lf_v2.12`), not from upstream TF-A (S1). Which one the platform image uses is a choice for the owner (Q3).
- OP-TEE is optional in the i.MX 9x secure boot flow. When it is used, it travels in the same SPL-authenticated container as BL31 and U-Boot (S2 §1.1, §1.4.1.1).
- Upstream OP-TEE has an i.MX 95 platform with one flavour, `mx95evk`. It builds for six A55 cores, talks to the ELE through the messaging unit (`CFG_IMX_ELE`), and turns off the older i.MX blocks the 95 lacks (SNVS, CAAM, OCOTP, TZC380) (S7, `plat-imx/conf.mk`). There is no FRDM PRO flavour upstream; the EVK flavour fixes the DDR size and UART, so the FRDM PRO needs at least its own flavour or overrides. Whether the board has an OP-TEE at all is the `secure-world` row's open question; this survey records only that the chain carries one at no extra signing step.

### 3.5 U-Boot to the kernel: FIT signature verification

Two public mechanisms carry the chain from U-Boot to Linux. They can be combined.

- **AHAB OS container** (NXP): the kernel goes in an AHAB container signed with the same SRK set, and U-Boot asks the ELE to authenticate it (S4). It uses the fused root directly, but is NXP-specific, and the check depends on the `sec_boot` environment variable (§3.3).
- **FIT signature verification** (upstream U-Boot): the kernel, device tree and initramfs go in a FIT image. U-Boot checks the signature against a public key held in its own control device tree. A chain can go on to further levels, each with its own key (S8, `verified-boot.rst`). The trust anchor is then U-Boot's own device tree, which on this SoC sits inside the AHAB container that SPL has the ELE authenticate. That gives one unbroken chain from the fused SRK hash to the kernel. Upstream recommends signing *configurations* rather than single images, so that a kernel and a device tree cannot be mixed and matched from different signed releases (S8, `signature.rst`).
- Neither the NXP FRDM PRO defconfig nor its upstream doc enables FIT signature checking (S5, S1). It is a build choice for this repository (Q4).

### 3.6 Root filesystem: dm-verity, IMA

- Linux's dm-verity checks a read-only block device against a hash tree as blocks are read. The tree's root hash must come from a trusted place: the signed kernel command line, a signed initramfs, or a root-hash signature that the kernel checks against a key in its trusted keyring (S12).
- Upstream U-Boot can produce the dm-verity parameters itself when the FIT carries the root filesystem as a `filesystem` loadable with a `dm-verity` subnode (`CONFIG_FIT_VERITY`). It appends `dm-mod.create=` to the kernel command line, so no initramfs is needed (S13). This relies on a Linux "uImage.FIT block driver" that exposes the FIT's loadables as `/dev/fitN`. Whether that driver is in mainline Linux, or in which kernel version, could not be confirmed (§4). With the root filesystem inside the FIT, the FIT is as large as the root filesystem, which affects the eMMC layout and A/B updates.
- The usual alternative, which needs no new driver, is a separate read-only verity partition whose root hash goes in the signed FIT (in the kernel command line or the initramfs) (S12, S8).
- IMA (measurement and appraisal of files at run time) is a different control from verified boot and was not surveyed here. `docs/SPEC.md` leaves the A55 side of `hsm-self-defence`, the IMA log included, open for the owner.

### 3.7 Signing tools: CST and SPSDK

- NXP's guide says that from i.MX 95 B0 (AHAB 2.0) signing needs **SPSDK or CST 4.0.1**. It also says SPSDK is NXP's recommended tool for the i.MX 9x family from now on, and that CST will get bug fixes only, with no new AHAB features (S2 §1.1). `docs/SPEC.md` (`boot-container`) names **CST 3.1.0**. Going by S2, CST 3.1.0 cannot sign AHAB 2.0 containers. This mismatch is for the owner (Q1); this lane does not edit SPEC.
- SPSDK's `nxpimage ahab` builds and signs i.MX 95 (`mimx9596`) containers from YAML. It can rebuild what imx-mkimage builds, as the primary set (ELE firmware, OEI/DDR, System Manager, optional M7 application, SPL) and the secondary set (BL31, U-Boot, TEE) (S10). It can also re-sign an existing `flash.bin`, with ML-DSA plus ECC keys on B0 (S9).
- SPSDK's container `signer` field takes either a key file or a *signature provider* plugin. With a plugin the private key can stay in an HSM, which is the custody model `docs/SPEC.md` asks for (S10; the plugin interface itself was not read, §4).
- The SRK table holds four public keys of one type. SPSDK lists RSA-PSS, ECDSA (P-256, P-384, P-521), Dilithium/ML-DSA and SM2, with PQC only in the new container format. A container names the SRK it uses and can carry a revoke mask (S10).
- The SPSDK examples were tested on the i.MX 95 **EVK**, not the FRDM PRO, and some were made on A0/A1 silicon, whose container format differs from B0 (S10, S11).
- CST's download page could not be reached from this lane: the URL tried answered 404, and NXP downloads need an account. CST 4.0.1's release notes were not read (§4).

### 3.8 Anti-rollback

- Each AHAB container has a `fuse_version`. The ELE loads a container only if its value is at least the version held in fuses, and the fused value moves up only when an ELE commit command is sent, which SPSDK's `nxpele` tool can do over the U-Boot console. NXP's ELE firmware container has its own fuse version, which follows the firmware's major version and is committed separately (S11).
- On an OEM open part, a container whose version is too low still boots and leaves an ELE "bad version" event. On OEM closed or locked parts it does not boot (S11). This is the only public i.MX 95 source found that says how enforcement depends on the life cycle.
- A separate `sw_version` lets a boot companion choose between images that share a fuse version (S10).
- AHAB anti-rollback covers only the containers: SPL, BL31, OP-TEE, U-Boot and, with S4, the OS container. A FIT-signed kernel and a dm-verity root filesystem need their own rollback rule, for example a version check in U-Boot or OP-TEE, or a counter in the enclave (RM00284 §3.24 per `docs/SPEC.md`). That mechanism was not surveyed (§4).
- How many fuse version steps the i.MX 95 has is in the fuse map, which is missing (IMX95RM, Security Reference Manual).

## 4. What could not be confirmed

1. **The i.MX 95 Security Reference Manual and IMX95RM** are not public and not in `references/`. Without them the following could not be confirmed: ROM behaviour on a failed signature in each life cycle (beyond S11's version check), the fuse map, the number of anti-rollback fuse steps, and whether the `_no_ahabfw` mkimage targets boot on a closed part.
2. **CST 4.0.1**: the download page and release notes could not be reached (404 from this lane; NXP downloads need an account).
3. **AN14533** (anti-rollback application note, linked from S11) was not read.
4. **SPSDK signature provider interface**: the plugin API, and whether it supports PKCS#11 or ML-DSA in an HSM, was not read.
5. **`CONFIG_AHAB_BOOT` default**: whether `ARCH_IMX9` or the i.MX 95 target selects it implicitly was not checked in Kconfig.
6. **Linux uImage.FIT block driver** (needed by `CONFIG_FIT_VERITY`): whether it is in mainline, and from which version.
7. **FRDM PRO silicon revision**: the upstream doc gives only B0 build steps for the FRDM PRO (S1). That the board in hand is B0 was not confirmed.
8. **NXP i.MX Linux User's Guide and Linux Reference Manual** (cited by S6) were not read; `docs/SPEC.md` lists the BSP documentation as missing.
9. **Issue #52's body** could not be read from this lane (no forge credentials); this survey follows the lane brief and the `platform-image` and `boot-container` rows of `docs/SPEC.md`.

## 5. Questions for the owner

1. **Signing tool for AHAB 2.0.** Options: (a) SPSDK `nxpimage` only; (b) CST 4.0.1 only; (c) both, with one as the cross-check. **Recommendation: (a) SPSDK**, because NXP names it the recommended tool for i.MX 9x and limits CST to bug fixes (S2 §1.1), and its signature provider fits HSM custody (S10). Whatever the choice, the `boot-container` row's "CST 3.1.0" needs correcting, because S2 says AHAB 2.0 needs CST 4.0.1 or SPSDK.
2. **Image layout.** Options: (a) mkimage's `flash_lpboot_sm_all` style (System Manager on the M33, M7 and A55 in one ELE-authenticated set); (b) `flash_singleboot`; (c) build the containers with SPSDK YAML instead of mkimage. No recommendation from the sources. (a) matches `docs/SPEC.md` (the board boots on the M33, and the M7 image must be in the signed container), but which target the FRDM PRO product image needs was not confirmed.
3. **TF-A and U-Boot sources.** Options: (a) NXP forks (`nxp-imx/imx-atf`, `nxp-imx/uboot-imx`) at a pinned `lf-*` tag; (b) upstream TF-A and U-Boot; (c) NXP for the first image, then upstream once the FRDM PRO is complete there. **Recommendation: (c).** Upstream U-Boot's own FRDM PRO guide takes BL31 from NXP's fork (S1), and upstream OP-TEE has only an EVK flavour (S7).
4. **Kernel verification.** Options: (a) AHAB OS container (S4); (b) U-Boot FIT with signed configurations, its key in U-Boot's AHAB-authenticated device tree (S8); (c) both. **Recommendation: (b).** It is upstream, covers kernel, device tree and initramfs together, and does not depend on a U-Boot environment variable.
5. **Root filesystem integrity.** Options: (a) dm-verity on a separate read-only partition, root hash in the signed FIT; (b) `CONFIG_FIT_VERITY` with the root filesystem inside the FIT (S13); (c) dm-verity with a kernel root-hash signature (S12); (d) none at boot, with IMA at run time. **Recommendation: (a)**, because it needs no driver of unconfirmed status (§4 item 6) and keeps the FIT small. IMA is left to the `hsm-self-defence` question.
6. **Locking down U-Boot in the product image.** Options: (a) a product defconfig or fragment with `CONFIG_AHAB_BOOT`, FIT signature checking, a fixed environment and no fastboot, SDP, `fuse` or write commands, beside the development defconfig; (b) keep NXP's defconfig and protect only with AHAB. **Recommendation: (a).** S5 shows a writable environment and download paths that would bypass §3.5's checks.
7. **SRK algorithm.** Options: (a) classic ECDSA P-384 only; (b) hybrid ECDSA plus ML-DSA, with both SRK hash regions fused (S2 §1.6, S9); (c) RSA. No recommendation. (b) depends on whether the HSM chosen for custody can sign with ML-DSA (§4 item 4).
8. **Subordinate keys.** Options: (a) sign every container with an SRK held in the HSM; (b) SRK offline, with a subordinate key (SGK) certificate for routine signing (S2 §1.3). No recommendation; it depends on the custody design for go-xkms (AN14471 per `docs/SPEC.md`).
9. **Anti-rollback policy.** Options: (a) raise the OEM `fuse_version` on every release; (b) raise it only on security fixes, and use `sw_version` otherwise; (c) leave it at 0 until the fuse map is known. **Recommendation: (c) for now, then (b)**, because fuse steps are finite and their number is unconfirmed (§4 item 1). A rollback rule for the kernel and root filesystem (§3.8) is needed whichever is chosen.
10. **ELE detector flags in the container** (`GDET`, `VDET`, `AGDET`, `FDET`, `TMPSNS`, S3). Options: (a) decide them with the `hsm-self-defence` row; (b) leave NXP's defaults in the platform image. **Recommendation: (a)**, because they are signed into the boot container and change only with a re-signed image.
