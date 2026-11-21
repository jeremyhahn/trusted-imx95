# Encrypted boot on the i.MX 95: survey (boot-container, #95)

> Status: DRAFT survey for the owner · Row: boot-container ([SPEC](../SPEC.md)) · Public sources only

## 1. Scope and method

This survey answers issue #95 for the `boot-container` row: how AHAB encrypts boot container images on the
i.MX 95, what encryption adds over signing alone and what it costs, how it meets the anti-rollback (#41) and SRK
rotation (#58) surveys, and whether the first release should encrypt any image. It ends with questions for the
owner (§9).

It is documentation only. No key, fuse, life-cycle or provisioning step is run or scripted here, and the commands
the sources show are described, not reproduced as steps to follow. It was written from public sources only (§2),
summarised in this file's own words. Where a source covers the i.MX 9 family or another part and not the i.MX 95
by name, the text says so, and §8 lists every point left unconfirmed.

## 2. Sources and versions

All sources are public, and all were read on 2026-11-12. Every source is summarised in this file's own words;
none is quoted. NXP's private documents (RM00284, AN14471, the CST user guides) are cited only where the SPEC row
already cites them; this survey did not read them.

| Id | Title | Version | URL |
|---|---|---|---|
| S1 | NXP U-Boot, *i.MX 8ULP, i.MX 9x Encrypted Boot guide using AHAB* (`doc/imx/ahab/guides/mx8ulp_9x_encrypted_boot.txt`) | `nxp-imx/uboot-imx` branch `lf_v2026.04`, commit `bb41975aeb4c` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/doc/imx/ahab/guides/mx8ulp_9x_encrypted_boot.txt |
| S2 | NXP U-Boot, AHAB CSF example for an encrypted boot image (`doc/imx/ahab/csf_examples/csf_enc_boot_image.txt`) | same commit as S1; upstream U-Boot `v2026.10` carries the same file name | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/doc/imx/ahab/csf_examples/csf_enc_boot_image.txt |
| S3 | NXP U-Boot, `dek_blob` command and its Kconfig (`arch/arm/mach-imx/cmd_dek.c`, `arch/arm/mach-imx/Kconfig`) | same commit as S1 | https://github.com/nxp-imx/uboot-imx/tree/lf_v2026.04/arch/arm/mach-imx |
| S4 | SPSDK device database, i.MX 95 (`spsdk/data/devices/mimx9596/database.yaml`) | SPSDK `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/spsdk/data/devices/mimx9596 |
| S5 | SPSDK AHAB blob module (`spsdk/image/ahab/ahab_blob.py`) | SPSDK `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/image/ahab/ahab_blob.py |
| S6 | SPSDK `nxpimage ahab` commands (`spsdk/apps/nxpimage_apps/nxpimage_ahab.py`) | SPSDK `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/apps/nxpimage_apps/nxpimage_ahab.py |
| S7 | SPSDK `nxpele` and the ELE messages (`spsdk/apps/nxpele.py`, `spsdk/ele/ele_message.py`, `spsdk/ele/ele_constants.py`) | SPSDK `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/spsdk/ele |
| S8 | Upstream U-Boot AHAB documentation tree (`doc/imx/ahab/`) | `u-boot/u-boot` tag `v2026.10` | https://github.com/u-boot/u-boot/tree/v2026.10/doc/imx/ahab |
| S9 | SPSDK AHAB signature block (`spsdk/image/ahab/ahab_sign_block.py`) | SPSDK `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/image/ahab/ahab_sign_block.py |
| S10 | NXP imx-mkimage, i.MX 95 makefile (`iMX95/soc.mak`) | branch `lf-6.18.37_2.1.0`, commit `b1f801d30cf3` | https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37_2.1.0/iMX95/soc.mak |
| S11 | NXP U-Boot, *i.MX Secure and Encrypted Boot using AHAB* (`doc/imx/ahab/introduction_ahab.txt`) | same commit as S1 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2026.04/doc/imx/ahab/introduction_ahab.txt |
| R41 | This repository's anti-rollback survey, `docs/boot-container/anti-rollback-survey.md` (#41) | branch `issue/41-rollback-survey`, draft, not on `main` | (this repository) |
| R58 | This repository's SRK revocation and key rotation survey, `docs/boot-container/key-rotation-survey.md` (#58) | branch `issue/58-srk-rotation`, draft, not on `main` | (this repository) |

Upstream U-Boot `v2026.10` has only the i.MX 8 and 8X encrypted boot guide; the i.MX 8ULP and i.MX 9x guide is in
NXP's fork alone [S8; S1].

## 3. How AHAB encrypts boot container images

The public descriptions of AHAB encrypted boot for the i.MX 9 family are NXP's U-Boot guide for the i.MX 8ULP and
i.MX 9x [S1], its CSF example [S2], and the U-Boot `dek_blob` code [S3]. The guide works through the i.MX 93 and
says the same scheme applies to the other i.MX 9 parts with the same AHAB design. It does not mention the i.MX 95
by name, so every i.MX 95 statement in this section is an inference from the family (see §8).

### 3.1 Which images can be encrypted

- An AHAB container holds a header, the image entries and a signature block. When an image is encrypted, the
  signature block also carries a DEK blob after the signature and the optional SGK certificate [S1 §1.1].
- The guide's worked example builds a `flash.bin` of three containers with imx-mkimage. It encrypts the second
  container (SPL) and the third (U-Boot with TF-A), each with its own DEK. It leaves the first container alone [S1 §1.4, §1.5]. In
  imx-mkimage's builds that first container is NXP's own signed enclave firmware [S10].
- Encryption is chosen per image inside a container. By default every image the container's signature block
  covers is encrypted. An optional *Image Indexes* bitmask in the CSF picks the images to encrypt. Both NXP
  examples clear bit 0 (`0xFFFFFFFE`), which this survey reads as leaving image 0 of the container in the clear
  [S1 §1.5; S2] (§8, item 4).
- An optional *Key Identifier* in the CSF must equal the identifier given when the blob is made. It defaults to
  zero [S1 §1.5].
- On the i.MX 95 the OEM boot container is laid out differently from the i.MX 93's. In imx-mkimage's i.MX 95
  makefile, the `flash_all` target puts these into one container after the enclave firmware: the OEI (the
  Cortex-M33 DDR and early-init image), the System Manager for the Cortex-M33, the Cortex-M7 image and the
  Cortex-A55 SPL. U-Boot with TF-A goes in the next container [S10]. The `flash_a55` target leaves out the M7
  image [S10].
- So on the i.MX 95, encrypting "the second container" covers the System Manager, the M7 firmware and SPL
  together, and the Image Indexes mask picks among them. Which index each image takes, and whether the ROM can
  decrypt the OEI and System Manager images it runs on the Cortex-M33 before DDR is up, is not confirmed (§8).
  Container 3 (U-Boot and TF-A) matches the i.MX 93 example directly.
- The i.MX 95 B0 builds container format version 2 by default; the A1 revision uses version 0 [S10]. SPSDK puts a
  blob slot in both of its signature block classes [S9]. The public guide [S1] was written against the i.MX 93
  container, so it does not show that the ROM decrypts version 2 containers on the B0. That is not confirmed (§8).
- Nothing public describes the boot ROM decrypting containers that are loaded later, such as a Linux kernel or an
  M7 image loaded after U-Boot starts. U-Boot's AHAB authentication of an OS container goes through the same
  enclave service, but whether that path accepts an encrypted image on the i.MX 95 is not confirmed (§8).

### 3.2 The data encryption key and its blob

- CST encrypts the images with a random AES data encryption key (DEK) it generates. The examples use 128 bits;
  the CSF *Key Length* field selects the length [S1 §1.5, §1.6; S2]. U-Boot's ELE `dek_blob` code accepts 128-,
  192- and 256-bit DEKs and always asks the enclave for key identifier 0 [S3]. Whether the i.MX 95 boot ROM
  accepts each length is not confirmed (§8).
- The DEK never goes into the image in the clear. The enclave wraps it into a 72-byte blob under a key derived from
  the device's OTP master key (OTPMK), which is unique to each chip. So a blob opens only on the chip that made
  it [S1 §1.1.1, §1.6].
- The blob is made on the device itself, by the enclave's generate-key-blob request. U-Boot exposes this as the
  `dek_blob` command (`CONFIG_CMD_DEKBLOB`, with `CONFIG_IMX_ELE_DEK_ENCAP` on ELE parts) [S1 §1.1.1, §1.2; S3].
  The DEK file therefore has to travel from the signing host to each board, and the blob has to travel back. The
  guide does this through a filesystem and USB mass storage [S1 §1.7].
- CST prints the offset where the blob goes. The blob is written into the signed image afterwards, at that
  offset. It sits outside the signed range of the signature block, so inserting it does not invalidate the
  signature [S1 §1.1, §1.8].
- The guide says twice that the device must be in the OEM closed life cycle to make a DEK blob, yet its final
  check shows a board in OEM open booting the encrypted image [S1 §1.1.1, §1.7, §1.11]. Which life cycle the
  i.MX 95 enclave needs to make a blob, and to open one, is not confirmed (§8).
- Because each blob opens only on its own chip, an encrypted boot image is unique to each device: one `flash.bin`
  per board, not one per release. This is the main operational fact of the scheme.

### 3.3 Tools: CST and SPSDK

- **CST.** Encryption has been in CST's standard build since 3.0.0; earlier versions needed the back end rebuilt
  [S1 §1.3]. On that point alone, the project's pinned CST 3.1.0 would do. But NXP's AHAB introduction says the
  i.MX 95 B0 and later i.MX 9 parts use AHAB 2.0, which needs CST 4.0.1 or SPSDK to sign, and that SPSDK is the
  recommended tool for the family from now on, with CST getting bug fixes only [S11 "AHAB 2.0" note]. If the
  FRDM-IMX95-PRO carries a B0 part, CST 3.1.0 cannot sign its containers at all, encrypted or not. The board's
  silicon revision is not confirmed (§8). The CSF adds an `[Install Secret Key]` section
  after `[Authenticate Data]`; CST signs, encrypts and writes out the DEK in one pass [S1 §1.5, §1.6; S2]. With
  CST's HSM back end (AN14471's model), the signature is made in the HSM. Whether the DEK can also be made and
  held in the HSM, rather than written to a host file, is not described in any public source reached (§8).
- **SPSDK.** SPSDK 3.13.0 lists the i.MX 95 (`mimx9596`, latest revision B0) as an AHAB target [S4]. An AHAB
  image configuration can carry a `blob` section with the DEK (read from a file or a hex value), its size (128 by
  default) and a key identifier. SPSDK encrypts the images with the DEK in AES-CBC. If no device blob is given, it
  leaves an empty placeholder of the right size in the signature block [S5]. `nxpimage ahab update-keyblob` later
  writes the blob that the device made into a built container [S6]. `nxpele generate-keyblob` sends the enclave's
  generate-key-blob request (command 0xAF) over a debug or download connection to the board, so the blob can be
  made without U-Boot's `dek_blob` [S7].
- **No host-side blob for the i.MX 95.** SPSDK 3.13.0 also has an offline blob generator. It derives the wrapping
  key on the host from a customer master key, the SRK hashes and the life cycle. In SPSDK's device database this
  feature (`offline_keyblob`) is turned on only for the i.MX RT2662, not for any i.MX 95 part [S5; S4]. On the
  i.MX 95 the blob is therefore made on each device.
- **Same DEK in both tools.** Both tools need the DEK as host data at build time: CST writes it to a file, and
  SPSDK reads it from one [S1 §1.6; S5]. Neither public source reached describes making the DEK inside a PKCS#11
  HSM.

## 4. What encryption adds over signing alone

- **It adds confidentiality, not integrity.** Signing already makes the ROM and enclave reject a changed image.
  Encryption only stops someone who reads the eMMC, or a `flash.bin` copied off the board, from reading the image
  code [S1 §1.1]. Integrity and the SRK chain are the same with or without it.
- **What the images would hide on this board.** Container 2 holds NXP's System Manager, SPL and the M7 firmware of
  trusted-firmware's `imx95` row; container 3 holds U-Boot and TF-A [S10]. All of these are open source or
  NXP-published binaries. The SPEC keeps the board's keys in the enclave's key store, never in the clear
  ([SPEC](../SPEC.md), `secure-key-handling`). So the boot images should carry no secret, and encrypting them hides
  little that is not already public. This is this survey's reasoning, not a vendor statement.
- **Where it would matter.** It would matter if a boot image ever had to carry a secret or non-public code: for
  example a provisioning credential, a proprietary M7 algorithm, or a configuration that reveals the tamper
  response. Nothing in the SPEC puts such data in a boot image today. The better fix for a secret is to keep it out
  of the image (the key-store route), not to encrypt the image.
- **What it does not cover.** The Linux kernel, root filesystem and xkmsd sit outside the boot containers. Boot
  container encryption does nothing for them, and the public guide covers only the bootloader containers [S1].
  Protecting them is a matter for the `platform-image` row (for example disk encryption keyed from the enclave),
  not for AHAB.

## 5. What it costs

### 5.1 Boot time

- The enclave decrypts each encrypted image with AES-CBC (SPSDK's model of the blob, [S5]) as part of
  authentication. No public source reached gives a figure for the time this adds on the i.MX 95, or on any i.MX 9
  part. The cost is not confirmed (§8). It grows with the size of the encrypted images. The images in the boot
  containers are small next to the Linux image, so a large cost is not expected, but that has to be measured on the
  board, not assumed.
- Each encrypted container also adds a blob unwrap in the enclave. Its cost is not published either.

### 5.2 Key custody under go-xkms

- **The DEK is a symmetric secret that must exist in the clear.** CST writes the DEK it makes to a file on the
  signing host [S1 §1.6], and SPSDK reads it from a file [S5]. The SPEC's custody model (AN14471, keys held in an
  HSM and used through go-xkms) covers the *signing* keys. No public source reached describes a way to keep the DEK
  inside an HSM through CST's HSM back end or SPSDK (§8). The DEK would be the first boot secret outside the HSM.
- **The DEK has to reach every device.** The blob is made by the enclave on the device, from the clear DEK
  [S1 §1.7; S3; S7]. So each board has to receive the DEK in the clear, over USB mass storage and U-Boot in NXP's
  guide [S1 §1.7], or over the serial download or debug link with `nxpele` [S7]. That transfer has to happen in a
  trusted provisioning step, which the `oem-key-provisioning` row owns ([SPEC](../SPEC.md)).
- **Per-device artefacts.** Each board's blob is different, because it is wrapped under that chip's OTPMK
  [S1 §1.1.1]. The build produces one encrypted image, but each board's flash image is that image plus its own blob
  [S1 §1.8; S6]. The release pipeline and go-trusted-platform's provisioning then have to track a blob per device,
  or the device has to make its own blob at install time, which brings the clear DEK back onto the device.
- **One DEK for many devices widens the blast radius.** If a single DEK serves every board, one disclosure exposes
  every board's boot image. A DEK per device removes that, but it multiplies the custody load. The public sources
  give no guidance on DEK lifetime or sharing (§8).
- **A leaked DEK costs confidentiality only.** The signature still protects integrity. So a DEK leak is less
  serious than a signing key leak, but nothing on the device can revoke a DEK. A new release has to use a new DEK
  and get new blobs.

## 6. Interaction with anti-rollback (#41) and SRK rotation (#58)

- **Version fields stay in the clear.** The fuse version and SW version are in the container header [R41 §2], and
  the header is in the signed range but outside the encrypted images [S1 §1.1]. Encryption does not change the
  anti-rollback floor: an old encrypted image is refused by the version check the same way as an old signed image.
  The ELE commit that raises the floor [R41 §2.1; R58 §7] does not touch the blob.
- **An old DEK keeps old images decryptable.** If a release reuses an earlier release's DEK, its blobs still open
  old images. Only the version floor stops those images from booting. Encryption gives no rollback protection of
  its own.
- **Updates need a blob per device.** An A/B update of an encrypted boot container needs the new container's blob
  for the device being updated. Either the update carries a blob made earlier for that device, or the device makes
  one, which needs the clear DEK on the device. This adds a step to the update design (#66) that signing alone does
  not need.
- **SRK rotation and revocation do not touch the blob.** The blob sits outside the signed range [S1 §1.1] and is
  wrapped under the chip's OTPMK, not under an SRK [S1 §1.1.1]. Re-signing with another SRK or an SGK [R58 §5]
  should therefore not need new blobs. On the i.MX 95 this is an inference, not confirmed (§8): SPSDK's host-side
  generator for another part derives the wrapping key from the SRK hashes and the life cycle [S5], and if the
  i.MX 95 enclave does the same, a change of the fused SRK hash or of the life cycle would make every blob unusable.
- **The life cycle matters more.** NXP's guide asks for the OEM closed life cycle before blobs are made [S1 §1.1.1].
  If the wrapping key depends on the life cycle (as in SPSDK's derivation for another part, [S5]), blobs made while
  a board is open would not open after it is closed. Encryption would then have to wait until after the
  irreversible close, the step R58 and the `oem-key-provisioning` row treat as the owner's decision. Not confirmed
  for the i.MX 95 (§8).

## 7. Recommendation for the first release

**Encrypt no boot image in the first release. Sign every container, and keep the design open to encrypting
later.**

The reasons, each from the sections above:

1. **Little to hide.** The boot containers hold open-source or NXP-published code, and the SPEC keeps the keys in
   the enclave (§4). Encryption would protect no asset the SPEC names.
2. **A new secret outside the HSM.** The DEK has to exist in the clear on the build host and on every device that
   makes a blob. No public source shows a way to hold it in go-xkms's HSM custody (§5.2).
3. **Per-device images and an update dependency.** Every board needs its own blob, made by its own enclave, and
   every A/B update needs one too (§5.2, §6).
4. **An irreversible prerequisite.** NXP's guide asks for the OEM closed life cycle before blobs are made (§3.2, §6).
   Closing the life cycle is the owner's decision, and it cannot be undone.
5. **Too much unconfirmed on the i.MX 95.** The i.MX 95 is not named in the guide; the container version 2 path,
   the decryption of the Cortex-M33 images, the accepted DEK lengths and the boot time cost are all unconfirmed
   (§8).

To keep encryption open for a later release at low cost:

- Make it a SPEC rule that boot images carry no secret and no non-public code. Then the question of encrypting
  them comes up again only if that rule has to be broken.
- Choose the signing tool (#9) with encryption in mind. SPSDK has a blob placeholder, `update-keyblob` and the
  `nxpele` blob request [S5; S6; S7], and NXP names it the recommended tool for AHAB 2.0 [S11]. This survey
  supports SPSDK over CST 3.1.0 for the i.MX 95 B0 whether or not encryption is ever used.
- Leave confidentiality of the Linux side (kernel, root filesystem, xkmsd configuration) to the `platform-image`
  row. That is where the board's non-public data, if any, would live.

## 8. Not confirmed

Points this survey could not confirm from public sources. The i.MX 95 Security Reference Manual and IMX95RM would
settle most of them; both are missing ([references](../references/README.md)).

1. That the i.MX 95 supports AHAB encrypted boot at all. The NXP guide covers "i.MX 9x" through the i.MX 93 [S1];
   no public source reached names the i.MX 95.
2. That the B0 boot ROM decrypts images in container format version 2 (AHAB 2.0) [S10; S11].
3. Which images in the i.MX 95's second container (OEI, System Manager, M7, SPL) may be encrypted, and which index
   each has. In particular, whether the OEI and System Manager, which run on the Cortex-M33 before DDR is up, can
   be [S10].
4. The polarity of the Image Indexes mask: the guide's wording and NXP's `0xFFFFFFFE` examples are read here as
   "a set bit means encrypted" [S1 §1.5; S2].
5. Which DEK lengths the i.MX 95 boot ROM accepts. U-Boot's `dek_blob` takes 128, 192 and 256 bits [S3].
6. Which life cycle the i.MX 95 enclave needs to make, and to open, a DEK blob. NXP's guide asks for OEM closed but
   shows an OEM open board booting the result [S1 §1.1.1, §1.11].
7. What the i.MX 95 enclave mixes into the blob wrapping key (life cycle, SRK hashes or only the OTPMK). SPSDK's
   derivation for the RT2662 uses all three [S5]; this decides whether SRK revocation or closing the life cycle
   invalidates blobs (§6).
8. Whether U-Boot's or Linux's authentication of later containers (OS, M7 loaded after boot) decrypts encrypted
   images on the i.MX 95.
9. Whether CST's HSM back end or SPSDK can make and keep the DEK inside a PKCS#11 HSM.
10. The boot time cost of decryption on the i.MX 95.
11. The silicon revision (A1 or B0) of the FRDM-IMX95-PRO, which decides the container format and whether CST 3.1.0
    can sign at all [S10; S11].
12. Whether the image hashes in the signed container header are taken over the plain or the encrypted image. This
    decides whether one signed container serves every board, with only the blob differing.

Sources not read:

| Source | State |
|---|---|
| NXP AN14471, *Using Hardware Security Module for Code Signing* (https://www.nxp.com/docs/en/application-note/AN14471.pdf) | Reached (HTTP 200), but not read: the lane has no PDF text tool. The SPEC already cites it for HSM custody; whether it covers the DEK is unconfirmed. |
| NXP AN12312, *Secure Boot on i.MX 8 and i.MX 8X Families using AHAB* (https://www.nxp.com/docs/en/application-note/AN12312.pdf) | Not reached (HTTP 404 from the lane). |
| NXP i.MX Linux User's Guide (https://www.nxp.com/docs/en/user-guide/IMX_LINUX_USERS_GUIDE.pdf) | Not reached (HTTP 404 from the lane). |
| NXP IMX95RM (https://www.nxp.com/docs/en/reference-manual/IMX95RM.pdf) | Not reached (HTTP 404 from the lane); listed as missing in the SPEC. |
| i.MX 95 Security Reference Manual | Not public (NDA); listed as missing in the SPEC. |
| NXP RM00284 (EdgeLock Enclave HSM API) and the "ELE API Reference Guide" the U-Boot guide cites [S1] | Not read in this survey; the generate-key-blob request is known here only through U-Boot [S3] and SPSDK [S7]. |
| NXP CST 3.1.0 and 4.0.1 user guides | Behind NXP's download login; not read. |

## 9. Questions for the owner

1. **Should the first release encrypt any boot image?**
   (a) No: sign only. (b) Container 3 (U-Boot and TF-A) only. (c) Containers 2 and 3.
   *Recommendation:* (a), for the reasons in §7.
2. **Should the SPEC say that boot images carry no secret and no non-public code?**
   (a) Yes, as a `boot-container` requirement. (b) No; decide image by image.
   *Recommendation:* (a). It is what makes (a) in question 1 safe, and it points any future secret to the
   enclave's key store, which the SPEC already requires (§4).
3. **Which signing tool, given AHAB 2.0 on the B0?** This feeds #9.
   (a) SPSDK. (b) CST 4.0.1 or later. (c) Keep CST 3.1.0, only if the board turns out to carry an A1 part.
   *Recommendation:* (a). NXP names SPSDK the recommended AHAB tool for the i.MX 9 family, CST 3.1.0 cannot sign
   AHAB 2.0, and SPSDK has the blob tooling encryption would need later [S11; S5; S6; S7].
4. **How should the board's silicon revision (A1 or B0) be confirmed?**
   (a) The owner reads it from the board or its documentation. (b) It is taken from a boot log of the board as
   shipped.
   *Recommendation:* (a) or (b), whichever is first. It decides the container format and the CST question (§8,
   item 11). Either is a read only; no fuse or life-cycle step is involved.
5. **If encryption is adopted later, how widely is one DEK shared?**
   (a) One DEK per release for every board. (b) One per board. (c) One per production batch.
   *Recommendation:* none; the public sources give no guidance (§5.2). (a) is simplest to hold; (b) limits the
   damage of a leak but multiplies custody.
6. **If encryption is adopted later, where is the DEK made and held?**
   (a) Inside the go-xkms HSM, exported only in wrapped form to the provisioning station, if the tools can be made
   to accept that. (b) By CST or SPSDK on an offline signing host, as a file, in a key ceremony. (c) Not adopted.
   *Recommendation:* none until §8 item 9 is answered. (b) is the only route the public sources show, and it puts
   a boot secret outside the HSM.
7. **If encryption is adopted later, where are blobs made?**
   (a) At factory provisioning, by `nxpele` over the board's download link [S7]. (b) In U-Boot with `dek_blob`
   [S1; S3]. (c) On the device during each update.
   *Recommendation:* (a). It keeps the clear DEK off field devices, and it fits the `oem-key-provisioning` row.
   (b) needs a filesystem and USB mass storage on the board [S1 §1.7]. (c) needs the clear DEK on every field
   device.
8. **Does the board need confidentiality for its Linux side (kernel, root filesystem, xkmsd configuration)?**
   (a) Yes: open a `platform-image` survey of disk encryption keyed from the enclave. (b) No.
   *Recommendation:* (a) if any confidentiality is wanted at all. The board's non-public data would live there, and
   AHAB boot encryption does not reach it (§4).
9. **Before any encrypted release, must the boot time cost be measured on the board?**
   (a) Yes, a measurement against a signed-only image is a release gate. (b) No.
   *Recommendation:* (a). No public figure exists (§5.1).
