# Device end-of-life, RMA and decommissioning: survey

Status: draft survey for the owner (issue #72, row `device-lifecycle`).
Documentation only: nothing here runs, scripts or recommends running a fuse,
life-cycle or provisioning step on a board.

## 1. Scope and method

The question (issue #72): what the i.MX 95 and its EdgeLock Secure Enclave
(ELE) offer when a device reaches end of life or comes back as a field return;
how go-trusted-platform's control plane would revoke the device's enrollment
and attested identity; and which steps of a return or decommission cannot be
undone.

Only public sources were used: upstream open-source code on GitHub and NXP's
public GitHub repositories. The i.MX 95 Reference Manual (IMX95RM), the i.MX 95
Security Reference Manual and the ELE API reference manual (RM00284) are
NXP-controlled documents that this lane cannot read; every point that only
those documents can settle is listed in section 7. Every statement below is a
summary in this document's own words, not vendor text. Where a statement is an
inference from code rather than something the code or a document says, it is
marked **inference**.

## 2. Sources surveyed

| # | Source | Version surveyed | URL |
|---|--------|------------------|-----|
| S1 | U-Boot, `arch/arm/mach-imx/ele_ahab.c` (the `ahab_*` commands) | `master` at commit `ece349a` (2026-11-12; newest release tag `v2026.10`) | https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-imx/ele_ahab.c |
| S2 | U-Boot, `drivers/misc/imx_ele/ele_api.c` and `arch/arm/include/asm/mach-imx/ele_api.h` (ELE message calls) | same as S1 | https://github.com/u-boot/u-boot/blob/master/drivers/misc/imx_ele/ele_api.c |
| S3 | NXP `imx-secure-enclave` (ELE HSM / SHE user-space library and `nvm_daemon`): `include/hsm/internal/hsm_lc_update.h`, `hsm_key_store.h`, `hsm_delete_key.h`, `src/common/nvm/nvmd.conf`, `README` | tag `lf-6.18.20-2.0.0` (commit `d7e1180`, 2026-06-09) | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.20-2.0.0 |
| S4 | go-trusted-platform, `docs/device/architecture.md` (device record, lifecycle state machine, operator Disable/Enable) and `docs/SPEC.md` (row `hsm-device-lifecycle`) | `main` at commit `641fd51` (2026-11-11; `VERSION` 0.1.0-alpha, newest tag `v0.1.0-alpha`) | https://github.com/jeremyhahn/go-trusted-platform/blob/main/docs/device/architecture.md |
| S5 | go-trusted-platform, `pkg/webservice/v1/device/boot_service.go` (boot refusal for revoked devices) and `pkg/auth/mtls.go` (mTLS revocation check) | same as S4 | https://github.com/jeremyhahn/go-trusted-platform/tree/main/pkg |
| S6 | go-trusted-platform, `docs/ca/cli.md` (`ca revoke`, `ca crl`) and `pkg/api/rest/ca_handlers.go` (`GET /api/v1/ca/crl`) | same as S4 | https://github.com/jeremyhahn/go-trusted-platform/blob/main/docs/ca/cli.md |
| S7 | go-trusted-platform, `pkg/securewipe/securewipe.go` (file overwrite-and-unlink helper) | same as S4 | https://github.com/jeremyhahn/go-trusted-platform/tree/main/pkg/securewipe |

## 3. i.MX 95 and EdgeLock enclave: life cycle after OEM closed

### 3.1 The life-cycle states the boot firmware knows

U-Boot (S1) reads the life-cycle value from the fuse shadow block (FSB) and
names each one-hot bit. For the i.MX 95 (and the i.MX 94 and i.MX 952) it uses
a different offset and bit map from the older i.MX 8ULP / i.MX 93 parts:

| Bit (i.MX 95) | Name in S1 | Bit (i.MX 93 / 8ULP, for comparison) |
|---------------|------------|--------------------------------------|
| 0x001 | Blank | 0x001 |
| 0x002 | FAB default | (none) |
| 0x004 | FAB | 0x002 |
| 0x008 | NXP provisioned | 0x004 |
| 0x010 | OEM open | 0x008 |
| 0x020 | OEM secure world closed | (none) |
| 0x040 | OEM closed | 0x020 |
| 0x080 | OEM locked | 0x100 |
| 0x100 | Field return OEM | 0x040 |
| 0x200 | Field return NXP | 0x080 |
| 0x400 | Bricked | 0x200 |

Two points follow for the i.MX 95:

- It has a state the older parts lack, *OEM secure world closed*, between OEM
  open and OEM closed. What that state enforces (presumably that the secure
  world is authenticated while the rest is not yet) is not described in S1;
  **unconfirmed** (section 7).
- After OEM closed there are three onward states: *OEM locked*, *field return
  OEM* and *field return NXP*; and a terminal *bricked* state.

### 3.2 How the states are entered

- **OEM open to OEM closed.** U-Boot's `ahab_close` checks that the part is in
  OEM open, warns that a part without the SRK hash fused and a signed image
  that boots cleanly becomes unrecoverable, and then sends the ELE a
  *forward life-cycle update* request (S1, S2). The value U-Boot passes on every
  SoC is 8, the same as on the older parts; whether the i.MX 95 ELE maps that
  value to OEM closed rather than to another state is **unconfirmed**.
- **OEM closed to field return OEM.** U-Boot's `ahab_return_lifecycle` passes
  a *signed message* to the ELE's *return life-cycle update* request (S1, S2).
  The command's help text says the message is signed by the OEM SRK; U-Boot
  checks only the message header tag and then leaves verification to the ELE.
  So entering field return needs the OEM's signing key (or a key in its SRK
  table) to sign a device-addressed message; **inference**: the message is
  bound to one device (for example by its unique ID), as it is on other NXP
  parts, but S1 and S2 do not show the payload, so this is **unconfirmed**.
- **OEM locked, field return NXP, bricked.** S1 and S2 name these states but
  contain no command that enters them. Field return NXP is, by its name, the
  state NXP's failure analysis puts a part in; how it is entered, and whether
  an OEM must first be in field return OEM, is **unconfirmed**.

### 3.3 Life-cycle change from Linux

NXP's user-space library (S3) has an HSM call, `hsm_lc_update`, that asks the
enclave for a new life-cycle state. Its enum lists NXP provisioned, OEM open,
OEM closed, OEM field return, NXP field return and OEM locked, with bit values
that match neither table in 3.1 (they appear to be the request encoding, not
the fuse value). So the API surface suggests a Linux process can request a
move to OEM locked or a field-return state; whether the i.MX 95 ELE firmware
accepts each request from the Linux messaging unit, and what authorisation it
asks for, is **unconfirmed** (RM00284 is needed).

## 4. Keys, debug access and the enclave key store at end of life

### 4.1 Where the enclave key store lives

S3 shows that the ELE HSM key store is not held only inside the enclave:

- A key store is created or loaded through a key-store service. Its contents
  are kept by the user-space `nvm_daemon`, which writes the blob the enclave
  hands it to the Linux file system; the default configuration names
  `/etc/ele/` and a master file under it (S3, `nvmd.conf`).
- Key-store create, and key delete, have a *strict* (newer firmware: *sync*)
  flag: the call returns only when the updated store has been written out. A
  *monotonic* flag, with strict, also makes the call wait for the enclave's
  monotonic counter to advance, which is the store's rollback protection (S3,
  `hsm_key_store.h`, `hsm_delete_key.h`).
- Closing a key-store session drops the in-enclave copy; anything not yet
  written out is lost (S3).
- NXP's own test instructions reset the HSM between runs by stopping the
  daemon and deleting the storage directory (S3, `README`). That is a test
  procedure, not a documented secure-erase.

**Inference** from the above: the stored blob is protected by a key the enclave
derives inside the chip, so a copied blob is of no use on another part; and
deleting every key with the strict flag, then deleting the blob, leaves
nothing on the board that the enclave can reload. Neither point is stated in
S3; the blob's protection key, and whether a deleted store's counter state
can be rolled back, are **unconfirmed**.

### 4.2 What the life-cycle states do to keys and debug

None of S1 to S3 says what a field-return or locked state does to keys or
to debug. In particular, the following are **unconfirmed** for the i.MX 95:

- whether entering *field return OEM* changes the enclave's device-unique
  derived keys, so that key-store blobs and wrapped OEM keys (the
  oem-key-provisioning row) no longer open;
- whether field return re-opens JTAG / debug, and whether it still enforces
  signed boot with the OEM SRK;
- what *OEM locked* forbids (by its name, further life-cycle moves, and
  presumably field return) and whether it is reversible by anyone;
- what *bricked* means in practice and how a part reaches it.

These are the facts IMX95RM, the i.MX 95 Security Reference Manual and RM00284
are expected to hold; see section 7. Until they are read, the survey treats a
field-return state as one that may expose the board to NXP or OEM failure
analysis and must not be relied on to erase secrets: the erasure has to be
done in software first (section 6).

## 5. go-trusted-platform: revoking enrollment and attested identity

go-trusted-platform's `hsm-device-lifecycle` row, which is the control-plane
side of this row, is marked *future, not started* (S4, `docs/SPEC.md`). There
is no HSM-device or i.MX 95 specific code to survey. What exists is the
generic device machinery that the row would reuse:

- **Device record and states.** Enrollment (today, TPM attestation through
  ACME) saves a device record whose state moves through a closed table:
  registered, installing, installed, activated, attested; with quarantined
  and suspended as recoverable side states and **revoked as terminal**, with
  no transition out (S4 §4.3, §6). A revoked device cannot be re-admitted
  under the same record.
- **What revoked does today.** The boot service refuses boot credentials to a
  device in revoked or suspended state (S5). Suspended is reachable by an
  operator verb (*Disable*) that first blocks the device's switch port; S4
  §4.6 describes Disable and Enable only, and the generic update refuses to
  write a state. S4 names no operator verb that moves a device to revoked;
  how a device reaches it is **unconfirmed** from the docs read.
- **Attested identity.** The device's identity certificates (IAK and IDevID
  in the TPM case) are issued by the platform CA. The CA has a certificate
  revoke command with a reason code and publishes a CRL (S6); the mTLS
  adapter checks a client certificate against the CA and rejects one the CA
  reports revoked (S5, `pkg/auth/mtls.go`). So revoking the attested identity
  is a CA operation on each certificate serial the device holds, separate
  from the device-record state.
- **Local secret disposal.** go-trusted-platform has a helper that overwrites,
  fsyncs, unlinks and TRIMs a file that held key material (S7). It is written
  for the installer's key container on an x86 ESP, not for the ELE store, but
  is the closest existing pattern for removing the `nvm_daemon` blob (4.1).

**Inference**, for the owner: for an i.MX 95 HSM device the control plane
would decommission in two halves that must both happen: (a) revoke every
certificate the platform CA issued to the device (its attested identity, and
any TLS or enrollment certificate) so that relying parties reject it via the
CRL; and (b) move the device record to revoked so boot, config and admission
are refused. Neither half touches the board; they hold even for a board that
never comes back. The attestation evidence for the i.MX 95 (what replaces the
TPM's EK and IAK) is itself an open question in this repository's SPEC, so
which serials (a) revokes is open too.

## 6. Return and decommission steps, and which are irreversible

The table is this survey's synthesis of sections 3 to 5. It describes steps
only; it is not a procedure, and no step is run or scripted by this
repository.

| # | Step | Where | Reversible? | Basis |
|---|------|-------|-------------|-------|
| 1 | Suspend the device (block its port, refuse boot credentials) | control plane | yes (Enable, then re-attest) | S4 §4.6, S5 |
| 2 | Export or re-wrap any key that must outlive the device (if policy allows any) | board, ELE | n/a; impossible once step 3 runs | S3; key export policy is the secure-key-handling row's |
| 3 | Delete every ELE key-store key with the strict/sync flag, close the store, remove the `nvm_daemon` storage directory | board, Linux + ELE | **no**: the keys are gone | S3; secure-erase property **unconfirmed** (4.1) |
| 4 | Revoke the device's certificates at the platform CA; publish the CRL | control plane | **no**: a revoked serial stays revoked; a re-enrolled device gets new serials | S6 |
| 5 | Move the device record to revoked | control plane | **no**: terminal state | S4 §4.3, §6 |
| 6a | Decommission: wipe the rest of the board's storage (eMMC, RPMB) | board | **no** | not surveyed here (RPMB row, #62) |
| 6b | Field return: move the life cycle to *field return OEM* with an OEM-SRK-signed message | board, ELE | **no**: no surveyed command moves the life cycle back (section 7, item 9) | S1, S2; effects **unconfirmed** (4.2) |
| 6c | Retire for good: move to *OEM locked* (if that is what it does) | board, ELE | **no** | S3 enum only; effects **unconfirmed** |
| 7 | Remove the device's serial from any fleet allow-list or EAB record | control plane | yes | S4 (generic) |

Order matters: steps 3 and 4 come before the board leaves the owner's hands,
because 6b may expose the part to failure analysis and nothing surveyed says
it erases anything. The irreversible board-side steps are 3, 6a, 6b and 6c;
the irreversible control-plane steps are 4 and 5.

## 7. What could not be confirmed

Each of these needs a document the lane could not read (IMX95RM, the i.MX 95
Security Reference Manual, RM00284 ELE API reference, all NXP-controlled), or
the go-trusted-platform `hsm-device-lifecycle` design, which does not exist
yet.

1. What *OEM secure world closed* enforces on the i.MX 95 (3.1).
2. Which value the i.MX 95 ELE expects in the forward life-cycle request to
   reach OEM closed, given U-Boot passes the same value on every SoC (3.2).
3. The format of the field-return signed message and what binds it to one
   device (3.2).
4. How *field return NXP*, *OEM locked* and *bricked* are entered, and by whom
   (3.2, 3.3).
5. Whether field return changes the device-unique keys, re-opens debug, or
   keeps signed boot (4.2).
6. Whether deleting the `nvm_daemon` blob is a secure erase of the key store,
   and how the monotonic counter treats a deleted store (4.1).
7. Which go-trusted-platform operation moves a device record to revoked (5).
8. NXP's public web site answered from the lane, but this survey did not
   find or read a public NXP application note on i.MX 95 field return or
   decommissioning; if one exists it should be added as a source.
9. That life-cycle changes are one-way. Every command in S1 to S3 moves the
   state forward only and none moves it back, which is the basis for marking
   6b and 6c irreversible; the fuse-level guarantee is **unconfirmed**.

## 8. Questions for the owner

1. **What does end of life mean for a board: scrap, field return, or both?**
   Options: (a) scrap only, never return a part to NXP; (b) field return
   allowed for failure analysis; (c) both, decided per incident.
   Recommendation: (a) until question 5's facts are confirmed, because field
   return's effect on keys and debug is unknown (section 7, items 3 to 5).
2. **Is the key-store wipe (step 3) mandatory before a board leaves the
   owner's custody?** Options: (a) yes, always; (b) only for scrap; (c) no,
   rely on the life-cycle change. Recommendation: (a): it is the only erase
   step the public sources describe, and the life-cycle change is not shown to
   erase anything (4.1, 4.2).
3. **May any key outlive its device (step 2)?** Options: (a) no key ever
   leaves the enclave, so decommission destroys all; (b) only keys the
   secure-key-handling row marks exportable, re-wrapped to a successor.
   Recommendation: (a), unless the hsm-device-protocol row needs key
   migration; no source here supports either over the other.
4. **Which control-plane record is the revocation of record?** Options: (a)
   the CA's CRL entry; (b) the device record's revoked state; (c) both,
   with the CRL first. Recommendation: (c): the two cover different relying
   parties (certificate holders versus the control plane's own admission),
   and both are terminal (S4, S6).
5. **Should the board ever enter OEM locked?** Options: (a) never; (b) at
   manufacture, after OEM closed, to prevent field return; (c) at
   decommission, as a final step. No recommendation: what OEM locked does on
   the i.MX 95 is unconfirmed (section 7, item 4); answer after IMX95RM is
   read.
6. **Who holds the authority to sign a field-return message?** Options: (a)
   the same offline SRK holder that signs boot images; (b) a separate
   ceremony with two-person control; (c) nobody (field return disabled by
   policy). Recommendation: (b) if question 1 allows field return, because the
   message needs an OEM SRK signature (3.2) and an SRK signing is a
   high-value event; otherwise (c).
7. **Where should the decommission procedure live?** Options: (a) in this
   repository as a documented runbook only; (b) as a go-trusted-platform
   `hsm-device-lifecycle` verb that drives steps 1, 4, 5 and 7 and asks the
   board for step 3; (c) both. Recommendation: (c): the control-plane steps
   belong in go-trusted-platform (S4), and the board-side wipe needs a
   documented runbook here; neither is scripted until the owner approves.
