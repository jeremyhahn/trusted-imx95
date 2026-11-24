# device-lifecycle: feature folder index

> **Status: INDEX, PROVISIONAL, pending go-trusted-platform's hsm-device-lifecycle row and the owner (#25, #177)** · Row: device-lifecycle · Issue: #25

## Purpose

This folder is the device side of go-trusted-platform's `hsm-device-lifecycle` row (see [SPEC.md](../SPEC.md), row `device-lifecycle`). Ruling 927 gives the board a firmware TPM, so the device attests through that TPM, and go-xkms's `device-attest-01` challenge, `tpm` format, is the route to a certificate. The go-trusted-platform row is blocked, so everything here is survey and provisional (#25). Owner ruling 1234 decides the order and the caller: the enclave attestation comes first and the Cortex-A55 calls the enclave ([architecture.md](architecture.md)); the rest stays survey and provisional. This index lists the documents and gathers their owner questions in one place; it decides nothing.

## Documents

| Document | Question it answers | Status (from the file's own status line) | Owner questions it holds |
|---|---|---|---|
| [attestation-survey.md](attestation-survey.md) | What evidence the EdgeLock enclave can produce, and what root it chains to | SURVEY, for the owner's decision | 7 (A1 to A4, D1, F1, F2) |
| [enrollment-survey.md](enrollment-survey.md) | Which enrollment protocol carries the evidence, and what authorises the first request | survey, input to the owner's choice | 5 (C1 to C5) |
| [decommission-survey.md](decommission-survey.md) | What end of life, RMA and decommissioning mean for a board | draft survey for the owner | 7 (E1 to E7) |
| [evidence-binding-survey.md](evidence-binding-survey.md) | How the firmware TPM's identity could be bound to the chip's own attestation | SURVEY, PROVISIONAL, pending go-trusted-platform's hsm-device-lifecycle row and the owner (#25) | 4 (B1 to B4) |
| [architecture.md](architecture.md) | The device-side order under ruling 1234, the open items for go-xkms, and where the life cycle closes | PROVISIONAL, pending go-xkms and go-trusted-platform | none (points at A2, B1, B3, C2, F2) |
| [evidence-bundle.md](evidence-bundle.md) | What the device hands to endorse-01 under ruling 1234 | PROPOSED, pending owner approval, go-xkms and go-trusted-platform | none (points at A2, B1, B3, B5, C2, F2) |
| [decommission-runbook.md](decommission-runbook.md) | The ordered decommission steps, who acts, and what is not described | PROPOSED, pending owner approval, documentation only; nothing here is scripted, and no step is run on a development board | none (points at E1 to E7) |
| [../ftpm/README.md](../ftpm/README.md) | The firmware TPM design: components, NV storage, EK lifecycle, measured boot | NORMATIVE | 7 (B5 to B10, D2) |

## How the pieces fit

- The decided order and the open items for go-xkms (ruling 1234): [architecture.md](architecture.md).
- Enclave evidence: [attestation-survey.md](attestation-survey.md).
- TPM evidence and its binding to the chip: [ftpm](../ftpm/README.md) for the TPM, [evidence-binding-survey.md](evidence-binding-survey.md) for the binding.
- The evidence handed to endorse-01 (proposed): [evidence-bundle.md](evidence-bundle.md), and the A55 collector (`scripts/device-lifecycle/collect-evidence.sh`; it needs no Python, run-time needs and the opt-in recipe, which no image installs by default, in evidence-bundle.md). Verification and the wire format belong to go-xkms and go-trusted-platform; this repository ships no verifier.
- Carriage and enrollment: [enrollment-survey.md](enrollment-survey.md).
- End of life: [decommission-survey.md](decommission-survey.md), and the proposed runbook that orders its steps, [decommission-runbook.md](decommission-runbook.md).

Each survey states its own claims and sources; this index links to them and does not restate them.

## Open questions for the owner, consolidated

Thirty questions in all: every numbered question of the four surveys and of the ftpm "Open questions for the owner" appears once. The source's own text wins over this index wherever they differ. The source links go to the section that holds the question; "Rec." repeats the source's recommendation or provisional default and nothing more.

The NXP root is the one answer that matters most. A2 (attestation Q2), C3 (enrollment Q3, first-request authority) and B1 (evidence-binding Q1) all turn on whether the enclave evidence chains to a root that go-trusted-platform will trust. A2 is the single answer that unblocks the others: C3 says it depends on it, and B1 says to re-examine (b) once it is known.

### Evidence and root

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| A1 | What evidence does the board present (enclave response, plus key attestation, token wrapper, or OP-TEE evidence)? | [attestation Q1](attestation-survey.md#questions-for-the-owner) | answered: ruling 1234, see [architecture.md](architecture.md#decision) | C2 (wire encoding), B1 |
| A2 | What root does the evidence chain to (NXP key or CA, factory-pinned key, OEM-imported key)? | [attestation Q2](attestation-survey.md#questions-for-the-owner) | no recommendation | C3 and B1 turn on it; the answer here unblocks them |
| A3 | Which response versions are accepted, and how is freshness enforced? | [attestation Q3](attestation-survey.md#questions-for-the-owner) | (a), verifier-chosen 16-byte nonce | B3 (nonce field) |
| A4 | Should EdgeLock 2GO be used for provisioning or attestation certificates? | [attestation Q6](attestation-survey.md#questions-for-the-owner) | (c), decide after NXP confirms i.MX 95 support | C4 (NXP cloud in the enrollment path) |

### Binding and re-registration

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| B1 | Which binding between the TPM and the chip? | [evidence-binding Q1](evidence-binding-survey.md#questions-for-the-owner) | provisional default: (a) now, with (d) as the carried evidence | A2 (root), A1, B3 |
| B2 | How is a re-created EK re-registered after an NV wipe? | [evidence-binding Q2](evidence-binding-survey.md#questions-for-the-owner) | provisional default: (b), pending go-xkms's endorse-01 checks | B6 is the same question from the ftpm side |
| B3 | Is a device-chosen value in the enclave nonce field acceptable at all? | [evidence-binding Q3](evidence-binding-survey.md#questions-for-the-owner) | provisional default: (b), the nonce stays the verifier's | A3, B1 |
| B4 | Does the owner accept that the TPM's seeds are random, not chip-derived, on the code read? | [evidence-binding Q4](evidence-binding-survey.md#questions-for-the-owner) | provisional default: (a) | B1, B7 |
| B5 | Which EK template (RSA 2048 or ECC P-256) and which handle? | [ftpm Q3](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | B2 |
| B6 | What clears the TPM, who may do it, and is the EK certificate revoked or reissued through endorse-01? | [ftpm Q4](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | B2 (the same question; the evidence-binding survey cites this one), E4 (revocation) |
| B7 | Are the EK and attestation keys the device's TPM identity, held outside the enclave, rather than board keys under `secure-key-handling`? | [ftpm Q7](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | B1, B4 |
| B8 | Is RPMB wanted for the TPM's NV, or is REE FS accepted at first? | [ftpm Q1](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | B6 (what a reflash does to NV) |
| B9 | Which fTPM TA source and revision? | [ftpm Q2](../ftpm/README.md#open-questions-for-the-owner) | no recommendation (the question text records what is proposed and built) | B4 |
| B10 | Image scope for the redeploy: the full image, or only part of it? | [ftpm Q5](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | B6 |

### Enrollment protocol and first-request authority

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| C1 | Which enrollment protocol does the board use? | [enrollment Q1](enrollment-survey.md#12-questions-for-the-owner) | (a), ACME with `device-attest-01` | F2 (channel); the choice is go-trusted-platform's |
| C2 | How is the enclave's evidence encoded on the wire? | [enrollment Q2](enrollment-survey.md#12-questions-for-the-owner) | (b), inside a RATS CMW | A1 (token wrapper), C1 |
| C3 | What authorises the first request? | [enrollment Q3](enrollment-survey.md#12-questions-for-the-owner) | no recommendation | A2 (the NXP root; the answer there unblocks this), B1 |
| C4 | Is an NXP cloud service acceptable in the enrollment path? | [enrollment Q4](enrollment-survey.md#12-questions-for-the-owner) | (a), no | A4 |
| C5 | Does the SE051 take part in enrollment? | [enrollment Q5](enrollment-survey.md#12-questions-for-the-owner) | (a), no, unless the `secure-key-handling` SE051 question is answered otherwise | B7 |

### Image attestation

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| D1 | How is the image attested (signing-root evidence only, plus a measured-boot or IMA log, or deferred)? | [attestation Q4](attestation-survey.md#questions-for-the-owner) | image attestation stays unresolved; no pick | D2 |
| D2 | Measured-boot depth for `device-attest-01`: which gaps must close, and is evidence from U-Boot or the kernel accepted? | [ftpm Q6](../ftpm/README.md#open-questions-for-the-owner) | no recommendation | D1 |

### End of life and RMA

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| E1 | What does end of life mean for a board: scrap, field return, or both? | [decommission Q1](decommission-survey.md#8-questions-for-the-owner) | (a), scrap only, until its question 5 facts are confirmed | E5, E6 |
| E2 | Is the key-store wipe mandatory before a board leaves the owner's custody? | [decommission Q2](decommission-survey.md#8-questions-for-the-owner) | (a), always | E3 |
| E3 | May any key outlive its device? | [decommission Q3](decommission-survey.md#8-questions-for-the-owner) | (a), no key outlives its device, unless `hsm-device-protocol` needs migration | E2 |
| E4 | Which control-plane record is the revocation of record? | [decommission Q4](decommission-survey.md#8-questions-for-the-owner) | (c), both, CRL first | B6 (revoked or reissued) |
| E5 | Should the board ever enter OEM locked? | [decommission Q5](decommission-survey.md#8-questions-for-the-owner) | no recommendation | E1 |
| E6 | Who holds the authority to sign a field-return message? | [decommission Q6](decommission-survey.md#8-questions-for-the-owner) | (b) if field return is allowed, otherwise (c) | E1 |
| E7 | Where should the decommission procedure live? | [decommission Q7](decommission-survey.md#8-questions-for-the-owner) | (c), a runbook here plus a go-trusted-platform verb; runbook drafted, proposed ([decommission-runbook.md](decommission-runbook.md)) | none |

### Who calls the API

| Label | Question | Source | Rec. | Overlap |
|---|---|---|---|---|
| F1 | Which side calls the attestation API: Cortex-A55 Linux or Cortex-M7? | [attestation Q5](attestation-survey.md#questions-for-the-owner) | answered: ruling 1234, see [architecture.md](architecture.md#decision) | none |
| F2 | Over which channel is the evidence carried: go-xkms's `hsm-device-protocol` or go-trusted-platform's enrollment and attestation API? | [attestation Q7](attestation-survey.md#questions-for-the-owner) | no recommendation here | C1 |

## What is blocked on what

This list is a reading of the sources, not a ruling. Where it is uncertain, the survey wins.

- Blocked on go-trusted-platform: C1, C2 and F2 (enrollment and attestation API, issue #884 per the attestation survey), and E7 (a control-plane verb).
- Blocked on go-xkms (#24 territory, itself blocked): B2 and B6 (endorse-01 checks), F2 (`hsm-device-protocol`).
- Blocked on NXP answers: A2, A4 and C4 (root and EdgeLock 2GO support), A3 (silicon revision), B3 (nonce handling), E5 (what OEM locked does), E1 and E6 through E5's facts. C3 and B1 follow A2.
- Decidable by the owner alone now, on what the surveys say: B4, B5, B7, B8, B9, B10, C5, E2, E3, E4, and D2 as a scoping choice. D1 stays unresolved, because the sources do not support a pick.
- Answered by ruling 1234: A1 and F1 ([architecture.md](architecture.md#decision)).

## Proposed SPEC changes (proposed, pending owner approval)

Text only; this lane does not edit [SPEC.md](../SPEC.md) or the roadmap.

- None left. The SPEC `device-lifecycle` row now links [architecture.md](architecture.md) as its feature folder entry.
