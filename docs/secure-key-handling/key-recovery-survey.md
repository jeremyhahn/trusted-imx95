# Key backup and recovery on the i.MX 95 EdgeLock enclave: survey

Row: `secure-key-handling` ([SPEC.md](../SPEC.md)). Issue #120. Status: survey for the owner's decision; nothing here is decided.

Scope: whether keys in the i.MX 95 EdgeLock secure enclave (ELE) key store can be backed up, exported wrapped, or re-created after a board is replaced; which keys must be unrecoverable by design; and the risks each recovery path adds. Public sources only. Documentation only: no keys, fuses, life-cycle or provisioning steps are run or scripted here.

## 1. Sources surveyed

Each source is public. The tag or version is the one read for this survey, on 2026-11-12.

| Id | Source | Version | URL |
|----|--------|---------|-----|
| S1 | NXP, *imx-secure-enclave*: the Secure Enclave user-space library (ELE HSM API) and its NVM manager. Its `README` and the HSM API headers under `include/hsm/internal/` were read | tag `lf-6.18.37-2.1.0` (library 1.1.1, NVM 1.1.1 per `se_version.txt`) | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 |
| S2 | Arm, *PSA Certified Crypto API*: the key policy chapter (usage flags, including the export permission) and the key management chapter | 1.2 | https://arm-software.github.io/psa-api/crypto/1.2/api/keys/policy.html and https://arm-software.github.io/psa-api/crypto/1.2/api/keys/management.html |

Sources not reached, or reached but not usable, are listed in §6.

The repository's private references (RM00284, AN14861, AN14471 in [references/](../references/README.md)) are cited by [SPEC.md](../SPEC.md). They are not public, and this survey does not rely on them. Where SPEC.md already states a fact from them, this survey points to SPEC.md and does not restate it.

## 2. How the ELE key store persists

- The ELE HSM library supports the i.MX 95 through its `ele` build (S1, `README`, Table 1).
- The enclave does not keep the key store in its own non-volatile memory. A user-space daemon, the NVM manager, runs on Linux. It serves the enclave firmware and keeps the key store as files on the Linux filesystem. On the i.MX 95 these files are under `/etc/ele/` (S1, `README`, "NVM Manager" and Table 2). On the FRDM-IMX95-PRO, that filesystem is the platform image's root filesystem on the eMMC.
- A key store is created or loaded by opening a key store service. A new key store reaches the NVM only when the create request carries the strict (newer firmware: "sync") flag. With the monotonic flag added, the request completes only after the monotonic counter has advanced. Closing the service drops anything not yet written (S1, `hsm_key_store.h`). SPEC.md's `secure-key-handling` row already relies on this, through RM00284 §2.4.2.
- Access to a key store is bound to the domain ID and Messaging Unit used when it was created, plus an optional nonce (S1, `hsm_key_store.h`, group "Key store").
- **Not confirmed from a public source:** how the stored files are protected. That includes which key encrypts and authenticates them, and whether it comes from a chip-unique secret. If it does, files copied to another chip cannot be opened there. S1's headers and README do not say. The ELE firmware API manual that would say is not public (see §6).

## 3. Recovery paths

A build note matters for the i.MX 95. The library's `ele` build, which serves the i.MX 95, compiles with `PSA_COMPLIANT` defined (S1, `src/plat/ele/ele.mk`). Several older key transport calls are compiled only when `PSA_COMPLIANT` is undefined. These are the root KEK export (`hsm_root_kek_export.h`) and the manage-key import under a part-unique or common root KEK (`hsm_managekey.h`). They exist for the SECO and V2X builds, not for the ELE build (S1). This survey therefore treats them as **not available on the i.MX 95**. That conclusion comes from reading the build flags, not from a firmware statement.

### 3.1 Key store blob migration to another board

- Mechanically, the key store is a set of files under `/etc/ele/` on Linux (§2). So the files themselves can be copied off the board with the root filesystem.
- S1 offers no API to re-target, re-wrap or migrate a key store to another chip. Its key store calls are create, load, close, status, and "reprovisioning enable". Per the header, reprovisioning erases every key store the HSM handles and needs a signed message (S1, `hsm_key_store.h`, `common/key_store.h`). It is a wipe, not a migration.
- Whether a copied key store loads on another i.MX 95 depends on how the files are sealed. That is **not confirmed** (§2, §6). Two facts point to "no", but neither proves it. First, key store access is bound to the creating domain and Messaging Unit. Second, the library's general-purpose data blob can bind its key to the chip's unique ID (S1, `hsm_blob_unblob.h`, derivation-context flags).
- Rollback adds a further barrier. The key store is tied to the monotonic counter (§2; SPEC.md row). So even a same-board restore of an older copy of `/etc/ele/` is expected to be refused once the counter has moved on. The exact refusal behaviour is **not confirmed** from a public source.
- **Assessment:** there is no supported cross-board migration path in the public API. A same-board file backup protects at most against loss of the filesystem, not against loss of the board. Even that is limited by the counter.

### 3.2 Wrapped export of individual keys

- Keys carry a usage bit that permits export (S1, `hsm_key.h`, `HSM_KEY_USAGE_EXPORT`). It has the same bit value as PSA's export permission. In PSA, that permission lets a key leave its security boundary through the export or copy calls. A public key can always be exported, whether or not the bit is set (S2, key policies). However, the library at this tag declares no call that exports a private or secret key in any form, wrapped or clear. The only export call is the public-key export, `hsm_pub_key_recovery`, which the header says is also known as public key exportation under PSA naming (S1, `hsm_key_recovery.h`).
- `hsm_gen_ele_key_blob` takes a plaintext key supplied by the caller (a DEK, or an OTFAD key configuration) and returns an enclave-made blob. That blob is for the boot ROM or the inline decryption engines (S1, `hsm_gen_ele_key_blob.h`). It wraps a key going *into* the chip's boot path. It does not export a key-store key.
- `hsm_blob_unblob` wraps and unwraps caller data under a derived key. The derivation context can include the Messaging Unit attributes, the boot stage and the chip's unique ID (S1, `hsm_blob_unblob.h`). With the unique ID bound, such a blob is board-specific by construction.
- **Assessment:** wrapped export of key-store private keys is **not offered** by the public API at this tag. Whether the ELE firmware has such a command that the library does not expose is **not confirmed**.

### 3.3 Re-provisioning (import of wrapped OEM keys)

- The ELE build imports keys with `hsm_import_key`. Input is either an ELE TLV or an EdgeLock 2GO TLV. Flags can request a strict write and a monotonic counter increment (S1, `hsm_importkey.h`). In the PSA build, a key exchange call (`hsm_key_exchange`) establishes the key under which the imported key is wrapped (S1, `hsm_key_exchange.h`).
- SPEC.md's `oem-key-provisioning` row already describes this flow from the private references: key exchange, then import of the wrapped key.
- **Not confirmed for the i.MX 95.** The calls above are declared in S1's headers, but a header declaration does not establish that the i.MX 95 firmware serves them. The README at the same tag lists the Key Exchange API and the Key Import API as not supported on the i.MX 95 ([algorithm-support-survey.md](algorithm-support-survey.md) §3.2). Whether the OEM import that SPEC.md's row describes is a separate enclave service that the i.MX 95 does serve is unresolved (same survey, question 7).
- If an applicable i.MX 95 import service is confirmed by NXP, or validated on this board's firmware, it would be the one recovery path the public API offers. A key that was **generated outside the enclave and kept outside it** could then be imported into a replacement board, wrapped. It works only for keys that have an off-board master copy, held for example in go-xkms custody or an offline HSM.
- **Assessment:** re-provisioning is **unconfirmed** on the i.MX 95. No source read here guarantees that a replacement board can restore any key. Keeping an off-board master copy of every key that must be recoverable is still advised, because it is the precondition of this path if the import service is confirmed. It can never bring back a key that was generated inside the enclave.

### 3.4 Re-creation (re-generate and re-enrol)

- A key generated inside the enclave never leaves it (SPEC.md row). For such a key, the only "recovery" after a board is replaced is to generate a new key on the new board and re-enrol its public half. Re-enrolment means re-certifying it with whoever trusts it. The public half can be read out with `hsm_pub_key_recovery` (S1, `hsm_key_recovery.h`). Enrolment and the device registry belong to go-trusted-platform (SPEC.md, scope).
- Anything sealed only to the old key is lost with the old board. Examples are data encrypted to it, or blobs bound to its unique ID. That loss is acceptable only if no such data exists, or the data is also held elsewhere.
- **Assessment:** this is the default path for every key that should be device-bound. It needs no new mechanism in this repository. It needs go-trusted-platform's enrolment to accept a replacement device for a retired one.

## 4. Which keys are unrecoverable by design, and which need a path

The key classes below come from SPEC.md's rows. The recovery path for each follows §3. The "Decided by" column marks the classes whose recovery policy is go-xkms's or go-trusted-platform's to set, not this repository's. Neither project's documents were reachable from this lane (§6). So the column names the owner of each decision. It does not report what that owner has decided.

| Key class | Where it lives | Recoverable? | Path (§3) | Decided by |
|-----------|----------------|--------------|-----------|------------|
| Enclave device attestation key (SPEC.md `device-lifecycle`, RM00284 §3.12) | Inside the enclave, set up by NXP. Whether it is fused or derived is **not confirmed** publicly | **No, by design.** It is the chip's identity | None. A new board brings a new attestation identity | This repository (device side); go-trusted-platform (what it trusts) |
| Device identity and enrolment keys generated in the key store (the board's identity towards xkmsd and the control plane) | ELE key store under `/etc/ele/` | **No, by design.** Generated in the enclave; no export call exists (§3.2) | 3.4: re-create and re-enrol | go-trusted-platform (enrolment and revocation of the retired board); go-xkms (`hsm-device-protocol` identity) |
| Keys the board holds as an HSM on behalf of go-xkms (the service's working keys) | ELE key store | **Only if a master copy exists off the board, and only once an i.MX 95 import service is confirmed** (unconfirmed, §3.3) | 3.3: wrapped re-import from custody, conditional on that confirmation; otherwise 3.4 and loss of what they protect | **go-xkms** (key custody model) |
| OEM keys provisioned by `oem-key-provisioning` | ELE key store, imported wrapped | **Unconfirmed.** Only if the provisioning side keeps the master and the i.MX 95 import service is confirmed or validated (§3.3) | 3.3, conditional | This repository (`oem-key-provisioning`), with the owner |
| Code-signing keys for the boot container (SPEC.md `boot-container`) | Off the board, in an HSM under go-xkms custody (AN14471 model, per SPEC.md). The board holds only the fused key hash | Not a board recovery question. A replacement board must be fused with the same hash, which is an `oem-key-provisioning` step not covered here | n/a | go-xkms (custody); this repository (fusing, in `oem-key-provisioning`) |
| Data blobs sealed with `hsm_blob_unblob` bound to the chip's unique ID | Caller storage | **No.** Board-bound by construction (S1) | Re-create the data from its source | This repository |

## 5. Risks each path adds, as the other SPEC rows see them

**3.1 Key store file backup (same board only)**

- `secure-key-handling`: a restored older copy is exactly the rollback that the monotonic counter exists to refuse (§2). A backup scheme that "works" would be a sign that rollback protection is not in force.
- `platform-image`: the key store files live in `/etc/ele/` on the Linux filesystem (S1). If an image update replaces or rolls back the root filesystem, the key store is replaced or rolled back with it. This is a way to lose keys without losing the board. It is a risk whether or not a backup path is adopted (question 3).
- `hsm-self-defence`: copies of the key store files outside the board are harmless only if the sealing is chip-bound, which is **not confirmed** (§6). If it is not chip-bound, every copy weakens zeroisation.

**3.3 Wrapped re-import from an off-board master** (only if the i.MX 95 import service is confirmed, §3.3)

- `secure-key-handling`: a key with an off-board master is only as safe as the custody that holds the master. The board stops being the only place the key exists. This is a deliberate change from "never leaves the enclave in the clear". It still holds as written, because the key travels wrapped. But the key's root of trust moves off the board.
- `oem-key-provisioning`: re-import reuses the key exchange and wrapped import flow (S1; SPEC.md row). The replacement board must be in a life-cycle state that allows the import. Moving between life-cycle states is not run or scripted here.
- `device-lifecycle`: the replacement board must be attested before any key is re-imported into it. Otherwise the import can be redirected to a board that is not genuine.
- `hsm-device-protocol`: if go-xkms drives re-import over the wire, the protocol gains an import operation. That is go-xkms's to define (SPEC.md scope).
- `hsm-self-defence`: zeroisation of an importable key ends the board's copy, not the key. The tamper response stays meaningful only if custody also revokes or rotates the key after a tamper event.

**3.4 Re-create and re-enrol**

- `device-lifecycle`: go-trusted-platform's registry must retire the old board's identity and enrol the new one. Without a revocation step, a stolen old board still presents a valid identity.
- `secure-key-handling`: anything sealed only to a re-created key is lost. Any data whose loss is unacceptable must not be sealed only to a device-bound key.
- `boot-container`: not affected. A new board needs its fuses set to the same signing-key hash through `oem-key-provisioning`, and no key on the board is recovered.

## 6. What could not be confirmed

- **How the ELE seals the key store files** under `/etc/ele/`: the key, whether it is chip-unique, and whether a copy loads on another i.MX 95. S1's headers, README and its generated API document (`doc/ele_hsm_api_document.rtf`, same tag) do not state it. The ELE firmware API manual (RM00284) is in the repository's private references, not on a public URL: `https://www.nxp.com/docs/en/reference-manual/RM00284.pdf` returned "page not available" from the lane.
- **Whether ELE firmware has a key export or migration command** that S1 does not expose. The PSA build of S1 has none at tag `lf-6.18.37-2.1.0`.
- **Whether the i.MX 95 firmware serves any wrapped key import** usable for re-provisioning. S1's headers declare `hsm_import_key` and `hsm_key_exchange`, but S1's README at the same tag lists the Key Exchange and Key Import APIs as not supported on the i.MX 95 ([algorithm-support-survey.md](algorithm-support-survey.md) §3.2), and whether the OEM import path is a separate service is open (same survey, question 7). Needs NXP confirmation or validation on the board's firmware.
- **The exact behaviour when an older key store copy is restored** on the same board after the monotonic counter has advanced.
- **The i.MX 95 Security Reference Manual and IMX95RM**: they are missing from the references (SPEC.md) and not public.
- **NXP EdgeLock 2GO** (the service behind the `E2GO_TLV` import input in S1): the public product pages tried returned "page not available" from the lane. Its re-provisioning model for a replacement device is not surveyed.
- **go-xkms's and go-trusted-platform's decisions** on key custody, device replacement and revocation: no public source was reachable from the lane, and the lane cannot read issues. §4 names who decides; it does not report what was decided.
- **The upstream Linux kernel and OP-TEE ELE support** were not surveyed. Neither is expected to add an export path beyond the firmware's, but that is not confirmed.

## 7. Questions for the owner

1. **Which key classes must have a recovery path?**
   - (a) None. Every board key is device-bound. Board replacement always means re-create and re-enrol (§3.4).
   - (b) Only the keys the board holds for go-xkms, through wrapped re-import from go-xkms custody (§3.3). Device identity stays unrecoverable.
   - (c) Also the device identity keys.

   Recommendation: **(a) as the design stance now; (b) only once an i.MX 95 import service is confirmed by NXP or validated on the board's firmware, and only if go-xkms keeps an off-board master.** Wrapped import is the only recovery path the public API declares (S1), but its availability on the i.MX 95 is unconfirmed (§3.3), so no recovery of a key on a replacement board is guaranteed today. go-xkms keeping an off-board master for keys it may need to restore remains advised. Device identity cannot be recovered without an export call that does not exist (§3.2), so (c) is not supported by the sources.
2. **Does go-xkms hold an off-board master for the working keys it places on the board, or does it generate them on the board?**
   - (a) It holds a master and imports wrapped.
   - (b) It generates on the board and accepts loss on replacement.
   - (c) It generates on the board and replicates through its own protocol.

   No recommendation: this is go-xkms's decision (§4). Note that (a) depends on an i.MX 95 import service that is unconfirmed (§3.3), and (c) needs an export path that S1 does not offer.
3. **Where does `/etc/ele/` live relative to image updates (`platform-image`)?**
   - (a) On the root filesystem, replaced and rolled back with it.
   - (b) On a separate persistent partition that image updates never touch.
   - (c) Bind-mounted from a persistent partition.

   Recommendation: **(b)** (or (c), which is equivalent). The key store is plain files under `/etc/ele/` (S1), and a rolled-back copy conflicts with the monotonic counter (§2, §5).
4. **Should a same-board backup of the key store files be made?**
   - (a) No.
   - (b) Yes, against filesystem loss only.

   Recommendation: **(a).** It does not survive board loss (§3.1). On a working board it is expected to be refused once the counter moves. Its safety rests on chip-bound sealing that is not confirmed (§6).
5. **How should the open facts in §6 be confirmed?**
   - (a) Add the ELE firmware API manual's key store chapter and the i.MX 95 Security Reference Manual to the private references and cite them.
   - (b) Ask NXP support.
   - (c) Leave them unconfirmed and design as if sealing were not chip-bound.

   Recommendation: **(a)**, with (c) as the design stance until it is done. Board experiments that touch the key store or life cycle are out of scope for documentation lanes.
6. **On board replacement, who retires the old board's identity?**
   - (a) go-trusted-platform's registry, on an operator action.
   - (b) Automatically when the new board enrols for the same slot.

   Recommendation: **(a)**, so that a lost board cannot silently keep or transfer its slot. This is go-trusted-platform's decision (SPEC.md scope); this repository needs only to present the new board's evidence.
7. **Is NXP EdgeLock 2GO (the `E2GO_TLV` import, S1) in scope for provisioning or re-provisioning keys?**
   - (a) No; use the OEM key exchange and wrapped import only.
   - (b) Yes, survey it as a separate item.

   No recommendation: its public pages were not reachable (§6).
