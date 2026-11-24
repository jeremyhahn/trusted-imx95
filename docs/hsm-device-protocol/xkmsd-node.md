# hsm-device-protocol: the board as an xkmsd node, the device-side design

> **Status: DESIGN, per owner rulings 1243 and 1244 (the HSM is an xkmsd node) and 1234 (the A55 calls the enclave key API); each requirement below is proposed, pending owner approval, unless a ruling decides it** · Row: hsm-device-protocol · Issue: #24 · Written: 2026-11-24

Sources are the repository documents linked in each item, the [survey](on-device-transport-survey.md) sections written **[Sn §k]** (survey section k), the rulings, and the [enclave interface trace](enclave-interface-trace.md) (facts read from NXP's driver and library sources). Where the sources show nothing, the item says **unconfirmed**. This document names no wire-protocol detail: go-xkms owns the protocol (go-xkms #1521). It runs or scripts no fuse, life-cycle or provisioning step.

## 1. What runs where

| Part | Where | Source |
|---|---|---|
| xkmsd | Cortex-A55 Linux, in the platform image | rulings 1243, 1244; [SPEC.md](../SPEC.md) rows `platform-image`, `hsm-device-protocol` |
| Key operations | The enclave's HSM API, called from the A55 through the secure-key-handling client | ruling 1234; [ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md) §8 question 1, option (a) |
| Board keys | The enclave's key store; they do not leave it in the clear | SPEC row `secure-key-handling` |
| Device identity | The firmware TPM in OP-TEE (device-attest-01, `tpm` format); its keys are not board keys | SPEC rows `ftpm`, `device-lifecycle`; ruling 927 |
| Cortex-M7, System Manager | Unchanged: the M7 stays trusted-firmware's product and the System Manager stays NXP's | SPEC row `secure-world` |

The enclave HSM API caller is the A55 Linux user space. The OP-TEE and M7 callers of the ELE survey are not used by this design.

## 2. The boundary

**go-xkms owns:** xkmsd, the wire protocol and the network protocol surface (go-xkms #1521; SPEC row `hsm-device-protocol`; the SPEC Purpose lines that say this repository never defines the protocol and never implements xkmsd).

**This repository owns:**

- the image integration of xkmsd (SPEC row `platform-image`);
- the enclave access path: the kernel driver, the user-space library and the key-store blob storage (ELE survey §6, §8);
- the transports: the board's two 1 GbE ports now, and the 10 GbE card on the Slim-SAS connector, which is not in the kit and whose documentation is missing (SPEC row `hsm-device-protocol`; survey, "Network side");
- the hardening of the node (threat model TH15, TH17, TH23).

**How xkmsd is consumed (proposed):** as a tagged go-xkms release only. No copied code, no `replace` directive, no branch pin.

## 3. Requirements

Each item is proposed, pending owner approval, unless the text says a ruling decides it.

| # | Requirement | Status | Source |
|---|---|---|---|
| R1 | xkmsd runs on the A55 Linux side of the platform image | decided | rulings 1243, 1244 |
| R2 | xkmsd performs key operations through the enclave HSM API; the A55 is the caller | decided | ruling 1234 |
| R3 | The image carries the enclave driver. NXP's tree has it, mainline does not, so the image builds on NXP's kernel tree or carries its patches | proposed, pending owner approval | survey §1; ELE survey §8 question 2 |
| R4 | The user-space enclave library is pinned by tag and commit with the kernel of the same BSP release | proposed, pending owner approval | ELE survey §8 question 3 |
| R5 | The key store blob storage has a place on the image, and a key update counts as committed only when the enclave acknowledges both the strict-operation flag and the monotonic-counter flag | proposed, pending owner approval | SPEC row `secure-key-handling`; ELE survey §8 question 4 |
| R6 | The enclave device nodes are reachable only by the xkmsd service account | proposed, pending owner approval | survey §5 row "Who can open the path"; threat model TH9 |
| R7 | The device offers the 1 GbE ports as the network transport now; the 10 GbE card is added when it is in the kit and its documentation is in the repository | proposed, pending owner approval | SPEC row `hsm-device-protocol`; survey, "Network side" |
| R8 | The network-facing listener and the key-holding process are separable, with a local socket and peer credentials between them if go-xkms's design has two processes | proposed, pending owner approval | survey §4 (mechanisms named, details unconfirmed) |
| R9 | The image runs xkmsd with runtime hardening and a defined integrity measurement; the form is chosen once the owner decides the IMA question | proposed, pending owner approval | threat model TH17; SPEC row `hsm-self-defence` |
| R10 | The device keeps answering or fails closed under a flood on its network ports; no key operation runs unauthenticated | proposed, pending owner approval | threat model TH15, TH23 |
| R11 | A reset or loss of the enclave interface makes xkmsd fail closed and recover without leaving a key operation half done | proposed, pending owner approval | survey §1 ("survives a reset" is unconfirmed) |
| R12 | The device identity stays in the fTPM and is never the same key as a board key | proposed, pending owner approval | SPEC rows `ftpm`, `secure-key-handling` |

R6 to R11 carry no number or protocol detail on purpose: sizes, message formats and timeouts belong to go-xkms.

## 4. Open questions

For go-xkms, which has to define them first (go-xkms #1521, owner-queue item 160):

1. The wire protocol and the network transport security the device has to offer.
2. Whether xkmsd is one process or two (a network listener and a key holder); the [local seam trace](local-seam-trace.md) summarises what public man pages say about a Unix socket between the two.
3. How xkmsd asks for device attestation, and which evidence it expects beyond the fTPM's `tpm` format (SPEC row `device-lifecycle`).
4. The tagged release the image pins, and the Go toolchain and build inputs that release needs.

For the owner, or for a later survey of the sources:

5. Whether the enclave interface allows several processes at once, its message size limit and its behaviour after an enclave reset: the [trace](enclave-interface-trace.md) read NXP's driver and library at lf-6.18.37-2.1.0. The driver gives each open descriptor its own context but allows one command in flight per interface (one enclave-initiated-command receiver); it enforces no upper bound on request length in the code read, and has a 256-byte buffer for enclave-initiated commands; and it has no reset handling in the code read, only a timeout, a busy flag and a late-response recovery. Still **unconfirmed**: the node's mode and owner on the image, the messaging unit's own size limit, and what a descriptor sees after an enclave reset (trace (a), (d), (e)).
6. Whether the enclave driver works on the FRDM-IMX95-PRO: **unconfirmed** (survey §1).
7. Whether the SE051 holds any key (SPEC row `secure-key-handling`).
8. The IMA log and the runtime integrity form (R9; threat model TH17).
9. The 10 GbE card: its availability and documentation, and the DMA protection its port needs (survey, "Network side").
10. The secure-key-handling client contract: its document is not yet in the repository, so R5 and R6 cite the ELE survey and the SPEC row instead.

## 5. What this design does not do

- It defines no protocol message, port number, timeout or size.
- It edits neither SPEC.md nor ROADMAP.md; the row text is updated by another lane.
- It builds nothing and touches no fuse, life-cycle or board step.
