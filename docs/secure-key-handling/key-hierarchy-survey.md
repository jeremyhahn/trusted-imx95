# Key hierarchy survey: the EdgeLock secure enclave on the i.MX 95

Row: `secure-key-handling` ([SPEC.md](../SPEC.md)). Issue #97. Documentation only: no key, fuse,
life-cycle or provisioning step is run or scripted here, and none is described as a procedure.

## 1. Scope and method

This survey answers three questions for the row:

1. What key hierarchy does the EdgeLock secure enclave (ELE) expose on the i.MX 95, and how are its
   key store and blobs bound to the device and to its life cycle?
2. Which key attributes and usage policies does the public HSM API expose, and which should a
   production key carry?
3. How should this board's identity, signing, storage and transport keys map onto those attributes,
   and which of those choices belong to go-xkms rather than to this repository?

Only public sources were used: NXP's public GitHub repositories and the upstream projects named in
§2. NXP's restricted documents that [SPEC.md](../SPEC.md) cites (RM00284, AN14861, the i.MX 95
Security Reference Manual) were not used for this survey; where SPEC.md relies on them, this file
says so rather than restating them. Every statement is a summary in our own words, cited as
`[S<n>]` against the source list. A statement the sources do not support is in §6, not in the body.

## 2. Sources surveyed

| Id | Source | Version surveyed | Where |
|----|--------|------------------|-------|
| S1 | NXP `imx-secure-enclave`, the ELE/SECO HSM user-space library (headers, sources, tests) | tag `lf-6.18.37-2.1.0` (commit dated 2026-09-08); library version 1.1.1 per its `se_version.txt` | <https://github.com/nxp-imx/imx-secure-enclave> |
| S2 | "ELE HSM API", the Doxygen reference shipped in S1 as `doc/ele_hsm_api_document.rtf` / `.pdf` | Rev 1.0, generated 2023-09-06, as shipped in S1 at the tag above; it names the i.MX8ULP and i.MX93 as its targets | <https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0/doc> |

## 3. The enclave's key hierarchy

### 3.1 Sessions, services and the key store

- A caller reaches the enclave by opening a session, which fixes the messaging-unit route between
  caller and enclave; per-category service flows (key store, key management, signing, …) are then
  opened under the session and closed with it [S2, "General concepts", "Session"]. A session can be
  opened restricted to FIPS-certified operations, exclusive (no other session on the enclave), or
  with no key store attached [S2, "Session", `HSM_OPEN_SESSION_*_MASK`].
- A key store is created by opening the key store service with a create flag. It is not persisted to
  external non-volatile memory (NVM) until a key is generated or imported with the strict-operation
  flag [S2, "Key store"].
- Only secret material (symmetric keys and private keys) lives in the key store. Public keys are
  returned when a pair is generated, or recomputed later through the public-key recovery call
  [S2, "Key store"].
- Secret keys are never exportable in any form; they can be imported only encrypted [S2, "Key store"].

### 3.2 Key groups and NVM

- Keys are organised in key groups. A group is written to and read from NVM as one block. The enclave
  holds up to three groups in its internal memory at once and swaps groups in from NVM as needed, up
  to 1000 groups in NVM; a caller can lock a group into the internal cache [S2, "Key management"
  (general concepts); `HSM_OP_MANAGE_KEY_GROUP_FLAGS_*`].
- The blocks written to NVM are the enclave's key store blobs. The public library does not decrypt or
  interpret them: it hands them to and from storage through the NVM manager (`include/nvm.h`) [S1].

### 3.3 Rollback protection and the strict-operation flag

- Every call that creates or changes the key store (open key store, generate, import, delete,
  derive, manage group) carries a strict-operation flag. With the flag, the enclave writes the
  affected blocks to NVM and burns one bit of an OTP monotonic counter, which is what protects the
  stored blobs from rollback. Without it, the change lives only in enclave memory and is lost at
  reset [S2, "NVM writing"].
- Because the counter is small and one-way, the guidance is to batch updates into one group and
  set the flag once. When the counter is exhausted, every later export returns a warning that the
  update is no longer rollback-protected [S2, "NVM writing"].
- This agrees with the row's statement in [SPEC.md](../SPEC.md) (`secure-key-handling`), which cites
  RM00284 §2.4.2.

## 4. Key attributes and usage policies in the HSM API

The attributes below are the ones the public header set and its reference expose at the S1 tag.

### 4.1 Key types and sizes

| Type | Sizes |
|------|-------|
| HMAC | 224, 256, 384, 512 bits |
| AES | 128, 192, 256 bits |
| SM4 | 128 bits |
| RSA | 2048, 3072, 4096 bits |
| ECC NIST | P-224, P-256, P-384, P-521 |
| ECC Brainpool R1 | 224, 256, 320, 384, 512 bits |
| ECC Brainpool T1 (public keys only in S2's type list) | 224, 256, 320, 384 bits |

[S2, "Key management", `hsm_key_type_t`, `hsm_bit_key_sz_t`, `hsm_pubkey_type_t`]

### 4.2 Usage flags

A key carries a bit mask of permitted usages: export, encrypt, decrypt, sign message, verify message,
sign hash, verify hash, derive [S2, `HSM_KEY_USAGE_*`]. The export usage applies only to what
§3.1 allows to leave the enclave (the public part of a pair); see §6.

### 4.3 Permitted algorithm

A key is bound to one permitted algorithm, from: SHA-2 and SM3 hashes; HMAC-SHA-256/384; CMAC;
AES in CTR, CFB, OFB, ECB and CBC (no padding); CCM and GCM; RSA PKCS#1 v1.5 and PSS with SHA-224
to SHA-512; ECDSA with SHA-224 to SHA-512; an HMAC-SHA-256 KDF; "all ciphers"; "all AEAD"; and a
KEK-CBC wrap mode [S2, `hsm_permitted_algo_t`].

### 4.4 Lifetime and persistence

- Lifetime combines a location (the enclave key storage) with a persistence level: volatile,
  persistent, or persistent-permanent [S2, `hsm_key_lifetime_t`, `hsm_storage_persist_lvl_t`].
- A separate key-info field marks a key as permanent, transient, master or KEK
  [S2, `HSM_KEY_INFO_*`].

### 4.5 Key life cycle

A key carries the device life-cycle states in which it may be used: open, closed, and
closed-locked, as a bit mask [S2, `hsm_key_lifecycle_t`]. This is the attribute that binds a key's
use to the device's life cycle.

### 4.6 Import

Import accepts either an EdgeLock 2GO TLV object or a signed message, chosen by a flag, and a strict
flag that commits the imported key to NVM with the counter advanced [S2,
`HSM_OP_IMPORT_KEY_INPUT_*`, `HSM_OP_IMPORT_KEY_FLAGS_STRICT_OPERATION`].

## 5. Proposed hierarchy for this board

## 6. What could not be confirmed

- S2 is written for the i.MX8ULP and i.MX93 [S2, introduction]; that each feature it describes
  behaves the same on the i.MX 95 is not stated in S2. Where S1's sources show an i.MX 95 path, §3–§4
  say so; elsewhere i.MX 95 applicability is unconfirmed.

## 7. Questions for the owner
