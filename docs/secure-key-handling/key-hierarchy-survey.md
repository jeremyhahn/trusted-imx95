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

Only public sources were used: NXP's public GitHub repository named in §2. The NXP documents that
[SPEC.md](../SPEC.md) cites from the private reference set (RM00284, AN14861) were not used for this
survey, and the ones SPEC.md lists as missing (IMX95RM, the i.MX 95 Security Reference Manual) were
not sought. Where SPEC.md relies on them, this file says so and does not restate them. Every statement is a summary in our own words, cited as
`[S<n>]` against the source list. A statement the sources do not support is in §6, not in the body.

## 2. Sources surveyed

| Id | Source | Version surveyed | Where |
|----|--------|------------------|-------|
| S1 | NXP `imx-secure-enclave`, the ELE/SECO HSM user-space library (its `README` and its file layout; its code was not read) | tag `lf-6.18.37-2.1.0` (commit dated 2026-09-08); library version 1.1.1 per its `se_version.txt` | <https://github.com/nxp-imx/imx-secure-enclave> |
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
- The blocks written to NVM are the enclave's key store blobs. On Linux, NXP's NVM manager daemon
  (`nvm_daemon`, with `libele_nvm`) serves the enclave firmware as a slave and keeps the blobs as
  files on the Linux file system; for the ELE on the i.MX 95 the directory is `/etc/ele/`
  [S1, `README`, "NVM Manager", Table 2]. The daemon stores what the firmware gives it; the sources
  surveyed do not say how the blob is encrypted or which device key seals it (§6).
- The i.MX 95 is listed as an ELE-HSM platform of the library, and also as a V2X-HSM and V2X-SHE
  platform [S1, `README`, Table 1]. The V2X HSM is a separate accelerator with its own NVM directory
  (`/etc/v2x_hsm/`) [S1, `README`, Table 2]; this survey covers only the ELE.

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

### 3.4 How a key store is bound to its caller

- A key store is named by a caller-chosen 32-bit identifier, and only one key store service can be
  open on an identifier at a time [S2, "Key store", `open_svc_key_store_args_t`].
- Access is granted by checking the caller's domain ID and messaging unit against those recorded when
  the store was created, plus an optional caller-chosen authentication nonce [S2, "Key store"]. The
  nonce is therefore a shared value the caller must keep, not a key the enclave derives; see §6.
- Opening a store loads a previously created store from its blob; creating one needs the create
  flag, and the store reaches NVM only with the strict flag. A minimum MAC length can be fixed for the
  whole store, at creation only [S2, `HSM_SVC_KEY_STORE_FLAGS_*`].
- Closing the key store service drops the store from enclave memory; anything not yet committed to
  NVM is lost [S2, `hsm_close_key_store_service`].
- A store can be re-provisioned with a signed message; doing so erases every key store the enclave
  handles [S2, "Key store", detailed description].

### 3.5 Device identity and life cycle as the API sees them

- The get-info call returns the chip's unique identifier, the current monotonic counter value, the
  chip life-cycle bit field, the firmware version, and whether the part runs in, and is certified
  for, FIPS-approved mode [S2, "Get Info", `op_get_info_args_t`].
- The life-cycle update call names the states the enclave can move to: NXP provisioned, OEM open,
  OEM closed, OEM field return, NXP field return and OEM locked [S2, "Life Cycle update",
  `hsm_lc_new_state_t`]. This survey describes the states only; it does not describe or script a
  transition (see the row rules in [SPEC.md](../SPEC.md), `oem-key-provisioning`).
- A key's own life-cycle attribute (§4.5) is what ties a key to these states: a key marked usable
  only in closed states cannot be used while the device is open, and the reverse.

### 3.6 Device attestation

- The attestation call takes a caller nonce and returns a firmware nonce, the chip unique ID, the
  SoC ID and revision, the life-cycle value, the security state machine state, SHA-256 digests of the
  ROM patch fuses and of the installed enclave firmware, the OEM super-root-key hash (SRKH), and a
  signature over an info buffer, with a pass/fail result [S2, "Dev attest", `op_dev_attest_args_t`;
  "Dev Info", `op_dev_getinfo_args_t`].
- So the evidence binds the device's identity, its life cycle and the OEM's boot root of trust (the
  SRKH fused for AHAB) in one signed statement. Which key signs it, and the certificate chain a
  verifier checks it against, are not in the sources surveyed (§6).

### 3.7 Root and derived keys

- Inside the key store, the API's own hierarchy is: master keys (the only inputs a key derivation
  may take), KEKs (which only wrap keys for import), and ordinary keys, all bound to one store,
  one group and one caller identity (§3.4, §4.4) [S2, `HSM_KEY_INFO_*`].
- Below the key store, the API names keys it never exposes: the key that seals the key store blob,
  the attestation key (§3.6), and a root KEK; S1's header set at the surveyed tag contains a
  root-KEK export call (`hsm_root_kek_export.h`) and an ELE key-blob call (`hsm_gen_ele_key_blob.h`)
  that S2 does not document [S1, `include/hsm/internal/`]. Their semantics, and how any of these
  derive from a fused device secret, are not in the public sources surveyed (§6).
- The OEM boot root (the SRK hash) is outside the key store: it is fused, and the enclave reports it
  in attestation (§3.6). Its fuse map is in sources [SPEC.md](../SPEC.md) lists as missing.

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
sign hash, verify hash, derive [S2, `HSM_KEY_USAGE_*`]. S2 does not say what the export usage permits,
given that secret keys never leave the enclave (§3.1); see §6.

### 4.3 Permitted algorithm

A key is bound to one permitted algorithm, from: SHA-2 and SM3 hashes; HMAC-SHA-256/384; CMAC;
AES in CTR, CFB, OFB, ECB and CBC (no padding); CCM and GCM; RSA PKCS#1 v1.5 and PSS with SHA-224
to SHA-512; ECDSA with SHA-224 to SHA-512; an HMAC-SHA-256 KDF; "all ciphers"; "all AEAD"; and a
KEK-CBC wrap mode [S2, `hsm_permitted_algo_t`].

### 4.4 Lifetime and persistence

- Lifetime combines a location (the enclave key storage) with a persistence level: volatile,
  persistent, or persistent-permanent [S2, `hsm_key_lifetime_t`, `hsm_storage_persist_lvl_t`].
- A separate key-info field marks a key as persistent, permanent, transient, master or KEK
  [S2, `HSM_KEY_INFO_*`]:
  - persistent (the default) keys go to NVM with their group at the next strict operation;
  - permanent keys are write-locked once created: they can never be updated or deleted, and the bit
    cannot be cleared;
  - transient keys disappear when their key store service is closed or at power-on reset, and may not
    share a group with persistent keys;
  - only master keys may be the input of a key derivation function;
  - KEK keys may only wrap keys for import; they cannot be used for anything else, and only keys
    brought in through the key-management import path can carry the attribute.
- Generation also takes the key group (0–1023) and, for MAC-capable keys, a minimum MAC length,
  which in FIPS-approved mode may not be under 32 bits [S2, `op_generate_key_ext_args_t`].
- The attributes of an existing key (type, size, usage, permitted algorithm, life cycle, lifetime)
  can be read back with the get-key-attributes call [S2, `op_get_key_attr_args_t`].

### 4.5 Key life cycle

A key carries the device life-cycle states in which it may be used: open, closed, and
closed-locked, as a bit mask [S2, `hsm_key_lifecycle_t`]. This is the attribute that binds a key's
use to the device's life cycle. The source is a library header; that the enclave firmware refuses
to use a key outside its mask is **unconfirmed** (the firmware API reference is not public) and
was not tested. No life-cycle close is run or proposed to test it.

### 4.6 Import

Import accepts either an EdgeLock 2GO TLV object or a signed message, chosen by a flag, and a strict
flag that commits the imported key to NVM with the counter advanced [S2,
`HSM_OP_IMPORT_KEY_INPUT_*`, `HSM_OP_IMPORT_KEY_FLAGS_STRICT_OPERATION`].

### 4.7 Data storage

- Plain data storage keeps caller data, named by a data identifier, in the NVM the enclave firmware
  manages on the Linux file system; it needs an open key store [S2, "Data storage", `hsm_data_ops`].
- Encrypted data storage encrypts with one key-store key and signs with another, both named by
  identifier with their algorithms, and stores the result as a signed TLV that carries the device
  UUID, the IV, the ciphertext and the signature. It also takes a device life-cycle mask that limits
  in which states the data can be read back [S2, `op_enc_data_storage_args_t`,
  `ENC_DATA_TLV_*`].

### 4.8 What a production key should carry

Drawn from §3–§4; the choice of values for this board is §5.

- Persistent lifetime, committed with the strict flag in a batch, so the key survives reset and its
  blob is rollback-protected (§3.3, §4.4).
- One usage set and one permitted algorithm, the narrowest the key's role needs; no export usage on
  anything but the public half of a signing or agreement pair (§4.2, §4.3).
- A key life-cycle mask of closed (and closed-locked if used), so a production key cannot be
  exercised while the device is still open, provided the enclave enforces the mask (unconfirmed,
  §4.5).
- Permanent only for a key that must never be rotated, since the attribute is irreversible (§4.4).
- Sessions opened in FIPS mode where the part reports FIPS-approved operation (§3.1, §3.5); whether
  the i.MX 95 part is FIPS certified is unconfirmed (§6).

## 5. Proposed hierarchy for this board

A proposal for the owner, not a decision. Each line maps a role onto the attributes of §4. The last
column says who decides: **this repo** (the device side, the `secure-key-handling` row), **go-xkms**
(the wire protocol, xkmsd, key naming and custody policy; [SPEC.md](../SPEC.md) Scope), or
**go-trusted-platform** (enrollment, the device registry, attestation verification).

| Role | Type, size (§4.1) | Usage, algorithm (§4.2–§4.3) | Lifetime, info (§4.4) | Key life cycle (§4.5) | Group | Who decides |
|------|------|------|------|------|------|------|
| Device attestation | the enclave's own attestation key (§3.6) | not a key-store key | — | — | — | Evidence format and chain: go-trusted-platform. That the board answers with ELE attestation: this repo |
| Device identity (enrollment, transport authentication) | ECC NIST P-256 or P-384 | sign hash; ECDSA with the matching SHA-2 | persistent, not permanent | closed (and closed-locked if used) | its own group, written once | Curve and certificate profile: go-trusted-platform with go-xkms. Attributes and group: this repo |
| Signing keys held for go-xkms clients | ECC NIST or RSA 3072/4096, as the client asks | sign hash only; one algorithm per key | persistent | closed | per tenant or per policy, batched commits | Names, policy, which client may use which key: go-xkms. Mapping to groups and commits: this repo |
| Storage (data at rest on the board) | AES-256 for encryption, plus an ECC signing key for the encrypted-data TLV (§4.7) | encrypt/decrypt with GCM; sign/verify hash with ECDSA | persistent | closed; data life-cycle mask closed | storage group | This repo |
| Transport session keys | per the protocol | per the protocol | transient (gone at reset or store close) | current | a transient-only group (transient and persistent keys cannot share a group) | Protocol and algorithms: go-xkms (`hsm-device-protocol`). Transient handling: this repo |
| Import KEK (provisioning) | AES, KEK-CBC | KEK only (§4.4) | persistent | per the provisioning flow | provisioning group | `oem-key-provisioning` row and the owner |

Rules the proposal follows, each from §3–§4:

- No secret key ever leaves the enclave; only public halves are exported, and only through the
  public-key export call (§3.1).
- Every persistent change is committed with the strict flag in batches per group, so the one-way
  counter lasts the product's life (§3.3). Groups are laid out by write frequency: the identity group
  is written once, client-key groups often.
- No production key carries the permanent attribute unless the owner wants it irrevocable (§4.4).
- Development keys are made with an open life-cycle mask and production keys with a closed one, so a
  development key cannot sign once the device is closed and a production key cannot be used before,
  if the enclave enforces the mask as the header describes (unconfirmed, §4.5).
- The key store blobs stay in the NVM manager's directory on the board (§3.2) and are device-bound;
  restoring an older copy is what the counter refuses (§3.3).

## 6. What could not be confirmed

- S2 is written for the i.MX8ULP and i.MX93 [S2, introduction]. S1's README lists the i.MX 95 as an
  ELE-HSM platform of the same library [S1, `README`, Table 1], so the API surface applies; that each
  feature, size and algorithm S2 lists is accepted by the i.MX 95's enclave firmware is not stated in
  any source surveyed and is unconfirmed.
- The enclave's root keys: which fused or hardware secret the key store blob, the attestation key
  and the root KEK derive from, how, and whether the derivation changes with the life cycle. None
  of the public sources surveyed describes them. They are expected in the i.MX 95 Security Reference
  Manual, which [SPEC.md](../SPEC.md) lists as missing.
- The format and encryption of the key store blob in `/etc/ele/`, and whether a blob from one chip
  can be opened on another (assumed not, but not stated).
- The semantics of the root-KEK export and ELE key-blob calls present in S1's headers but not in S2.
  This survey saw only their file names; their code was not read.
- Which key signs device attestation, and the certificate chain a verifier uses.
- The size of the monotonic counter that the strict flag advances on the i.MX 95, and so how many
  committed key store updates the device can make.
- Whether ECDH key agreement and HKDF-style derivation are available for transport keys on the
  i.MX 95. S1 has key-agreement and key-exchange headers, but S2's permitted-algorithm list (§4.3)
  names no agreement algorithm.
- Whether the i.MX 95 part is FIPS certified, and in which mode it runs by default.
- What the export usage bit permits beyond the public half of a pair (§4.2). S2 states that secret
  keys never leave the enclave (§3.1).
- Whether the Cortex-M7 can reach the HSM API. S1's library and NVM daemon are Linux user space only.
- Sources not reached: none. The ELE sections of NXP's i.MX 95 reference manual and Security
  Reference Manual are not public and were not sought.

## 7. Questions for the owner

1. **Which side calls the HSM API on this board?**
   Options: (a) the Cortex-A55 Linux side, through `libele_hsm` and the NVM daemon, next to xkmsd;
   (b) the Cortex-M7; (c) both, with separate key stores.
   Recommendation: (a). It is the only path the public sources support: the library and the NVM
   manager that keeps the blobs are Linux user space (§3.2) [S1, `README`]. An M7 path is
   unconfirmed (§6).
2. **Which curve for the device identity key?**
   Options: (a) NIST P-256 with ECDSA-SHA-256; (b) NIST P-384 with ECDSA-SHA-384; (c) RSA-3072.
   Recommendation: no source here favours one. go-trusted-platform's enrollment profile should set
   it, and this repository should follow that profile.
3. **Should the identity key be permanent?**
   Options: (a) persistent, so it can be replaced at re-enrollment; (b) permanent, so it is
   irrevocable for the device's life.
   Recommendation: (a). The permanent bit can never be cleared, and a permanent key can never be
   deleted (§4.4).
4. **What key life-cycle mask should production keys carry?**
   Options: (a) closed only; (b) open and closed; (c) closed-locked only.
   Recommendation: (a) for production keys, and separate development keys with an open mask, so
   neither can be used in the other's state (§4.5). The device's life-cycle transition itself is the
   `oem-key-provisioning` row's open question and is not touched here.
5. **How should key groups and strict commits be laid out?**
   Options: (a) one group per role, as in §5, with batched strict commits; (b) one group for
   everything; (c) one group per go-xkms tenant.
   Recommendation: (a), extended with (c) for client signing keys if go-xkms has tenants. The
   counter is one-way and limited, so batching is the vendor's own guidance (§3.3). Its size on the
   i.MX 95 is unconfirmed (§6).
6. **Where does the key store authentication nonce come from?**
   Options: (a) a constant in the signed image; (b) a value go-xkms or go-trusted-platform supplies
   at enrollment and xkmsd keeps; (c) none (the domain and messaging-unit check only).
   Recommendation: none from the sources. They say only that the nonce is caller-chosen and checked
   along with the domain ID and messaging unit (§3.4). Ask go-xkms, which runs xkmsd.
7. **What evidence does the board present at attestation?**
   Options: (a) the enclave's device attestation (§3.6) only; (b) a signature by the device identity
   key only; (c) both, with the identity public key covered by the enclave attestation.
   Recommendation: (c). The enclave evidence binds the chip ID, the life cycle, the firmware digest
   and the OEM SRK hash, which the identity key alone cannot (§3.6). The verifier and the chain are
   go-trusted-platform's decision.
8. **Should the key store blobs be backed up?**
   Options: (a) no: the blobs are device-bound, and a lost store means re-enrollment; (b) yes, as an
   encrypted copy for the same device; (c) a go-xkms-level backup of client keys by wrapped export.
   Recommendation: (a) for the device store. An older blob cannot be restored past the rollback
   counter (§3.3), and secret keys cannot be exported (§3.1). Client-key backup, option (c), is
   go-xkms's decision and needs an export path the sources do not show (§6).
9. **Does the i.MX 95's V2X HSM hold any key?**
   Options: (a) no, the ELE only; (b) yes, for high-rate signing.
   Recommendation: (a) until a public source describes the V2X HSM's key store and its binding to
   the device. The library lists it for the i.MX 95 (§3.2), but this survey did not cover it.
10. **Should HSM sessions run in FIPS mode?**
    Options: (a) yes, always; (b) only for production keys; (c) no.
    Recommendation: (a) if the part reports FIPS-certified (§3.5). Otherwise the choice waits on the
    certification status, which is unconfirmed (§6).
