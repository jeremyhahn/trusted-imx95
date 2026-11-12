# EdgeLock enclave firmware for the i.MX 95: sourcing, pinning and update (survey)

Issue #80, row boot-container. Documentation only. Public sources only; every claim cites one from
the [Sources](#sources) list by its number, e.g. [S1].

Status: draft survey, surveyed 2026-11-12.

## 1. What the firmware is

The EdgeLock secure enclave (ELE) has a boot ROM of its own and can load a firmware image from the
boot device. NXP builds that firmware, signs it with NXP's keys, and ships it as an AHAB container
file, `mx95<rev>-ahab-container.img` for the i.MX 95 [S4], [S6]. In the boot image it is the first
container: the enclave ROM authenticates it against NXP's key, and the enclave firmware then
authenticates the next container (the OEM-signed one) [S7]. The layout is documented for the i.MX 93
in U-Boot [S7]; that the i.MX 95 follows the same order is an inference from the i.MX 95 binman
description in U-Boot, which places the `mx95*-ahab-container.img` file first [S8], and from
imx-mkimage [S6].

The firmware is optional in the image. imx-mkimage offers `_no_ahabfw` variants of every i.MX 95
System Manager target, the Cortex-M33 boot this project uses, that leave it out [S9], and U-Boot's
i.MX 93 guide calls it optional [S7]. What the enclave can and cannot do without it (which services
are then missing, whether AHAB authentication of the OEM container still works) is not stated in any
public source reached (section 9).

## 2. Where it comes from

NXP does not publish the enclave firmware in a git repository. It ships it as a package named
`firmware-ele-imx-<version>-<short-hash>.bin` on its Yocto download mirror,
`https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/` [S1], [S2]. The `.bin` is a self-extracting archive that
asks the user to accept NXP's licence before it unpacks (the `fsl-eula=true` fetch flag in the recipe
handles this in Yocto; U-Boot's instructions run it with an auto-accept flag) [S1], [S3], [S11]. The community layer also lists a third-party mirror of the same
files as a fallback [S2]; this survey treats only the NXP URL as the origin.

The Yocto recipe that fetches it is `firmware-ele-imx` in meta-freescale (master, recipe version
2.0.7, last changed by commit `c506c76`, 2026-11-10) [S1]. For the i.MX 95 the package holds two boot
containers, `mx95b0-ahab-container.img` and `mx95b1-ahab-container.img`, one per silicon revision;
the build picks the one that matches the board's `IMX_SOC_REV` [S4], [S5]. The B1 container was added
to the community layer only in November 2026, following NXP's LF6.18.37_2.1.0 BSP [S5].

The boot container is not the only enclave firmware file in the package: the recipe also installs a
runtime ("SECOEXT") firmware under `/lib/firmware/imx/ele` [S1]. This survey is about the boot
container; whether the i.MX 95 needs the runtime file at all is not confirmed here (section 9).

## 3. Versions and how a version is pinned and checked

The version is pinned in three places in the recipe [S1]:

| What | Value at meta-freescale master, 2026-11-12 |
|---|---|
| Package version (`PV`) | 2.0.7 |
| Source revision abbreviation (`IMX_SRCREV_ABBREV`) | `0265375` |
| SHA-256 of the downloaded `.bin` | `a24f0e6be783a09281d44b0c2fb26ed719038387441e7ef325b9d4c514592b1d` |
| MD5 of the licence file `COPYING` inside it | `ef4f968b9dae8ba406390cd617c2301d` |

The fetcher refuses a download whose SHA-256 differs, and the licence check refuses a package whose
`COPYING` differs from a licence version the layer knows; the MD5 above is the one the layer calls
`LA_OPT_NXP_SOFTWARE_LICENSE` v64.2 [S1], [S3]. So a pin is the triple (version, hash abbreviation,
SHA-256 of the archive). Nothing in the recipe checks the individual `.img` files after unpacking;
their integrity rests on the archive checksum, and on the boot ROM, which verifies NXP's signature on
the container at boot [S7] (section 5).

### Other pins seen in public sources

| Source | Version it names for the i.MX 95 | Containers |
|---|---|---|
| meta-freescale master, 2026-11-12 [S1], [S4] | 2.0.7-0265375 | `mx95b0`, `mx95b1` |
| NXP meta-imx, branch `lf-6.18.37-2.1.0` [S10] | 2.0.7-0265375, same SHA-256 as above | (set by the class, not read) |
| U-Boot master doc `doc/board/nxp/imx95_evk.rst`, read 2026-11-12 [S11] | 2.0.2-89161a8 | `mx95a0`, `mx95b0` |
| U-Boot master `arch/arm/dts/imx95-u-boot.dtsi` [S8] | (file name only) | `mx95a0`, `mx95b0` |
| imx-mkimage tag `lf-6.18.37_2.1.0` [S6] | (file name only) | `mx95<rev>`, chosen by `REV`, default B0; A0 maps to the `a0` file |

So upstream U-Boot documents an older package and has no B1 entry, while NXP's BSP and the community
layer have moved to 2.0.7 with B1 support. A build that follows upstream U-Boot's instructions gets a
different firmware from one that follows NXP's BSP.

The package version and the firmware's own version are different things. The version the enclave
reports at run time, and the `fuse_version` NXP set in the container header, are not published per
package anywhere this survey reached (section 9).

## 4. Licence and redistribution

The recipe declares the licence as proprietary (`LicenseRef-Proprietary`) [S1], and the layer's EULA
class will not unpack it unless the build sets `ACCEPT_FSL_EULA = "1"` [S3]. The licence text is
NXP's "LA_OPT_NXP_SOFTWARE_LICENSE" (v64.2 for this package, by the checksum match in [S3]).

NXP's licence gives two grants [S3]. The standard one (its §2.2) lets a licensee use and copy the
software with NXP parts, but not hand it to anyone else. The additional distribution one (§2.3) lets
a licensee distribute it in object form, but only built into a product made with NXP parts, never on
its own, and only where the package's Software Content Register (SCR) says §2.3 applies. The SCR sits
inside the package, after the licence prompt; this survey did not accept the licence on the owner's
behalf, so whether §2.3 is granted for `firmware-ele-imx` 2.0.7 is not confirmed (section 9).

Consequences, in plain terms (not legal advice):
- The `.img` must not be committed to this repository, nor attached to a release as a separate file:
  either would be distribution on a standalone basis, which neither grant permits.
- A `flash.bin` that embeds the container and ships on a board is the case §2.3 is written for, if
  the SCR grants it. Whether a `flash.bin` published as a download still counts as part of such a
  product is a question for the owner, and possibly NXP (question 2).
- A build can always fetch the package itself, from NXP's URL, after the person building accepts the
  licence; that keeps the repository and the release free of the binary.

## 5. How the firmware is loaded and updated in the field

The enclave ROM loads the firmware container from the boot image at boot and authenticates it with
NXP's key, before the OEM container [S7]; no public source reached describes any other place the
firmware is kept (whether the enclave can retain it is unconfirmed, section 9). So there is no
separate "enclave update" step. The enclave firmware changes when the boot image (`flash.bin`)
changes: an update replaces the boot image on the boot device, and the next boot loads the new
firmware. The firmware travels with the bootloader, in the same file and the same write.

Anti-rollback is a separate, explicit step. U-Boot's `ahab_commit` command asks the enclave to commit
into fuses "any new SRK revocation and FW version information" [S12] (help text of the command). Read
with SPSDK's AHAB schema [S13], whose `fuse_version` field must be at least the value held in fuses
for the image to be accepted, the picture is: booting a newer container does not by itself raise the
floor; issuing the commit does, and after it an image whose `fuse_version` is below the new floor is
refused. This survey reads "FW version" in that text as the version of the NXP firmware container; the
source code was not traced to confirm it, and which fuse word it uses on the i.MX 95 is not public (section 9).

## 6. Failure of an update

Since the firmware is part of the boot image, a failed update is a failed boot-image update:
- If the write is torn or the new firmware container fails authentication, the ROM cannot load it,
  and the board does not boot from that image. Whether the i.MX 95 ROM then tries a second copy of
  the boot image (a secondary image set) is in the reference manual, which is not public (SPEC.md
  lists IMX95RM as missing); not confirmed.
- If the new image boots but misbehaves, rolling back to the old image works only as long as nobody
  has run the commit of section 5. After the commit, the old image is refused if its `fuse_version`
  is below the new floor, and a fuse, once written, cannot be cleared.
- How a board that boots from nothing is recovered (for example the ROM's USB serial download mode)
  is in the reference manual and the board's manual; not covered by the sources of this survey.

So the safe order is: write the new image (to the inactive copy, if the board has two), boot it,
check it, and only then commit. This survey does not script or run any commit; it is a fuse write.

## 7. Interaction with the AHAB version fields (#41)

Each AHAB container header carries a `fuse_version` (the anti-rollback number checked against fuses)
and a `sw_version` (a number used to choose between images, not checked against fuses) [S13]. The NXP
firmware container has its own header with its own values, set and signed by NXP; this project cannot
change them. The OEM containers (the one the System Manager and the Cortex-M7 image ride in) carry
the values this project sets under #41.

What follows for #41:
- The OEM floor and the NXP firmware floor are separate numbers in separate containers. Raising this
  project's `fuse_version` does not require a new NXP firmware, and a new NXP firmware does not change
  this project's floor.
- One enclave request carries both commits [S12], but they are **independently selectable**: the
  commit request is a bitmask in which the NXP firmware version (bit 1) and the OEM firmware version
  (bit 5) are separate bits (`key-rotation-survey.md` §3, SPSDK `EleInfo2Commit`). Sharing a command
  does not require committing both floors. Setting the NXP bit locks in whatever NXP firmware version
  is in the image at that moment, and would permanently reject an older NXP firmware that a recovery
  image may still need. Any commit mask must be explicitly chosen and reviewed per release, bit by
  bit; the NXP bit is set only with a firmware package this project has pinned and tested. When to
  commit is an owner decision, not a step of this survey.
- A pinned firmware package should be recorded next to the `fuse_version` of the release that
  carries it, so that a later release does not go back to an older firmware the fuses refuse.

## 8. How this build should pin it

Proposal (to be decided by the owner, question 1):

1. A small manifest file in the repository, text only, names the package: URL on NXP's mirror,
   package version, hash abbreviation and SHA-256 of the `.bin`, exactly the triple of section 3; plus
   the SHA-256 of each extracted `mx95b0` / `mx95b1` container, recorded the first time the owner
   fetches and accepts the package (the survey could not compute them, section 9).
2. The build fetches the `.bin` into a cache outside the repository, checks the SHA-256, unpacks it
   only when the person building has accepted NXP's licence explicitly (a variable like Yocto's
   `ACCEPT_FSL_EULA`), and checks the container's SHA-256 before handing it to imx-mkimage.
3. The build fails, instead of downloading a newer file, when either checksum differs. Moving to a new
   firmware is a reviewed change of the manifest, with the release notes of section 7.
4. `.gitignore` excludes `*-ahab-container.img` and `firmware-ele-imx-*` so a binary cannot be
   committed by accident.
5. Start from the pin NXP's own BSP uses, 2.0.7-0265375 [S10], not the older one in U-Boot's doc
   ([S11]), because it is the one NXP tests with the current BSP and the only one with a B1 container.

## 9. What could not be confirmed

- **The Software Content Register of `firmware-ele-imx` 2.0.7.** It is inside the package, behind
  the licence prompt; the survey did not accept NXP's licence. Whether §2.3 (distribution) is granted
  for this package is therefore open.
- **SHA-256 of the extracted `mx95b0` / `mx95b1` containers**, for the same reason.
- **The firmware's own version and `fuse_version`** in each container header, and NXP's release
  notes for the 2.0.x packages: no public page lists them. NXP's i.MX Linux release notes, which may,
  were not reached (the NXP documentation site needs a login for most i.MX 95 documents).
- **ROM fallback to a secondary boot image on the i.MX 95**, and the fuse word `ahab_commit` writes
  for the firmware version: both are in IMX95RM and the i.MX 95 Security Reference Manual, which
  SPEC.md already lists as missing.
- **What the enclave offers without the firmware container** (`_no_ahabfw` images [S9]).
- **The silicon revision of the FRDM-IMX95-PRO** (B0 or B1), which decides which container the build
  embeds. Not stated in any public source reached; reading it from a board answers it.
- **That the i.MX 95 image layout matches the i.MX 93 one in [S7]** is inferred from [S6] and [S8],
  not stated by NXP for the i.MX 95.
- **Whether the runtime ("SECOEXT") firmware applies to the i.MX 95** [S1]: the recipe installs it
  when the machine defines it; the i.MX 95 value was not read.

## Sources

All read on 2026-11-12. Commit or tag is the state read.

- [S1] meta-freescale, `recipes-bsp/firmware-imx/firmware-ele-imx_2.0.7.bb`, branch master, last
  changed by commit `c506c76` (2026-11-10).
  https://github.com/Freescale/meta-freescale/blob/master/recipes-bsp/firmware-imx/firmware-ele-imx_2.0.7.bb
- [S2] meta-freescale, `conf/layer.conf` (`IMX_MIRROR`, `FSL_MIRROR`, the fallback mirror), master.
  https://github.com/Freescale/meta-freescale/blob/master/conf/layer.conf
- [S3] meta-freescale, `EULA` (NXP Software License Agreement, LA_OPT_NXP_Software_License v64.2,
  May 2026; MD5 `ef4f968b9dae8ba406390cd617c2301d`, the same as the package's `COPYING` in [S1]) and
  `classes/fsl-eula-unpack.bbclass`, master. Summarised, not quoted.
  https://github.com/Freescale/meta-freescale/blob/master/EULA
- [S4] meta-freescale, `classes/use-imx-security-controller-firmware.bbclass`, master.
  https://github.com/Freescale/meta-freescale/blob/master/classes/use-imx-security-controller-firmware.bbclass
- [S5] meta-freescale commit `c506c76935c356d5b93ca91517c7a5f83066c181`, "imx-boot, firmware-ele-imx:
  Ship the i.MX 95 B1 ELE boot container", 2026-11-10.
  https://github.com/Freescale/meta-freescale/commit/c506c76935c356d5b93ca91517c7a5f83066c181
- [S6] NXP imx-mkimage, `iMX95/soc.mak`, tag `lf-6.18.37_2.1.0` (commit `b1f801d`, 2026-08-27).
  https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37_2.1.0/iMX95/soc.mak
- [S7] U-Boot, `doc/imx/ahab/guides/mx93_secure_boot.rst`, sections 1 and 3, master (commit
  `3cb2cbb`, 2026-11-11). https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/guides/mx93_secure_boot.rst
- [S8] U-Boot, `arch/arm/dts/imx95-u-boot.dtsi`, master (`3cb2cbb`).
  https://github.com/u-boot/u-boot/blob/master/arch/arm/dts/imx95-u-boot.dtsi
- [S9] NXP imx-mkimage, `Readme.imx95`, tag `lf-6.18.37_2.1.0`.
  https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37_2.1.0/Readme.imx95
- [S10] NXP meta-imx, `meta-imx-bsp/recipes-bsp/firmware-imx/firmware-ele-imx_2.0.7.bb`, branch
  `lf-6.18.37-2.1.0`. https://github.com/nxp-imx/meta-imx/blob/lf-6.18.37-2.1.0/meta-imx-bsp/recipes-bsp/firmware-imx/firmware-ele-imx_2.0.7.bb
- [S11] U-Boot, `doc/board/nxp/imx95_evk.rst`, "Get ahab-container.img", master (`3cb2cbb`).
  https://github.com/u-boot/u-boot/blob/master/doc/board/nxp/imx95_evk.rst
- [S12] U-Boot, `arch/arm/mach-imx/ele_ahab.c`, the `ahab_commit` command and its help text, master
  (`3cb2cbb`). https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-imx/ele_ahab.c
- [S13] NXP SPSDK v3.13.0 (commit `e104adf`, 2026-11-03), AHAB container configuration, the
  `fuse_version` and `sw_version` field descriptions (as in `tests/nxpimage/data/ahab/config_ctcm.yaml`).
  https://github.com/nxp-mcuxpresso/spsdk

Unreachable or not used: NXP's i.MX Linux Release Notes and the i.MX 95 Security Reference Manual
(login or NDA); the package's SCR (behind the licence prompt).

## Questions for the owner

1. **How should the build obtain and pin the firmware?**
   (a) Text manifest (URL, version, hash abbreviation, SHA-256 of the `.bin` and of each container),
   fetched at build time after explicit licence acceptance, never committed (section 8);
   (b) commit the `.img` to the repository or a private submodule;
   (c) leave it out and build `_no_ahabfw` images.
   Recommendation: (a). (b) conflicts with the licence (section 4); (c) depends on behaviour not
   confirmed (section 9).
2. **May a release publish a `flash.bin` that embeds the NXP container?**
   (a) Yes, if the package's SCR grants §2.3 and the owner reads a downloadable image as part of an
   Authorized System; (b) no: releases ship without it, plus a script that fetches the package and
   assembles the final image after the user accepts NXP's licence; (c) ask NXP.
   Recommendation: (b) until the SCR is read, then decide between (a) and (b); (c) if the SCR is
   unclear.
3. **Which package version to start from?**
   (a) 2.0.7-0265375, as in NXP's BSP lf-6.18.37-2.1.0 and meta-freescale master [S1], [S10];
   (b) 2.0.2-89161a8, as in U-Boot's doc [S11].
   Recommendation: (a): current, NXP-tested, and the only one with a B1 container.
4. **Which silicon revision does the board carry, B0 or B1?** Options: read it from the board's boot
   log, or carry both containers and select at build time as meta-freescale does [S5].
   Recommendation: carry both in the manifest, select by a build variable, and confirm the board's
   revision from its boot log before the first signed image.
5. **When may the anti-rollback commit be run, and by whom?**
   (a) Never automatically: a manual, documented step, after a release has booted and passed checks
   on that board; (b) automatically by the updater after a successful boot; (c) not at all on
   development boards.
   Recommendation: (a) for now, and (c) on boards used for development, because the commit also locks
   in the NXP firmware version (section 7) and cannot be undone. Revisit (b) with #41 once the boot
   fallback of the i.MX 95 ROM is confirmed.
6. **Should each release record the firmware package next to its `fuse_version` (#41)?**
   Options: yes, in the release manifest; no. Recommendation: yes (section 7).
