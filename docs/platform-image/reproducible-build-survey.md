# Platform image: reproducible build and SBOM survey

Row: `platform-image` ([SPEC](../SPEC.md)). Issue #56. Status: draft survey for the owner.

This survey uses public sources only. Each claim names its source by title, version and URL
(see [Sources](#sources)). Nothing here is copied from vendor documents; it is a summary in our own words.
Where a point could not be confirmed it is marked **Unconfirmed**.

## 1. Scope and question

The `platform-image` row says the Linux image for the FRDM-IMX95-PRO is built in this repository, then
provisioned and attested by go-trusted-platform. An image that is attested needs two things that this
survey looks at:

- **A reproducible build.** Two builds of the same pinned inputs should give the same bytes, so that a
  measured or signed digest can be checked again by someone who was not at the original build.
- **An SBOM.** Each image should come with a machine-readable list of what went into it, so that licence
  and vulnerability review can be done against the exact release.

The image build system has not been chosen yet; it is question 1 below. So this survey compares the candidates only on
reproducibility and SBOM. It does not choose the build system. It ran no build: every statement below
comes from reading public sources, not from a test.

## 2. NXP's public BSP baseline for the i.MX 95

NXP publishes its Linux BSP for i.MX as a set of Yocto layers, listed in a `repo` manifest [S1].

- **Latest release surveyed:** `imx-6.18.37-2.1.0.xml` on branch `imx-linux-wrynose` of
  `nxp-imx/imx-manifest`. The branch tip read was commit `5e07321d`, dated 2026-10-09 [S1]. Older
  release lines are on `imx-linux-whinlatter` (`imx-6.18.2-1.0.0`) and `imx-linux-walnascar`
  (`imx-6.12.49-2.2.0`) [S1].
- **Yocto base:** in that manifest, bitbake, openembedded-core and meta-yocto are pinned to the
  `yocto-6.0.2` tag, which is Yocto release "wrynose" [S1].
- **How inputs are pinned:** most layers are pinned to a full commit hash. Three of NXP's own layers
  (`meta-imx`, `meta-nxp-connectivity`, `meta-nxp-demo-experience`) are pinned to the tag
  `rel_imx_6.18.37_2.1.0`, and not to a hash [S1]. Git tags can be moved, so a build that wants
  fixed inputs should record the commit each tag resolves to. This survey did not check whether NXP
  has ever moved a release tag.
- **The board's machine:** `meta-imx` at tag `rel_imx_6.18.37_2.1.0` has the machine
  `imx95-19x19-lpddr5-frdm-pro`. It uses the device tree `imx95-19x19-frdm-pro`, the U-Boot config
  `imx95_19x19_frdm_pro` and the System Manager config `mx95frdm-pro` [S2]. The comment header in that
  file still describes the 19x19 EVK; this looks like a copy from the EVK file, not a different board.
- **NXP's own SBOM:** the `meta-imx` tag has a file `SBOM-NXP.spdx.json` at its root [S2]. It is an
  SPDX 2.3 JSON document named `LinuxBSP-lf-6.18.37-2.1.0`, dated 2026-09-07, with 126 packages, made
  by the organisation NXP and using SPDX licence list 3.28. Several entries use `LicenseRef-` licences
  (NXP's proprietary licences) and give `https://www.nxp.com` as their download location, not a fetch
  URL. This SBOM describes the BSP release as a whole, not an image built from it. It is no substitute
  for an SBOM of our own image. The `fsl-eula2-unpack2` class in the same layer removes the SCR and
  SBOM files from what it installs [S2].
- **Reproducibility in NXP's layers:** `meta-imx` has some recipe-level reproducibility work. Its Xen
  recipes take their build date from `SOURCE_DATE_EPOCH` and add path-prefix maps, and its QEMU recipe
  strips compiler flags for the same reason [S2]. This survey found no NXP document that claims the
  whole BSP image is bit-for-bit reproducible. **Unconfirmed.**
- **Binary inputs:** the machine also pulls in prebuilt firmware, for example the LPDDR5 training
  firmware `lpddr5_dmem_v202409.bin` [S2]. Prebuilt inputs like this can't be rebuilt from source.
  They can only be pinned by digest, and listed in the SBOM.

## 3. Yocto Project: reproducibility

Surveyed: the Yocto test manual page "Reproducible Builds" and OE-core, both at tag `yocto-6.0.2`, the
Yocto base of NXP's latest manifest [S3, S4].

- **What Yocto means by it:** the same build configuration should give the same binary output, whenever
  it is built, whatever path it is built in, and whatever host distribution and tools it runs on [S3].
- **Default since 3.1:** reproducible output, down to timestamps, has been on by default since Yocto
  3.1 ("dunfell") [S3].
- **How Yocto gets it:** it maps build paths in debug data through `DEBUG_PREFIX_MAP`. It gives each
  recipe its own sysroot. It limits the host tools on `PATH` to `HOSTTOOLS`. It asks recipes to state
  their configure options (`PACKAGECONFIG`) and not detect host features [S3]. At `yocto-6.0.2`,
  `bitbake.conf` sets a fallback `SOURCE_DATE_EPOCH` and a fixed `REPRODUCIBLE_TIMESTAMP_ROOTFS` for
  the root filesystem [S4].
- **What is promised, and what is not:** the page says only bitbake and OE-core carry the guarantee.
  Any added layer voids it [S3]. For us that means every NXP layer (`meta-imx`, `meta-freescale` and
  the rest) and every layer of our own is outside the guarantee until we test it. The page's own
  status note is old (it was written at release 3.3). At that time Go and Ruby documentation were the
  known gaps, and Go was the hard case, because its output depended on the build path [S3]. The Go
  point matters to this row, because xkmsd from go-xkms runs on the image. Whether the Go toolchain in
  `yocto-6.0.2` still has the problem is **unconfirmed**.
- **How to test it:** OE-core has a selftest, `reproducible.ReproducibleTests.test_reproducible_builds`.
  It builds the targets twice, the second time without shared state, and compares the packages. It can
  run `diffoscope` on any package that differs. Variables named `OEQA_REPRODUCIBLE_TEST_*` limit the
  test to chosen recipes or images [S3]. This is the obvious CI check for this row if Yocto is chosen.
- **Live status:** the page points to a results page on the Yocto Project website and to the
  autobuilder [S3]. This survey did not read the current results. **Unconfirmed.**

## 4. Yocto Project: SBOM

Surveyed: the Yocto dev manual page "Creating a Software Bill of Materials" and the OE-core classes,
both at `yocto-6.0.2` [S4, S5].

- **On by default:** the default distro setup puts `create-spdx` in `INHERIT_DISTRO` [S4, S5]. At
  `yocto-6.0.2`, `create-spdx.bbclass` just inherits `create-spdx-3.0`, so the default output is SPDX
  3.0 [S4]. (NXP's own BSP SBOM, in section 2, is SPDX 2.3: a different document in a different
  version.)
- **What it writes:** an image build writes `IMAGE-MACHINE.spdx.json` into the image deploy
  directory. A recipe-only SBOM can be made with `bitbake <recipe> -c create_recipe_sbom` [S5].
- **Options that matter here** [S5]:
  - `SPDX_INCLUDE_SOURCES` and `SPDX_INCLUDE_COMPILED_SOURCES` list the source files, or only the ones
    that were compiled.
  - `SPDX_INCLUDE_KERNEL_CONFIG` records the kernel's `CONFIG_*` options. This is useful when a
    hardening review needs to know what the kernel was built with.
  - `SPDX_IMAGE_SUPPLIER` and `SPDX_PACKAGE_SUPPLIER` name the supplier.
  - `SPDX_INVOKED_BY`, `SPDX_ON_BEHALF_OF` and `SPDX_INCLUDE_BITBAKE_PARENT_BUILD` record which CI run
    made the image.
  - Language classes (cargo, go-mod, pypi, npm, cpan) add Package URLs. The `go-mod` one would cover
    the Go modules of xkmsd.
- **Vulnerability data:** OE-core at `yocto-6.0.2` has an `sbom-cve-check` class. It runs CVE analysis
  on the image SBOM after the SBOM is made, and is turned on as a config fragment
  (`core/yocto/sbom-cve-check`). It also has a `vex` class [S4]. No `cve-check.bbclass` was found in
  the class directories at that tag [S4]. How much of the old `cve-check` behaviour
  `sbom-cve-check` replaces is **unconfirmed**.
- **Can the SBOM itself be reproduced?** An SBOM that records who ran the build, or when, differs
  between two builds even when the image is the same. Whether the default SPDX 3.0 output is the same
  byte for byte across two builds (creation time, document IDs) is **unconfirmed**. Until that is
  tested, attest the image digest and treat the SBOM as a signed companion to it, not as a reproduced
  artefact.

## 5. Buildroot: reproducibility and SBOM

Surveyed: Buildroot at tag `2026.08.1`, the newest release tag when this was written [S6].

- **No i.MX 95 board support:** the `configs/` directory has defconfigs for the i.MX 91 and i.MX 93
  (EVK and FRDM), but none for the i.MX 95. A text search of `package/` and `boot/` found no `imx95` or
  `mx95` reference [S6]. Choosing Buildroot would mean writing the board support (System Manager, OEI,
  the container build, U-Boot and kernel configs) ourselves, without NXP's layers to start from.
- **Reproducibility:** `BR2_REPRODUCIBLE` is marked experimental in Buildroot's own help text. It holds
  only when both builds use the same output directory, because absolute paths leak into the target
  root filesystem. Not every package is known to behave [S6]. That is a weaker promise than Yocto's
  path-independent one (section 3).
- **SBOM:** `make legal-info` collects licences and sources, and records package hashes in a manifest
  [S6]. `utils/generate-cyclonedx` turns the output of `make show-info` into a CycloneDX document. Its
  default CycloneDX version is 1.6.2 [S6]. The manual says this adds no information beyond
  `show-info`; it only gives it in a standard format [S6]. Buildroot has no SPDX generator at this tag.
  **Unconfirmed** beyond the absence of one in `utils/`.

## 6. Boot-firmware artefacts outside the root filesystem

The board boots a container that holds several images apart from Linux. The SPEC rows `boot-container`
and `system-manager-config` cover them. Each is its own reproducibility question, whatever builds the
root filesystem.

- **imx-mkimage** (`nxp-imx/imx-mkimage`, tag `lf-6.18.37-2.1.0`) [S7]. It packs the boot container. A
  text search found no use of `time()`, `__DATE__`, `__TIME__`, `date +` or `SOURCE_DATE_EPOCH` in it.
  Its Makefile writes mkimage's own short git commit into `src/build_info.h`, and the i.MX 95 make
  file asks the tool for that commit (`-commit`) while it builds the image [S7]. That value is fixed for
  a given mkimage commit, so it does not by itself break reproducibility. But a build from a tarball,
  with no `.git`, would record something else. **Unconfirmed** by a build.
- **System Manager** (`nxp-imx/imx-sm`, tag `lf-6.18.37-2.1.0`) [S8]. Its
  `sm/makefiles/build_info.mak` writes the wall-clock build date and time (`SM_DATE`, `SM_TIME`) into a
  generated header with `date`. It also writes the git commit and a first-parent commit count. Nothing
  in it reads `SOURCE_DATE_EPOCH` [S8]. The Yocto recipe that builds it, `imx-system-manager.inc` in
  `meta-imx` [S2], does nothing about this, as far as this survey could see. So two builds of the same
  System Manager source, at different times, will very likely differ, and so will the boot container
  that holds it. This is read from source; it has **not** been confirmed by building twice. A fix
  would be a small patch that takes the date from `SOURCE_DATE_EPOCH`.
- **U-Boot.** Upstream U-Boot's "Reproducible builds" page (branch `master`, read 2026-11-12) says
  U-Boot takes its build timestamp from `SOURCE_DATE_EPOCH` [S9]. NXP builds from its own fork,
  `u-boot-imx`. This survey did not check that the fork keeps this behaviour. **Unconfirmed.**
- **OEI, TF-A and the ELE firmware.** `meta-imx` has recipes for the OEI (`imx-oei_1.0.0.bb`) and for
  the prebuilt boot firmware files (`imx-boot-firmware-files_8.33.bb`) [S2]. This survey did not read
  the OEI or TF-A build for timestamps. Firmware that ships prebuilt (the DDR training images, and the
  EdgeLock Enclave firmware if it is delivered that way) can only be pinned by digest. All of this is
  **unconfirmed**.
- **Signing.** A signed container holds a signature over its contents. Under ECDSA, whether the
  signature is the same each time depends on the signer's nonce. So a reproducible build should be
  checked on the unsigned container, or on the part the signature covers, and the signature checked
  on its own. How CST or SPSDK handle this is left to the `boot-container` row's CST/SPSDK decision.
  **Unconfirmed** here.

## 7. Formats and conventions

- **`SOURCE_DATE_EPOCH`.** This is the Reproducible Builds project's convention: an environment
  variable, in seconds since the Unix epoch, that tools use in place of the current time. The spec page
  has revisions 1.0 and 1.1 [S10]. Yocto [S4], Buildroot's `BR2_REPRODUCIBLE` [S6] and U-Boot [S9] all
  use it. NXP's System Manager build does not (section 6).
- **diffoscope** compares two build outputs and shows where they differ, down into archives and binary
  formats [S11]. Yocto's selftest can call it [S3].
- **SPDX 3.0.** This is what Yocto writes by default at `yocto-6.0.2` [S4]. The spec read is version
  3.0.1 [S12]. NXP's BSP SBOM is SPDX 2.3 [S2]. A consumer that must read both needs a tool that knows
  both versions.
- **CycloneDX 1.6.** This is what Buildroot's generator writes [S6, S13]. It is a different format
  from SPDX. A converter would be needed if the attestation side wants one format for all
  components.

## 8. What could not be confirmed

- Issue #56's own text: the forge was not reachable from this lane (the `gh` CLI had no
  credentials). This survey follows the lane brief and the `platform-image` row of the SPEC.
- NXP's "i.MX Yocto Project User's Guide" and "i.MX Linux Release Notes" for `lf-6.18.37-2.1.0`. The
  NXP Embedded Linux for i.MX page answers [S14], but the guides are PDFs on nxp.com, and this lane did
  not read them. Whether NXP states anything about reproducibility or SBOMs in them is unknown.
- Whether NXP's tags (`rel_imx_6.18.37_2.1.0`, `lf-6.18.37-2.1.0`) have ever been moved.
- The current state of Go reproducibility in `yocto-6.0.2`, and the live Yocto reproducibility results.
- Whether the SPDX 3.0 output of OE-core is the same byte for byte across two builds.
- How far `sbom-cve-check` replaces the old `cve-check` class.
- Whether `u-boot-imx`, the OEI and TF-A builds for the i.MX 95 are reproducible.
- That the System Manager's timestamps really make two builds differ. This was read from source, not
  tested.
- Other build systems (Debian-based builders such as Isar, or NXP's own Debian offering) were not
  surveyed.
- No build was run. Every point is from reading.

## Sources

All read on 2026-11-12.

1. **[S1]** NXP, `imx-manifest`, branch `imx-linux-wrynose` (tip `5e07321d`), file
   `imx-6.18.37-2.1.0.xml`. Branches `imx-linux-whinlatter` and `imx-linux-walnascar` were also listed.
   https://github.com/nxp-imx/imx-manifest
2. **[S2]** NXP, `meta-imx`, tag `rel_imx_6.18.37_2.1.0`: `SBOM-NXP.spdx.json`,
   `meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf`,
   `meta-imx-bsp/classes/fsl-eula2-unpack2.bbclass`,
   `meta-imx-bsp/recipes-bsp/imx-system-manager/imx-system-manager.inc`, and the Xen and QEMU recipes.
   https://github.com/nxp-imx/meta-imx
3. **[S3]** Yocto Project, Test Environment Manual, "Reproducible Builds"
   (`documentation/test-manual/reproducible-builds.rst`), `yocto-docs` tag `yocto-6.0.2`.
   https://git.yoctoproject.org/yocto-docs
4. **[S4]** OpenEmbedded-Core, tag `yocto-6.0.2`: `meta/conf/bitbake.conf`,
   `meta/conf/distro/defaultsetup.conf`, `meta/classes/create-spdx.bbclass`,
   `meta/classes-recipe/sbom-cve-check.bbclass`, `meta/classes/vex.bbclass`.
   https://git.openembedded.org/openembedded-core
5. **[S5]** Yocto Project, Development Tasks Manual, "Creating a Software Bill of Materials"
   (`documentation/dev-manual/sbom.rst`), `yocto-docs` tag `yocto-6.0.2`.
   https://git.yoctoproject.org/yocto-docs
6. **[S6]** Buildroot, tag `2026.08.1`: `Config.in` (`BR2_REPRODUCIBLE`), `configs/`,
   `utils/generate-cyclonedx`, `docs/manual/common-usage.adoc`, `docs/manual/adding-packages-*.adoc`.
   https://gitlab.com/buildroot.org/buildroot
7. **[S7]** NXP, `imx-mkimage`, tag `lf-6.18.37-2.1.0`: `Makefile`, `iMX95/soc.mak`,
   `src/mkimage_imx8.c`. https://github.com/nxp-imx/imx-mkimage
8. **[S8]** NXP, `imx-sm` (System Manager), tag `lf-6.18.37-2.1.0`: `sm/makefiles/build_info.mak`.
   https://github.com/nxp-imx/imx-sm
9. **[S9]** U-Boot, "Reproducible builds" (`doc/build/reproducible.rst`), branch `master`.
   https://github.com/u-boot/u-boot/blob/master/doc/build/reproducible.rst
10. **[S10]** Reproducible Builds project, "SOURCE_DATE_EPOCH" specification, revision 1.1.
    https://reproducible-builds.org/specs/source-date-epoch/
11. **[S11]** diffoscope project page. https://diffoscope.org/
12. **[S12]** SPDX Specification, version 3.0.1. https://spdx.github.io/spdx-spec/v3.0.1/
13. **[S13]** CycloneDX, JSON reference, version 1.6. https://cyclonedx.org/docs/1.6/json/
14. **[S14]** NXP, "Embedded Linux for i.MX Applications Processors" (the page answered; its documents
    were not read).
    https://www.nxp.com/design/design-center/software/embedded-software/i-mx-software/embedded-linux-for-i-mx-applications-processors:IMXLINUX

## Questions for the owner

1. **Which build system builds the platform image?**
   - (a) Yocto, on NXP's `imx-manifest` release `imx-6.18.37-2.1.0` (Yocto `yocto-6.0.2`).
   - (b) Buildroot `2026.08.x`, with the i.MX 95 board support written here.
   - (c) Something else (for example a Debian-based builder), surveyed first.

   *Recommendation: (a).* It is the only option with NXP board support for the FRDM-IMX95-PRO
   (machine `imx95-19x19-lpddr5-frdm-pro`) [S2]. Its reproducibility promise does not depend on the
   build path [S3], and it writes an SBOM by default [S5]. Buildroot has no i.MX 95 support at
   `2026.08.1`, and its reproducible mode is experimental [S6].

2. **How much reproducibility do we promise?**
   - (a) Bit-for-bit for the whole release: root filesystem, kernel, and the unsigned boot container.
   - (b) Bit-for-bit for the root filesystem and kernel only. The boot container is pinned by digest.
   - (c) None for now: pinned inputs and a recorded build only.

   *Recommendation: (a) as the goal, with (b) as the first milestone.* Yocto's selftest can gate the
   root filesystem in CI now [S3]. The System Manager's timestamps [S8] need a patch first.
   A module-signing key made fresh at each build would break (a) and (b) for the kernel; the
   [hardening survey, question 3](hardening-survey.md) pins the release's public certificate instead
   and verifies module signatures separately from the unsigned payloads.

3. **How do we pin NXP's inputs?**
   - (a) Use NXP's manifest as is (three layers pinned by tag).
   - (b) Keep our own copy of the manifest, with every project pinned by commit hash, and record the
     hash each NXP tag resolves to.

   *Recommendation: (b).* Tags can move; hashes can't [S1].

4. **May we carry a patch for the System Manager's build date and time?**
   - (a) Yes: a small patch that takes `SM_DATE` and `SM_TIME` from `SOURCE_DATE_EPOCH`, carried in
     our layer and offered to NXP.
   - (b) No: treat the System Manager binary as a pinned input, built once and kept by digest.

   *Recommendation: (a)*, once a double build has confirmed the difference [S8, S10]. (b) is the
   fallback if the owner wants no changes to NXP's code.

5. **Which SBOM format do we publish?**
   - (a) Yocto's default SPDX 3.0 for the image, with NXP's SPDX 2.3 BSP SBOM shipped beside it.
   - (b) SPDX 2.3 only, to match NXP (needs the older class or a converter).
   - (c) CycloneDX (needs a converter from Yocto).

   *Recommendation: (a).* It is the default, it is generated with the build [S4, S5], and it keeps
   NXP's document unchanged.

6. **What does the SBOM record?** Do we turn on `SPDX_INCLUDE_KERNEL_CONFIG`,
   `SPDX_INCLUDE_COMPILED_SOURCES`, the supplier fields, and the CI fields (`SPDX_INVOKED_BY`,
   `SPDX_ON_BEHALF_OF`)? [S5]
   - (a) All of them.
   - (b) Kernel config and supplier only, so that the SBOM stays closer to reproducible.

   *No recommendation:* no source here shows how the CI fields affect whether the SBOM is the same
   across builds. Confirm this by test first.

7. **Is the SBOM attested with the image?**
   - (a) Yes: go-trusted-platform's attestation covers the image digest, and the SBOM is signed and
     tied to that digest.
   - (b) No: the SBOM is a release artefact only.

   *No recommendation from sources:* this depends on go-trusted-platform's attestation design, which
   this survey did not read.

8. **Is vulnerability checking a release gate?**
   - (a) Yes: run `sbom-cve-check` [S4] on each image SBOM in CI and fail on findings that have not
     been triaged.
   - (b) Report only.

   *Recommendation: (b) first, then (a)* once the triage process (VEX, [S4]) is agreed.
