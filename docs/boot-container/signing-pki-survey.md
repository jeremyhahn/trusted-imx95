# boot-container: AHAB signing PKI layout survey

> **Status: SURVEY (draft for the owner)** · Row: boot-container · Issue: #124 · Surveyed: 2026-11-12
> Public sources only. Vendor text is summarised, never copied. Each claim cites a source from the
> [Sources](#sources) list by its tag, for example [S1]. What could not be confirmed is marked **Unconfirmed**.

## 1. Scope

The AHAB signing PKI that signs this repository's OEM boot containers on the i.MX 95 (the boot-container row of
[SPEC.md](../SPEC.md)): the SRKs, their certificates, the SRK table and its fused hash; the production layout the
test PKI (#9) mirrors; which keys go-xkms holds; and how the test PKI is kept apart from production. It is a
survey: no key is generated, no fuse is written, no life-cycle or provisioning step is run or scripted.

## 2. Sources

All reached on 2026-11-12 from public repositories. NXP's PDFs in the private context repository (AN14471, CST
3.1.0 guides, RM00284) are not public and are not cited here.

| Tag | Source | Version surveyed | URL |
|---|---|---|---|
| S1 | U-Boot, *i.MX Secure and Encrypted Boot using AHAB* (`doc/imx/ahab/introduction_ahab.rst`) | `master` at commit `3cb2cbb` (2026-11-11) | https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/introduction_ahab.rst |
| S2 | U-Boot, i.MX 95 container notes (`doc/imx/imx95_container.txt`) | `master` at commit `3cb2cbb` | https://github.com/u-boot/u-boot/blob/master/doc/imx/imx95_container.txt |
| S3 | SPSDK documentation, *AHAB* (`docs/images/ahab.rst`), i.MX 95 container layout | v3.13.0 (`e104adf`, 2026-11-03) | https://github.com/nxp-mcuxpresso/spsdk/blob/master/docs/images/ahab.rst |
| S4 | SPSDK device database, `mimx9596` (`spsdk/data/devices/mimx9596/database.yaml`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/tree/master/spsdk/data/devices/mimx9596 |
| S5 | SPSDK example, i.MX 95 signed U-Boot (`examples/ahab/imx95/`, `inputs/configs/mx95_signed_uboot_primary.yaml`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/tree/master/examples/ahab/imx95 |
| S6 | SPSDK release notes (`docs/release_notes.rst`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/master/docs/release_notes.rst |
| S7 | SPSDK example, *AHAB SRK Table* (`examples/ahab/srk_table/srk_table.ipynb`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/tree/master/examples/ahab/srk_table |
| S8 | SPSDK AHAB data model (`spsdk/image/ahab/ahab_data.py`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/master/spsdk/image/ahab/ahab_data.py |

## 3. The AHAB signing PKI on the i.MX 95

AHAB on the i.MX 95 is run by the EdgeLock secure enclave (ELE): the ELE ROM checks the NXP-signed ELE firmware
container, and the ELE then authenticates every OEM container (the Cortex-M and Cortex-A images) before it is
started [S1 §1.1.3, §1.4]. The OEM root of trust is a hash of the SRK table burned into fuses; the SRK table itself
travels inside each signed container [S1 §1, §2.2].

### 3.1 SRKs: count, key types and sizes

- **Four SRKs.** NXP's PKI script builds a tree of one CA and four Super Root Keys, SRK1 to SRK4; the SRK table
  is built from all four certificates [S1 §2, §2.2]. A container is signed under one of the four, selected by
  index; the other three are spares for revocation.
- **Key types.** The CST 4.x PKI script offers RSA, RSA-PSS, ECC (P-256, P-384, P-521), Dilithium, ML-DSA and a
  hybrid (classical plus post-quantum) tree, with SHA-2 or SHA-3 digests [S1 §2]. U-Boot's worked example is
  ECC P-384 with SHA-384 [S1 §2]. Which of these the i.MX 95 ROM accepts per silicon revision is in §3.2.
- **One known size limit** on another part (RSA-4096 SRK plus SGK on i.MX 8QXP B0) shows that the accepted
  combinations are silicon-specific [S1 §3]; no such limit is published for the i.MX 95 (**Unconfirmed**).

### 3.2 Post-quantum SRK on B0 silicon

- **Two container formats.** SPSDK models i.MX 95 revisions A0/A1 with AHAB container v1 and B0 onwards with
  container v2 (alongside v1) [S3]. SPSDK's device database names B0 as the latest i.MX 95 revision and gives it a
  different root-of-trust type (an SRK table *array*, `srk_table_ahab_v2`) from the A revisions [S4].
- **Two SRK tables, two hash fuses on B0.** For B0 the database lists two fuse groups: the classic SRK hash and a
  separate PQC SRK hash [S4]. A v2 container can carry two SRK tables and two signatures over the same header
  (SPSDK calls this double signing): the first table classic (ECDSA or RSA-PSS), the second post-quantum [S5].
- **PQC algorithms.** SPSDK's i.MX 95 signed-boot example pairs an ECC P-384 table with an ML-DSA-65 table, four
  keys each, and signs every container with SRK 0 of each table [S5]. Its configuration comments describe the
  second table as Dilithium level 3 with SHA-3 hashes, and the first table as RSA-PSS, ECDSA, Dilithium or SM2 with
  RSA-2048/4096, P-256, P-384 or P-521 [S5]. The database defines both a Dilithium and an ML-DSA algorithm code
  [S4]. SPSDK 3.13.0 also routes an LMS-key SRK table to the PQC hash fuses [S6].
- **Which PQC algorithm the B0 ROM and ELE firmware accept** (pre-standard Dilithium-3, final ML-DSA-65, ML-DSA-87,
  LMS) is not stated by any public source reached here: **Unconfirmed**. It needs the i.MX 95 Security Reference
  Manual or the ELE firmware release notes.
- **Which revision the FRDM-IMX95-PRO carries** is not stated by any public source reached here (UM12527 is in the
  private context repository): **Unconfirmed**. The two-table layout applies only if the board is B0 or later.
- **Hash width.** U-Boot's AHAB guide gives a 256-bit SRK hash for the i.MX 9x family [S1 §2.2]; SPSDK's B0 fuse
  description gives 512-bit SRKH and PQC_SRKH fields, and 256 bits for the A revisions [S4]. The two sources
  disagree for B0: **Unconfirmed** until the Security Reference Manual is in hand.

### 3.3 Signing-key (SGK) certificates

- Each SRK may carry one subordinate signing key (SGK). The tree is generated with the CA flag set on the SRK
  certificates, and each SRKn issues SGKn [S1 §2.1].
- With an SGK, the container carries a certificate for the SGK signed by the SRK, and the image signature is
  made by the SGK [S1 §2.1]. The SRK private key is then used only to issue SGK certificates, not to sign
  every build.
- Without an SGK, the SRK private key signs every container directly [S1 §2].

### 3.4 The SRK table, the SRK hash and the fuses

- The SRK table is built from the four SRK public-key certificates and is embedded in each signed container
  [S1 §2.2]. The format holds one to four SRK records, all of one key type, and fixes the signature algorithm
  and length [S7]; NXP's tooling always fills all four [S1 §2.2].
- On the i.MX 95 each container header carries a fuse version and a software version, and its signature block
  holds the SRK table, the signature, an optional SGK certificate and an optional encryption blob [S2]. The
  fuse version is the anti-rollback field the SPEC row names; its fuse mapping is **Unconfirmed** (IMX95RM).
- The container selects which of the four SRKs signed it and may carry a revocation mask that tells the ELE to
  revoke SRKs by index [S5]. Revocation burns fuses and is out of scope here.
- On the i.MX 8ULP and i.MX 9x families the fused SRK hash is 256 bits (SHA-256 over the table); on i.MX 8/8x it
  is 512 bits [S1 §2.2]. At boot the ELE compares the table's hash with the SRK_HASH fuses before trusting any
  key in it [S1 §2.2].
- The fuse words that hold the hash, the SRK revocation bits and the life-cycle effect of closing the device are
  in IMX95RM and the i.MX 95 Security Reference Manual, which this repository does not have
  ([references](../references/README.md#still-missing)): **Unconfirmed**. This survey scripts no fuse step.

## 4. The production layout the test PKI (#9) mirrors

## 5. What go-xkms holds

## 6. Keeping the test PKI from being taken for production

## 7. Unconfirmed

## 8. Questions for the owner
