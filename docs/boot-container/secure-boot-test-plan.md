# boot-container: secure boot negative test plan

Status: survey, draft for the owner (issue #118). Documentation only: nothing
here was run on a board, and no key, fuse, life-cycle or provisioning step is
run or scripted by this repository.

Row: `boot-container` in [docs/SPEC.md](../SPEC.md).

## 1. Scope and method

This survey lists the boot container tampering cases that AHAB (Advanced High
Assurance Boot, run by the EdgeLock secure enclave, ELE) must reject on the
i.MX 95, says which can be checked on a host by parsing the container and
which need a board, and proposes which belong in this repository's test suite
(input to #9).

Method: only public sources were read (NXP's public GitHub repositories,
SPSDK's public documentation, U-Boot's public documentation). Every statement
below gives its source by the tag in section 2. Vendor text is summarised,
never quoted. Where a public source does not settle a point, the point is
marked **not confirmed** and collected in section 8.

The vendor documents that would settle most points — the i.MX 95 Reference
Manual (IMX95RM) and the i.MX 95 Security Reference Manual — are not public and
are listed as missing in [docs/SPEC.md](../SPEC.md). They were not read.

## 2. Sources surveyed

| Tag | Source | Version | URL | Reached |
|---|---|---|---|---|
| S1 | SPSDK documentation, "AHAB" page (nxpimage AHAB, i.MX 95 container layout, `mimx9596` rev. b0 configuration template) | SPSDK v3.13.0 (release of 2026-11-03) | https://spsdk.readthedocs.io/en/v3.13.0/images/ahab.html | yes |
| S2 | U-Boot documentation, "imx95_evk" board page | U-Boot v2026.10 | https://docs.u-boot.org/en/v2026.10/board/nxp/imx95_evk.html | yes |
| S3 | U-Boot AHAB documentation (`doc/imx/ahab/`) | U-Boot v2026.10 | https://github.com/u-boot/u-boot/tree/v2026.10/doc/imx/ahab | yes (see note) |

Note on S3: at v2026.10 the directory holds only the encrypted boot guide and
its CSF example; the earlier i.MX 8 secure boot guide is no longer in it.

## 3. Background: what AHAB checks

What follows is the model the test cases rest on. Each point gives its source.

1. **Container chain.** On the i.MX 9x family the boot image is a sequence of
   AHAB containers that the boot ROM processes in order: container 0 is the ELE
   firmware, signed by NXP; container 1 (OEM-signed, loaded to on-chip RAM)
   carries, on the i.MX 95, the OEI DDR firmware, the System Manager for the
   Cortex-M33, an optional Cortex-M7 application and U-Boot SPL; container 2
   (OEM-signed, loaded to DDR) carries BL31, U-Boot and optionally OP-TEE (S1,
   "AHAB Container Structure for imx-boot (i.MX 9x)"). The Cortex-M7 image of
   trusted-firmware's `imx95` row therefore sits in an OEM container, container 1
   in the default layout (S1, `cortex_m7_app` image entry, core `cortex-m7-1`).
2. **Container formats.** The i.MX 95 accepts AHAB container format v1 on A0/A1
   silicon and v2 (with v1) on B0 and later (S1, "Key Differences"). The
   `mimx9596` rev. b0 template defaults to container version 2 (S1, template
   field `container_version`).
3. **Signature and key selection.** Each OEM container names an SRK (super root
   key) set (`none`, `nxp`, `oem`, `devhsm`) and which SRK of the set signed it
   (`used_srk_id`); the header is signed by that SRK, which must not have been
   revoked (S1, template fields `srk_set`, `used_srk_id`, `signer`). A container
   can carry a second signature for post-quantum keys (S1, `signer_#2`), and a
   flag can force verification of all present signatures instead of the fuse
   default (S1, `check_all_signatures`).
4. **Revocation.** A container carries an SRK revoke mask, one bit per SRK
   (S1, `srk_revoke_mask`). S1 does not say when the enclave acts on the mask
   (that it is applied to fuses only by an explicit enclave command in a closed
   life cycle is the usual AHAB model, but it is **not confirmed** for the
   i.MX 95 from a public source).
5. **Anti-rollback.** A container carries a fuse version; the container loads
   only if its fuse version is equal to or greater than the version held in
   fuses (S1, `fuse_version`). A separate software version field is used by the
   boot companion to choose between images of the same fuse version, and is not
   an anti-rollback floor (S1, `sw_version`).
6. **Image hashes.** Each image entry in a container carries a hash of the
   image, SHA-384 by default on the i.MX 95 (S1, `hash_type` defaults in the
   `mimx9596` template). The signed container header covers the image array,
   so an image whose bytes no longer match its entry fails authentication
   (S1 describes signing the header; that the image array is inside the
   signed region is the AHAB container model, **not confirmed** byte-for-byte
   for format v2 from a public source).
7. **Tooling.** SPSDK's `nxpimage ahab parse` parses a binary AHAB image on the
   host; `nxpimage ahab re-sign` re-signs one container in an existing image
   (S1, "AHAB", "AHAB Re-sign"). U-Boot builds the i.MX 95 boot image from the
   ELE container, OEI, System Manager and BL31 (S2).

## 4. Tampering cases

TODO

## 5. Host-side versus on-board checks

TODO

## 6. Enclave event log entries

TODO

## 7. What belongs in this repository's test suite (input to #9)

TODO

## 8. Not confirmed

TODO

## 9. Questions for the owner

TODO
