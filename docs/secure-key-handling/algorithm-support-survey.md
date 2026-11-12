# EdgeLock enclave algorithm support on the i.MX 95: a survey

Row: secure-key-handling (docs/SPEC.md). Issue #100. Status: survey, for the owner's decision.
Surveyed 2026-11-12.

## 1. Scope and method

This survey covers which algorithms and key sizes the EdgeLock secure enclave (ELE) of the
i.MX 95 offers through its HSM API, what certification its public material claims, and what
it offers for post-quantum algorithms. It ends with a recommendation for the board's keys,
as input to #97 (key hierarchy) and to go-xkms.

Only public sources were used. Each one is listed in section 2 with its version or tag. The
text summarises those sources in our own words; nothing is copied from vendor documents.
The main public source is NXP's user-space library for the enclave, `imx-secure-enclave`.
Its headers list the algorithm and key-type identifiers that the library can send to the
enclave. **A header constant shows only that the library can ask for the algorithm. It does
not show that the i.MX 95 enclave firmware accepts the request.** This survey marks that
difference wherever it matters.

The enclave reference manual that docs/SPEC.md cites (RM00284) and the i.MX 95 Security
Reference Manual are not public, and this lane did not read them. Claims that would need
them are marked *unconfirmed*.

## 2. Sources surveyed

| # | Source | Version or tag | URL |
|---|--------|----------------|-----|
| S1 | NXP `imx-secure-enclave` (ELE/V2X/SECO HSM library): headers `include/hsm/internal/hsm_common_def.h`, `hsm_key.h`, `hsm_sign_gen.h`, `hsm_verify_sign.h` | tag `lf-6.18.37-2.1.0` (commit date 2026-09-08); library version 1.1.1 (`se_version.txt`) | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 |
| S2 | Same repository, `README`: platform support table and "Known Limitations" | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/blob/lf-6.18.37-2.1.0/README |
| S3 | Same repository, commit "LF-18545: ELE-HSM: add ML-DSA support" (2026-08-04) and the ML-DSA test commit LF-18730 (2026-09-08) | first tag that contains them: `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/commit/054be41 |

## 3. Classical algorithms

The table lists what library S1 defines at tag `lf-6.18.37-2.1.0`. The "i.MX 95" column
adds what README S2 says about the i.MX 95 in particular.

### 3.1 Signing

| Family | Curves or sizes (S1) | Schemes (S1) | i.MX 95 |
|--------|----------------------|--------------|---------|
| ECDSA, NIST curves | P-224, P-256, P-384, P-521 | ECDSA with SHA-224/256/384/512 | Library supported (S2 table). Firmware acceptance per curve: *unconfirmed* |
| ECDSA, Brainpool | r1 224–512, t1 224–384 (t1 512 has a key-type constant but no size constant) | as above | *unconfirmed* |
| EdDSA | Ed25519 (255), Ed448 (448) | pure EdDSA, Ed25519ph, Ed448ph | *unconfirmed* |
| RSA | 2048, 3072, 4096 (key-size constants; the legacy key-type list has 2048 and 4096 only) | PKCS#1 v1.5 and PSS-MGF1, SHA-224/256/384/512 | *unconfirmed* |
| SM2 | 256-bit (SM2 Fp-256) | SM2 with SM3 | *unconfirmed* |
| ML-DSA | see section 5 | see section 5 | see section 5 |

S1 also defines separate attestation algorithm identifiers (CMAC, and ECDSA with SHA-224 to
SHA-512), which the device-attestation call uses.

### 3.2 Key agreement and key derivation

- S1 defines Montgomery-curve keys (X25519 at 255 bits, X448 at 448 bits) next to the NIST
  and Brainpool curves, plus raw ECDH and ECDH combined with HKDF (SHA-256, SHA-384), in a
  "key import" and a plain variant.
- Derivation: HKDF with SHA-256 or SHA-384 (full, extract only, expand only), and the
  TLS 1.2 and TLS 1.3 key-schedule steps with SHA-256 or SHA-384.
- **i.MX 95:** README S2 lists the Key Exchange API and the Key Import API as not supported
  on the i.MX 95. So the ECDH-based key-exchange and import paths in S1 cannot be counted on
  for this SoC. Whether a plain ECDH key-agreement call, as opposed to the Key Exchange API,
  works on the i.MX 95: *unconfirmed*.

### 3.3 Symmetric ciphers and MACs

- AES-128, AES-192 and AES-256 keys. Modes: ECB and CBC (without padding), CTR, CFB, OFB.
  AEAD: CCM and GCM. ChaCha20-Poly1305 with a 256-bit key. SM4-128 (S1).
- MACs: CMAC, CBC-MAC, HMAC-SHA-256 and HMAC-SHA-384. HMAC key sizes run from 224 to 512 bits (S1).
- **i.MX 95:** README S2 says HMAC operations are not supported on the i.MX 95. CMAC is not
  in that list of limitations. Whether it works on the i.MX 95 firmware: *unconfirmed*.

### 3.4 Hashing

SHA-224, SHA-256, SHA-384, SHA-512 and SM3 (S1). S1 has no SHA-3 hash identifier. SHA3-256,
SHA3-512 and SHAKE256 appear only as pre-hash choices inside the ML-DSA schemes (section 5).
docs/SPEC.md records that the Generic Crypto APIs are not available on the i.MX 95
(RM00284 §3.45, not public). Whether the stand-alone hash service is available on the
i.MX 95: *unconfirmed*.

### 3.5 Random numbers

S1 has a random-number service (`include/common/rng.h`). The public sources reached do not
say which DRBG construction or entropy source it uses, or how it is rated: *unconfirmed*.

## 4. Certification claims

TODO

## 5. Post-quantum algorithms

### 5.1 ML-DSA (FIPS 204)

- Commit LF-18545 (S3, 2026-08-04) added ML-DSA to the library. It adds a key type, a public
  key type, three key sizes labelled by security strength (128, 192 and 256), and these
  signature schemes: pure ML-DSA, and pre-hash ML-DSA over SHA-256, SHA-512, SHA3-256,
  SHA3-512 and SHAKE256. The sign and verify calls gained an optional context string.
- In the standard's terms, the 128/192/256 strengths most likely map to ML-DSA-44, ML-DSA-65
  and ML-DSA-87. S1 does not name the parameter sets, so this mapping is *unconfirmed*.
- The first release tag that contains it is `lf-6.18.37-2.1.0`. Earlier tags, for example
  `lf-6.18.20-2.0.0` and the 6.6 and 6.12 series, have no ML-DSA in the library.
- The library change does not say which SoCs or enclave firmware versions accept ML-DSA. On
  the i.MX 95 in particular: *unconfirmed* (see 5.3).

### 5.2 ML-KEM (FIPS 203)

The library has no ML-KEM, Kyber or other KEM identifier at tag `lf-6.18.37-2.1.0` (S1). No
public source this lane reached says that ML-KEM is offered on the i.MX 95 enclave.

### 5.3 Enclave firmware versions

TODO

## 6. Recommended algorithms for this board's keys

TODO

## 7. What could not be confirmed

TODO

## 8. Questions for the owner

TODO
