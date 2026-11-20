# Platform image: build system options

Status: survey for the owner's decision on #14. Nothing here has been decided.
Row: platform-image (see [SPEC.md](../SPEC.md)). Issue: #31.

This record compares three ways to build the Linux image for the NXP
FRDM-IMX95-PRO:

1. **Yocto Project / OpenEmbedded**, using NXP's `meta-imx` layer or the
   community `meta-freescale` layer.
2. **Buildroot**.
3. **A Debian-based image**: a Debian root filesystem with a board kernel and
   boot chain built separately.

The comparison covers seven things: NXP support for the i.MX 95 and the FRDM
board, reproducibility, signed boot (AHAB, `imx-mkimage`), how measured boot
and attestation fit with go-trusted-platform, CI cost, xkmsd packaging, and
licensing of the vendor firmware.

Every source is public. Sources were read on 2026-11-12, and each one is
pinned to the tag, branch or release that was read. Vendor text is summarised
here, never copied. Claims that could not be confirmed are marked
**Unconfirmed**.

## 1. Sources

Each source is listed by title, version or ref, and URL. "Reached" means the
lane fetched it.

| # | Source | Version / ref | URL | Reached |
|---|--------|---------------|-----|---------|
| S1 | NXP i.MX Release Manifest (`imx-manifest`), README and release manifest `imx-6.18.37-2.1.0.xml` | branch `imx-linux-wrynose`, manifest `imx-6.18.37-2.1.0.xml` | https://github.com/nxp-imx/imx-manifest | yes |
| S2 | NXP i.MX Yocto BSP layer (`meta-imx`) | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx | yes |
| S3 | `meta-imx` machine configuration `imx95-19x19-lpddr5-frdm-pro.conf` | tag `rel_imx_6.18.37_2.1.0`, path `meta-imx-bsp/conf/machine/` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf | yes |
| S4 | `meta-imx` boot recipe `imx-boot_1.0.bb` | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/recipes-bsp/imx-mkimage/imx-boot_1.0.bb | yes |
| S5 | Community NXP layer (`meta-freescale`), machine directory and `imx-boot_1.0.bb` | branches `wrynose` and `master` | https://github.com/Freescale/meta-freescale | yes |
| S6 | `meta-freescale` branch `topic/secure-boot` | tip commit dated 2023-10-14 | https://github.com/Freescale/meta-freescale/tree/topic/secure-boot | yes |
| S7 | NXP i.MX Mkimage tool (`imx-mkimage`), `Readme.imx95` and `iMX95/` | branch `lf-6.18.37_2.1.0` | https://github.com/nxp-imx/imx-mkimage | yes |
| S8 | Yocto Project Releases wiki page | page as of 2026-11-12 | https://wiki.yoctoproject.org/wiki/Releases | yes |
| S9 | Yocto Project Test Environment Manual, ch. 6 "Reproducible Builds" | 6.1-tip docs | https://docs.yoctoproject.org/test-manual/reproducible-builds.html | yes |
| S10 | Yocto Project Security Manual (table of contents) | 6.1-tip docs | https://docs.yoctoproject.org/security-manual/index.html | yes |
| S11 | OpenEmbedded-Core classes `go.bbclass`, `go-mod.bbclass`, `uboot-sign.bbclass` | tag `yocto-6.0.2` | https://github.com/openembedded/openembedded-core/tree/yocto-6.0.2/meta/classes-recipe | yes |
| S12 | `meta-security` layer tree (sub-layers `meta-tpm`, `meta-integrity`, `meta-hardening`, `meta-parsec`) | branch `wrynose` | https://git.yoctoproject.org/meta-security/tree/?h=wrynose | yes |
| S13 | Buildroot source tree (`configs/`, `board/freescale/`, `package/freescale-imx/`, `package/imx-mkimage/`, `package/pkg-golang.mk`, `Config.in`) | tag `2026.08.1` and `master` as of 2026-11-12 | https://github.com/buildroot/buildroot (mirror of https://gitlab.com/buildroot.org/buildroot) | yes |
| S14 | Buildroot defconfig `freescale_imx95_15x15_frdm_defconfig` | `master`, added in a commit dated 2026-11-11 | https://github.com/buildroot/buildroot/blob/master/configs/freescale_imx95_15x15_frdm_defconfig | yes |
| S15 | Buildroot download page | page as of 2026-11-12 | https://buildroot.org/download.html | yes |
| S16 | The Buildroot user manual (release policy, Go packages) | manual for 2026.08 | https://buildroot.org/downloads/manual/manual.html | yes |
| S17 | Linux kernel tree, `arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts` | present in `v7.2` and `v7.3`, absent in `v7.1` and `v6.18`; first commit dated 2026-06-05 | https://github.com/torvalds/linux/tree/v7.3/arch/arm64/boot/dts/freescale | yes |
| S18 | NXP Linux kernel fork (`linux-imx`), same device tree file | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/linux-imx | yes |
| S19 | U-Boot tree, `configs/imx95_19x19_frdm_pro_defconfig` | present in `v2027.01-rc1`, absent in `v2026.10` | https://github.com/u-boot/u-boot/tree/v2027.01-rc1/configs | yes |
| S20 | Debian releases page | page as of 2026-11-12 (Debian 13.7 "trixie") | https://www.debian.org/releases/ | yes |
| S21 | Debian package `linux-image-arm64` in trixie | 6.12.116-1 | https://packages.debian.org/trixie/linux-image-arm64 | yes |
| S22 | `mmdebstrap(1)` manual page | trixie | https://manpages.debian.org/trixie/mmdebstrap/mmdebstrap.1.en.html | yes |
| S23 | go-trusted-platform README | `main` as of 2026-11-12 (latest tag `v0.1.0-alpha`) | https://github.com/jeremyhahn/go-trusted-platform | yes |
| S24 | NXP desktop layer (`meta-nxp-desktop`) | last branch `lf-6.1.55-2.2.0-mickledore`, last push 2024-01-04 | https://github.com/nxp-imx/meta-nxp-desktop | yes (metadata only) |
| U1 | NXP FRDM-IMX95 product page | n/a | https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX95 | **no** (HTTP 404 at this URL) |
| U2 | NXP "Embedded Linux for i.MX Applications Processors" page (release notes, i.MX Linux User's Guide, i.MX Yocto Project User's Guide) | n/a | https://www.nxp.com/design/design-center/software/embedded-software/i-mx-software/embedded-linux-for-i-mx-applications-processors:IMXLINUX | **no** (HTTP 404 at this URL) |
| U3 | Buildroot manual section on reproducible builds | 2026.08 | https://buildroot.org/downloads/manual/manual.html | partly: the manual was reached but no section on the option was found; the help text in `Config.in` (S13) was used instead |

## 2. NXP support for the i.MX 95 and the FRDM-IMX95-PRO

**Yocto, NXP BSP (`meta-imx`).**
- NXP's newest Linux BSP release on GitHub is `6.18.37-2.1.0` (S1, S2).
- Its release manifest pins Yocto `yocto-6.0.2` ("wrynose") for bitbake,
  OpenEmbedded-Core and meta-yocto. It pins `meta-freescale`, `meta-arm`,
  `meta-security`, `meta-virtualization` and NXP's own layers to fixed
  commits or tags (S1).
- At that tag, `meta-imx` has a machine `imx95-19x19-lpddr5-frdm-pro` (S3).
  It selects:
  - the device tree `imx95-19x19-frdm-pro`;
  - the U-Boot configuration `imx95_19x19_frdm_pro`;
  - the System Manager configuration `mx95frdm-pro`;
  - LPDDR5 DDR firmware;
  - an `imx-boot` target that switches to a FlexSPI variant when U-Boot is
    configured for FlexSPI.
- `meta-imx` also has machines for the 15x15 FRDM boards (LPDDR4X and LPDDR5)
  and for the EVKs (S2).
- The manifest README says the community `poky` distribution breaks the build
  with `meta-imx`, and that NXP's `fsl-imx-*` distributions are the ones to
  use (S1).

**Yocto, community layer (`meta-freescale`).**
- On both `wrynose` and `master`, the layer has the i.MX 95 15x15 FRDM
  machines, the 19x19 EVK and a Verdin module. It has **no** FRDM-PRO machine
  (S5).
- Building the PRO board from the community layer alone would therefore need
  a machine configuration of our own.

**Buildroot.**
- Release `2026.08.1` has defconfigs for the i.MX 91 and i.MX 93 boards and
  none for the i.MX 95 (S13).
- `master` gained `freescale_imx95_15x15_frdm_defconfig` on 2026-11-11 (S14).
  That defconfig is for the 15x15 FRDM board, not the 19x19 PRO. It builds
  NXP's `linux-imx`, `uboot-imx` and `imx-atf` at `lf-6.18.37-2.1.0`, plus the
  OEI, the System Manager, the ELE firmware, the DDR firmware and host
  `imx-mkimage`.
- Buildroot has **no** FRDM-PRO defconfig in any release or on `master`.
  **Unconfirmed:** which Buildroot release will first carry the i.MX 95
  support. Under the release policy, the next LTS is `2027.02` (S15, S16).

**Mainline kernel and U-Boot (relevant to Debian, and to Yocto or Buildroot
without the NXP fork).**
- The FRDM-PRO device tree entered mainline Linux in `v7.2` (S17). NXP's fork
  carries it at `lf-6.18.37-2.1.0` (S18).
- The FRDM-PRO U-Boot defconfig is in `v2027.01-rc1` but not in the released
  `v2026.10` (S19).
- **Unconfirmed:** whether mainline kernel and U-Boot drive every peripheral
  of the board that the platform needs (eMMC, Ethernet, ELE access).

**Debian.**
- Debian 13 "trixie" is the current stable release (S20). Its arm64 kernel
  package is 6.12.116 (S21), which is older than the `v7.2` release that
  added the FRDM-PRO device tree (S17).
- A Debian image for this board therefore needs a kernel and a boot chain
  built outside Debian: the System Manager, the OEI, the ELE firmware, TF-A,
  U-Boot and the `imx-mkimage` container. The Yocto and Buildroot
  configurations above show all of these as separate components (S3, S14).
- NXP's own Ubuntu-based desktop layer has had no branch since Yocto
  "mickledore", and its last push was on 2024-01-04 (S24).
- **Unconfirmed:** whether NXP supports any Debian-based image for the
  i.MX 95.

**Board identity.** The SPEC names the board "FRDM-IMX95-PRO". The match to
the `imx95-19x19-lpddr5-frdm-pro` machine and the `imx95-19x19-frdm-pro`
device tree rests on the names alone. The machine file's own header still
calls it the "19x19 Evaluation Kit" (S3). **Unconfirmed** against an NXP
board page (U1 was unreachable).

## 3. Lifetime of the base

- **Yocto 6.0 "wrynose"** is a Long Term Support release, supported until
  April 2030 (S8). NXP's `6.18.37-2.1.0` release is based on it (S1).
- **Buildroot**, from 2025.02 on, makes the first release of each
  odd-numbered year an LTS release with three years of support. The current
  LTS is `2025.02.x`, end of life March 2028. The next is `2027.02` (S15,
  S16). The LTS that is current today has no i.MX 95 support (S13).
- **Debian 13** is the current stable release (S20). **Unconfirmed** here:
  its security support end date (not read).

## 4. Reproducibility

- **Yocto.** The project defines a reproducible build as one where the same
  input configuration gives the same binary output whatever the build date,
  the build path or the host distribution. The project says this has held
  down to the binary level, timestamps included, since 3.1 "dunfell". It
  provides a test (`OEQA_REPRODUCIBLE_TEST_*`) that a layer can run on its
  own recipes, and it advises making a product reproducible before release
  (S9). NXP's manifest pins every layer to a commit or tag (S1).
- **Buildroot.** `BR2_REPRODUCIBLE` is labelled experimental. Its help text
  says identical output is only expected when the output directory is the
  same, because absolute paths can leak into the root filesystem (S13).
  `BR2_DOWNLOAD_FORCE_CHECK_HASHES` makes every download hash-checked, and
  the i.MX 95 defconfig enables it (S14).
- **Debian.** `mmdebstrap` derives the filesystem UUID and hash seed from
  `SOURCE_DATE_EPOCH`, which gives reproducible ext4 images (S22).
  **Unconfirmed:** whether the whole image is bit-for-bit reproducible once
  the separately built kernel and boot chain are added.

## 5. Signed boot (AHAB, `imx-mkimage`)

- `imx-mkimage` builds the i.MX 95 boot container with `SOC=iMX95`. Its
  targets include the System Manager alone, the System Manager with the M7,
  the System Manager with the A55 from SD/eMMC or FlexSPI NOR, and variants
  without the AHAB firmware. Container flags (GDET, VDET and others) are set
  on the command line (S7).
- The `imx-boot` recipes in `meta-imx` and in `meta-freescale` wrap
  `imx-mkimage`. Neither has a step that signs the i.MX 95 AHAB container
  with CST or SPSDK. The only signing in them is U-Boot FIT signature
  handling (`UBOOT_SIGN_ENABLE`) and pre-signed i.MX 8M display firmware
  (S4, S5).
- OE-core's `uboot-sign.bbclass` signs U-Boot FIT images, not AHAB
  containers (S11).
- `meta-freescale` has a `topic/secure-boot` branch. It has recipes for
  `imx-cst` 3.3.1 and `cst-signer`, and it adds HAB4 and AHAB secure boot
  overrides. Its last commit is dated 2023-10-14, and these recipes are not
  on `wrynose` (S5, S6).
- Buildroot ships host `imx-mkimage` and the i.MX 9 bootloader-prepare
  script (S13). **Unconfirmed:** any AHAB signing support in Buildroot (none
  was found in the tree).
- Whichever build system is chosen, signing the AHAB container is a step the
  project has to supply. The boot-container row already leaves CST vs SPSDK
  and HSM custody open (SPEC row `boot-container`, issue #9). That step can
  sit inside the build or after it.

## 6. Measured boot and attestation with go-trusted-platform

- go-trusted-platform's README describes the platform as built on a TPM 2.0,
  Secure Boot (linked to UEFI) and its own certificate authority. It lists
  TPM 2.0 attestation, sealing and device identity (S23).
- At `rel_imx_6.18.37_2.1.0`, `meta-imx` carries OP-TEE 4.10.0 recipes and
  a `stmm-imx` recipe (UEFI Standalone MM, with an RPMB variable store) (S2).
- `meta-security` on `wrynose` has a `meta-tpm` sub-layer and a
  `meta-integrity` sub-layer (IMA/EVM) (S12). NXP's manifest already
  includes `meta-security` (S1).
- **Unconfirmed:**
  - whether the FRDM-IMX95-PRO has a discrete TPM;
  - whether a firmware TPM under OP-TEE is supported on the i.MX 95;
  - whether go-trusted-platform supports any non-TPM root (for example the
    EdgeLock Enclave or the SE051) as attestation evidence.

  The SPEC lists the attestation evidence as an open question.
- **Fit.** Yocto has ready layers for TPM and IMA (S12) and NXP's secure
  world recipes (S2). Buildroot and Debian would need these assembled by
  hand. **Unconfirmed:** which of them are packaged in Buildroot or Debian
  (not surveyed).

## 7. CI cost

- **Unconfirmed:** no public source reached gives build times or disk use
  for these configurations on comparable hardware. This record makes no
  numeric claim.
- **Yocto.** The project's reproducibility work makes shared-state reuse
  (hash equivalence) work better, because unchanged inputs give unchanged
  outputs (S9). A persistent shared-state and download cache is the main
  lever on a Yocto build's CI cost.
- **Buildroot.** The i.MX 95 defconfig uses a prebuilt Bootlin external
  toolchain (S14), so the toolchain is not built from source.
- **Debian.** The root filesystem comes from prebuilt packages (S22). The
  kernel and the boot chain still have to be built (section 2).

## 8. xkmsd packaging

- xkmsd is a Go program from go-xkms (SPEC row `platform-image`).
- **Yocto.** OE-core at `yocto-6.0.2` has `go.bbclass` and `go-mod.bbclass`
  for building Go modules in a recipe, and `go-mod-update-modules.bbclass`
  for keeping the module list in the recipe (S11).
- **Buildroot.** Buildroot has a Go package infrastructure
  (`package/pkg-golang.mk`) and a manual chapter on adding Go packages
  (S13, S16).
- **Debian.** xkmsd would be shipped as a `.deb` built by the project.
  **Unconfirmed:** which Debian Go packaging route fits go-xkms's
  dependencies (not surveyed).
- **Unconfirmed** for all three: whether go-xkms builds with the Go version
  each base ships.

## 9. Vendor firmware licence

- Buildroot marks NXP's `firmware-imx` package as licensed under the "NXP
  Semiconductor Software License Agreement" and as not redistributable
  (S13).
- The i.MX 95 boot chain needs the DDR firmware and the ELE firmware
  (S3, S14). Every option therefore pulls in NXP-licensed binaries that
  must not be redistributed. This matters for publishing images and caches
  from CI.
- **Unconfirmed:** the exact EULA acceptance mechanism in the Yocto layers
  (not read).

## 10. Summary

| Criterion | Yocto + `meta-imx` | Yocto + `meta-freescale` only | Buildroot | Debian-based |
|-----------|--------------------|-------------------------------|-----------|--------------|
| FRDM-PRO machine/config upstream | yes, at `rel_imx_6.18.37_2.1.0` (S3) | no (S5) | no; 15x15 FRDM only, on `master` (S14) | no stable kernel with the device tree (S17, S21) |
| Base lifetime | Yocto 6.0 LTS to April 2030 (S8) | same | i.MX 95 not in any LTS yet (S13, S15) | Debian 13 stable (S20) |
| Reproducibility | defined and tested by the project (S9) | same | experimental, same output path (S13) | rootfs reproducible with `mmdebstrap` (S22); whole image unconfirmed |
| AHAB signing in the build | none; project adds it (S4) | none on release branches (S5, S6) | none found (S13) | none; done outside |
| TPM/IMA layers | `meta-security` in NXP manifest (S1, S12) | `meta-security` available (S12) | unconfirmed | unconfirmed |
| Go/xkmsd | `go-mod` class (S11) | same | `pkg-golang` (S13) | project-built `.deb` |

**Recommendation, where the sources support one: Yocto with NXP's
`meta-imx`, pinned to the `imx-6.18.37-2.1.0` manifest.** It is the only
option with a published FRDM-PRO machine configuration. It sits on a Yocto
LTS that runs to April 2030. Its reproducibility is defined and tested
upstream. The TPM, IMA, OP-TEE and Go building blocks are already in the
manifest or in OE-core. AHAB signing has to be added in every option, so it
does not separate them.

## 11. Questions for the owner (#14)

1. **Which build system builds the platform image?**
   - (a) Yocto with NXP `meta-imx`;
   - (b) Yocto with `meta-freescale` only, plus our own FRDM-PRO machine;
   - (c) Buildroot, with our own FRDM-PRO defconfig;
   - (d) a Debian root filesystem with a separately built kernel and boot
     chain.

   *Recommendation: (a)*. Sections 2 to 4 and 10.

2. **Which BSP release is the baseline, and how is it pinned?**
   - (a) NXP manifest `imx-6.18.37-2.1.0.xml` on `imx-linux-wrynose`, with
     every layer pinned to the commits the manifest gives;
   - (b) `meta-imx` tag `rel_imx_6.18.37_2.1.0` with our own pins for the
     other layers;
   - (c) follow the newest NXP release each quarter.

   *Recommendation: (a)*, moved forward only by a deliberate change (S1).

3. **Which distribution configuration?**
   - (a) one of NXP's `fsl-imx-*` distributions as is;
   - (b) our own distribution configuration in this repository, derived
     from an `fsl-imx-*` one and stripped to a headless, hardened image;
   - (c) `poky`.

   NXP warns that (c) breaks with `meta-imx` (S1). *Recommendation: (b)*.
   Which `fsl-imx-*` base works best headless is **unconfirmed** and needs a
   build test.

4. **Where is the AHAB container signed?**
   - (a) inside the build, in a class that calls CST or SPSDK;
   - (b) as a separate signing step after the build, which takes the
     unsigned `imx-mkimage` output to the HSM-held keys.

   No surveyed layer signs i.MX 95 AHAB containers (S4, S5, S6).
   *Recommendation: (b)*. It keeps signing keys and the HSM away from the
   build hosts, and it can follow whichever answer #9 (CST vs SPSDK) gets.
   The sources reached do not settle this; it is a design judgment.

5. **What is the measured-boot and attestation root on the A55 side?**
   - (a) a discrete TPM, if the board has one or one is added;
   - (b) a firmware TPM under OP-TEE;
   - (c) evidence rooted in the EdgeLock Enclave or the SE051, with
     go-trusted-platform extended to accept it.

   go-trusted-platform assumes a TPM 2.0 today (S23). The board's TPM
   situation and fTPM support on the i.MX 95 are **unconfirmed**. *No
   recommendation*: the sources reached do not support one. This ties to
   the SPEC's open attestation-evidence question.

6. **What reproducibility bar must the image meet?**
   - (a) bit-for-bit identical images from the pinned inputs, checked in CI
     with Yocto's reproducibility test on our layers;
   - (b) pinned inputs only, with no bit-for-bit check.

   *Recommendation: (a)*. Yocto supports it and advises it before release
   (S9).

7. **Where do image builds run, and what may CI publish?**
   - (a) self-hosted runners with a persistent shared-state and download
     cache, with images and caches kept private;
   - (b) hosted runners with no persistent cache.

   The NXP firmware in the image is marked not redistributable (S13).
   *Recommendation: (a)*, kept private, on the strength of S9 and S13. No
   source reached gives build-time figures.

8. **How is xkmsd built into the image?**
   - (a) built from source in a recipe of our layer with `go-mod.bbclass`,
     pinned to a go-xkms release tag;
   - (b) a prebuilt, signed go-xkms release binary installed by a recipe.

   *Recommendation: (a)*. It keeps xkmsd under the image's own
   reproducibility check (S9, S11). Whether go-xkms builds with the Go
   version in Yocto 6.0 is **unconfirmed**.

9. **Kernel and U-Boot source: NXP's forks or mainline?**
   - (a) NXP `linux-imx` and `uboot-imx` at `lf-6.18.37-2.1.0`, as
     `meta-imx` uses;
   - (b) mainline Linux `v7.2` or later and U-Boot `v2027.01` or later,
     which carry the FRDM-PRO support (S17, S19).

   *Recommendation: (a)* for now. U-Boot's FRDM-PRO support is only in a
   release candidate (S19), and mainline peripheral coverage is
   **unconfirmed**. Revisit when U-Boot `v2027.01` is released.
