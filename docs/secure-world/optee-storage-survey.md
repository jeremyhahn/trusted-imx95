# OP-TEE secure storage and TA signing on the i.MX 95: survey

Status: survey for the owner (issue #88), documentation only. Input to #32.

## 1. Scope and method

The questions (issue #88):

1. How OP-TEE on the i.MX 95 stores secrets (REE FS, RPMB), which key
   protects them, how the i.MX 95 port gets its hardware unique key (HUK),
   and what changes when the device's life cycle closes.
2. How trusted applications (TAs) are signed and verified, who holds the TA
   signing key (go-xkms), and how a TA is revoked or updated.
3. Whether OP-TEE is needed at all if the Cortex-M7 and the EdgeLock
   Enclave (ELE) hold the keys (input to #32).

Method: public sources only, listed in section 2 with their version. The
text is a summary in this document's own words; nothing is copied from
vendor documents. For the OP-TEE source trees, this survey read the
**commit history** (subjects, messages, and the first release tag that
contains each commit), not the C source. A claim that would need the
source is marked as not confirmed (section 10). No fuse, life-cycle or
provisioning step was run or scripted.

## 2. Sources surveyed

| Id | Source | Version | URL | Read |
|----|--------|---------|-----|------|
| S1 | OP-TEE OS (upstream) | tag 4.9.0 (2025-12-29); history back to 2022 | https://github.com/OP-TEE/optee_os/tree/4.9.0 | commit history of `core/drivers/crypto/ele` and `core/arch/arm/plat-imx` |
| S2 | OP-TEE documentation, "Secure storage" | tag 4.9.0 | https://github.com/OP-TEE/optee_docs/blob/4.9.0/architecture/secure_storage.rst (rendered: https://optee.readthedocs.io/en/latest/architecture/secure_storage.html) | in full |
| S3 | OP-TEE documentation, "Porting guidelines", section "Hardware Unique Key" | tag 4.9.0 | https://github.com/OP-TEE/optee_docs/blob/4.9.0/architecture/porting_guidelines.rst | that section |
| S4 | OP-TEE documentation, "Trusted Applications" (architecture) | tag 4.9.0 | https://github.com/OP-TEE/optee_docs/blob/4.9.0/architecture/trusted_applications.rst | TA locations, REE FS TA formats, rollback, subkeys, secure storage TAs |
| S5 | OP-TEE documentation, "Trusted Applications" (building), section "Signing of TAs" | tag 4.9.0 | https://github.com/OP-TEE/optee_docs/blob/4.9.0/building/trusted_applications.rst | that section |
| S6 | OP-TEE documentation, "Platforms: NXP", security disclaimer | tag 4.9.0 | https://github.com/OP-TEE/optee_docs/blob/4.9.0/architecture/platforms/nxp.rst | in full |
| S7 | NXP OP-TEE OS fork `imx-optee-os` | branch `lf-6.18.37_2.1.0` (described as tag `lf-6.18.37-2.1.0`) | https://github.com/nxp-imx/imx-optee-os/tree/lf-6.18.37_2.1.0 | commit history of `core/drivers/crypto/ele` and `plat-imx/conf.mk` since 2024 |
| S8 | NXP U-Boot fork, "i.MX 8ULP/9x Secure boot guide using AHAB" | branch `lf_v2025.04` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt | boot image content, SRK fuse, closing the device |
| S9 | NXP, "i.MX Linux User's Guide" (UG10163) | not determined | https://www.nxp.com/docs/en/user-guide/UG10163.pdf | downloaded, **not read**: the lane has no PDF reader |

Not reached or not used: the i.MX 95 Security Reference Manual and IMX95RM
(not public), the ELE firmware API reference for the i.MX 95 (not found as
a public document), and the OP-TEE "Subkeys" page (present in S2's tree,
not read; section 7 relies on S4's summary of it).

## 3. OP-TEE support for the i.MX 95

From the upstream history (S1), with the first release tag that contains
each change:

| Change (upstream commit subject) | First in |
|------|------|
| "core: imx: add support for i.MX95 EVK" | 4.4.0 |
| "core: imx: enable CFG_CORE_HUK_SUBKEY_COMPAT_USE_OTP_DIE_ID by default" (the SSK uses the platform's die ID) | 4.4.0 |
| "drivers: ele: use the baseline API to retrieve the UID" (the ELE driver reads the device UID from the enclave) | 4.6.0 |
| "core: imx: enable MU and ELE drivers for imx95" | 4.9.0 |
| "drivers: ele: enable getting HUK/RNG from ELE on imx95" | 4.9.0 |
| "core: imx: enable attestation PTA" (all i.MX, by default) | 4.4.0 |

"First in" is the earliest of the tags 4.1.0 to 4.9.0 that contains the
commit; author dates are often much earlier than the release.

So upstream OP-TEE talks to the i.MX 95's enclave, and takes its HUK from
it, only from **4.9.0**. Upstream names the i.MX 95 **EVK** as its board; an
upstream flavour for the FRDM-IMX95 board was not looked for and is not
confirmed.

NXP's fork (S7, `lf-6.18.37_2.1.0`) carries more ELE work than upstream:
a call to read the device's life cycle from the ELE, a refusal to read
fuses once the life cycle is closed, ELE key-store access (including a
"shared" key store flag), RSA and ECC operations in the ELE, and "trusted
keys" early TA support used for dm-crypt on newer parts. Which of these are
built for the i.MX 95 by default was not confirmed (it needs the
`conf.mk` source).

The OP-TEE documentation (S6) states that NXP's i.MX OP-TEE releases are
enablement software, not production-ready, that the default security
configuration of i.MX platforms is left open, and that using upstream
releases rather than NXP's may change features and security level.

## 4. Secure storage: REE FS and RPMB

Source: S2.

OP-TEE implements GlobalPlatform trusted storage with two back ends, which
can be built together:

- **REE FS** (`CFG_REE_FS=y`, the default). OP-TEE encrypts and authenticates
  each object itself and hands the ciphertext to `tee-supplicant`, which
  writes it into the Linux file system (by default under `/data/tee/`). A
  directory file lists the objects. Confidentiality and integrity come from
  OP-TEE; the files can still be deleted, or replaced by an older copy,
  because Linux owns the medium. The documentation states that with REE FS
  alone the rollback protection level is 0.
- **RPMB FS** (`CFG_RPMB_FS=y`). Objects live in the Replay Protected
  Memory Block partition of an eMMC. OP-TEE has no eMMC driver: every RPMB
  frame goes through `tee-supplicant` and the Linux MMC ioctl, but each
  frame is authenticated with an HMAC under the RPMB key and a write
  counter, so Linux can relay or drop requests but cannot forge or roll
  back their content. The documented rollback protection level is 1000.
- **Both together.** If both are built, OP-TEE keeps a hash of the REE FS
  state in RPMB (`dirfile.db.hash`), which gives the bulk REE FS store
  rollback detection anchored in RPMB.

Key hierarchy, common to both back ends:

| Key | Derived from | Lives |
|-----|--------------|-------|
| HUK (hardware unique key) | platform hook `tee_otp_get_hw_unique_key()` | hardware; see section 5 |
| SSK (secure storage key) | HMAC-SHA256 over the chip ID and a fixed string, keyed by the HUK | secure RAM, derived at each boot |
| TSK (per-TA storage key) | HMAC-SHA256 of the TA UUID, keyed by the SSK | secure RAM |
| FEK (per-file key) | random at file creation, stored wrapped by the TSK | in the file's metadata |
| RPMB authentication key | also derived from the HUK (and the eMMC identity) unless `CFG_RPMB_TESTKEY=y` | programmed once into the eMMC |

Points that matter for this board:

- The RPMB key can be written into an eMMC only once in its life. OP-TEE
  can write it itself (`CFG_RPMB_WRITE_KEY=y`), but then the key crosses the
  normal world in clear; the documentation calls that a development-only
  option and prefers programming it in a controlled factory step. A platform
  hook, `plat_rpmb_key_is_ready()`, lets the port refuse to write the key
  until the device is in its secured state.
- Because a secured SoC is expected to give a different HUK from an open
  one, an RPMB key programmed while the device is open will not match the
  key OP-TEE derives after the device is closed, and RPMB access is then
  denied for the life of that eMMC (section 6).
- `CFG_RPMB_TESTKEY=y` embeds a fixed key. It is for development only.
- A platform that does not implement the HUK hook falls back to a constant
  key, which gives no confidentiality and no binding to the device.

Whether the FRDM-IMX95-PRO's boot medium is an eMMC with an RPMB partition
that Linux exposes is not confirmed here (section 10).

## 5. The hardware unique key on the i.MX 95

- The OP-TEE porting guide (S3) says the generic HUK hook is a stub that a
  real product must replace, ideally with a key that software, even secure
  software, never reads directly, for example one held by a crypto engine
  or a secure co-processor.
- On the i.MX 95 that co-processor is the ELE. From upstream 4.9.0 (S1),
  OP-TEE obtains its HUK from the ELE ("enable getting HUK/RNG from ELE on
  imx95"); the same change was made for the i.MX 943 and, in NXP's fork,
  the i.MX 952 and i.MX 937 (S1, S7). An earlier upstream commit describes
  the ELE driver doing an "HUK derivation" with memory shared with the ELE
  (S1), which indicates that the ELE derives a key for OP-TEE on request
  rather than OP-TEE reading a fuse.
- The chip ID that enters the SSK derivation (section 4) is the platform
  die ID on i.MX builds since 4.4.0, and the ELE driver fetches the device
  UID from the ELE (S1). That the die ID used for the SSK is exactly this
  UID is an inference from two commit subjects, not confirmed from source.

Not confirmed from public sources: which root inside the ELE the HUK is
derived from, the derivation context OP-TEE passes, whether the result is
exposed in OP-TEE's memory (it is, at least transiently, since the
generic hook returns key bytes), and whether the derived value changes
with the life cycle (section 6).

Consequence: an OP-TEE older than 4.9.0 upstream, or an NXP build that
does not enable the ELE HUK for the i.MX 95, does not bind secure storage
to the enclave. Which HUK such builds use instead is not confirmed.

## 6. What changes when the life cycle closes

- NXP's AHAB guide for the i.MX 8ULP and 9x family (S8) describes the
  close: after the SRK hash fuses are programmed and a signed image boots
  without enclave security events, the life cycle is moved from OEM open
  to OEM closed. The step is irreversible and, if an earlier step failed,
  leaves the part unbootable. After it the enclave boots only containers
  signed under the fused SRK. The guide lists OP-TEE as an optional part of
  the boot image, beside TF-A and U-Boot, so the OP-TEE binary, its embedded
  TA public key and any early TAs are covered by the container signature.
  (This survey describes the step; it does not script or run it.)
- NXP's fork (S7) reads the life cycle from the ELE and refuses fuse reads
  from OP-TEE once the life cycle is closed.
- The OP-TEE storage documentation (S2) states that security-aware SoCs
  generally give a different HUK once they are set to boot only signed
  images. **Whether the ELE-derived HUK on the i.MX 95 changes at the close
  is not confirmed.** If it does: every REE FS object written before the
  close becomes unreadable, and an RPMB key programmed before the close no
  longer matches, which locks the RPMB partition of that eMMC for good.
- Whether the i.MX port implements `plat_rpmb_key_is_ready()` to refuse
  RPMB key programming while the life cycle is open is not confirmed.

Practical reading, valid whichever way the HUK behaves: nothing that must
survive into the field should be written to OP-TEE secure storage, and no
RPMB key should be programmed, before the life cycle is closed.

## 7. TA signing and verification

Sources: S4, S5.

- **Where TAs come from.** A TA is either an *early TA*, linked into the
  OP-TEE core image and therefore covered by the boot container's
  signature (section 6), or a *REE FS TA*, a separate `.ta` file that
  `tee-supplicant` loads from Linux and OP-TEE verifies, or a TA installed
  into secure storage.
- **Verification of REE FS TAs.** OP-TEE embeds one RSA public key at
  build time and checks each TA's signature against it on every load. The
  documentation states that only a single TA key is supported. The source
  tree ships a default private key for development; the documentation says
  never to deploy a build that trusts it.
- **Offline signing.** The build can embed only a public key
  (`TA_PUBLIC_KEY`). Signing is then done in three steps: produce a digest
  of the stripped TA, have the private key sign the digest elsewhere (the
  documentation gives an RSA-PSS with SHA-256 example, including through a
  PKCS#11 HSM), and stitch the signature onto the TA. The private key never
  needs to be on the build machine.
- **Subkeys.** A chain of subkeys, each signed by the one above and the
  first by the root TA key, can delegate signing; a TA signed with a subkey
  is confined to that subkey's UUID namespace (S4).
- **Encrypted TAs** (`CFG_ENCRYPT_TA=y`) are signed, then encrypted with a
  symmetric key that the platform supplies through a hook. Whether the i.MX
  port supplies that key from the ELE is not confirmed.

Custody under go-xkms: the offline flow fits a model where the TA root
private key (and any subkey private keys) are held by go-xkms in its HSM,
the OP-TEE build gets only the public key, and CI submits digests to
go-xkms for signature. How go-xkms exposes signing (its interface,
policy and audit) is go-xkms's and is not surveyed here. Note that the TA
public key is part of the OP-TEE image, so its integrity rests on the
boot container's signature, whose key (SRK) is a different key with its
own custody.

## 8. TA revocation and update

- **Update.** A REE FS TA is updated by replacing its `.ta` file. OP-TEE
  keeps a version database (`ta_ver.db`) in secure storage and refuses to
  load a TA whose version (`CFG_TA_VERSION`) is lower than the last one
  loaded. The documentation states this downgrade protection is effective
  only with RPMB (S4), because the database itself can otherwise be rolled
  back.
- **Revoking one TA.** None of the documents read describes a revocation
  list. The mechanism they give is the version floor, and shipping a
  higher version of the TA (or a stub with a higher version) does not by
  itself revoke the old one. The floor rises only when OP-TEE loads the
  newer TA and persists its version, and REE FS TAs reach OP-TEE through
  Linux and tee-supplicant. A compromised Linux or tee-supplicant can
  withhold the new `.ta` file and keep presenting the old, validly signed
  one, so the floor never advances. Revocation of a REE FS TA is
  therefore complete only once the newer version has been loaded on that
  board and its floor persisted in RPMB, or when the trusted image itself
  enforces a revocation policy (for example a minimum version or a
  denied-TA list built into the signed OP-TEE image, which none of the
  documents read describes; not confirmed). Early TAs change only with a
  new boot container.
- **Revoking the TA signing key.** With a single root key built into the
  image, the key is replaced by building OP-TEE with a new public key and
  shipping a new signed boot container. Every REE FS TA must then be
  re-signed. Preventing a downgrade to an old container that still trusts
  the old key depends on the enclave's container anti-rollback, which this
  survey did not confirm for the i.MX 95.
- **Revoking a subkey.** Not described in the documents read; not
  confirmed.

## 9. Is OP-TEE needed at all? (input to #32)

What the sources establish:

- The row's own plan (docs/SPEC.md, secure-key-handling) keeps the board's
  keys in the ELE key store, used through the enclave's HSM API, with the
  caller (Cortex-A55 Linux or Cortex-M7) still open. OP-TEE secure storage
  would then hold no key the plan depends on.
- OP-TEE is optional in the i.MX 9x boot image (S8).
- What OP-TEE adds on the i.MX 95, per S1 and S7: an HUK and RNG from the
  enclave inside the TrustZone secure world, an attestation pseudo-TA
  enabled by default on i.MX, a PKCS#11 TA, and, in NXP's fork, ELE key
  store, RSA and ECC operations and trusted keys for dm-crypt. Upstream
  added an OP-TEE-only ("trusted") messaging unit for the enclave on the
  i.MX 93 and i.MX 91 in 4.6.0 (S1); whether the i.MX 95 port uses a separate trusted MU, and
  whether the enclave grants it rights the Linux side does not have, is
  not confirmed.
- What OP-TEE costs: a second trusted code base on the A55 with its own
  image, its own signing key (section 7) and its own storage whose key
  may change at the close (section 6); NXP describes its i.MX OP-TEE as
  not production-ready by default (S6).

Options:

- **(a) No OP-TEE.** TF-A and Linux on the A55; keys in the ELE; the
  Cortex-M7 (or Linux) calls the HSM API. Smallest trusted base. Linux
  features that need OP-TEE (OP-TEE trusted keys, the OP-TEE PKCS#11 TA,
  the attestation PTA) are not available.
- **(b) Minimal OP-TEE, no loadable TAs.** OP-TEE built with the ELE HUK
  and RNG, early TAs only (for example trusted keys for dm-crypt), REE FS
  loading of TAs disabled. No TA signing key to keep. Secure storage, if
  any, holds nothing that cannot be regenerated.
- **(c) Full OP-TEE with REE FS TAs.** A TA fronts the enclave or holds
  application secrets; needs RPMB, a TA signing key in go-xkms, and a
  factory step for the RPMB key after the close.

Recommendation, from the sources: if #32 places the HSM API caller on the
Cortex-M7, take **(a)**; if it places it on the A55, take **(b)** only for
a named need (dm-crypt, a secure-world RNG or attestation), and do not
make OP-TEE secure storage the home of any long-term key in either case.
(c) adds a signing key and an RPMB factory step for no need the SPEC
names today.

## 10. Not confirmed

1. The internal root, context and life-cycle dependence of the HUK the ELE
   derives for OP-TEE on the i.MX 95 (sections 5, 6).
2. That the SSK's chip ID is the ELE UID (section 5).
3. Which NXP-fork ELE features (key store, RSA/ECC, trusted keys) are built
   for the i.MX 95 by default (section 3).
4. Whether the i.MX port implements `plat_rpmb_key_is_ready()` or the TA
   encryption key hook (sections 6, 7).
5. Whether the FRDM-IMX95-PRO boots from an eMMC whose RPMB partition Linux
   exposes, and whether upstream OP-TEE has an FRDM-IMX95 flavour
   (sections 3, 4).
6. The enclave's container anti-rollback on the i.MX 95, needed to make a
   TA key revocation stick (section 8).
7. Whether OP-TEE uses a separate trusted messaging unit on the i.MX 95 and
   what the enclave grants it (section 9).
8. Subkey revocation (section 8).
9. The content of S9 (not readable in the lane), and the non-public i.MX 95
   Security Reference Manual, IMX95RM and ELE API reference.

## 11. Questions for the owner

1. **Does the board run OP-TEE?** Options: (a) no OP-TEE; (b) minimal
   OP-TEE with early TAs only; (c) full OP-TEE with REE FS TAs.
   Recommendation: decide with #32; (a) if the Cortex-M7 calls the HSM API,
   (b) if the A55 does and a named need exists (section 9).
2. **Which OP-TEE tree?** Options: (a) upstream, 4.9.0 or later (the first
   with the ELE HUK on the i.MX 95); (b) NXP's `imx-optee-os`
   `lf-6.18.37_2.1.0` or later, for its ELE key store and trusted keys.
   Recommendation: (a) unless an NXP-only feature is needed, because S6
   describes NXP's release as enablement software; never a tree older than
   4.9.0 (section 5).
3. **Secure storage back end, if OP-TEE stores anything?** Options:
   (a) REE FS only; (b) RPMB only; (c) REE FS with its state hash in RPMB.
   Recommendation: (c), because REE FS alone has no rollback protection and
   TA downgrade protection needs RPMB (sections 4, 8); conditional on
   confirming the board's eMMC and RPMB (section 10, item 5).
4. **When and where is the RPMB key programmed?** Options: (a) by OP-TEE
   at first boot (`CFG_RPMB_WRITE_KEY=y`); (b) in the factory, after the
   life cycle is closed, from a controlled station. Recommendation: (b);
   S2 limits (a) to development, and programming before the close risks a
   permanently locked RPMB (section 6).
5. **Who holds the TA signing key?** Options: (a) go-xkms holds the root
   TA key and signs digests (offline flow); (b) go-xkms holds the root and
   signs subkeys per TA vendor; (c) no TA key, because no REE FS TAs are
   loaded. Recommendation: (c) with option 1(b); otherwise (a), adding (b)
   only when a second TA author exists (section 7).
6. **How is a TA or the TA key revoked?** Options: (a) version floor via
   `ta_ver.db` on RPMB for TAs, and a new boot container for the key;
   (b) early TAs only, so every change is a new signed container.
   Recommendation: (b) if OP-TEE is kept minimal, else (a), after the
   enclave's container anti-rollback is confirmed (section 8). Under (a)
   a TA counts as revoked on a board only once the newer version has been
   loaded there and its floor persisted, because Linux can withhold the
   new file; a revocation policy in the trusted image would remove that
   dependency but none is documented (section 8).
7. **Can the non-public i.MX 95 security documents be added to the
   private references?** The ELE HUK derivation and its life-cycle
   behaviour (section 10, items 1 and 6) cannot be settled from public
   sources. Recommendation: yes, before any OP-TEE storage is designed.
