# Boot-container SRK revocation and signing-key rotation: survey

Row: `boot-container` (docs/SPEC.md). Issue #58. Documentation only: nothing here is a fuse, life-cycle or
provisioning step to run, and nothing here should be read as one. Every fuse-touching operation named below is
named so the owner can decide on it; none is scripted by this repository.

Status: draft, written from public sources only, surveyed on 2026-11-12. Vendor text is summarised, not quoted.

## 1. Scope

The `boot-container` row signs the platform image's AHAB containers with keys held in an HSM (docs/SPEC.md). This
survey answers three questions for that row:

1. How a Super Root Key (SRK) is revoked on an AHAB part such as the i.MX 95, and what is irreversible.
2. How the signing keys below the SRKs are rotated without touching fuses.
3. What each signing tool (CST, SPSDK, imx-mkimage, U-Boot's binman) lets us express, so the row can choose.

It does not cover the EdgeLock enclave's key store (row `secure-key-handling`) or the anti-rollback design
beyond where it shares the commit mechanism with revocation (section 7).

## 2. Sources surveyed

| Id | Source | Version surveyed | URL | Reached |
|----|--------|------------------|-----|---------|
| S1 | U-Boot, *i.MX Secure and Encrypted Boot using AHAB* (`doc/imx/ahab/introduction_ahab.rst`) | master at 3cb2cbbc (2026-11-11); nearest tag v2026.10-rc5 | https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/introduction_ahab.rst | yes |
| S2 | U-Boot, *i.MX93 Secure boot guide using AHAB* (`doc/imx/ahab/guides/mx93_secure_boot.rst`) | as S1 | https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/guides/mx93_secure_boot.rst | yes |
| S3 | U-Boot, `arch/arm/mach-imx/ele_ahab.c` (the `ahab_commit` command) | as S1 | https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-imx/ele_ahab.c | yes |
| S4 | NXP uboot-imx, `doc/imx/ahab/csf_examples/*.txt` and `arch/arm/mach-imx/ele_ahab.c` | branch lf_v2025.04 at 99518e6b, tag lf-6.18.2-1.0.0 | https://github.com/nxp-imx/uboot-imx/tree/lf_v2025.04/doc/imx/ahab | yes |
| S5 | NXP SPSDK, `spsdk/image/ahab/ahab_container.py` (AHAB container header) | master at e104adf5 (2026-11-03); latest tag v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/master/spsdk/image/ahab/ahab_container.py | yes |
| S6 | NXP SPSDK, `spsdk/ele/ele_constants.py` (`EleInfo2Commit`) and `spsdk/apps/nxpele.py` (`commit` command) | as S5 | https://github.com/nxp-mcuxpresso/spsdk/tree/master/spsdk/ele | yes |
| S7 | NXP imx-mkimage, `src/mkimage_imx8.c` and `Readme.imx95` | tag lf-6.18.20-2.0.0 at 1b577853 | https://github.com/nxp-imx/imx-mkimage/tree/lf-6.18.20-2.0.0 | yes |
| S8 | NXP SPSDK, `docs/release_notes.rst` | as S5 | https://github.com/nxp-mcuxpresso/spsdk/blob/master/docs/release_notes.rst | yes |
| U1 | NXP AN12312 and AN14471 (application notes) | not determined | https://www.nxp.com/docs/en/application-note/AN12312.pdf, https://www.nxp.com/docs/en/application-note/AN14471.pdf | no (HTTP 404 from the lane) |
| U2 | NXP CST 3.1.0 user guide (`CST_UG.pdf`) | 3.1.0 | NXP download, login required | no |
| U3 | i.MX 95 Security Reference Manual and IMX95RM | not determined | NDA | no |

## 3. The AHAB key model on the i.MX 95

- **Four SRKs, one fused hash.** CST's `ahab_pki_tree` builds a CA with four SRKs under it. The four SRK public keys
  form an SRK table that travels inside every signed container; only a hash of that table is fused. On the i.MX 8ULP
  and i.MX 9x parts the fused hash is 256 bits; on i.MX 8/8x it is 512 bits. At boot the enclave checks the table in
  the container against the fused hash, then checks the container signature with the SRK the container selects. (S1 §2,
  §2.2.)
- **Optional subordinate signing keys (SGK).** If the SRK certificates are issued with the CA flag, each SRK can
  certify one subordinate key, and the container is signed with that subordinate key; the SRK then signs only the
  subordinate key's certificate, which travels in the container. (S1 §2.1.)
- **Algorithms.** The CST version that U-Boot's guide documents (CST 4.0.0 or later) offers RSA, RSA-PSS, ECC
  (P-256/P-384/P-521) and post-quantum choices (Dilithium, ML-DSA, and a hybrid). (S1 §2.) The repository's
  reference copy is CST 3.1.0 (docs/references/README.md); whether 3.1.0 offers the same key types is unconfirmed
  (section 8).
- **Selecting and revoking in the container header.** The AHAB container header carries a flags word. SPSDK decodes
  it as: bits 0-1 the SRK set (none, NXP, OEM, and further sets on some parts), bits 4-5 the index of the SRK used to
  sign (0-3), and bits 8-11 an SRK revoke mask, one bit per SRK. The same header carries a *fuse version*, which SPSDK
  describes as the minimum fuse version the container needs. (S5, the `AHABContainerBase` flag constants and
  `set_flags`.)
- **SRK sets.** An OEM container is signed under the OEM SRK set; NXP's enclave firmware container is signed under
  NXP's set. SPSDK also knows a `devhsm` set and an `iccs` set on some parts. (S5.) Which sets the i.MX 95 offers, and
  whether it holds a second, post-quantum SRK hash beside the classical one, is unconfirmed (section 8).

## 4. SRK revocation

Revocation is a two-step mechanism in every public source we reached:

1. **Declare.** A container signed with a still-valid SRK carries a non-zero revoke mask in its header (S5). CST's
   AHAB CSF expresses the same thing as a `Revocations` bitmask in the `[Install SRK]` section; every public CSF
   example ships it as zero (S4, `csf_examples/csf_boot_image.txt` and siblings). Booting such a container does not by
   itself change any fuse.
2. **Commit.** Software that runs after that container has been authenticated asks the enclave to *commit* the
   information it found. The commit request is a bitmask of information types. SPSDK names four: NXP-container SRK
   revocation (bit 0), NXP-container firmware fuse version (bit 1), OEM-container SRK revocation (bit 4) and
   OEM-container firmware fuse version (bit 5) (S6, `EleInfo2Commit`). U-Boot exposes the same request as
   `ahab_commit <hex mask>`, whose help text says it commits into the fuses any new SRK revocation and firmware
   version found in the NXP and OEM containers (S3; identical in NXP's fork, S4). SPSDK exposes it on the host side
   as `nxpele commit` (S6).

Consequences for this row, read from the sources above:

- **Revocation is a fuse write and cannot be undone.** The commit is described as writing to fuses (S3). We found no
  public statement of an un-revoke, and fuses are one-time programmable by nature; treat it as irreversible.
- **Revocation and anti-rollback share one commit.** The same request, with different bits, also commits the firmware
  fuse version (S3, S6). A boot flow that commits one must choose the mask with care so it does not commit the other
  by accident (section 7).
- **Revocation needs a container that is still trusted.** Since the mask is read from an authenticated container, the
  revoking image must be signed with an SRK that is not being revoked. With four SRKs, the row can revoke at most three
  of them over the board's life before it would need a new SRK hash; and a new SRK hash cannot be fused once the
  hash fuses are written and locked (S1 §2.2 describes the hash as fused; the lock behaviour on the i.MX 95 is
  unconfirmed, section 8).
- **Ordering.** The safe order the mechanism implies is: ship images signed with the replacement SRK first; confirm
  every board boots them; only then ship an image whose header carries the revoke bit, and commit. Committing before
  the fleet has the new images bricks any board that later falls back to an old image. The sources describe the
  mechanism, not this procedure; it is our reading (section 8).

## 5. Rotating the signing keys

The key model gives the row three levels of rotation, from cheapest to irreversible. The levels are our reading of
the mechanism in S1 and S5; no public source we reached lays them out as a procedure.

| Level | What changes | Fuses touched | What it protects against |
|-------|--------------|---------------|--------------------------|
| L1: new subordinate key (SGK) | A new SGK certificate under the same SRK; images are re-signed with it | none | Wear on the day-to-day key; limits how much is signed with one key. It does **not** stop a leaked SGK: we found no public SGK-level revocation, so a leaked SGK stays valid until its parent SRK is revoked (section 8). |
| L2: switch to another SRK | Containers select a different SRK index (header bits 4-5, S5); the SRK table, and so the fused hash, stay the same | none | Planned retirement of an SRK, or the first step before revoking a compromised one |
| L3: revoke an SRK | A container signed by a surviving SRK sets the revoke bit, then a commit writes it to fuses (section 4) | yes, irreversible | A compromised SRK (or a compromised SGK under it) |

Points that follow from the sources:

- **All four SRKs are trusted from the first boot.** The fused hash covers the whole table (S1 §2.2), so the spare
  SRKs must be generated, and their private keys put into custody, before the hash is fused. A spare SRK whose private
  key was never kept cannot be used for L2 later.
- **The spares should not share custody with the active SRK.** If all four private keys sit in the same HSM partition
  under the same credentials, one compromise takes all four and L3 has nothing left to sign the revoking image with.
  This is our recommendation, not a vendor statement. The SPEC's HSM custody model follows AN14471, which we could not
  reach publicly (section 8).
- **SGKs fit the HSM model.** With SGKs the SRK private keys are needed only to issue an SGK certificate, so they can
  stay offline (or in a separate HSM partition with quorum), while the signing service holds only the SGK (S1 §2.1).

## 6. Tooling: CST, SPSDK, imx-mkimage and U-Boot

| Tool | Revoke mask | SRK selection | Fuse version / SW version | Commit to fuses | Source |
|------|-------------|---------------|---------------------------|-----------------|--------|
| CST (AHAB CSF) | `Revocations` bitmask in `[Install SRK]` | `Source index` in `[Install SRK]` | not set by the CSF in the examples; taken from the container | no (host tool) | S4 |
| SPSDK `nxpimage` AHAB config | `srk_revoke_mask` | `used_srk_id`, `srk_set` | `fuse_version`, `sw_version` | no | S5 |
| SPSDK `nxpele` | n/a | n/a | n/a | `commit` with the information types of section 4, sent to the enclave over a host link | S6 |
| imx-mkimage | only as raw header flags (`--cntr_flags`) | as raw flags | `--fuse_version` (8 bits), `--sw_version` (16 bits) | no; mkimage builds the unsigned container, CST signs it | S7 |
| U-Boot | n/a (binman's `nxp-imx93cst` etype drives CST; whether it exposes the revoke mask is unconfirmed) | as binman | as binman | `ahab_commit <mask>` on the target | S2, S3 |

Notes:

- SPSDK models the revoke mask in other places as well: its release notes for the current master record that the
  EdgeLock Enclave V2 debug-authentication (DAT) configuration carries an `srk_revoke_mask` that is checked against
  the fuses (S8). So a revocation also affects debug authentication, not only boot.
- The repository's reference CST is 3.1.0 (docs/references/README.md), while U-Boot master documents CST 4.0.0 or
  later (S1 §2). The row's choice between CST and SPSDK is open as #9; this survey does not settle it but shows that
  both can express the revoke mask and SRK index, and that only SPSDK and U-Boot can send the commit.

## 7. Interaction with the anti-rollback floor

- Each container carries an 8-bit *fuse version* and a 16-bit *software version* (S7, `mkimage_imx8.c` options;
  S5, which describes the fuse version as the minimum fuse version a container needs).
- Advancing the fused firmware version uses the same enclave commit as SRK revocation, with a different bit (OEM
  firmware fuse version, bit 5, against OEM SRK revocation, bit 4; S6). U-Boot's `ahab_commit` takes the whole mask as
  one hex argument (S3).
- So the row's boot flow must not issue a broad commit mask. A flow that commits `0x30` to raise the floor would also
  commit any revoke bit an image happens to carry. The row should commit only the bits it means, and only from a
  release step that the owner has approved (question 4).
- The SPEC ties the anti-rollback floor to RM00284 §3.24 (the monotonic counter) and to the AHAB version field. How
  the 8-bit fuse version maps to fuse words on the i.MX 95, and how many increments it allows, is in the i.MX 95
  reference manuals, which are not public (section 8).

## 8. What could not be confirmed

| Item | Why | Where it would be confirmed |
|------|-----|-----------------------------|
| i.MX 95 SRK hash fuse words, their lock, and the revoke fuse bits | Not in any public source we reached | i.MX 95 Security Reference Manual and IMX95RM (NDA; listed as missing in docs/references/README.md) |
| Whether the enclave refuses a revoke mask that includes the SRK signing the same container, and whether all four SRKs can be revoked | Not stated in the sources reached; our section 4 reasoning assumes the revoking container must use a surviving SRK | as above |
| Whether the i.MX 95 has more than one OEM SRK set (for example a post-quantum set beside the classical one), and which sets it accepts | SPSDK models several sets per family (S5), but we did not trace the i.MX 95 family data | SPSDK family database for `mx95`; the SRM |
| Whether there is any SGK-level revocation | No public source we reached mentions one | the SRM; CST user guide |
| CST 3.1.0 key types and CSF keywords | The tarball and its CST_UG are in the private vendor repository, not reachable from this lane | `release/docs/CST_UG.pdf` in CST 3.1.0 |
| Whether U-Boot's binman `nxp-imx93cst` etype exposes `Revocations` and works for the i.MX 95 | Not read in this survey | U-Boot `tools/binman/etype/nxp_imx8mcst.py` and siblings |
| NXP application notes on AHAB secure boot, among them AN12312 and AN14471 | `www.nxp.com/docs/en/application-note/AN12312.pdf` and `AN14471.pdf` returned HTTP 404 from the lane | nxp.com with a browser session, or the private vendor repository |
| The rotation levels and ordering in sections 4 and 5 | Our reading of the mechanism; no public source gives it as a procedure | the SRM; NXP support |

## 9. Questions for the owner

1. **How many of the four SRKs are generated and held before the SRK hash is fused?**
   - (a) All four, each with its own custody (separate HSM partition or credentials, at least one kept offline).
   - (b) All four in the same HSM partition.
   - (c) Fewer than four, with placeholders.
   - Recommendation: (a). All four are trusted from the first boot (S1 §2.2), and revocation needs a surviving,
     uncompromised SRK to sign the revoking image (section 4). (c) wastes slots that cannot be added later.

2. **Do containers carry subordinate signing keys (SGK), or are they signed by the SRK directly?**
   - (a) SGK under each SRK; SRK private keys used only to certify an SGK.
   - (b) SRK signs directly.
   - Recommendation: (a), so the SRKs can stay offline and the HSM signing service holds only the SGK (S1 §2.1).
     Note that a leaked SGK still needs its SRK revoked (section 5), so (a) reduces exposure but not the cost of a
     leak.

3. **What triggers an SRK revocation (L3)?**
   - (a) Only a confirmed or suspected compromise of the SRK or of an SGK under it.
   - (b) Also scheduled retirement on a fixed period.
   - Recommendation: (a). Revocation is irreversible and the board has at most three to spend (section 4);
     scheduled retirement is served by L2 (switching SRK index) without touching fuses.

4. **Which software is allowed to send the enclave commit, and with which bits?**
   - (a) A dedicated, owner-approved release step that commits only the bits it names (OEM SRK revocation, or OEM
     firmware fuse version, never both by default).
   - (b) The normal boot path (U-Boot `ahab_commit` in the boot script) on every boot.
   - (c) Never in the field; boards are only updated in a service setting with SPSDK `nxpele commit`.
   - Recommendation: (a). The same commit serves revocation and the anti-rollback floor (S3, S6), so a broad or
     automatic commit can burn a revocation by accident. (c) is safer still but may not suit fielded boards.

5. **Which tool carries the revoke mask and SRK index?** (This joins the open CST-versus-SPSDK question, #9.)
   - (a) CST CSF (`Revocations`, `Source index`), with mkimage building the container.
   - (b) SPSDK `nxpimage` AHAB configuration (`srk_revoke_mask`, `used_srk_id`).
   - Recommendation: none from this survey alone. Both express the fields (S4, S5); SPSDK also has the commit and
     models the i.MX 95 family, while CST is what the SPEC names today. Decide with #9.

6. **Do we obtain the i.MX 95 Security Reference Manual before any SRK hash is fused?**
   - (a) Yes; fusing waits for it.
   - (b) No; proceed from public sources and the EVK defaults.
   - Recommendation: (a). The fuse words, their lock and the revocation limits on the i.MX 95 are unconfirmed from
     public sources (section 8), and every step in sections 4 and 7 is irreversible.
