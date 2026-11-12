# Per-device provisioning records: survey

Row: `oem-key-provisioning` ([SPEC](../SPEC.md)). Issue #119. Documentation only:
nothing here runs, scripts or describes a step that writes fuses, changes the
life cycle or provisions a key. No key material appears in this file.

## 1. Scope and method

When the OEM keys are provisioned into the EdgeLock secure enclave of an
FRDM-IMX95-PRO board, the provisioning station should leave behind one record
per device. This survey asks three questions of public sources:

1. What should the record hold?
2. What must it never hold, and how is it protected from tampering?
3. Where does it go, and who owns it?

Only public sources were used: NXP's public GitHub repositories and public
documentation pages, upstream project documentation (U-Boot, Linux), and open
standards (NIST, IETF, TCG). Each is cited by title, version or tag, and URL in
§2, and referred to below by its tag, e.g. **[S1]**. The vendor manuals that
[SPEC](../SPEC.md) cites for this row (AN14861, RM00284) are in the private
context repository, not public, and were not used here. Vendor text is
summarised, never copied. Where a source could not be read, or does not say
what this survey needs, §7 says so.

A source "supports" a claim below only where its text was read for this
survey. Where the claim is this survey's own inference from several sources,
it says so ("inference").

## 2. Sources surveyed

| Tag | Source | Version or tag surveyed | URL | Reached |
| --- | --- | --- | --- | --- |
| S1 | U-Boot documentation, *i.MX 93 AHAB secure boot guide* (`doc/imx/ahab/guides/mx93_secure_boot.rst`) | `master`, commit dated 2026-11-11 (latest tag `v2026.10-rc5`) | https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/guides/mx93_secure_boot.rst | yes |
| S2 | U-Boot documentation, *Introduction to AHAB* (`doc/imx/ahab/introduction_ahab.rst`) | as S1 | https://github.com/u-boot/u-boot/blob/master/doc/imx/ahab/introduction_ahab.rst | yes |
| S3 | NXP Secure Provisioning SDK (SPSDK): release notes, `nxpele` and `el2go-host` user guides | tag `v3.13.0` (2026-11-03) | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/docs | yes |
| S4 | NXP EdgeLock secure enclave library (`imx-secure-enclave`): source tree layout | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 | yes (file names only, see §7) |
| S5 | NXP AN14544, *EdgeLock 2GO provisioning methods* | page as linked from S3; version not shown | https://docs.nxp.com/bundle/AN14544/page/topics/edgelock_2go_provisioning_methods.html | no (page renders by script; content not read) |
| S6 | Linux kernel ABI documentation, `Documentation/ABI/testing/sysfs-devices-soc` | `master`, read 2026-11-12 | https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-devices-soc | yes |
| S7 | IETF RFC 9334, *Remote ATtestation procedureS (RATS) Architecture* | RFC, January 2023 | https://www.rfc-editor.org/rfc/rfc9334 | yes |
| S8 | IETF RFC 9162, *Certificate Transparency Version 2.0* | RFC, December 2021 | https://www.rfc-editor.org/rfc/rfc9162 | yes (reachable; used for the append-only log pattern only) |
| S9 | IETF RFC 3161, *Time-Stamp Protocol (TSP)* | RFC, August 2001 | https://www.rfc-editor.org/rfc/rfc3161 | yes |
| S10 | IETF RFC 9052, *CBOR Object Signing and Encryption (COSE): Structures and Process* | RFC, August 2022 | https://www.rfc-editor.org/rfc/rfc9052 | yes |
| S11 | NIST SP 800-57 Part 1 Rev. 5, *Recommendation for Key Management: Part 1 – General* | Rev. 5, May 2020 | https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final | landing page yes; PDF not re-read for this survey |
| S12 | TCG, *TPM 2.0 Keys for Device Identity and Attestation* | Version 1.00 Revision 12, 2021-10-08 (listed by TCG as a previous version; the current one not identified) | https://trustedcomputinggroup.org/resource/tpm-2-0-keys-for-device-identity-and-attestation/ | landing page yes; PDF not read |
| S13 | NIST SP 800-92, *Guide to Computer Security Log Management* | 2006 | https://csrc.nist.gov/pubs/sp/800/92/final | no (timed out) |
| S14 | NIST SP 800-193, *Platform Firmware Resiliency Guidelines* | May 2018 | https://csrc.nist.gov/pubs/sp/800/193/final | landing page yes; not used for a claim |

## 3. What the record should hold

No public NXP source surveyed defines a per-device provisioning record for the
i.MX 95. The fields below are therefore assembled from what the public sources
show the device can report and what the life-cycle and attestation standards
expect a manufacturer to retain. Each field gives its source.

| Field | Why it belongs | Source |
| --- | --- | --- |
| Device identifier: the SoC unique ID as reported by the enclave or the OS | Every record must name exactly one chip. Linux exposes a read-only SoC serial number attribute where the SoC driver supplies one; NXP's EdgeLock 2GO host tool harvests a device UUID before it provisions. Whether the i.MX 95 kernel driver fills the attribute from the enclave's UID is not confirmed (§7). | S6; S3 (`el2go-host` guide) |
| Board identifier: carrier serial or asset tag | The SoC ID alone does not name the board in the fleet. Inference; no source surveyed requires it. | inference |
| SRK hash written to the fuses | The SRK hash in fuses is the root of trust for signed boot; an error in it leaves a part that cannot boot signed images. Its width is **not** family-wide: on the i.MX 95, revisions A0 and A1 fuse a 256-bit SHA-256 hash in `OEM_SRKH0` to `OEM_SRKH7`, and revision B0 fuses a 512-bit SHA-512 hash across `OEM_SRKH0` to `OEM_SRKH15`, with a separate post-quantum SRK hash in `OEM_PQC_SRKH0` to `OEM_PQC_SRKH15` ([fuse-map-survey.md](fuse-map-survey.md) §3.1). The record should hold the silicon revision read from the device, the hash algorithm, the complete revision-specific fused hash (public), any PQC SRK hash written, and which SRK table each came from. Which revision the FRDM-IMX95-PRO carries is **unconfirmed** (§7). | S1 §5; S2 §2.2; S3 release notes; fuse-map survey §3.1 |
| SRK fuse lock state | SPSDK lists separate OEM SRK hash locks for the i.MX 95 (`ELE_OEM_SRKH0_LOCK`, `ELE_OEM_SRKH1_LOCK` and, on B0, `ELE_OEM_PQC_SRKH_LOCK`, fuse-map survey §3.1); a record that says the hash was written but not whether each lock that applies to the revision was set is incomplete. Inference from S3. | S3 release notes; fuse-map survey §3.1 |
| Life-cycle state before and after | U-Boot's `ahab_status` reports the life-cycle value (OEM Open, OEM Closed) and any AHAB events; NXP's guide requires no events, a fused SRK hash and a signed image that boots before the device is closed, and calls the close irreversible. The record should hold the state read back before and after, and the event list (expected empty). | S1 §6, §7 |
| AHAB event status at provisioning | As above: evidence that a signed image authenticated with the fused SRK before closing. | S1 §6 |
| Enclave firmware version | The enclave firmware is loaded from a signed container, and SPSDK's release notes track ELE firmware container versions per SoC. The record should hold the version the enclave reports. The exact get-info field set for the i.MX 95 could not be read from public sources (§7). | S3 release notes; S4 (`hsm_dev_getinfo` exists) |
| Enclave library and station software versions | Which `imx-secure-enclave` tag and which SPSDK release the station used, so a defect in either can be traced to the devices it touched. Inference. | S3; S4 |
| Public keys and their certificates | The device's attestation public key, and the public half of every OEM key imported or generated (or its key ID and a hash of the public key). RATS calls the manufacturer's statements about a device's signing capability *Endorsements*, consumed by a Verifier; the TCG device identity specification has the OEM create device identity keys and certificates at manufacture. | S7 §3, §8.2; S12 (title and scope only) |
| Key identifiers and policy | Key IDs, algorithms, usage and lifetime attributes as given to the enclave at import, without the key itself. Inference from S11's treatment of key metadata. | S11 (not re-read, §7) |
| Monotonic counter configuration | SPEC records that the monotonic counter fuses are configured once; the ELE library has a monotonic counter test. The record should hold the configured value. | [SPEC](../SPEC.md); S4 (file names) |
| Time | When each step happened, from a trusted time source (an RFC 3161 time-stamp over the record is one public option). | S9 |
| Station and operator | Which station and which operator role ran the provisioning, so a compromised station can be bounded. Inference. | inference |
| Outcome | Success, or the step that failed and the state left. Inference. | inference |

## 4. What the record must never hold

| Never in the record | Why | Source |
| --- | --- | --- |
| Private keys, symmetric keys, OEM master keys | The record is copied, archived and read by systems outside the station's custody; key-management guidance requires secret and private keys to have confidentiality protection that an ordinary record store does not give. | S11 (general; not re-read, §7) |
| Key-exchange secrets and session keys | The OEM key import starts with a key exchange (SPEC; the ELE library has key-exchange tests). The shared secret and derived keys protect the wrapped key in transit. They are not ephemeral: in the RT1180 walkthrough the derived import master key and its wrap and CMAC keys are shared by every device with the same SRK hash, so they are fleet secrets ([key-ceremony-survey.md](key-ceremony-survey.md) §3.1; the i.MX 95 behaviour is unconfirmed). They stay in HSM or go-xkms custody (key-ceremony survey §3.3) and never enter the record. | [SPEC](../SPEC.md); S4 (file names); key-ceremony survey |
| Wrapped key blobs, where custody would weaken | A wrapped blob is ciphertext, but anyone who later holds both the blob and the wrapping key, or can replay the blob into another device, gains the key. Keeping blobs out of the record keeps the record's custody independent of the key custody. If the owner wants blobs retained for recovery, they belong in the key custody system (go-xkms), not in the record, and the record holds only a hash of each blob. Inference. | inference |
| EdgeLock 2GO secure objects | `el2go-host` downloads secure objects to a local file before provisioning; those files carry device credentials. The record may hold their identifiers, never their contents. | S3 (`el2go-host` guide) |
| Credentials of the station itself | API keys, tokens, signing-service credentials. Inference. | inference |
| Unredacted personal data of operators | A role or pseudonymous station ID is enough to bound an incident. Inference. | inference |

## 5. Protecting the record from tampering

The record is evidence, so it needs integrity and ordering, not secrecy. The
public options:

1. **Signed record.** The station signs each record (a COSE_Sign1 structure is
   one standard envelope) with a station key held in an HSM. This proves which
   station wrote it but not that a record was not later withheld. S10.
2. **Device-signed evidence inside the record.** The enclave offers device
   attestation (SPEC, citing RM00284 §3.12; S4 has an attestation API and a
   public-key attestation test). A device-signed statement of its own life-cycle
   state, firmware version and key public halves, bound to a station nonce,
   lets a Verifier check the record against the device rather than trusting
   the station. This is the RATS Evidence/Endorsement split. S7; S4. It holds
   only if the Verifier checks the signature against an NXP root or
   attestation key it trusts independently of the station; an attestation
   public key that the station itself puts in the record proves nothing
   about the device. Which key signs i.MX 95 attestation, and the chain a
   Verifier would check, are **unconfirmed** (§7).
3. **Trusted time-stamp.** An RFC 3161 time-stamp over the signed record fixes
   when it existed. S9.
4. **Append-only log.** Records appended to a Merkle-tree log, as Certificate
   Transparency does for certificates, make deletion or rewriting detectable
   by anyone holding an earlier tree head. S8.

These compose: 1 is the minimum; 2 is what makes the record independent of
the station; 3 and 4 protect it after it leaves the station.

## 6. Where the record goes and who owns it

[SPEC](../SPEC.md) (Boundaries) says this repository never owns device
enrollment, the device registry, fleet policy or attestation verification:
go-trusted-platform and go-xkms own them, and go-trusted-platform provisions,
enrolls and attests the device and its image. In RATS terms (S7 §3), the
record is the manufacturer's Endorsement and Reference Value input to the
Verifier, and the Verifier's owner decides where it is kept.

What this survey can say, and what it leaves to the other repositories:

| Question | Decided by | Status |
| --- | --- | --- |
| Record schema and storage (the device registry) | go-trusted-platform (device registry, enrollment) | not decided here; go-trusted-platform's design not surveyed (not public) |
| Custody of wrapped keys and key-import material | go-xkms (key custody, wire protocol) | not decided here |
| Verification of device evidence against the record | go-trusted-platform and go-xkms (attestation verification) | not decided here |
| What the device can report to fill the record, and the station-side record of what was written to fuses | this repository's `oem-key-provisioning` and `device-lifecycle` rows | open: questions 1–6 below |
| Retention period and access to the record | owner | open: question 7 |

## 7. What could not be confirmed

- **The enclave's get-info and attestation field sets for the i.MX 95.** The
  ELE library (S4) has get-info, device attestation and public-key attestation
  interfaces, but the lane's tooling does not allow reading code outside this
  repository, so the fields (UID, life cycle, SRK hash readback, firmware
  version) were not read. The API reference (RM00284) is private. Nor was
  the key that signs the attestation, or a chain to an NXP root that a
  Verifier could check independently of the station, found in a public
  source; until it is, device-signed evidence in the record is only as
  trustworthy as the station that supplied it (§5).
- **Whether Linux on the i.MX 95 populates the SoC serial number from the
  enclave UID.** S6 documents the attribute only.
- **Which silicon revision the FRDM-IMX95-PRO carries, and so which SRK hash
  form applies.** The fuse-map survey (§3.1, question 1) gives the
  revision-specific widths from SPSDK: 256-bit SHA-256 on A0 and A1, 512-bit
  SHA-512 plus a separate PQC SRK hash on B0. The board's revision is not
  confirmed in public sources, and the U-Boot guide shows only the A0/A1 form.
- **The PQC SRK hash on B0.** SPSDK names its fuse group for the hash of a
  post-quantum SRK table; whether a device must have it written and locked
  before the close is not confirmed in public sources (fuse-map survey §3.1).
- **The i.MX 95 life-cycle values.** S1 shows the i.MX 93 values (OEM Open,
  OEM Closed); the i.MX 95 values are in IMX95RM and the i.MX 95 Security
  Reference Manual, which SPEC lists as missing.
- **EdgeLock 2GO for the i.MX 95.** S3's `el2go-host` guide describes
  per-product provisioning for MCX parts only; whether EdgeLock 2GO serves the
  i.MX 95 was not confirmed. S5 could not be read.
- **NIST SP 800-57 Part 1 and TCG device identity text.** Only the landing
  pages (S11, S12) were read in this survey; the claims citing them are
  general and should be checked against the documents.
- **NIST SP 800-92** (S13) could not be reached.
- **go-xkms and go-trusted-platform designs.** Not public; their decisions are
  marked as theirs in §6, not described.

## 8. Questions for the owner

1. **Which device identifier keys the record?**
   (a) the enclave-reported SoC UID; (b) the Linux SoC serial number;
   (c) a board serial with the SoC UID as a secondary field.
   Recommendation: (a), with the board serial alongside. It is read from the
   enclave itself, and S6 does not confirm (b) is populated on the i.MX 95.
2. **Does the record carry device-signed evidence?**
   (a) station-signed only; (b) station-signed plus an enclave attestation
   over the life-cycle state, firmware version and key public halves.
   Recommendation: (b). It makes the record checkable against the device and
   is the RATS Evidence/Endorsement split (S7); it depends on the i.MX 95
   attestation fields being confirmed (§7).
3. **Are wrapped key blobs retained anywhere?**
   (a) never, the record holds a hash of each blob; (b) retained in go-xkms's
   custody for recovery, the record holds the hash; (c) retained in the record.
   Recommendation: (a) or (b), never (c) (§4). The choice between (a) and (b)
   is go-xkms's.
4. **Is the SRK fuse lock state, and the before/after life cycle, mandatory?**
   (a) yes, a record without them is invalid; (b) optional.
   Recommendation: (a). S1 makes the close irreversible and conditional on
   the SRK hash and a clean `ahab_status`, so the record should prove both.
5. **How is the record protected after it leaves the station?**
   (a) station signature only; (b) signature plus RFC 3161 time-stamp;
   (c) signature plus time-stamp plus an append-only transparency log.
   Recommendation: (c) if go-trusted-platform already runs a log; otherwise
   (b). Sources: S8, S9, S10.
6. **Which envelope format?**
   (a) COSE_Sign1 over CBOR (S10); (b) JWS over JSON; (c) whatever
   go-trusted-platform's registry already uses.
   Recommendation: (c); no source here prefers one, and the registry is
   go-trusted-platform's.
7. **Who owns retention and access?**
   (a) go-trusted-platform's registry, with this repository writing only the
   station-side schema proposal; (b) a separate manufacturing archive.
   Recommendation: (a), matching SPEC's Boundaries; retention period is the
   owner's call, no source surveyed sets one.
8. **Is EdgeLock 2GO in scope for the i.MX 95?**
   (a) yes, investigate with NXP; (b) no, provisioning is the OEM's own
   station only. No recommendation: S3 shows it for MCX parts only and S5
   could not be read.
