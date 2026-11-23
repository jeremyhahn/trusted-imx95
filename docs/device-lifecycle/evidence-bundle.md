# device-lifecycle: endorse-01 evidence bundle

> **Status: PROPOSED, pending owner approval, go-xkms and go-trusted-platform** · Row: device-lifecycle · Issue: #177

This page proposes the one evidence bundle the Cortex-A55 hands to go-xkms for endorse-01. go-xkms's endorse-01 verifier and go-trusted-platform #884 own the real wire format; this is the device side's input to them, not a decision. Everything below beyond the order and the caller is proposed, pending owner approval.

## Decision basis

Owner ruling 1234 (Tenant, 2026-11-23), as recorded in [architecture.md](architecture.md#decision): go-xkms's endorse-01 requires an EdgeLock enclave attestation before it certifies the fTPM's endorsement key (EK), and the Cortex-A55 calls the enclave's key API. Owner ruling 927 sets the endorse-01, enroll-01, device-attest-01 sequence in the `tpm` format. The ruling decides only that order and that caller. It does not decide the root (A2), the EK binding (B1, B3), the EK template (B5) or the wire encoding (C2, F2); labels are those of the [README](README.md).

Provisional defaults followed here: B1 (a) now with (d) as the carried evidence, and B3 (b), the nonce stays the verifier's ([evidence-binding-survey.md](evidence-binding-survey.md#questions-for-the-owner)); A3 (a), response versions 2 and 3 and a 16-byte verifier nonce ([attestation-survey.md](attestation-survey.md#questions-for-the-owner)). That the 96-byte signature is ECDSA P-384 is an inference, marked unconfirmed in attestation-survey.md section 1.1.

## Fields

A JSON object, UTF-8, keys sorted, compact separators, one trailing newline. Byte fields are unpadded base64url. Proposed, pending owner approval.

| Field | Type | Size | Meaning |
|---|---|---|---|
| `format` | string | | `trusted-imx95/endorse-evidence` |
| `version` | integer | | `1` |
| `ele_attestation.response_version` | integer | | `2` or `3`, the enclave response version |
| `ele_attestation.signed` | bytes | opaque | the signed region of the response, as the library returns it |
| `ele_attestation.signature` | bytes | 96 | the response signature, read as ECDSA P-384 `r \|\| s` (unconfirmed) |
| `ele_attestation.verifier_nonce` | bytes | 16 | the nonce the verifier chose |
| `ftpm_ek.public` | bytes | 4 or more | a TPM2B_PUBLIC: 2-byte big-endian size, then the public area |
| `ftpm_ek.template` | string | free | the EK template; free text because B5 is open |
| `binding` | string | | `session`: option (d), two independent items bound by the session only |

No other key is allowed at any level.

## Order on the device

The enclave call comes first (the verifier's nonce in, the attestation response out), the EK read second (from `/dev/tpmrm0`), as [architecture.md](architecture.md#device-side-order) sets. The bundle holds both, in that order of production.

## Checks a verifier makes

The checker is `scripts/device-lifecycle/evidence-bundle.py check`, offline.

| Check | Status |
|---|---|
| Exact key set at every level; `format`, `version`, `binding` | proposed, pending owner approval |
| `response_version` is 2 or 3; strict unpadded base64url | proposed, pending owner approval |
| `verifier_nonce` is 16 bytes and equals the verifier's own nonce | follows B3 (b) |
| The 16 bytes occur exactly once in `signed` | assumption: the nonce's position in the response is not public (RM00284 section 3.12, attestation-survey.md section 1.1), so no offset is used |
| `signature` is 96 bytes and verifies over `signed` as ECDSA P-384 with SHA-384 against the enclave key | assumption: the algorithm is inferred, unconfirmed |
| `ftpm_ek.public` has a size field equal to the remaining length and type RSA (0x0001) or ECC (0x0023) | proposed, pending owner approval |
| `ftpm_ek.public` equals the EK read by the verifier, when it has one | proposed, pending owner approval |

The signed region and the signature are treated as opaque bytes. The check does not say which root the enclave key chains to (A2).

## Device collector

Proposed, pending owner approval. `scripts/device-lifecycle/collect-evidence.sh --nonce HEX --response-version N --ek-handle 0xHHHHHHHH --ek-template S -o OUT` composes the bundle on the Cortex-A55, in the order ruling 1234 sets:

1. It validates the nonce (32 hex digits) and the handle (persistent range 0x81000000 to 0x81FFFFFF) and refuses before running anything else.
2. It runs the enclave attestation: `$ELE_ATTEST_CMD NONCE_HEX SIGNED_OUT SIGNATURE_OUT`. The command is named by the environment variable, has no default, and must write the signed region and the signature to the two given paths and exit 0. The collector refuses to run without it.
3. Only if that succeeded, it reads the EK public area with `tpm2_readpublic -c HANDLE -f tss -o FILE`, a read-only command.
4. It runs `evidence-bundle.py build` into a temporary file, then, only when `ELE_ATTEST_PUB` names an enclave public key PEM (a device normally has none), `check` as a self-check. OUT is written only when every step passed.

The collector never calls `tpm2_createek`, `tpm2_clear`, `tpm2_evictcontrol` or any NV-writing command. The handle is a required argument with no default because the EK template and handle are open (B5). `EVIDENCE_PYTHON` names the interpreter (default `python3`, needs `cryptography`).

It waits on two things: the enclave client's attestation command (row 162, `secure-key-handling`, has none yet, so `ELE_ATTEST_CMD` is a contract, not a binding) and the answer to B5. It is tested only against doubles for both commands (`test/device_lifecycle_collect_test.sh`); nothing here touches life cycle, which closes only at the provisioning station.

## Verifier vectors

Proposed, pending owner approval. `scripts/device-lifecycle/evidence-bundle.py vectors OUTDIR` writes a labelled vector set for a verifier to test against: one bundle per case, public keys (`ele-pub.pem` and three wrong-key variants), two EK public areas, and `manifest.json`. For each file the manifest lists the `check` arguments (relative to the manifest directory), the expected exit code (0 valid, 1 invalid, 2 unusable input) and a substring naming the failed check.

The set is generated at test time and never committed: each run makes a fresh P-384 key in memory, writes only its public half, and signs synthetic regions (random bytes holding the nonce) with it. The manifest says so: the real response layout is not public, so these vectors prove the checks above and nothing about the real enclave output.

How go-xkms would use it: run `vectors` into a temporary directory in its own test setup (the script needs only Python and `cryptography`), read `manifest.json`, feed each bundle to its endorse-01 verifier with the listed public key, nonce and optional EK, and compare accept or reject with `expect_exit` (0 accepts; 1 and 2 reject). The reasons and the exact rejection codes are endorse-01's own; `expect_check` is a hint to which rule a reject case exercises, and endorse-01's acceptance rules remain go-xkms's.

## Open items

| Item | Belongs to |
|---|---|
| The root the attestation chains to (A2) | go-xkms endorse-01 verifier; no issue exists yet |
| How the attestation binds the EK (B1, B3) | go-xkms endorse-01; no issue exists yet |
| The EK template (B5) | go-xkms endorse-01, with the fTPM row ([ftpm](../ftpm/README.md)) |
| The wire encoding and its carriage (C2, F2) | go-trusted-platform #884; go-xkms #1521 (`hsm-device-protocol`) |

NXP documents (RM00284 section 3.12 and the surveys' sources) are cited by label only, never copied.
