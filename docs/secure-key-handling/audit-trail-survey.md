# Tamper-evident audit trail of key use and signing: survey

Row: secure-key-handling (#17). Issue: #82. Status: survey for the owner. Nothing here is a decision.

## 1. Question

The threat model (#48) asks how the board can show, after the fact, which key signed what, at whose request and when. This survey looks at ways the board could keep a tamper-evident record of each key use and signing operation, how that record leaves the board for go-trusted-platform or go-xkms to check, and what is left of it after a reboot, a power cut or a tamper response. It does not choose go-xkms's protocol (SPEC.md, `hsm-device-protocol` row). It does not run or script any fuse, life-cycle or provisioning step.

"Tamper-evident" here means that a verifier can detect a record that has been removed, reordered or changed. It does not mean the record cannot be destroyed. No design in this survey stops an attacker with root on the Linux side from deleting the log. The aim is that a deletion is visible to a verifier and cannot be hidden.

## 2. Sources surveyed

All sources are public. Versions are those fetched on 2026-11-12.

| # | Source | Version | URL |
|---|---|---|---|
| S1 | NXP `imx-secure-enclave` (ELE HSM API library, headers `include/hsm/`, README) | tag `lf-6.6.52-2.2.2`, `se_version.txt` 1.1.1 | https://github.com/nxp-imx/imx-secure-enclave |
| S2 | Schneier and Kelsey, "Secure Audit Logs to Support Computer Forensics", ACM TISSEC 2(2) | 1999 | https://www.schneier.com/academic/archives/1999/01/secure_audit_logs_to.html |
| S3 | Crosby and Wallach, "Efficient Data Structures for Tamper-Evident Logging", USENIX Security | 2009 | https://www.usenix.org/legacy/event/sec09/tech/full_papers/crosby.pdf |
| S4 | RFC 9162, Certificate Transparency Version 2.0 | RFC, December 2021 | https://www.rfc-editor.org/rfc/rfc9162 |
| S5 | OP-TEE documentation, "Secure storage" (REE FS and RPMB FS) | `latest` build of optee.readthedocs.io; newest optee_os tag at the time is 4.11.0 | https://optee.readthedocs.io/en/latest/architecture/secure_storage.html |
| S6 | Linux kernel documentation, "IMA Template Management Mechanism" | docs.kernel.org, built from 7.4.0-rc2 | https://docs.kernel.org/security/IMA-templates.html |
| S7 | systemd `journalctl(1)`, Forward Secure Sealing options | systemd 262 | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| S8 | go-trusted-platform README | `main` at 641fd51b21fa (newest tag `v0.1.0-alpha`) | https://github.com/jeremyhahn/go-trusted-platform |
| S9 | go-xkms README | `main` at d55b1b73c78f | https://github.com/jeremyhahn/go-xkms |
| S10 | RFC 9334, Remote ATtestation procedureS (RATS) Architecture | RFC, January 2023 | https://www.rfc-editor.org/rfc/rfc9334 |

S2's page on schneier.com returned 404; the paper's PDF at https://www.schneier.com/wp-content/uploads/2016/02/paper-auditlogs.pdf was reachable. The paper's scheme is summarised from the paper's well-known design; this lane did not re-read the PDF line by line (§8).

## 3. What an audit record must carry

The issue asks for "which key, which request, when". A record that answers that, and that a verifier can chain, needs at least:

- a sequence number that increases by one per record;
- the hash of the previous record (the chain link, §4.1);
- the key: its key store and key identifier in the enclave (S1 names keys by key store handle and a 32-bit key identifier), and, for a signing key, a digest of its public key so a verifier need not trust the identifier;
- the operation (generate, import, sign, verify, delete, key store update) and its result code;
- the request: a digest of the message or digest that was signed, and the identity of the caller (go-xkms's request identifier when one is given; the local process otherwise);
- the time: the board's clock at the time, and the boot counter (§6), because the board's clock is not trusted on its own (see the trusted-time survey, #77).

Whether the record should hold the signed digest itself or only a hash of it is a privacy question (Q4).

## 4. Building blocks on the device

### 4.1 Hash-chained and signed logs

Schneier and Kelsey (S2) describe a log on an untrusted machine in which each entry is chained to the one before it by a hash and authenticated by a MAC whose key is replaced by a one-way hash of itself after each entry. Because the old key is destroyed, an attacker who takes the machine later cannot forge or change entries written before the take-over; they can only cut the log short or stop writing it. A verifier that knows the first key can check the whole chain.

Crosby and Wallach (S3) replace the linear chain with a history tree, a Merkle tree that grows by appending. The logger publishes a signed commitment to the tree root after each append or batch. A verifier can then ask for a short proof that an entry is in the log and that a newer commitment extends an older one, without reading the whole log. Certificate Transparency (S4) standardises the same idea: a signed tree head over an append-only Merkle tree, with inclusion and consistency proofs, checked by independent monitors.

What this means for the board:

- A plain hash chain is enough to show reordering or editing. It shows a cut only if the verifier holds a later commitment (a chain head) than the one on the board. So the board must send chain heads off the board often (§5).
- The chain head is signed by an enclave key used only for audit (an ELE key whose usage is restricted to signing, S1 `hsm_key.h` key usage flags). A usage flag limits what the key may do, not which process may ask the enclave to do it: any caller with access to the key store session, a root-capable Linux process included, can have the enclave sign with it. The key not being extractable keeps it on the board, but it does not make the logger the key's only user, and it does not by itself make deletions visible. A root-capable attacker can drop the records written after the verifier's last accepted head, build a fabricated extension of that head, and have the enclave sign it; the §5 check that a new head extends the stored one passes on it.
- So, with a logger on Linux, a signed head protects only history already committed to an independent verifier (the heads it has accepted): editing, reordering or cutting that history is visible (S3, S4). Records after the last accepted head have no protection against Linux root. Protecting them needs a logger isolated from Linux root that holds exclusive authorization to use the audit key, for example an OP-TEE trusted application or the Cortex-M7 holding the only key store session that can use it. Whether the i.MX 95 enclave can restrict a key's use to one caller or one execution domain is **unconfirmed**: no source read here shows such a mechanism (§8).
- The forward-secure MAC of S2 needs a key that is destroyed after use. A key held by the Linux side and ratcheted in RAM gives that property only for entries written before the attacker arrived. An enclave key cannot be ratcheted in that way through the HSM API in S1, as far as this survey found (§8).

### 4.2 Anchoring in the enclave's monotonic counter

S1 exposes the monotonic counter in two places:

- `hsm_dev_mono_counter` partitions the counter's fuse words between the ELE HSM and the V2X HSM and SHE. The header says this can be issued once per device. If no partition has been written to the fuses, counter operations return a warning and give no rollback protection. This is a fuse step; this lane does not run or script it, and the owner's oem-key-provisioning row (SPEC.md) owns it.
- The key store flags: with the monotonic flag and the strict-operation flag set, a key store update completes only when the counter has been advanced (`hsm_key_store.h`). The header notes that newer ELE firmware renames strict to sync.

S1 does not show an API that lets an application read or advance the counter for its own use, separate from a key store update (§8).

What this means for the board:

- The counter is made of fuse words, so each advance burns fuse bits, and the count of advances in the board's life is bounded. The exact count on the i.MX 95 is in the Security Reference Manual, which is missing (SPEC.md; §8). The counter cannot be advanced once per log record.
- What the counter can do is tie the audit chain to the key store's version. If the logger writes the current chain head into the record of each strict key store update (key generate, import, delete), a rollback of the key store blob to an older copy is expected to be refused by the enclave (only while the counter is configured and still advancing, which the caller must confirm and treat any counter warning as a failure; [monotonic-counter-survey.md](monotonic-counter-survey.md) §4), and a rollback of the log past the last strict update is visible because the verifier can compare the log against the key store's state. Signing does not update the key store, so it does not advance the counter.
- The key store blob itself is written by NXP's NVM daemon to a directory on the Linux file system (`/etc/ele/` for the ELE on i.MX 95, S1 README Table 2). The enclave encrypts and authenticates it; the counter guards it against rollback. The audit log would sit beside it, not inside it.

The enclave's data storage service (S1 `hsm_data_storage.h`) stores small data objects under the key store. Writing each chain head there would cost a key store write. Whether it advances the counter on every write is not stated in the header (§8).

The enclave also reports an event list: the events the firmware has raised since the last power cycle, each with a command id and response code (S1 `hsm_get_event.h`). The list is cleared by a power cycle, so it cannot carry a trail, but the logger can read it at start-up and log it.

The enclave's device attestation (S1 `hsm_dev_attest.h`) returns the SoC id and revision, the life cycle, the firmware hash, the OEM SRK hash and a nonce supplied by the caller, signed by the enclave. A verifier can use it to know the board's enclave firmware, life cycle and OEM SRK hash. It does not tie a chain head to the attestation (the head is signed by a different key), and it says nothing about the Linux image, the IMA list or the logger, so it does not show which software wrote or signed the head (§4.4, §5).

### 4.3 Anchoring in the eMMC RPMB

An eMMC's Replay Protected Memory Block is a small partition whose writes are authenticated by an HMAC under a key programmed once into the device, and carry a write counter kept by the eMMC, so an old write cannot be replayed (S5). OP-TEE uses it in two ways (S5):

- the RPMB file system (`CFG_RPMB_FS=y`) stores trusted application objects in the RPMB itself. OP-TEE states its rollback protection level as 1000 (hardware controlled by the TEE) with RPMB and 0 without it;
- with both the REE file system and RPMB enabled, OP-TEE keeps a hash of the REE file system's state in an RPMB file (`dirfile.db.hash`), so files kept in the Linux file system cannot be rolled back either.

S5 says a single-block RPMB write is atomic by the eMMC specification, and that OP-TEE updates a file's FAT entry last, so a file operation is atomic.

What this means for the board:

- A small trusted application could hold the audit chain's head (sequence number and head hash) in RPMB and update it on each record or each batch. Unlike the fuse counter, the RPMB write counter is not a fuse, so updating it per record is possible; eMMC wear and write latency are the limits (not quantified here, §8). The log body stays in a Linux file; the RPMB head makes a rollback or truncation of that file visible on the board itself, before any export.
- The RPMB key is written once to the eMMC. S5 describes OP-TEE deriving it from the eMMC serial number and the Hardware Unique Key, and warns that using RPMB before the board is secured can lock out later access once it is. This is a provisioning step that this lane does not run or script; the RPMB survey (#62) and the oem-key-provisioning row own it.
- Whether the FRDM-IMX95-PRO's boot medium has an RPMB partition that OP-TEE can reach, and whether NXP's OP-TEE for the i.MX 95 enables `CFG_RPMB_FS`, was not confirmed from public sources in this lane (§8).
- The Linux kernel has an RPMB subsystem in recent releases; its documentation page was not reachable from this lane (§8).

### 4.4 The Linux IMA measurement log

IMA appends a measurement entry for each file or buffer its policy selects; the template sets what each entry holds, from the file hash and name (`ima-ng`, the default) to its signature (`ima-sig`) or the buffer itself (`ima-buf`) (S6). On a board with a TPM each entry is also extended into a PCR, and a verifier checks the list against a TPM quote. go-trusted-platform is built around that TPM model (S8).

What this means for the board:

- IMA measures what the kernel loads or reads under policy, not application events. It is not a place to record key use or signing requests.
- The measurement list lives in kernel memory and starts again on each boot. Without a TPM it has no hardware anchor. SPEC.md does not list a TPM on the board; it lists the enclave and an SE051 secure element. Whether the SE051 could serve as an anchor is an open question in SPEC.md and is not taken up here.
- IMA can measure the audit logger's binary and configuration, but on this board that measurement is **not attested**. The enclave's device attestation (§4.2) covers the SoC id and revision, the life cycle, the enclave firmware hash, the OEM SRK hash and the caller's nonce. It does not cover the IMA list, the Linux image or the logger. A compromised kernel can present a substituted IMA list beside a perfectly valid attestation, and presenting the two together is not a TPM PCR quote: nothing binds the list to the signed evidence. So the logger's identity is not attested by any evidence surveyed here, and a verifier cannot learn from it which logger wrote the trail.
- That guarantee is unavailable until an isolated measurement path cryptographically binds the measurements into authenticated evidence: for example a component outside Linux's control that extends a register or counter the enclave signs over, or an enclave attestation call that takes caller-supplied measurement data. No such mechanism is shown for the i.MX 95 in the sources read here; any such mechanism is **unconfirmed** (§8).

### 4.5 Linux-only sealing (journald FSS)

systemd's journal can seal its files with Forward Secure Sealing: a sealing key kept on the host evolves at a set interval, and a verification key kept elsewhere checks the seals (S7, `--setup-keys` and `--verify-key`). It is the S2 idea applied to the journal. Its sealing key is a file on the host, so it protects only the entries sealed before an attacker gained root, and it does not use the enclave. It is the cheapest option and the weakest.

## 5. How the trail leaves the device

Neither go-trusted-platform's README (S8) nor go-xkms's README (S9) describes an intake for a device audit trail. go-xkms's README says that event systems are outside the library's scope and belong to consuming applications. The format below is therefore a proposal for the owner, not a protocol; the transport is go-xkms's to choose (SPEC.md `hsm-device-protocol` row).

A transport-neutral export bundle could carry:

1. the records after the sequence number the verifier last acknowledged;
2. a signed head over the chain (or tree root, S3, S4): sequence number, head hash, boot counter, board time, and a nonce the verifier sent, signed by the enclave audit key;
3. when the verifier asks, an enclave device attestation over the same nonce (S1 `hsm_dev_attest.h`), so the verifier knows the board's life cycle, enclave firmware hash and SRK hash at the time of the nonce. It does not attest the Linux image, the IMA list or the logger, so it is not evidence of which logger produced the head (§4.4). In RATS terms (S10) the board is the attester, the bundle is the evidence, and go-trusted-platform or go-xkms is the verifier.

The verifier keeps the newest head it has accepted. A later bundle must extend it: for a linear chain the verifier recomputes the chain from its stored head; for a tree, a consistency proof does the same with less data (S3, S4). A board that shows a shorter chain, or a head that does not extend the stored one, has lost or rewritten records. The check covers only history up to the stored head: if Linux root can use the audit key, a fabricated extension of the stored head passes it (§4.1).

The audit key's public key and an attestation are exported at enrolment, so heads can still be checked after the key is gone (§6).

Pull (the verifier asks, with a nonce) gives freshness. Push (the board sends after each signing) keeps the window between a signing and the verifier's copy small. Q3 asks which.

## 6. What survives a reboot, a power cut or a tamper response

| Event | Lost | Kept | Source |
|---|---|---|---|
| Reboot | IMA list; enclave event list; records not yet written to storage | log file and key store blob on the file system; RPMB head; heads already exported | S1, S5, S6 |
| Power cut | the record being written, if it was not flushed; possibly a torn tail of the log file | RPMB writes are atomic per block (S5); the key store's state as of the last strict update (S1) | S1, S5 |
| Tamper response | not confirmed for the i.MX 95 (§8). If the response erases the enclave's keys, the audit key goes too, and no new head can be signed | heads and the audit public key already exported; the log file, if storage is not wiped | — |

To keep a power cut from looking like tampering, the logger writes and flushes the record first, then updates the head (RPMB or signed head). At start-up the log may be at most one record ahead of the head, never behind it. The logger then appends a "boot" record that carries the enclave's event list (S1 `hsm_get_event.h`) and a boot counter. A boot counter needs persistent, rollback-protected storage; the RPMB head can carry it.

What the enclave does on a tamper event on the i.MX 95, and what it erases, is in the Security Reference Manual, which is missing (SPEC.md). The hsm-self-defence tamper survey (#44) covers it; that file is not on main, so this survey does not depend on it.

## 7. Options

| Option | What it is | Detects | Needs | Cost |
|---|---|---|---|---|
| A | Hash-chained log file on Linux; heads signed by an enclave audit key; heads exported (§5) | edits, reordering and truncation of history already committed to the verifier (heads it accepted); nothing after the last accepted head if Linux root can use the audit key (§4.1) | one enclave signing key for audit | low |
| B | A, plus the head in RPMB through an OP-TEE trusted application | truncation and rollback on the board, before export, only if the trusted application itself is the logger with exclusive use of the audit key; a head fed by a Linux logger can be fed fabricated records | RPMB key programmed (provisioning); OP-TEE with RPMB on the i.MX 95 (unconfirmed); exclusive key use by the TA (unconfirmed, §8) | medium |
| C | A, plus the head written into each strict key store update | rollback of the log past the last key generate, import or delete; signing-only activity after that update has no counter anchor | the counter fuse partition (provisioning); fuse wear | low, but coarse |
| D | A or B with a Merkle tree (S3, S4) instead of a linear chain | the same as A or B | more code in the logger and the verifier | medium |
| E | journald Forward Secure Sealing only (S7) | edits before a compromise | nothing from the enclave | lowest; weakest |
| F | IMA as the trail | — (not fit: IMA does not record application events, S6) | — | — |

C costs nothing extra on the counter, because the strict updates it rides on happen anyway; it only adds the head to records that are written already.

Recommendation, where the sources support one: start with A and C together, with a linear chain, and claim for it only what it gives with a logger on Linux: protection of history already committed to the verifier. Protection of records after the last accepted head needs an isolated logger with exclusive use of the audit key (Q2), which is unconfirmed on this device (§8). Add B when the RPMB question (#62) is settled. IMA may measure the logger locally, but no evidence surveyed attests that measurement, so no claim about the logger's identity is made to a verifier (§4.4). Move to D if the trail grows large enough that sending the whole chain to the verifier is a problem.

## 8. What could not be confirmed

- The number of monotonic counter advances the i.MX 95's fuses allow, and whether `hsm_data_storage` advances the counter on each write: in the Security Reference Manual, which is missing.
- Whether S1 has an application-usable counter read or increment apart from key store updates: none was found in the headers at `lf-6.6.52-2.2.2`.
- What the enclave erases on a tamper response on the i.MX 95.
- Whether NXP's OP-TEE for the i.MX 95 enables the RPMB file system, and whether the board's eMMC RPMB is reachable from OP-TEE.
- The Linux kernel RPMB subsystem documentation: the page https://docs.kernel.org/next/misc-devices/rpmb.html returned 404.
- RPMB write endurance and latency for the board's eMMC: the JEDEC eMMC specification is not public.
- S2: the schneier.com archive page returned 404; the PDF was reachable but was not re-read in full for this survey.
- Whether the i.MX 95 enclave can limit the use of a key to one caller, one key store session or one execution domain (for example OP-TEE or the Cortex-M7), so that an isolated logger has exclusive use of the audit key. S1's key usage flags restrict operations, not callers; no source read here shows such a mechanism.
- Any mechanism on the i.MX 95 that cryptographically binds an IMA or logger measurement into authenticated evidence, outside Linux's control. The enclave's device attestation fields in S1 do not include such data (§4.2, §4.4).
- Any intake for an audit trail in go-trusted-platform or go-xkms: their READMEs (S8, S9) describe none; their source was not searched.

## 9. Questions for the owner

1. **Which audit design should the board use?** Options: A, A+C, A+B(+C), D, E (§7). Recommendation: A+C now, add B after #62 is settled; not E alone, not F (IMA's measurement of the logger is not attested on this board, §4.4).
2. **Where does the logger run?** It must sit on the only path to the enclave's HSM API, so it follows SPEC.md's open question of which core calls that API. Options: (a) Cortex-A55 Linux, in the daemon that calls the HSM API; (b) the Cortex-M7, with the trail stored through Linux; (c) an OP-TEE trusted application. Recommendation: put the logger in the same component that holds the HSM session, whichever core the owner picks for it. With (a), the trail protects only history already committed to the verifier, because Linux root can use the audit key (§4.1); (b) or (c) protects later records only if that component has exclusive use of the audit key, which is unconfirmed on this device (§8).
3. **How does the trail leave the board?** Options: (a) the verifier pulls, with a nonce; (b) the board pushes after each signing; (c) both. Recommendation: (c), a push after each signing and a pull with a nonce for freshness (§5). The transport is go-xkms's decision.
4. **What does a signing record hold about the request?** Options: (a) the signed digest; (b) a hash of the signed digest; (c) only go-xkms's request identifier. Recommendation: (b) together with the request identifier when one is given, so that the trail does not hold the signed content but a verifier holding the request can still match it.
5. **What happens when the trail cannot be written?** For example: storage is full, or the RPMB head cannot be updated. Options: (a) refuse to sign (fail closed); (b) sign and raise an alarm (fail open). Recommendation: (a), because a signing with no record defeats the trail; no source decides this.
6. **Is a separate enclave key for audit acceptable?** Options: (a) a dedicated audit signing key in the enclave; (b) reuse the device identity or attestation key. Recommendation: (a), so that the audit key signs nothing but heads (S1 key usage flags) and its use can itself be logged. The usage flags do not restrict which caller uses the key (§4.1).
7. **After a tamper response, should the board start a new trail under a new audit key, or stay out of service until it is re-enrolled?** Recommendation: none until the i.MX 95 tamper behaviour is confirmed (§8, #44).
