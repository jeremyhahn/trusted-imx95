# Boot-container signing tool: CST 3.1.0 or SPSDK

Status: survey and recommendation for the owner. Nothing is decided until the owner answers the
questions at the end. This is the decision record for issue #30, in the `boot-container` row of
[docs/SPEC.md](../SPEC.md), which unblocks #9.

Scope: the tool that builds and signs the AHAB containers of the platform image, with the signing
key held in an HSM (go-xkms custody, per the SPEC row). This record says nothing about fuses,
life-cycle changes or provisioning, and it contains no such steps.

Method: only public sources were read, on 2026-11-12. Each source is listed below with its version
or tag. Vendor text is summarised here, not quoted. Anything the public sources do not settle is
marked **unconfirmed**.

## Sources

### Reached

| Id | Title | Version / tag | URL |
|----|-------|---------------|-----|
| S1 | SPSDK (NXP Secure Provisioning SDK), GitHub release | tag `v3.13.0`, published 2026-11-03 | https://github.com/nxp-mcuxpresso/spsdk/releases/tag/v3.13.0 |
| S2 | SPSDK on PyPI (package metadata) | `spsdk` 3.13.0, Python >= 3.10 | https://pypi.org/project/spsdk/3.13.0/ |
| S3 | SPSDK `LICENSE` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/LICENSE |
| S4 | SPSDK documentation, `docs/images/ahab.rst` (AHAB in `nxpimage`) | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/images/ahab.rst |
| S5 | SPSDK device database for the i.MX 95, `spsdk/data/devices/mimx9596/database.yaml` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/data/devices/mimx9596/database.yaml |
| S6 | SPSDK signature providers, `spsdk/crypto/signature_provider.py` and `examples/plugins/` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/crypto/signature_provider.py |
| S7 | SPSDK release notes, `docs/release_notes.rst` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/release_notes.rst |
| S8 | `spsdk-pkcs11`, the PKCS#11 signature-provider plugin: PyPI metadata and its README | PyPI 0.3.8; README on branch `master` of `spsdk_plugins` | https://pypi.org/project/spsdk-pkcs11/0.3.8/ and https://github.com/nxp-mcuxpresso/spsdk_plugins/tree/master/pkcs11 |
| S9 | NXP U-Boot, `doc/imx/ahab/introduction_ahab.txt` | branch `lf_v2025.04`, head commit `99518e6b6f20` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/introduction_ahab.txt |
| S10 | NXP U-Boot, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` and `doc/imx/ahab/csf_examples/` | branch `lf_v2025.04`, head commit `99518e6b6f20` | https://github.com/nxp-imx/uboot-imx/tree/lf_v2025.04/doc/imx/ahab |
| S11 | This repository's own record of the vendor material: [docs/references/README.md](../references/README.md) and [docs/SPEC.md](../SPEC.md) | `main` at the time of writing | (in tree) |

### Not reached, or not public

| Id | Title | Why unconfirmed |
|----|-------|-----------------|
| U1 | NXP Code Signing Tool download page (`colCode=IMX_CST_TOOL_NEW`) | It redirects to an NXP account login. The latest CST version, its release notes and its licence text could not be read from a public page. |
| U2 | CST 3.1.0 user guides (CST_UG, CST-HSM_UG, HSM-CST_UG) | They ship inside the CST archive (S11) and are not public pages. Their content is not used here. |
| U3 | IMX95RM and the i.MX 95 Security Reference Manual | Listed as missing in S11. Not public. |
| U4 | Issue #30 itself | The lane has no forge credentials (`gh` is unauthenticated). This record works from the SPEC row and the lane brief. |
| U5 | The FRDM-IMX95 board's silicon revision (A0, A1 or B0) and orderable part number | No public source read here names it. It matters; see question 5. |

## What the sources say

### Both tools target the i.MX 95 AHAB container

- NXP's U-Boot guide for the i.MX 8ULP and 9x family covers the i.MX 95. Its image layout is the
  8ULP and i.MX 93 layout with an extra executable image and the V2X firmware. Signing is done with
  CST: you take the container and signature-block offsets that `mkimage` prints, put them in a
  CSF description file, and run `cst -i <csf>` (S10). The CSF examples in the same tree cover boot
  images, U-Boot with ATF, and Linux images (S10).
- The U-Boot AHAB introduction says CST can generate a P-384 ECC PKI tree from CST v3.1.0 onward,
  and its `srktool` builds the SRK table and the fuse-value file from four SRK certificates (S9).
- SPSDK's `nxpimage ahab` builds, signs, re-signs and parses AHAB containers from a YAML
  configuration. Since SPSDK 2.3.0 it can also sign an existing image without rebuilding it (S4).
  `nxpimage bootable-image` has templates for the i.MX 95 family (`mimx9596`) and per-board
  templates such as the i.MX 95 19x19 LPDDR5 EVK (S4). The FRDM-IMX95 is not named in the board
  list in S4: **unconfirmed** whether a board template exists for it.
- For the i.MX 95, S4 lists the Cortex-M7 among the cores an AHAB image can target. That is the
  core the SPEC row's container carries (S11).

### Container versions, algorithms and silicon revisions

- SPSDK's i.MX 95 database defines revisions `a0`, `a1` and `b0`, with `b0` the latest. On `b0` it
  supports container version 2 as the default and version 1 as well, and it maps two SRK hash fuse
  groups: a classic one and a PQC one (S5). S4 says the same: container v1 on A0/A1, v2 on B0 and
  later.
- The signature algorithms that S5 lists for the family are RSA-PSS, ECDSA, SM2, Dilithium and
  ML-DSA. SRK sets are none, NXP or OEM (S5).
- The SRK hash digest is unclear. The U-Boot guide says the 8ULP/9x SRK hash is SHA-256, 8 fuse
  words (S10). SPSDK's database calls the `b0` SRKH a SHA-512 digest and another section of the
  same file a SHA-256 digest (S5). **Unconfirmed** which one applies to the board's silicon. U3
  would settle it.
- Whether CST 3.1.0 can produce container v2 or PQC (ML-DSA) signatures for the i.MX 95 B0 is
  **unconfirmed**. No public source read here says so either way (U1, U2).

### HSM custody

- SPSDK has three built-in signature providers: a plain key file, an interactive key file, and an
  HTTP proxy that forwards the data to be signed to a remote signer (S6). Other providers load as
  plugins; SPSDK ships a template for writing one (S6).
- The `spsdk-pkcs11` plugin signs through any vendor PKCS#11 library. You choose it in the YAML
  configuration with `type=pkcs11`, plus the library path, the token label or serial, the key label
  and the PIN. The PIN and the library path can come from environment variables (S8). Its README
  lists RSA, RSA-PSS and ECDSA as the supported schemes. ML-DSA and Dilithium are not listed (S8),
  so PQC signing from an HSM through this plugin is **unconfirmed** and probably unsupported.
  The plugin is BSD-3-Clause and needs `spsdk` >= 3.10, < 4 (S8).
- S11 records that CST 3.1.0 ships an HSM back end with its own guides. How that back end talks to
  an HSM (PKCS#11 or otherwise) cannot be confirmed from public sources (U2).
- How go-xkms exposes signing (a PKCS#11 module, an HTTP API, or neither) is not covered by any
  source read here: **unconfirmed**.

### Licence, distribution and CI

- SPSDK is BSD-3-Clause (S3). It installs from PyPI (S2), so CI can pin an exact version with hashes
  and needs no vendor login.
- CST is downloaded from NXP behind an account login (U1). S11 records that this repository never
  holds CST: the build reads it from `CST_PATH`, and the tool is accepted under NXP's licence
  (LA_OPT36 per S11; the licence text itself is not public, U1). CI therefore needs a
  provisioned CST tree on the runner.

### Maturity

- SPSDK's i.MX 95 support has been under active change. The release notes record unsigned i.MX 95
  images in 2.2.0, A0/A1/B0 and PQC support in 2.3.0, and i.MX 95 fixes in most releases since:
  B0 container parsing (3.7.0), ML-DSA signing and HSM key-store fixes (3.8.0), B0 fast-boot
  alignment (3.9.0), PQC SRKH fuse mapping (3.11.0), and in 3.13.0 the removal of non-orderable
  i.MX 95 part aliases and a fix to AHAB RSA signature verification (S7). A pinned version is
  needed, and upgrades need re-testing.
- CST is the tool NXP's U-Boot AHAB guides use (S9, S10). Its release history for the i.MX 95
  could not be read (U1).

## Comparison

| Criterion | CST 3.1.0 | SPSDK 3.13.0 (+ `spsdk-pkcs11` 0.3.8) |
|-----------|-----------|----------------------------------------|
| i.MX 95 AHAB signing documented publicly | Yes, in NXP's U-Boot guides (S10) | Yes, `nxpimage ahab` with `mimx9596` templates (S4, S5) |
| Container v2 / B0 | Unconfirmed (U1, U2) | Yes (S4, S5) |
| PQC (ML-DSA) | Unconfirmed | Yes with key files (S5, S7); not listed for PKCS#11 (S8) |
| HSM signing | HSM back end exists (S11); interface unconfirmed (U2) | PKCS#11 plugin, HTTP proxy, or a custom plugin (S6, S8) |
| Licence | NXP licence behind login (U1, S11) | BSD-3-Clause (S3, S8) |
| CI install | Provisioned `CST_PATH` tree (S11) | `pip` with a pinned version (S2) |
| Inputs | CSF file plus `mkimage` offsets (S10) | YAML configuration; builds the container itself (S4) |
| Churn risk | Unknown (U1) | High for the i.MX 95; pin it (S7) |

## Recommendation

Where the sources support a choice, they favour **SPSDK** (`nxpimage`, pinned to 3.13.0, with
`spsdk-pkcs11` 0.3.8 for HSM signing, ECDSA P-384 SRKs). The reasons: it documents i.MX 95 B0 and
container v2 support publicly, it reaches an HSM through PKCS#11 without exposing the key, it is
BSD-3-Clause and installs reproducibly in CI, and it lists the Cortex-M7 as an AHAB target on the
i.MX 95 (S3–S8). Keep the existing `CST_PATH` plumbing until the owner decides. That is the
reversible option.

This recommendation depends on two things the sources do not confirm: the board's silicon revision
(U5) and whether go-xkms offers PKCS#11. If go-xkms has no PKCS#11 module, the HSM path becomes
SPSDK's proxy provider or a custom plugin (S6), and that path is not documented publicly for
go-xkms.

## Questions for the owner

1. **Which tool signs the boot container?**
   (a) CST 3.1.0 through `CST_PATH`; (b) SPSDK `nxpimage`, pinned; (c) SPSDK signs and CST
   cross-checks a sample image.
   Recommendation: (b). The sources show i.MX 95 B0 support, HSM signing and a CI install for
   SPSDK, and do not confirm them for CST 3.1.0 (S4–S8, U1, U2).
2. **Which SRK algorithm?**
   (a) ECDSA P-384; (b) hybrid or PQC (ML-DSA) SRKs, using the PQC SRK hash fuses; (c) RSA-PSS.
   Recommendation: (a). The PKCS#11 plugin lists ECDSA but not ML-DSA (S8), and PQC through an HSM
   is unconfirmed. Revisit (b) once go-xkms and the plugin both support ML-DSA.
3. **How does the signer reach go-xkms?**
   (a) a PKCS#11 module from go-xkms, used by `spsdk-pkcs11`; (b) a custom SPSDK signature-provider
   plugin that calls go-xkms (S6); (c) SPSDK's HTTP proxy provider pointed at a go-xkms signing
   service (S6); (d) CST's HSM back end.
   Recommendation: (a) if go-xkms offers PKCS#11, else (b). Which interfaces go-xkms offers is
   unconfirmed.
4. **How is the tool version pinned and upgraded?**
   (a) exact pins with hashes (`spsdk==3.13.0`, `spsdk-pkcs11==0.3.8`), upgraded by a reviewed PR
   that re-signs and re-parses a reference image; (b) a compatible-release range.
   Recommendation: (a), given how often i.MX 95 behaviour changes between SPSDK releases (S7).
5. **Which silicon revision does the FRDM-IMX95 carry: A0/A1 (container v1) or B0 (container
   v2)?** No public source read here says (U5). There is no recommendation; the answer picks the
   container version and the SRK hash fuse group (S4, S5).
6. **What happens to the `CST_PATH` plumbing (S11) if SPSDK is chosen?**
   (a) keep them as an optional path; (b) remove them in a follow-up.
   Recommendation: (a) until questions 1 and 5 are answered, then decide. Keeping them is the
   reversible option.
7. **Can the i.MX 95 Security Reference Manual and IMX95RM be obtained?** They settle the SRK hash
   digest (SHA-256 in S10, SHA-512 for B0 in S5), the fuse map and the AHAB version field for
   anti-rollback (U3).
   (a) request them from NXP under NDA into the private vendor repository; (b) proceed on SPSDK's
   device database alone.
   Recommendation: (a). The two public sources disagree on the digest.
