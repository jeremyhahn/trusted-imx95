# OEM key provisioning: failed-provisioning survey (i.MX 95)

Row: `oem-key-provisioning` ([SPEC.md](../SPEC.md)). Issue #132. Documentation only: nothing here is run or scripted, and no fuse, life-cycle or provisioning step is given as a procedure.

## 1. Scope and method

The question is what happens when OEM provisioning of an i.MX 95 is interrupted or goes wrong part way: power lost between fuse writes, a failed import of a wrapped key, or a wrong SRK hash fused. For each, which partial states can be recovered, which leave a device that does not boot, which leave a device that boots but is not secure, and how a provisioning station tells them apart. Section 5 gives the order of steps and the checks before each irreversible one, as input to #99.

Only public sources were used: NXP's public GitHub repositories and public documents, and upstream U-Boot. Each source is listed with the version or commit read. Everything below is a summary in this repository's own words; no vendor text is copied. Where the only public source is written for a sibling part (the i.MX 93, which uses the same EdgeLock secure enclave (ELE) and AHAB container scheme), the text says so; i.MX 95 behaviour that is inferred from it is marked as not confirmed. The i.MX 95 Reference Manual (IMX95RM) and Security Reference Manual are not public and were not read (see [SPEC.md](../SPEC.md)).

## 2. Sources surveyed

| Id | Source | Version read | URL | Reached |
|---|---|---|---|---|
| S1 | U-Boot, *i.MX93 Secure boot guide using AHAB* (`doc/imx/ahab/guides/mx93_secure_boot.rst`) | U-Boot `master` at commit `3cb2cbbc75aa` (2026-11-11); the file is not in tag `v2026.10` | https://github.com/u-boot/u-boot/blob/3cb2cbbc75aa7fe2391f662607d6b2f46c1292a7/doc/imx/ahab/guides/mx93_secure_boot.rst | yes |
| S2 | U-Boot, *i.MX Secure and Encrypted Boot using AHAB* (`doc/imx/ahab/introduction_ahab.rst`) | U-Boot `master` at commit `3cb2cbbc75aa` | https://github.com/u-boot/u-boot/blob/3cb2cbbc75aa7fe2391f662607d6b2f46c1292a7/doc/imx/ahab/introduction_ahab.rst | yes |
| S3 | NXP `imx-secure-enclave`, ELE HSM API reference (`doc/ele_hsm_api_document.rtf`) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/blob/lf-6.18.37-2.1.0/doc/ele_hsm_api_document.rtf | yes |
| S4 | U-Boot, *fuse command* (`doc/usage/cmd/fuse.rst`) | U-Boot `master` at commit `3cb2cbbc75aa` | https://github.com/u-boot/u-boot/blob/3cb2cbbc75aa7fe2391f662607d6b2f46c1292a7/doc/usage/cmd/fuse.rst | yes |
| S5 | NXP AN14861 (cited by SPEC.md for the provisioning flow) | PDF as served on 2026-11-12; revision not read | https://www.nxp.com/docs/en/application-note/AN14861.pdf | downloaded, but the lane has no PDF text tool; contents not read |

## 3. Interruption cases

### 3.1 Power loss between fuse writes

What the sources say:

- A fuse is one bit that can be set once and never cleared; an unset fuse reads 0. Fuses are read and written in 32-bit words (S4).
- At reset the fuse controller copies the fuses into a volatile shadow cache. Normal reads come from that cache. A *sense* reads the fusebox directly, and after a program operation the cache may or may not be refreshed, depending on the IP (S4).
- S4 advises that a reprogramming of a word sets only bits not yet blown, so that blown bits are not driven a second time.
- The i.MX 93 guide programs the 256-bit SRK hash as eight separate 32-bit word writes (S1 §5). The close is a separate, later operation (S1 §7).

What follows (inferred, not confirmed for the i.MX 95):

- **Power lost between SRK-hash words.** Some words hold their final value and the rest read 0. Until the part is closed, the hash is simply wrong, as in §3.3 OEM open. Whether it can be finished by writing the missing words in a later session depends on whether a word that reads 0 can still be written, and whether the i.MX 95 locks a bank or word group after its first write (ECC-protected words often take one write only). No public source read answers this for the i.MX 95. **Not confirmed.**
- **Power lost during one word write.** Whether a word can be left half-written, and whether the enclave reports it, is not in any public source read. **Not confirmed.**
- **Power lost between the last SRK-hash word and the close.** This is the intended resting point: the part is in OEM open with the hash fused, and the boot check in S1 §6 can be repeated as many times as needed.
- **Power lost during the close (life-cycle change).** S3 lists the target life-cycle states the enclave accepts (`hsm_lc_update`: OEM open, OEM closed, OEM locked, field return) but says nothing about an interrupted change. **Not confirmed**, and this is the step with the most at stake.
- **Detection.** After any interruption the station power-cycles the board so the shadow cache reloads, then reads the SRK-hash words and the life-cycle value fresh. Only sensed or freshly reloaded values count; values in the cache from before the write do not (S4). Each word is then classed as "expected value", "zero" or "other". Any word in the "other" class means the part is scrapped and never closed.

### 3.2 Failed key import

What the sources say (S3, the ELE HSM API reference, written for the i.MX 8ULP and i.MX 93; the i.MX 95 is not named in it):

- A new key store exists only in the enclave's local memory until a key is generated or imported with the "strict operation" flag; only then is it written to the external NVM (S3, "Key store").
- Any key-store change made without the strict flag lives in local memory only and is lost on reset. A change counts as made only once a strict operation has been acknowledged (S3, "NVM writing").
- Each strict operation exports the affected key-store blocks to the NVM and blows one bit of an OTP monotonic counter, as rollback protection. When the counter is used up the enclave still accepts updates but warns that they are no longer rollback-protected (S3, "NVM writing"; error code `HSM_KEY_STORE_COUNTER`).
- Closing a key-store session drops it from local memory; anything not yet in the NVM is lost (S3, "Key store" functions).
- An imported key arrives in encrypted form, either as an EdgeLock 2GO TLV or as a signed message wrapped under a key-encryption key (KEK). KEKs can only wrap and import other keys (S3, "Key management": `hsm_import_key`, `HSM_KEY_INFO_KEK`).
- A signed-message verification failure is a hard error in OEM closed but only a warning in OEM open (S3, error codes `HSM_OEM_CLOSED_LC_SIGNED_MSG_VERIFICATION_FAIL` and `HSM_OEM_OPEN_LC_SIGNED_MSG_VERIFICATION_FAIL`). Each key also carries the device life cycles in which it may be used (S3, `hsm_key_lifecycle_t`).

What follows (inferred, not confirmed for the i.MX 95):

- **Import fails with an error reply.** If the enclave answers with an error before the strict operation, the change was not made (S3, "NVM writing": a change counts only once acknowledged). The station may repeat the import, at no new counter cost beyond what earlier strict operations spent.
- **No acknowledgement arrives** (power loss, reset or a lost reply during a strict operation). This is an **indeterminate update**, not "NVM unchanged": the enclave may already have written the key-store blocks to the NVM, blown a counter bit, or both, before the reply reached the station, as the next bullet shows. The station must not retry blindly. It first reconciles state after a reset: whether the key store opens, whether the key is present with the expected attributes (`hsm_get_key_attr`), and, where the enclave reports it, the counter state. A retry is allowed only after that reconciliation, or under a vendor recovery rule. No vendor rule for this case was found in the sources read; it is **unconfirmed**. Each blind retry can spend finite OTP counter bits.
- **Power is lost after the enclave has blown the counter bit but before the NVM write finished**, or the other way round. No public source read says what the enclave does then. A counter ahead of the stored blob would make the stored key store look like a rollback and be refused. That would lose the store, not brick the SoC, but it would need a fresh key store and a fresh import. **Not confirmed.**
- **Import in OEM open with a bad signature.** The enclave warns and does not stop. A station that treats warnings as success would carry an unauthenticated key into a device that is then closed. That leaves the device insecure, not bricked.
- **Detection.** The station treats only an acknowledged strict operation as done. It then reads back the key's attributes (`hsm_get_key_attr`) and counts any warning code as a failure. It also logs the monotonic-counter warnings, because each provisioning retry spends OTP.

### 3.3 Wrong SRK hash written

What the sources say:

- On the ELE parts (i.MX 8ULP and the i.MX 9 family) the root of trust is a 256-bit SRK hash in fuses. The signed image carries an SRK table of four public keys; at boot the enclave checks the table against the fused hash, and only if they match does it go on to verify the container signature (S2 §2.2). On the i.MX 95 the width depends on the silicon revision ([fuse-map-survey.md](fuse-map-survey.md) §3.1): eight 32-bit words (`OEM_SRKH0` to `OEM_SRKH7`, a 256-bit SHA-256 hash) on A0 and A1, sixteen words (`OEM_SRKH0` to `OEM_SRKH15`, a 512-bit SHA-512 hash) on B0, which also adds a separate post-quantum SRK-hash group. Which revision this board carries is **unconfirmed**. Below, "the SRK-hash words" always means the complete, revision-specific word range.
- The i.MX 93 guide warns that the SRK hash is the base of the root of trust and that an error in it gives a part that does not boot (S1 §5). It does not say in which life-cycle state that holds.
- The same guide makes three conditions a precondition of closing: the part is in OEM open, the SRK hash is fused, and a signed image boots with no AHAB events reported. If any is not met when the part is closed, it says the sample cannot be recovered (S1 §7).
- The NXP-signed ELE firmware is authenticated in both OEM open and OEM closed (S2 §1.1.3). So the first container does not depend on the OEM SRK hash; the OEM containers (SPL onwards) do (S1 §3).

What follows for the i.MX 95 (inferred from S1 and S2, not confirmed for this part):

- **Wrong hash, still OEM open.** The guide's check after fusing boots the board and reads AHAB events with `ahab_status` before closing (S1 §6). That check only makes sense if, in OEM open, a failed authentication is recorded as an event and the boot continues. S1 implies this but does not say it. A wrong hash fused in OEM open is therefore not a brick yet, but the fuse words are one-time programmable, so the part can never be closed with that key set. In practice it is an engineering sample. *Not confirmed:* whether a wrong hash in OEM open stops the boot on the i.MX 95, and whether the i.MX 95 has spare SRK-hash fuses or a way to replace a fused hash. No public source read says either.
- **Wrong hash, then closed.** The part refuses every OEM container. With no recovery path named in any public source, this is a brick (S1 §5, §7).
- **Detection.** Before the close, the station compares every fused SRK-hash word of the revision's full range (eight on A0/A1, sixteen on B0), read back, with the hash srktool produced for the SRK table in the image (S2 §2.2), and requires a signed boot with zero AHAB events (S1 §6). S2 notes that its own digest-check example is not a reference for programming the fuses, and S1 §5 dumps the same file in a different word form for programming. The comparison should therefore be made in the fuse-word form the device reads back. Why the two forms differ is not explained in either source.

## 4. Partial states: recoverable, bricked, insecure

Life cycle as the enclave reports it (S1 §6, §7; S3). "Inferred" marks a class drawn from i.MX 93 or generic ELE sources and not confirmed for the i.MX 95.

| Partial state | Class | How a station detects it | Basis |
|---|---|---|---|
| OEM open, no SRK hash, any key import failed or not yet strict | Recoverable | Life cycle reads OEM open; hash words read 0; key not in the store after a reset | S1, S3 |
| OEM open, SRK hash partly written (power loss) | Recoverable only if the missing words can still be written; otherwise engineering sample | Freshly loaded hash words over the revision's full range (eight on A0/A1, sixteen on B0): some expected, some 0. On B0, eight correct words are still a partial hash | S1 §5, S4; inferred |
| OEM open, wrong SRK hash fused | Cannot be closed with this key set: engineering sample, not secure | Fused words differ from the hash of the image's SRK table; `ahab_status` shows AHAB events on a signed boot | S1 §5–§6, S2 §2.2; inferred |
| OEM open, correct hash, signed boot clean, not closed | Recoverable, **but insecure**: an unsigned or wrongly signed image is reported, not refused | Life cycle OEM open; zero AHAB events | S1 §6–§7 |
| OEM open, key imported with a signature warning | Insecure if carried forward | Warning code `HSM_OEM_OPEN_LC_SIGNED_MSG_VERIFICATION_FAIL` | S3 |
| OEM closed, wrong or partial SRK hash | **Bricked** | Board does not boot any OEM container | S1 §5, §7 |
| OEM closed, correct hash | Done. Recovery of a later key-store failure by re-import is **unconfirmed**: it needs an i.MX 95 import service that is confirmed or validated ([key-recovery-survey.md](../secure-key-handling/key-recovery-survey.md) §3.3) and an off-board master copy, and it costs OTP counter bits | Life cycle OEM closed; zero AHAB events | S1 §7, S3 |
| Strict key-store operation sent, no acknowledgement | Indeterminate: NVM write and counter bit may or may not have happened | Reconcile after a reset (key store opens, key attributes, counter state) before any retry | S3; inferred, vendor recovery rule not confirmed |
| Close interrupted | Unknown | Unknown | Not confirmed |
| Monotonic counter ahead of the stored key store | Key store lost, SoC not bricked | Key-store open fails after reset | S3; inferred, not confirmed |

## 5. Ordering and checks for each irreversible step (input to #99)

Three steps are irreversible: writing the SRK-hash fuses, each strict key-store operation (it blows a monotonic-counter bit), and the life-cycle change to OEM closed. This list describes order and gates. It is not a procedure, and nothing here is to be scripted from it. The steps are survey checks for a future station's design: no lane programs fuses, runs strict key-store operations or closes the life cycle.

1. **Before any fuse write.** First identify the silicon revision, and with it the SRK-hash width and word range (eight words for A0/A1, sixteen for B0; [fuse-map-survey.md](fuse-map-survey.md) §3.1). If the revision cannot be identified, stop. Then read the life cycle and every SRK-hash word of that range, freshly loaded. Go on only if the life cycle is OEM open and every hash word in the range reads either 0 or its expected value. Any other value means scrap (§3.1, §3.3).
2. **Check the hash off the device first.** Recompute the hash of the SRK table embedded in the signed image to be booted, with the revision's hash algorithm and full width (SHA-256 for A0/A1, SHA-512 for B0). Compare it with the fuse words the station is about to write, in the device's word order, not in the form of a host dump (S2 §2.2).
3. **SRK-hash words.** Only words in the revision's range that read 0 are candidates for writing (S4). After a power cycle, read back every word of that range (eight on A0/A1, sixteen on B0) and compare the whole hash with the expected value before going further (S1 §5, S4). A check over eight words passes on half a hash on B0, so it is not enough there. Whether B0 also needs the post-quantum SRK-hash group is **unconfirmed**.
4. **Signed boot check.** Boot the signed image to be shipped and require the life cycle to read OEM open with zero AHAB events (S1 §6). Treat an event as a stop.
5. **Key import, still in OEM open.** Import the wrapped OEM keys and treat only an acknowledged strict operation as done (S3). A missing acknowledgement is an indeterminate update: reconcile state before any retry (§3.2). Treat any warning, the OEM-open signature warning above all, as a failure. Read the key attributes back after a reset. Batch updates so that each device spends few monotonic-counter bits (S3, "NVM writing").
6. **Close last.** Change the life cycle to OEM closed only after steps 1–5 have passed and been recorded on this board, in this power cycle, with no power event since. S1 §7 makes the same three conditions (OEM open, hash fused, clean signed boot) a precondition.
7. **After the close.** Power-cycle, read the life cycle as OEM closed, and require zero AHAB events on the signed image (S1 §7).
8. **Power.** Because the result of losing power during steps 3 and 6 is not confirmed (§3.1), the station should hold the board on a supply it controls through those steps. This is a station design choice, not a source statement.

Whether the key import (step 5) must instead come after the close is not confirmed. SPEC.md's reading of AN14861 lists key exchange and wrapped-key import before the move to OEM closed, but AN14861 itself could not be read in this lane (S5).

## 6. Not confirmed

- Every statement above about the i.MX 95 in particular. All sources read cover the i.MX 93, the i.MX 8ULP or ELE parts in general. The i.MX 95 Reference Manual and Security Reference Manual (fuse map, life-cycle encoding, ECC and lock rules for fuse words) are not public.
- Whether a wrong SRK hash stops the boot in OEM open on the i.MX 95, and whether there is any SRK-hash replacement or revocation path before the close.
- Whether an SRK-hash word that reads 0 can be written in a later session after a partial write, and what a word interrupted mid-write reads as.
- What the enclave does if power is lost during the change to OEM closed.
- What the enclave does if power is lost between the monotonic-counter blow and the NVM write.
- AN14861 (S5): fetched as a PDF from NXP's public site, but the lane has no PDF text tool, so its contents (including its §2, §5.2 and §5.3 cited in SPEC.md) were not read. AN14861 is written for the RT1180 in any case (SPEC.md).
- U-Boot's `ahab_close` and ELE fuse driver source (`arch/arm/mach-imx/ele_ahab.c`, `drivers/misc/imx_ele/fuse.c`) were fetched but not read: the lane's tooling does not allow reading code outside this repository. Whether `ahab_close` checks any precondition itself is therefore not confirmed.

## 7. Questions for the owner

1. **Where does provisioning run?**
   Options: (a) a factory station with controlled power; (b) in the field, on first boot; (c) at the owner's own bench, per unit.
   Recommendation: (a). The two steps whose interruption is not understood (SRK-hash writes and the close, §3.1) should run only where the station controls the supply (§5 step 8).
2. **When is the device closed?**
   Options: (a) at the end of the same station session, after the gates in §5; (b) in a separate later session, after burn-in; (c) never in this phase (development parts stay OEM open).
   Recommendation: (a) for production, gated as in §5 step 6. Every board left OEM open is insecure (§4), and S1 §7 shows no reason to wait once the gates pass.
3. **Key import before or after the close?**
   Options: (a) before, in OEM open; (b) after, in OEM closed; (c) both: the KEK before, operational keys after.
   Recommendation: none until AN14861 and the i.MX 95 Security Reference Manual are read. In OEM open a bad-signature import is only a warning (S3), which argues for (b) or for treating warnings as failures under (a).
4. **What happens to a part found in an unexpected state (a hash word neither 0 nor expected, or AHAB events after fusing)?**
   Options: (a) scrap and record; (b) keep as an engineering sample, marked; (c) retry.
   Recommendation: (b), physically marked and never closed. Sources support no repair (§3.3).
5. **May the lane obtain the non-public i.MX 95 Security Reference Manual and Reference Manual, or a readable AN14861, to close the items in §6?**
   Options: (a) yes, through the private context repository; (b) no, keep the survey public-only.
   Recommendation: (a), for the fuse-word lock rules and the interrupted-close behaviour; #99 should not be finalised without them.
6. **How many monotonic-counter bits may provisioning spend per device?**
   Options: (a) one strict operation per key group, with retries limited by the station; (b) no limit.
   Recommendation: (a). Each strict operation burns OTP, and once the counter is used up, updates lose rollback protection (S3). So the station fails closed: it treats `HSM_KEY_STORE_COUNTER` and every counter warning as a failure, confirms that the counter split is configured and that the counter advanced, and stops provisioning that device rather than accept unprotected updates.
