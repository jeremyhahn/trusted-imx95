# boot-container: AHAB signing PKI layout survey

> **Status: SURVEY (draft for the owner)** · Row: boot-container · Issue: #124 · Surveyed: 2026-11-12
> Public sources only. Vendor text is summarised, never copied. Each claim cites a source from the
> [Sources](#2-sources) list by its tag, for example [S1]. What could not be confirmed is marked **Unconfirmed**.

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
| S9 | go-xkms docs: `docs/image-signing/`, `docs/post-quantum/`, `docs/pkcs11-backend/` | `main` at commit `d55b1b7` (2026-11-11) | https://github.com/jeremyhahn/go-xkms/tree/main/docs |

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
  SPSDK's container model has a distinct SRK-table-array block for this, beside the single SRK table [S8].
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

The layout below is what the sources support; the choices in it are the owner's (§8).

| Element | Production layout | Basis |
|---|---|---|
| Classic SRK table | Four SRKs of one type; ECC P-384 with SHA-384 is the type both NXP-side examples use | [S1 §2], [S5], [S7] |
| PQC SRK table (B0 only) | A second table of four post-quantum SRKs, each container signed by one key of each table | [S4], [S5] |
| SGKs | Optional: one SGK per SRK, with the SRK certificates carrying the CA flag | [S1 §2.1] |
| Active key | One SRK index per table signs; the other three are revocation spares | [S5] |
| Fused root | The hash of each table, in the SRKH and (B0) PQC SRKH fuses | [S1 §2.2], [S4] |
| Container fields | Fuse version (anti-rollback) and software version in each OEM container header | [S2] |

The test PKI mirrors the **shape**, not the keys: the same number of tables, four keys in each, the same key types
and hash algorithms, the same CA-flag setting and the same SGK presence. The CA flag must match because it
changes the SRK table, and so its hash, even though the ELE does not otherwise act on it [S5]. A test PKI with a
different shape would let a container pass in test that production cannot build.

## 5. What go-xkms holds

go-xkms surveyed at `main` commit `d55b1b7` (2026-11-11) [S9].

- **The device holds no signing key.** It holds only the fused SRK hash(es); the SRK public keys travel in the
  container [S1 §1, §2.2]. Every private key in §4 is off-device.
- **go-xkms custody, after the SPEC row.** The row names AN14471's model (signing AHAB containers with keys held in
  an HSM) for go-xkms custody ([SPEC.md](../SPEC.md), boot-container). On that model go-xkms would hold the
  private halves of the four classic SRKs, the four PQC SRKs on B0, and the SGKs if they are used. Whether the
  SRKs stay online in go-xkms or offline, with only the SGKs online, is the owner's choice (§8, Q3).
- **What go-xkms offers today.** Its docs describe an X.509 code-signing certificate profile and image signer
  [S9 image-signing], a PKCS#11 back end and a PKCS#11 provider module [S9 pkcs11-backend], and ML-DSA-44/65/87
  keys [S9 post-quantum]. Its docs at this commit do not mention AHAB, SRKs, NXP CST or SPSDK.
- **Gaps.** ML-DSA keys are reachable only by embedding go-xkms as a library or through its PKCS#11 module, not
  over its REST, gRPC or `xkmsctl` surfaces; HSS/LMS is not implemented [S9 post-quantum]. A B0 PQC SRK table held
  in go-xkms therefore needs either the PKCS#11 path or new go-xkms work, which is go-xkms's to own.
- **How CST or SPSDK reaches go-xkms** (CST's HSM back end, or an SPSDK signature provider, whose configuration
  takes a `type=<identifier>;key=value` string [S5]) is not settled by any public source reached here:
  **Unconfirmed**. AN14471 and the CST HSM guide answer it but are not public.

## 6. Keeping the test PKI from being taken for production

Three layers, each cheap, none of which runs a fuse or provisioning step.

1. **Naming.** Every test key label, file name and certificate subject carries a fixed marker such as
   `TEST-ONLY-NOT-FOR-PRODUCTION` and the repository name. go-xkms already stamps the tenant into a code-signing
   certificate's OU [S9 image-signing]; a separate test tenant gives the same separation at the custody layer.
2. **Fingerprints.** The SRK table hash is the one value that matters: it is what would be fused [S1 §2.2]. The
   repository records the test PKI's SRK hash(es), public values and not keys, in a deny-list. SPSDK's public
   example key sets (for example the P-384 and ML-DSA-65 SRK sets in its examples [S5], [S7]) are published
   with their private halves, so their hashes belong in the same deny-list.
3. **A check in the build.** After signing, the build recomputes the SRK hash of each table in the image (SPSDK
   computes it from the table [S7]) and compares it:
   - a test build fails unless the hash is on the test list;
   - a production build fails if the hash is on the deny-list, and unless it equals the production hash the owner
     has recorded.

   These rules apply to the containers this project signs (the OEM containers). The image also carries the
   NXP-signed EdgeLock enclave firmware container, whose SRK table is NXP's ([ele-firmware-survey.md](ele-firmware-survey.md)
   §7): it is checked against its own pinned vendor record, not against the production or test hash
   ([dev-boot-workflow-survey.md](dev-boot-workflow-survey.md), "Container roles"). Comparing every table in the
   image with the one production hash would reject every legitimate image.
   The check reads the image, not the signing configuration, so it also catches a container signed with the wrong
   set by hand.

No test private key is committed; how #9 generates or holds them
is #9's decision.

## 7. Unconfirmed

- The silicon revision on the FRDM-IMX95-PRO (A1 or B0), and so whether the PQC table applies (§3.2).
- Which PQC algorithms the B0 ROM and ELE firmware accept: Dilithium-3, ML-DSA-65, ML-DSA-87 or LMS (§3.2).
- The SRK hash width on B0: 256 bits [S1] against 512 bits [S4] (§3.2).
- The fuse words for SRKH, PQC SRKH, SRK revocation and the fuse version, and the life-cycle effects (§3.4); these
  are in IMX95RM and the i.MX 95 Security Reference Manual, both missing.
- Whether an SGK certificate is supported for the PQC table, and with which algorithms (§3.3).
- How CST 4.x or SPSDK reaches an HSM-held key in go-xkms (§5). CST 4.x itself was not surveyed: its PKI script's
  options are known here only through U-Boot's guide [S1]; NXP's CST download is behind NXP's licence page.
- Unreachable or not public from this lane: NXP's AN14471, the CST user and HSM guides, RM00284, UM12527 (all in
  the private context repository), IMX95RM and the i.MX 95 Security Reference Manual.

## 8. Questions for the owner

1. **Classic SRK key type.** Options: (a) ECC P-384 with SHA-384; (b) ECC P-521; (c) RSA-4096 (RSA-PSS).
   Recommendation: (a), the type used by both U-Boot's and SPSDK's i.MX 95 examples [S1], [S5], and a key type
   go-xkms's signers already cover [S9 image-signing].
2. **PQC SRK table.** Options: (a) build for B0 with a second, PQC table and double signing from the start; (b)
   classic only now, PQC when the board's revision and the accepted algorithm are confirmed; (c) classic only.
   Recommendation: (b), until §7's first two items are confirmed; if B0 is confirmed, ML-DSA-65 is the algorithm
   SPSDK's i.MX 95 example uses [S5] and go-xkms implements [S9].
3. **SGKs and where the SRKs live.** Options: (a) SRKs with the CA flag, kept offline, and four SGKs held online in
   go-xkms for routine signing; (b) all SRKs held in go-xkms and used directly, no SGKs; (c) SRKs in go-xkms and
   SGKs also in go-xkms. Recommendation: (a), which keeps the fused root out of daily use [S1 §2.1]; the
   test PKI then must also set the CA flag (§4).
4. **Signing tool.** Options: (a) SPSDK `nxpimage` with a signature provider into go-xkms; (b) NXP CST with its HSM
   back end over PKCS#11; (c) both. Recommendation: none from public sources; the SPEC row allows either, and the
   HSM path needs AN14471 and the CST HSM guide (§7).
5. **Who owns AHAB signing support in go-xkms.** Options: (a) a go-xkms issue for an AHAB signing profile (raw
   SRK public keys, PQC over its network API); (b) use go-xkms's PKCS#11 module unchanged. Recommendation: (b) for
   the classic table, (a) only if the PQC table is chosen, since ML-DSA is not on go-xkms's network API [S9].
6. **Test-PKI guard.** Options: (a) naming, a committed deny-list of test and SPSDK-example SRK hashes, and the
   build check of §6; (b) naming only. Recommendation: (a).
7. **Where the production SRK hash is recorded** for the build check. Options: (a) committed in this repository
   (it is public); (b) supplied by go-xkms at build time. Recommendation: (a), so a production build can be
   checked offline.
