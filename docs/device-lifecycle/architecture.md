# device-lifecycle: architecture

> **Status: PROVISIONAL, pending go-xkms and go-trusted-platform** · Row: device-lifecycle · Issue: #177

## Decision

Owner ruling 1234 (Tenant, 2026-11-23): go-xkms's endorse-01 requires an EdgeLock enclave attestation before it certifies the fTPM's endorsement key (EK), and the Cortex-A55 calls the enclave's key API. This answers the earlier question of what further evidence the device presents (A1 and F1 in [README.md](README.md)). The ruling does not name a root, a binding or a wire format. Owner ruling 927 gives the board its firmware TPM and the endorse-01, enroll-01, device-attest-01 sequence ([ftpm](../ftpm/README.md)).

## Device-side order

1. The Cortex-A55 asks the enclave for an attestation through the enclave's HSM API (RM00284 §3.12), with a nonce chosen by the verifier (the survey's recommendation A3, [attestation-survey.md](attestation-survey.md); not decided by ruling 1234).
2. The Cortex-A55 reads the fTPM's EK (public part and template) from `/dev/tpmrm0` ([ftpm](../ftpm/README.md)).
3. The device hands the enclave attestation and the EK to go-xkms. endorse-01 checks the attestation, then certifies the EK.
4. enroll-01, then device-attest-01 in the `tpm` format, as ruling 927 sets.

A device-side proposal for what step 3 hands over is in [evidence-bundle.md](evidence-bundle.md) (proposed, pending owner approval).

Which channel carries step 3 (F2) stays with go-xkms's `hsm-device-protocol` and go-trusted-platform's enrollment API.

## What the public references give about the root

This section fixes no root. A2 stays open for go-xkms. It records only what [attestation-survey.md](attestation-survey.md) says.

- Which key signs the device attestation response is unconfirmed: the sources read do not say whether it is per device or per product, how its public key or certificate is published, or whether NXP runs a CA for it ([survey section 2](attestation-survey.md#2-key-and-certificate-chain)).
- Response version 2 carries the OEM SRK hash, the hash of the OEM's boot-signing root keys. The survey calls this signing-root identity evidence, not image attestation ([survey 1.1](attestation-survey.md#11-device-attestation-ele-command-0xdb), [survey 1.4](attestation-survey.md#14-what-the-enclave-evidence-does-not-cover)).
- The signature algorithm of the response is unconfirmed; 96 bytes fits ECDSA P-384, which the survey marks as an inference ([survey 1.1](attestation-survey.md#11-device-attestation-ele-command-0xdb)).
- Public key attestation chains to whatever key the caller names as the attesting key, so its trust depends on how that key was put in place ([survey section 2](attestation-survey.md#2-key-and-certificate-chain)).
- NXP's HSM API reference (RM00284 §3.12) was not read by the survey and may answer which key signs the response ([survey section 2](attestation-survey.md#2-key-and-certificate-chain)).

## Open items for go-xkms

The public references do not give these. Nothing here fixes them.

| Item | Why open | Belongs to |
|---|---|---|
| The root the enclave attestation chains to (A2) | No root is named in the references; see [what the public references give](#what-the-public-references-give-about-the-root) | go-xkms endorse-01 verifier; no issue exists yet |
| How the attestation binds the EK (B1, B3) | The attestation's nonce is the verifier's; the EK is read separately in step 2, so nothing yet ties the two | go-xkms endorse-01; no issue exists yet |
| The wire format of the attestation and its carriage (C2, F2) | Not specified in the references; a device-side proposal exists ([evidence-bundle.md](evidence-bundle.md), proposed, pending owner approval) | go-trusted-platform #884 (enrollment and attestation API); go-xkms #1521 (`hsm-device-protocol`) |

Any requirement on the device beyond ruling 1234 is proposed, pending owner approval. NXP documents are cited only, never copied.
