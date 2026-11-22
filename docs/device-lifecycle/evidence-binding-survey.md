# device-lifecycle: binding the firmware TPM's identity to the chip's own attestation, public survey

> **Status: SURVEY, PROVISIONAL, pending go-trusted-platform's hsm-device-lifecycle row and the owner (#25)** · Row: device-lifecycle · Issue: #25 · Surveyed: 2026-11-22
>
> Public sources only; each claim cites a source from the [Sources](#sources) table as **[Sn]**. Vendor text is summarised, never copied. What the sources did not show is marked **unconfirmed**. Nothing here is built, run or provisioned; no fuse, life-cycle or RPMB step. Every recommendation is a **provisional default**.

## Question

Owner ruling 927 has the device attest through its firmware TPM with go-xkms's `device-attest-01` in the `tpm` format ([ftpm](../ftpm/README.md)). The enclave's own attestation is a second, independent evidence source ([attestation-survey.md](attestation-survey.md)). The firmware TPM's EK is created in OP-TEE storage and has no maker certificate; nothing on the board vouches for it ([EK lifecycle](../ftpm/README.md#ek-lifecycle)). No document says how a verifier could tie the TPM's EK or attestation key (AK) to the chip, or what each binding still leaves open. This survey sets that out. It does not repeat the enclave evidence ([attestation-survey.md](attestation-survey.md)), enrollment fit ([enrollment-survey.md](enrollment-survey.md)) or decommissioning ([decommission-survey.md](decommission-survey.md)).

## 1. What the `tpm` attestation format carries and what a verifier checks

The WebAuthn `tpm` statement format [S1] carries: a version (`"2.0"`), a signature algorithm, an `x5c` chain (the AIK certificate first), `sig` (a TPMT_SIGNATURE), `certInfo` (a TPMS_ATTEST) and `pubArea` (the TPMT_PUBLIC of the attested key). The attestation type is AttCA [S1].

A verifier checks [S1]:

1. `pubArea` matches the credential public key being attested.
2. `certInfo` has the TPM-generated magic and type certify.
3. `certInfo.extraData` equals the hash of the signed input (in WebAuthn, authenticator data plus client-data hash).
4. The certified name in `certInfo` is the valid Name of `pubArea`, computed with `pubArea`'s name algorithm.
5. `x5c` is present, and `sig` verifies over `certInfo` with the key in the AIK certificate.
6. The AIK certificate meets the profile: version 3, empty subject, a SAN as in the TCG EK profile, the AIK-certificate extended key usage, not a CA.

`qualifiedSigner`, `clockInfo` and `firmwareVersion` are ignored by the format and may only feed a risk engine [S1].

**Freshness and device-attest-01.** `device-attest-01` borrows the WebAuthn attestation object but replaces authenticator data plus client-data hash with the ACME key authorization (built from the challenge token and the account key) as the signed input; the token gives freshness and the account key is bound by the key authorization [S2]. The draft says formats are the format's business and supports vendor formats [S2]. Which formats go-xkms accepts, and whether it checks a `tpm` AIK chain as above, is go-xkms's and was not read here.

**EK and AK relationship.** The format's certificate requirements [S1] say how the AIK certificate looks but do not prove the AK lives in the same TPM as an EK. That is credential activation: a verifier who holds the EK public key and the AK name wraps a secret to the EK so that only a TPM holding both can recover it (`tpm2_makecredential`, its TPM-side counterpart activates) [S5]. Certify proves a key with a given name is loaded in the TPM and its public area is consistent [S6]. The `enroll-01` flow described in [enrollment-survey.md](enrollment-survey.md#9-fit-with-go-trusted-platforms-enrollment) uses credential activation against the EK.

**What neither proves.** Both are statements by one TPM about itself. Whether the EK belongs to a genuine TPM, or here to a genuine chip, depends on the EK certificate. A discrete TPM has the maker's; this firmware TPM has none ([EK lifecycle](../ftpm/README.md#ek-lifecycle)). The TCG EK Credential Profile (S4) was not read (see [Sources not reached](#sources-not-reached-or-not-read-unconfirmed)).

## 2. How the OP-TEE fTPM TA gets its seeds, and what that does to chip binding

Read: `optee_ftpm` `master` (S7), `platform/EPS.c`, `platform/Entropy.c`, `platform/Unique.c`, `platform/NVMem.c`, `sub.mk`, `include/user_ta_header_defines.h`; and `optee_os` `core/tee/tee_svc.c` (S8).

- **Endorsement primary seed.** `_plat__GetEPS` first tries a TA property named `com.microsoft.ta.endorsementSeed`. If it is missing or too short, it fills the seed from the TEE's random generator and the code comment says storage can be cleared to force re-manufacture [S7]. The TA header and `sub.mk` read here define no such property [S7], so, on the code read, the seed is random. That the property is not injected by another build step (for example by a platform or the BSP) is **unconfirmed**.
- **No HUK derivation of the seed.** In the code read, the EPS is not derived from the hardware unique key, a die ID or the enclave. The other seeds are produced by the reference implementation's own manufacture step from `_plat__GetEntropy`, which calls the TEE random generator [S7] (the manufacture path inside `ms-tpm-20-ref` itself was not read: **unconfirmed**).
- **Where the seeds live.** The TPM's NV, seeds included, is OP-TEE persistent objects in the storage `CFG_FTPM_TA_TEE_STORAGE_ID` selects (default private TEE storage) [S7]. OP-TEE's own storage encryption is rooted in its hardware unique key; whether the i.MX 95 port derives that from the enclave is unconfirmed ([ftpm](../ftpm/README.md#nv-storage)). So the HUK protects the seeds at rest, but is not their source.
- **Device identity inside the TA.** `_plat__GetUnique` reads the TEE property `gpd.tee.deviceID` [S7]. OP-TEE computes that from a SHA-256 over a fixed string and the platform's die ID (`tee_otp_get_die_id`) [S8]. Whether the i.MX 95 port implements the die ID from the chip UID, and where the TPM uses `_plat__GetUnique`, is **unconfirmed**.

**Consequence.** The EK is a function of a random seed in OP-TEE storage, not of the chip. Wipe the NV and the EK changes ([ftpm question 4](../ftpm/README.md#open-questions-for-the-owner)); copy the storage to another chip and, if storage encryption is chip-bound, it should not decrypt there (that depends on the HUK, unconfirmed). Nothing in the EK proves which chip made it. Any binding must therefore come from outside the TPM.

## 3. Binding options

Common terms: the enclave response is device attestation [attestation-survey §1.1](attestation-survey.md#11-device-attestation-ele-command-0xdb); its caller nonce is 16 bytes and sits inside the signed region [attestation-survey §3](attestation-survey.md#3-nonce-and-freshness).

### (a) No binding: factory records the EK next to the chip UID (trust on first use)

- **Proves:** that the record, made in a trusted facility, links one EK to one chip UID. Later credential activation proves the AK is in the TPM holding that EK.
- **Leaves out:** any live proof the EK is in this chip; a cloned or restored OP-TEE storage image with the same seeds is the same EK. The record is only as good as the facility; a re-created EK after an NV wipe has no record until re-registered.
- **Costs:** a registry in go-trusted-platform (named only); a factory step that reads the EK public key and the chip UID; no enclave call at runtime.

### (b) Enclave attestation whose nonce field carries a hash of the TPM AK name or EK public key

- **Fit with the public fields.** The response echoes a 16-byte caller nonce inside the signed region [S9; attestation-survey §3]. In `hsm_dev_attest.h` (the header read) the struct fields seen were the info buffer and signature [S9]; that the nonce is passed as opaque bytes is not shown in what was read here, so whether the library accepts a device-chosen value is **unconfirmed**; on the survey's reading it is caller-supplied.
- **The verifier's nonce is not preserved if replaced.** If the device writes `H(AK name)` into the field, the verifier's challenge is gone, so freshness breaks (a replayed response still verifies). A workable form puts a 16-byte truncation of `H(verifier nonce ‖ AK name)` in the field; the verifier recomputes it. That keeps freshness and binds the name, at 128 bits of truncation. The verifier's recomputation, and a verifier that supports it, are go-trusted-platform's (named only). This composition is not defined by any specification read here.
- **Proves:** at the time of the response, software that could call the enclave named that TPM key. It binds the claim to the chip's attestation root (whatever that is; [attestation-survey question 2](attestation-survey.md#questions-for-the-owner)).
- **Leaves out:** that the TPM key is *in* the TPM: the enclave signs what the caller supplies, so any Linux software that can call the enclave can name any hash. The binding is as strong as the access control on that call. A compromised A55 Linux can bind an attacker's TPM or an emulator to the real chip.
- **Costs:** one enclave API call per attestation; a version 2/3 response; a verifier rule for the nonce construction.

### (c) The TPM certifies an enclave-held or enclave-attested key

- **As stated, it does not fit.** `TPM2_Certify` proves an object with a given name is *loaded in the TPM* with a valid sensitive area; an object with only a public area cannot be certified [S6]. An enclave-held private key cannot be loaded into the fTPM without leaving the enclave, which breaks the key tier ([ftpm question 7](../ftpm/README.md#open-questions-for-the-owner)).
- **Variant (c'), reverse binding.** The TPM certifies its AK with the qualifying data set to a hash of the enclave response (or the enclave response hash is part of what the TPM signs) [S6]. This binds in the opposite direction from (b): the TPM vouches it saw the enclave statement. In the `tpm` format the `extraData` is fixed to the hash of the signed input [S1], so this needs a second certify structure beside the standard one.
- **Proves:** the TPM held that enclave statement; nothing about the enclave key.
- **Leaves out:** the same as (b), reversed: the enclave statement is not tied to the TPM unless (b) is also used; a TPM emulator can hash any statement.
- **Costs:** a TPM certify with custom qualifying data, a non-standard evidence item, plus an enclave call. Not covered by `device-attest-01` as the draft [S2] describes it; the wire protocol is #24.

### (d) Two independent evidence items sent together

- **Proves:** each source's own statement, fresh against the verifier's challenge and delivered in one session.
- **Leaves out:** that the two come from the same device. An attacker with one genuine chip and one genuine other TPM can send both; only the session, not the cryptography, ties them. RATS models a composite device where one entity combines evidence from several attesters [S3]; that composition is a verifier policy, not a binding.
- **Costs:** the least: two calls, a verifier that checks two formats. No protocol change beyond carrying both items ([attestation-survey §4](attestation-survey.md#4-carrying-the-evidence-to-a-remote-verifier)).

### (e) A DICE-style layered chain

- **Not available on this chip in the public sources.** The enclave's evidence is a flat signed structure over device state, with no layered derivation of a key from a measured stage [attestation-survey §1.4](attestation-survey.md#14-what-the-enclave-evidence-does-not-cover); "no public source shows a measured-boot log or DICE chain that the ELE keeps or signs". No chain was found in the fTPM TA either [S7]. TCG DICE specifications were **not read** here (see below). What a TPM-side DICE variant would need from the chip is unconfirmed.

## 4. Open questions each option depends on

| Option | ftpm questions ([README](../ftpm/README.md#open-questions-for-the-owner)) | attestation-survey questions ([list](attestation-survey.md#questions-for-the-owner)) |
|---|---|---|
| (a) factory record | 3 (EK template: what is recorded), 4 (re-provisioning: a new EK needs a new record) | 2 (root: this is its option (b) analogue) |
| (b) hash in enclave nonce | 3, 4, 7 (the TPM key stays outside the enclave) | 1 (evidence), 2 (root), 3 (versions, nonce, freshness), 5 (the A55 calls the enclave) |
| (c) TPM certifies | 7 (enclave key cannot enter the TPM), 2 (TA source: certify support in the TA), 3 | 1(b) (public key attestation), 5 |
| (d) two items | 4, 6 (how deep the TPM evidence is) | 1, 3, 4 (image scope) |
| (e) DICE-style | none can be answered from public sources | 2, 4 |

## 5. Options against the needs

| Option | Needs enclave API call | Needs go-trusted-platform change (named only) | Reversible | Survives TPM NV wipe (ftpm question 4) | Covers image measurement |
|---|---|---|---|---|---|
| (a) factory record | No at runtime; the UID read at the factory | An EK/UID registry and re-registration process | Yes | No: a wiped TPM has a new EK, needs a new record | No |
| (b) hash in enclave nonce | Yes, per attestation | A verifier that recomputes the nonce construction | Yes, until chips are enrolled on it | Partly: the enclave statement still verifies, but it names a new AK; the EK link is rebuilt by the next attestation | No |
| (c) TPM certifies | Yes (variant c') | A verifier for a second certify item | Yes | Same as (b) | No |
| (d) two items | Yes | A verifier that checks two formats | Yes | Yes for the enclave item; the TPM item is re-enrolled | No |
| (e) DICE-style | Unknown | Unknown | Not applicable | Not applicable | Only if the layers measure it; none shown |

**Image measurement is covered elsewhere for all five.** The enclave evidence is a signing-root identity, not image evidence [attestation-survey §1.4](attestation-survey.md#14-what-the-enclave-evidence-does-not-cover); PCR measurement and its gaps are in [ftpm Measured boot](../ftpm/README.md#measured-boot) and [ftpm question 6](../ftpm/README.md#open-questions-for-the-owner). No option here adds measurement.

## What this survey does not decide

Which option the owner picks; any go-xkms or go-trusted-platform code; the wire protocol (#24, blocked); the evidence and root questions of [attestation-survey.md](attestation-survey.md) (which stay with the owner and go-trusted-platform's hsm-device-lifecycle row); the EK template and re-provisioning rules of the [ftpm](../ftpm/README.md) row.

### Proposed, pending owner approval (text only)

A possible addition to the device-lifecycle row of SPEC.md, not made by this lane: "The device's TPM identity is tied to the chip by a factory record of the EK next to the chip UID, until a bound alternative is decided. Evidence of the TPM and of the enclave are carried together." This edits neither SPEC.md nor ROADMAP.md.

## Sources

| # | Title | Version surveyed | URL |
|---|---|---|---|
| S1 | W3C Web Authentication Level 2, §8.3 TPM Attestation Statement Format and §8.3.1 | W3C Recommendation, read 2026-11-22 | https://www.w3.org/TR/webauthn-2/#sctn-tpm-attestation |
| S2 | IETF draft-ietf-acme-device-attest-10, ACME device attestation (Internet-Draft, not an RFC) | -10, August 2026 | https://www.ietf.org/archive/id/draft-ietf-acme-device-attest-10.txt |
| S3 | RFC 9334, RATS Architecture (composite device, passport and background-check models, section headings read; body not re-read) | RFC 9334 | https://www.rfc-editor.org/rfc/rfc9334 |
| S4 | TCG EK Credential Profile for TPM Family 2.0 (file fetched, text not read) | V2.5 R2 | https://trustedcomputinggroup.org/wp-content/uploads/TCG-EK-Credential-Profile-V-2.5-R2_published.pdf |
| S5 | tpm2-tools manual `tpm2_makecredential(1)` | `master`, read 2026-11-22 | https://github.com/tpm2-software/tpm2-tools |
| S6 | tpm2-tools manual `tpm2_certify(1)` | `master`, read 2026-11-22 | https://github.com/tpm2-software/tpm2-tools |
| S7 | OP-TEE `optee_ftpm`: `README.md`, `sub.mk`, `include/user_ta_header_defines.h`, `platform/EPS.c`, `Entropy.c`, `Unique.c`, `NVMem.c` | `master`, commit f09f4cd (2026-09-25) | https://github.com/OP-TEE/optee_ftpm |
| S8 | OP-TEE `optee_os`: `core/tee/tee_svc.c` (`gpd.tee.deviceID`) | `master`, commit 4ec608a | https://github.com/OP-TEE/optee_os |
| S9 | NXP `imx-secure-enclave`: `include/hsm/internal/hsm_dev_attest.h` | tag `lf-6.18.20-2.0.0`, commit d7e1180 | https://github.com/nxp-imx/imx-secure-enclave |
| S10 | Linux `Documentation/security/tpm/tpm_ftpm_tee.rst` | `master`, read 2026-11-22 | https://github.com/torvalds/linux |

### Sources not reached or not read (unconfirmed)

- TCG EK Credential Profile (S4): the PDF was fetched but not read; claims about EK certificate contents and the default templates are therefore not made here.
- TCG TPM 2.0 library specifications (Part 1 credential activation, Part 3 `TPM2_Certify`, `TPM2_ActivateCredential`): not read; the credential-activation and certify behaviour above rests on the tpm2-tools manuals (S5, S6) and on the WebAuthn text (S1).
- TCG DICE specifications: not read; option (e) rests on the absence of a chain in sources S7 and attestation-survey.
- The `ms-tpm-20-ref` manufacture code (how the other seeds are generated), `optee_os` i.MX 95 die-ID and HUK code, and the `tee_otp_get_die_id` implementation for this platform: not read.
- RFC 9334 body, RFC 8555 text, tpm2-tss documentation: not read in this lane.
- The enclave response's nonce handling in the library source (only the header was read): see option (b).
- The Linux driver text (S10) says only that the driver is a thin pipe to the TrustZone TPM; it says nothing about seeds or identity.

## Questions for the owner

1. **Which binding between the TPM and the chip?**
   - (a) A factory record of the EK beside the chip UID, trust on first use.
   - (b) (a) plus the enclave response carrying the AK name through a hash of the verifier nonce and the name.
   - (c) The TPM certifying with enclave-statement qualifying data (variant c').
   - (d) Two independent items, bound by session only.
   - (e) A DICE-style chain (not available on public evidence).

   *Provisional default:* (a) now, with (d) as the carried evidence, and (b) re-examined once the library's nonce handling and the attestation root ([attestation-survey question 2](attestation-survey.md#questions-for-the-owner)) are known. (a) and (d) need nothing from the enclave API beyond what is already surveyed, and both are reversible.

2. **How is a re-created EK re-registered after an NV wipe?** ([ftpm question 4](../ftpm/README.md#open-questions-for-the-owner).) (a) A factory or service procedure re-reads the EK and the chip UID; (b) endorse-01 reissues with a fresh enclave statement; (c) the device is retired and re-enrolled. *Provisional default:* (b), pending go-xkms's endorse-01 checks, which this lane did not read.

3. **Is a device-chosen value in the enclave nonce field acceptable at all?** (a) Yes, with the hash construction in 3(b); (b) No: the nonce stays the verifier's, and binding uses (d). *Provisional default:* (b) until NXP or the library source confirms the nonce is opaque and the verifier side supports the construction.

4. **Does the owner accept that the TPM's seeds are random, not chip-derived, on the code read?** (a) Accept and record the EK at the factory; (b) ask for an fTPM variant seeded from the enclave. *Provisional default:* (a); (b) means a TA change and is out of this survey.
