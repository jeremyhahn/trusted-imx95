# secure-key-handling: architecture

> **Status: DRAFT, awaiting the owner's approval** · Scope: trusted-imx95 · Last verified: 2026-11-12

The detail behind the `secure-key-handling` row of [SPEC.md](../SPEC.md): where the board's keys live, what protects
the key store, which enclave services the board uses, and what each open choice needs from the references. It
decides nothing the owner has not decided; the open choices are under [Open questions](#open-questions).

## Sources

The sources are RM00284 (EdgeLock Enclave Hardware Security Module API, Rev. 4.5) and UM12527 (FRDM-IMX95-PRO
Board User Manual, Rev. 1.0), indexed in [references/README.md](../references/README.md#nxp-documents-and-the-code-signing-tool-private-context-repository).
The vendor repository could not be read when this file was written. Every fact below is therefore given as the
SPEC row cites it, and each is listed under [Missing](#missing) as not yet checked against the document.

## Where the keys live

The board's keys are generated and held in the key store of the EdgeLock secure enclave, and never leave it in
the clear (RM00284 §2.4, §3.2). The enclave is the trust boundary: no core, operating system or file system holds a
key in the clear, and what crosses the boundary is a request through the HSM API and its result (RM00284 §2.4,
§3.2). This is what trusted-firmware's `imx95` row requires of the key tier ([SPEC.md](../SPEC.md), row
`secure-key-handling`).

## Key store rollback protection

An update to the key store counts only after an operation carrying the strict-operation flag is acknowledged. That
operation also advances the monotonic counter that protects the stored key store from rollback (RM00284 §2.4.2). An
update made without the flag, or not yet acknowledged, is not a committed update (RM00284 §2.4.2).

The monotonic counter fuses are configured once, during provisioning; that belongs to the `oem-key-provisioning`
row (RM00284 §3.24, as cited by that row in [SPEC.md](../SPEC.md)).

## Enclave services the board uses

| Need | HSM API service | Source |
|---|---|---|
| Sign with a key held in the enclave | Signing | RM00284 §3.4 |
| Store data under the enclave's protection | Data storage | RM00284 §3.8 |
| Prove the device's state to a verifier | Attestation | RM00284 §3.12 |
| Key store and key management | Key store, key management | RM00284 §3.2 |

The Generic Crypto APIs are not available on the i.MX 95; nothing in this feature may depend on them
(RM00284 §3.45).

## The calling side

Which side calls the HSM API is the owner's choice. The i.MX 95 has six Cortex-A55, one Cortex-M33, one Cortex-M7
and the EdgeLock secure enclave ([references/README.md](../references/README.md#the-device), from UM12527). The
Cortex-M33 runs NXP's System Manager, which stays NXP's code ([SPEC.md](../SPEC.md), row `system-manager-config`).
The candidates are the Cortex-A55 Linux side and the Cortex-M7 ([SPEC.md](../SPEC.md), row `secure-key-handling`).

| Choice | What it needs from the references | Where the references stand |
|---|---|---|
| Cortex-A55, Linux | The enclave's HSM API (RM00284 §3.2, §3.4, §3.8, §3.12); a path from Linux to the enclave; the TrustZone configuration that decides whether the caller runs in the secure or the normal world | The HSM API is in RM00284. The A55 path to the enclave and the TrustZone configuration are under [Missing](#missing); the latter is the `secure-world` row's open question ([SPEC.md](../SPEC.md)) |
| Cortex-M7 | The same HSM API (RM00284 §3.2, §3.4, §3.8, §3.12); a path from the M7 to the enclave; the resources the System Manager grants the M7 ([SPEC.md](../SPEC.md), row `system-manager-config`) | The HSM API is in RM00284. The M7 path to the enclave and the System Manager's resource grants are under [Missing](#missing) |

Under either choice the keys stay in the enclave's key store (RM00284 §2.4, §3.2) and the rollback rule holds
(RM00284 §2.4.2).

## The SE051 secure element

The board also carries an NXP SE051 secure element: U28, on I2C2 at address 0x48, with the J4 control header
(UM12527 §1.1, §1.5 Table 3, §2.5 Table 9). Whether it holds any key, and its role beside the enclave, is the
owner's choice (see [Open questions](#open-questions)). A role for it needs the SE051's own documentation, which is
under [Missing](#missing).

## What this feature does not do

- It does not provision OEM keys, close the life cycle or configure the counter fuses: that is the
  `oem-key-provisioning` row (AN14861 §2, §5.2, §5.3; RM00284 §3.20, §3.23, §3.24, as cited by that row in
  [SPEC.md](../SPEC.md)).
- It does not define the protocol between xkmsd and the board: that is the `hsm-device-protocol` row, which go-xkms
  defines ([SPEC.md](../SPEC.md), row `hsm-device-protocol`).
- It does not hold the container signing keys: their custody in an HSM is go-xkms's (AN14471, as indexed in
  [references/README.md](../references/README.md#nxp-documents-and-the-code-signing-tool-private-context-repository)).

## Missing

- **Not checked against the documents.** The vendor repository could not be read, so none of these was checked:
  RM00284 §2.4 and §3.2 (keys generated and held in the enclave, never in the clear); RM00284 §2.4.2
  (strict-operation flag, acknowledgement, monotonic counter); RM00284 §3.4, §3.8, §3.12 (signing, data storage,
  attestation); RM00284 §3.45 (no Generic Crypto APIs on the i.MX 95); UM12527 §1.1, §1.5 Table 3, §2.5 Table 9
  (SE051, U28, I2C2, 0x48, J4). Each needs a reader with access to confirm the section numbers and the facts.
- **IMX95RM**, the i.MX 95 Applications Processor Reference Manual: the messaging path from each core to the enclave,
  and which cores may reach it.
- **The i.MX 95 Security Reference Manual**: the enclave's configuration on the i.MX 95, the fuse map behind the
  monotonic counter, and the TrustZone configuration.
- **The SE051 documentation**: its key storage, its API, and how it would sit beside the enclave.
- **The System Manager documentation**: which resources it grants the Cortex-M7, including any route to the enclave.
- **The Linux driver and library for the enclave's HSM API on the Cortex-A55**: no document in
  [references/](../references/README.md) names them.
- **The number of keys, key types and key store size** the board needs: the cited sections give no figures for the
  board's use.

## Open questions

These are the owner's. They are recorded, not answered.

1. Which side calls the HSM API: the Cortex-A55 Linux side or the Cortex-M7?
2. Does the SE051 hold any key, and what is its role beside the enclave?
