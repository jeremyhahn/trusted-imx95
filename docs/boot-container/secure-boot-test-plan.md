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
| S4 | NXP U-Boot fork, "i.MX 8ULP/9x Secure boot guide using AHAB" (`doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt`) | nxp-imx/uboot-imx branch `lf_v2025.04` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt | yes |
| S5 | NXP U-Boot fork, AHAB introduction (`doc/imx/ahab/introduction_ahab.txt`), section 1.4 on the i.MX 8ULP/9x boot flow | nxp-imx/uboot-imx branch `lf_v2025.04` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/introduction_ahab.txt | yes |
| S6 | SPSDK documentation, `nxpimage` command reference (`ahab parse`, `ahab verify`, `ahab info`) | SPSDK v3.13.0 | https://spsdk.readthedocs.io/en/v3.13.0/apps/nxpimage.html | yes |
| S7 | SPSDK documentation, `nxpele` command reference (`get-events`, `get-info`) | SPSDK v3.13.0 | https://spsdk.readthedocs.io/en/v3.13.0/apps/nxpele.html | yes |
| S8 | U-Boot source, `arch/arm/mach-imx/ele_ahab.c` (the `ahab_status` command and its event decoding) | U-Boot v2026.10 | https://github.com/u-boot/u-boot/blob/v2026.10/arch/arm/mach-imx/ele_ahab.c | file reached, **content not read** (see section 8) |
| S9 | i.MX 95 Reference Manual (IMX95RM), i.MX 95 Security Reference Manual | — | not public | **no** |

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

Each case starts from a good, signed boot image and changes one thing. "Expected"
is what the enclave must do with the tampered container; "Source" gives the
public basis for that expectation. All test images would be signed with
throw-away test keys generated when the test runs and never stored in this
repository (see question 2).

| ID | Case | How the tampered image is made | Expected | Source |
|---|---|---|---|---|
| C1 | Bad signature | Flip one bit in the signature of an OEM container's signature block | The container fails authentication | S1 (`signer`: the header is signed by the selected SRK); S4 §1.7 (a good image boots with no AHAB events, so a failure is recorded as an event) |
| C2 | Wrong SRK | Sign the container with a complete, valid SRK table whose hash is not the one fused in the device (a second test PKI) | The container fails authentication, because the SRK table does not match the fused SRK hash | S4 §1.6 (the fused SRK hash is the root of trust; an error in it leaves a part that does not boot) |
| C2b | SRK index mismatch | Sign with SRK *n* but set `used_srk_id` to another index | The signature does not verify against the named key | S1 (`used_srk_id`, `signer`) |
| C3 | Revoked key | Sign with an SRK whose revocation bit is set in the device | The container is rejected | S1 (`signer`: the SRK must not have been revoked; `srk_revoke_mask`) |
| C4 | Lower anti-rollback version | Build a container whose `fuse_version` is below the version held in the device fuses | The container is not loaded | S1 (`fuse_version`: must be equal to or greater than the fused version) |
| C5a | Modified image | Change bytes of an image (for example the Cortex-M7 application) after signing, leaving the container untouched | The image hash does not match its entry; authentication fails | S1 (`hash_type`, SHA-384 by default for i.MX 95 entries); the "hash covered by signature" part is **not confirmed** for format v2 (section 3, point 6) |
| C5b | Modified image hash | Change the hash in an image entry to match the changed image, without re-signing | The header signature no longer verifies | as C1 and C5a |
| C6 | Truncated container | Cut the image short so that a declared image or signature block lies past its end | The container cannot be loaded or authenticated | S1 (`nxpimage ahab parse` parses the offsets and sizes); boot ROM behaviour on a short read is **not confirmed** |

## 5. Host-side versus on-board checks

**On the host, now.** A host has the container but not the device's fuses. It
can check everything that is a property of the container alone, and can check
the fuse-dependent cases only as policy: by comparing the container against
values this repository records as expected (the SRK table hash, the revocation
policy, the anti-rollback floor). Those values are per signer: the OEM
containers are compared with the OEM records, and the NXP-signed enclave
firmware container with its own pinned vendor record (its digest and version
fields from the pinned firmware package), never with the OEM hash or floor
([dev-boot-workflow-survey.md](dev-boot-workflow-survey.md), "Container
roles"; [ele-firmware-survey.md](ele-firmware-survey.md) §7).

| ID | Host check | Board needed for the real behaviour | Life cycle |
|---|---|---|---|
| C1 | Yes: parse, then verify the header signature with the public key from the container's own SRK table | To see the enclave reject it | OEM open (event only) or OEM closed (boot stops) |
| C2 | Policy only: compare the hash of the container's SRK table with the expected hash recorded in the repository | The device must have an SRK hash fused | Needs fuses; **not run** |
| C2b | Yes: verify with the key at `used_srk_id` | As C1 | As C1 |
| C3 | Policy only: refuse an image whose `used_srk_id` is on the repository's revoked list, and check `srk_revoke_mask` is the intended value | The device must have a revocation fused | Needs fuses; **not run** |
| C4 | Policy only: refuse an image whose `fuse_version` is below the repository's floor | The device must have a version fused | Needs fuses; **not run** |
| C5a | Yes: recompute the SHA-384 of each image and compare with its entry | As C1 | As C1 |
| C5b | Yes: as C1 | As C1 | As C1 |
| C6 | Yes: every offset plus size lies inside the file; the parser must fail cleanly | To see what the boot ROM does | OEM open |

SPSDK offers the host side ready-made: `nxpimage ahab parse` and
`nxpimage ahab verify` (with `-p` to list only problems) accept the i.MX 95
families, including `mimx9596` (S6). The command reference does not say which
checks `verify` performs (signature, hashes, SRK hash, version), so its
coverage of C1–C6 is **not confirmed**; a test would have to establish it.

**On a board.** In the OEM open life cycle the enclave authenticates and records
failures as events, which `ahab_status` in U-Boot (S4 §1.7) or `nxpele
get-events` from a host (S7) reads back; a good image shows the life cycle and
no events (S4 §1.7). The guide only advises closing a device once a signed image
boots without events (S4 §1.8), which implies that in OEM open a failed
authentication is reported rather than fatal. That reading is **not confirmed**
for the i.MX 95 from a public source, and nor is it confirmed whether the
enclave checks anything against the SRK table when no SRK hash has been fused.
In OEM closed a failure must stop the boot; testing that needs a closed
device, which this repository does not do.

## 6. Enclave event log entries

| ID | Expected entry in OEM open |
|---|---|
| C1, C2b, C5b | One authentication failure event for the tampered container (signature check) |
| C2 | One authentication failure event (SRK hash mismatch); needs a fused SRK hash |
| C3 | One authentication failure event (revoked key); needs a fused revocation |
| C4 | One failure event (version below the fuse floor); needs a fused version |
| C5a | One authentication failure event (image hash mismatch) |
| C6 | Not confirmed: a load failure may leave no enclave event at all |
| good image | No events (S4 §1.7) |

Sources and limits: the way to read the log is public (S4 §1.7, S7). The
encoding of an event word (which field gives the command, the status and the
failure indicator) and the indicator names for each case are **not
confirmed**: no public prose document reached by the lane gives them for the
i.MX 95. U-Boot's `ahab_status` decodes them in S8, and the i.MX 95 Security
Reference Manual (S9) would define them; neither was read. The rows above
therefore give the kind of entry, not its code.

## 7. What belongs in this repository's test suite (input to #9)

Proposed, in order:

1. **Host tests, in CI (C1, C2b, C5a, C5b, C6).** Build a good image from
   throw-away keys made at test time, tamper it as in section 4, and assert that
   the host verifier rejects each tampered image and accepts the good one. These
   need no board, fuse or key in the repository.
2. **Host policy checks, in CI and at release (C2, C3, C4).** Before an image is
   released, check each container's SRK table hash, `used_srk_id`,
   `srk_revoke_mask` and `fuse_version` against the recorded values of its
   signer's role (OEM records for OEM containers, the pinned vendor record for
   the NXP enclave firmware container), check that each OEM container carries
   exactly the required image entries of its role (the OEM boot container must
   carry the Cortex-M7 image), and include a complete mixed-signer image that
   must be accepted, an image without the M7 and one with the OEM containers
   swapped that must both be rejected
   ([dev-boot-workflow-survey.md](dev-boot-workflow-survey.md), N12, N13). These catch the
   mistake on the host; they cannot show that the enclave rejects the image.
3. **On-board tests in OEM open, manual, outside CI (C1, C2b, C5a, C5b, C6).**
   Boot each tampered image on an OEM open board and record the event log. Only
   after the event codes are confirmed (section 8) can the expected entries be
   asserted.
4. **Not in this repository: C2, C3, C4 on a board, and anything in OEM closed.**
   They need fused SRK hash, revocation or version, or a closed life cycle. The
   brief rules out running or scripting those.

## 8. Not confirmed

1. Event word encoding and the failure indicator for each case (section 6).
   Public basis would be S8 (code, not read by the lane) or S9 (not public).
2. Whether in OEM open a failed authentication is only reported, and boot
   continues, on the i.MX 95 (section 5); inferred from S4 §1.7–1.8, not stated.
3. Whether the enclave checks anything against the SRK table when no SRK hash
   is fused (section 5).
4. That the signed region of a format v2 container covers the image array, so
   that C5b fails on the signature (section 3, point 6).
5. When the `srk_revoke_mask` takes effect on the i.MX 95 (section 3, point 4).
6. Which checks `nxpimage ahab verify` performs (section 5).
7. What the boot ROM does with a truncated container (C6): fall back to another
   boot source, the serial downloader, or stop.
8. The i.MX 95 fuse words for the SRK hash: S4 §1.6 gives fuse bank 16 for the
   i.MX 93 and i.MX 95, but for a different SoC revision and BSP; IMX95RM (S9)
   would confirm it. This plan programs no fuse.
9. The U-Boot secure boot guides of S4 and S5 are in NXP's fork, not upstream
   U-Boot v2026.10 (S3); whether upstream carries equivalents elsewhere was not
   established.

## 9. Questions for the owner

1. **Host verifier.** Which tool do the host tests (section 7, items 1–2) run?
   Options: (a) SPSDK `nxpimage ahab verify`/`parse` (S6), pinned to a version,
   as a test dependency; (b) a container parser written in this repository;
   (c) both, with the own parser checked against SPSDK. Recommendation: (a) to
   start, since SPSDK supports `mimx9596` today (S6); revisit (b) if the
   coverage of `verify` (section 8, item 6) proves too thin.
2. **Test keys.** How are the keys for the tampered images made? Options:
   (a) generated fresh in each test run and discarded; (b) a fixed test PKI
   kept outside the repository; (c) the HSM's test partition. Recommendation:
   (a): it keeps keys out of the repository, as the rules require, and needs
   no HSM in CI.
3. **Policy values.** Where does the repository record the expected SRK table
   hash, the revoked SRK list and the anti-rollback floor for C2–C4?
   Options: (a) a versioned, reviewed file under `docs/boot-container/`,
   kept apart from the build that produces the image; (b) in the build
   configuration of the image; (c) not recorded until
   `oem-key-provisioning` decides them. No source picks one, but (b) and
   (c) both fail the host checks' purpose: under (b) the image's own build
   supplies the reference it is checked against, and under (c) C2–C4 do not
   run, so a correctly signed image with a revoked `used_srk_id`, an
   unintended `srk_revoke_mask` or a `fuse_version` below the floor passes
   on the host, and an OEM-open board does not stop it either.
   Recommendation: (a). Until `oem-key-provisioning` decides the values,
   the file states them explicitly ("no SRK revoked", the current floor),
   and a missing or unreadable file fails the release check rather than
   skipping it (see `dev-boot-workflow-survey.md` §8, stage 2.3).
4. **On-board OEM open runs.** Should the manual OEM open tests (section 7,
   item 3) be run at all before the event codes are confirmed? Options:
   (a) yes, record the raw event words as the reference; (b) wait for the
   i.MX 95 Security Reference Manual (S9). Recommendation: (b) for asserting
   results; (a) is acceptable only as observation. Running an OEM open board
   with no fuse change is within the brief, but any board run is the owner's
   call.
5. **Obtaining S9.** Should the i.MX 95 Security Reference Manual and IMX95RM
   be requested from NXP under NDA and added to the private context? Options:
   (a) yes; (b) no, rely on public sources and observation. Recommendation:
   (a): items 1, 2, 3, 5 and 8 of section 8 depend on it.
6. **Container format.** Do the tests target AHAB container v2 only (B0 and
   later silicon, the template default) or v1 too? Options: (a) v2 only;
   (b) both. Recommendation: (a) if the FRDM-IMX95-PRO carries B0 or later
   silicon, which this survey did not confirm (S1 gives v2 for b0+).
