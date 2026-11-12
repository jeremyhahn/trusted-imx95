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
difference wherever it matters. The library's own test suite (S6) is a stronger hint, because
it chooses which tests to run on each SoC and silicon revision. It is still not a datasheet.

The enclave reference manual that docs/SPEC.md cites (RM00284) and the i.MX 95 Security
Reference Manual are not public, and this lane did not read them. Claims that would need
them are marked *not confirmed in public sources*.

## 2. Sources surveyed

| # | Source | Version or tag | URL |
|---|--------|----------------|-----|
| S1 | NXP `imx-secure-enclave` (ELE/V2X/SECO HSM library): headers `include/hsm/internal/hsm_common_def.h`, `hsm_key.h`, `hsm_sign_gen.h`, `hsm_verify_sign.h`, `include/common/rng.h` | tag `lf-6.18.37-2.1.0` (commit date 2026-09-08); library version 1.1.1 (`se_version.txt`) | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 |
| S2 | Same repository, `README`: the platform support table and the "Known Limitations" section | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/blob/lf-6.18.37-2.1.0/README |
| S3 | Same repository, commit "LF-18545: ELE-HSM: add ML-DSA support" (2026-08-04) and the ML-DSA test commit LF-18730 (2026-09-08) | first tag that contains them: `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/commit/054be41 |
| S4 | NXP `meta-imx` BSP layer, recipe directory `meta-imx-bsp/recipes-bsp/firmware-imx` | branches `wrynose-6.18.37-2.1.0` (`firmware-ele-imx_2.0.7.bb`) and `wrynose-6.18.20-2.0.0` (`firmware-ele-imx_2.0.6.bb`) | https://github.com/nxp-imx/meta-imx/tree/wrynose-6.18.37-2.1.0/meta-imx-bsp/recipes-bsp/firmware-imx |
| S5 | Yocto `meta-freescale` layer, `recipes-bsp/firmware-imx/firmware-ele-imx_2.0.7.bb`, last changed by commit c506c76935 ("Ship the i.MX 95 B1 ELE boot container", 2026-11-10) | branch `master` at that commit | https://github.com/Freescale/meta-freescale/commit/c506c76935 |
| S6 | `imx-secure-enclave` tests: `test/hsm/hsm_test.c`, `test/common/sign_verify_test.c` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0/test |
| S7 | NIST CMVP validated-modules search, vendor "NXP", status Active and Historical; CMVP modules-in-process list | queried 2026-11-12 | https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search |
| S8 | Common Criteria Portal, certified products list (CSV) | downloaded 2026-11-12 | https://www.commoncriteriaportal.org/products/certified_products.csv |
| S9 | go-xkms: `docs/SPEC.md` (rows `post-quantum`, `hsm-device-protocol`, `transparency-log`), `ROADMAP.md`, `docs/post-quantum/architecture.md` | commit d55b1b7 (2026-11-11), default branch | https://github.com/jeremyhahn/go-xkms/tree/d55b1b7 |

The NXP i.MX 95 product pages, fact sheets and enclave firmware release notes were not read.
The firmware release notes ship inside the firmware archive, which sits behind NXP's licence
click-through (the recipe in S5 marks it `fsl-eula`).

## 3. Classical algorithms

The tables list what library S1 defines at tag `lf-6.18.37-2.1.0`. The "i.MX 95" column
adds what README S2 and the tests in S6 say about the i.MX 95 in particular.

### 3.1 Signing

| Family | Curves or sizes (S1) | Schemes (S1) | i.MX 95 |
|--------|----------------------|--------------|---------|
| ECDSA, NIST curves | P-224, P-256, P-384, P-521 | ECDSA with SHA-224/256/384/512 | ELE-HSM library supported on the i.MX 95 (S2 table). Which curves the firmware accepts: *not confirmed in public sources* |
| ECDSA, Brainpool | r1 224–512, t1 224–384 (t1 512 has a key-type constant but no size constant) | as above | *not confirmed in public sources* |
| EdDSA | Ed25519 (255), Ed448 (448) | pure EdDSA, Ed25519ph, Ed448ph | *not confirmed in public sources* |
| RSA | 2048, 3072, 4096 (key-size constants; the older key-type list has only 2048 and 4096) | PKCS#1 v1.5 and PSS-MGF1, SHA-224/256/384/512 | *not confirmed in public sources* |
| SM2 | 256-bit (SM2 Fp-256) | SM2 with SM3 | The tests run SM2 sign and verify on the i.MX 95 only on silicon later than revision B0 (S6) |
| ML-DSA | see section 5 | see section 5 | see section 5 |

S1 also defines separate algorithm identifiers for device attestation: CMAC, and ECDSA with
SHA-224 to SHA-512. On the i.MX 95 from revision B0, the tests verify a signature with a key
held in the enclave (an "opaque key") instead of passing the public key in (S6).

### 3.2 Key agreement and key derivation

- S1 defines Montgomery-curve keys (X25519 at 255 bits, X448 at 448 bits) next to the NIST
  and Brainpool curves. It also defines raw ECDH and ECDH combined with HKDF (SHA-256,
  SHA-384), each in a "key import" form and a plain form.
- Derivation: HKDF with SHA-256 or SHA-384 (full, extract only, expand only), and the steps
  of the TLS 1.2 and TLS 1.3 key schedules with SHA-256 or SHA-384 (S1).
- **i.MX 95:** README S2 lists the Key Exchange API and the Key Import API as not supported
  on the i.MX 95. The ECDH-based exchange and import paths in S1 therefore cannot be relied
  on for this SoC. Whether a plain ECDH key agreement, outside the Key Exchange API, works on
  the i.MX 95: *not confirmed in public sources*.

### 3.3 Symmetric ciphers and MACs

- AES-128, AES-192 and AES-256 keys. Modes: ECB and CBC (without padding), CTR, CFB and OFB.
  AEAD: CCM and GCM. Also ChaCha20-Poly1305 with a 256-bit key, and SM4-128 (S1).
- MACs: CMAC, CBC-MAC, HMAC-SHA-256 and HMAC-SHA-384. HMAC key sizes run from 224 to 512 bits (S1).
- **i.MX 95:** README S2 says HMAC operations are not supported on the i.MX 95. CMAC is not
  in that list of limitations, but whether it works on the i.MX 95 firmware is *not
  confirmed in public sources*.

### 3.4 Hashing

S1 offers SHA-224, SHA-256, SHA-384, SHA-512 and SM3. It has no stand-alone SHA-3 hash.
SHA3-256, SHA3-512 and SHAKE256 appear only as pre-hash choices inside the ML-DSA schemes
(section 5). docs/SPEC.md records that the Generic Crypto APIs are not available on the
i.MX 95 (RM00284 §3.45, not public). Whether the stand-alone hash service is available on
the i.MX 95: *not confirmed in public sources*.

### 3.5 Random numbers

S1 has a random-number service (`include/common/rng.h`). No public source this lane reached
says which DRBG construction or entropy source it uses, or how it is rated: *not confirmed
in public sources*.

## 4. Certification claims

- **FIPS 140-3:** the CMVP search (S7) shows NXP certificates for the i.MX 8DXL SECO HSM
  (#4837), the i.MX 8DXL V2X (#4839) and the SE052F secure element (#5139). It shows none for
  the i.MX 95, for any EdgeLock enclave, or for an i.MX 9 part. This lane found no NXP entry
  in the modules-in-process list. The lane read that list automatically, so an entry might
  have been missed: *not confirmed in public sources*.
- README S2 describes a FIPS variant of the i.MX 8DXL and i.MX 8QXP that disables some
  services. It describes no such variant for the i.MX 95.
- **Common Criteria:** the certified products list (S8) has no NXP i.MX or EdgeLock entry.
- **Other schemes** (SESIP, PSA Certified): not searched. Any claim of this kind on NXP
  product pages is *not confirmed in public sources* by this lane.
- Conclusion: no public source reached supports a certification claim for the i.MX 95
  enclave. The project should not claim one.

## 5. Post-quantum algorithms

### 5.1 ML-DSA (FIPS 204)

- Commit LF-18545 (S3, 2026-08-04) added ML-DSA to the library. It adds a key type, a public
  key type, three key sizes labelled by security strength (128, 192 and 256), and these
  signature schemes: pure ML-DSA, and pre-hash ML-DSA over SHA-256, SHA-512, SHA3-256,
  SHA3-512 and SHAKE256. The sign and verify calls gained an optional context string.
- The tests (S6) use the FIPS 204 public-key and signature sizes of ML-DSA-44, ML-DSA-65 and
  ML-DSA-87. That supports reading the 128/192/256 strengths as those three parameter sets.
- The first release tag that contains ML-DSA is `lf-6.18.37-2.1.0`. Earlier tags (the
  `lf-6.18.20-2.0.0` tag and the 6.6 and 6.12 series) have no ML-DSA in the library.
- **i.MX 95:** the HSM test suite runs the ML-DSA sign and verify tests on the i.MX 95 only
  when the silicon revision is later than B0 (S6). That points to B1 or later silicon.
  `meta-freescale` began shipping an i.MX 95 B1 enclave boot container on 2026-11-10 (S5).
  No public statement that ML-DSA works on the i.MX 95 was found. The silicon revision of
  this board's SoC is *not confirmed in public sources*.

### 5.2 ML-KEM (FIPS 203)

The library has no ML-KEM, Kyber or other KEM identifier at tag `lf-6.18.37-2.1.0` (S1). No
public source this lane reached says that ML-KEM is offered on the i.MX 95 enclave. Other
post-quantum schemes (SLH-DSA, LMS, XMSS) do not appear in S1 either.

### 5.3 Enclave firmware versions

- NXP's BSP pairs library tag `lf-6.18.37-2.1.0` with enclave firmware `firmware-ele-imx`
  2.0.7. The release before it, 6.18.20-2.0.0, pairs with 2.0.6 (S4). The `meta-freescale`
  community layer also carries 2.0.7 (S5).
- The firmware release notes are behind NXP's licence and were not read. So it is *not
  confirmed in public sources* which firmware version first accepts ML-DSA on the i.MX 95.
  The best public inference is firmware 2.0.7 or later, used with library
  `lf-6.18.37-2.1.0` or later, on silicon later than B0.

## 6. Recommended algorithms for this board's keys

This section is input to #97 (key hierarchy). It recommends; the owner decides (section 8).

| Use | Recommendation | Basis |
|-----|----------------|-------|
| Device identity and attestation signing, held in the enclave | ECDSA P-384 with SHA-384; P-256 with SHA-256 as the fallback if the i.MX 95 firmware rejects P-384 | ECDSA is the enclave's attestation algorithm family (S1). go-xkms accepts ECDSA keys (S9). Which curves the i.MX 95 accepts is *not confirmed in public sources* |
| Post-quantum signing | ML-DSA-65 next to the ECDSA key, as a hybrid pair, once the board is shown to be later than B0 and to run firmware 2.0.7 or later | S3, S5, S6; go-xkms supports ML-DSA-44, -65 and -87 (S9) |
| Data storage and key wrapping in the enclave | AES-256 (GCM where the call offers it) | S1. HMAC is not available on the i.MX 95 (S2), so integrity comes from AEAD or CMAC |
| Hashing | SHA-384 with P-384 keys, SHA-256 with P-256 keys | S1 |
| Key agreement and KEM | Not in the enclave. ML-KEM-768 (or ML-KEM-1024), if needed, runs in go-xkms on the Cortex-A55 Linux side, and its private key is sealed with an AES key held in the enclave | No ML-KEM in S1. Key Exchange and Key Import APIs not supported on the i.MX 95 (S2). go-xkms offers ML-KEM-768/1024 from the Go standard library (S9) |
| Avoid | RSA (large keys, and i.MX 95 support *not confirmed in public sources*), SM2/SM3/SM4 (no project need), HMAC (not supported on the i.MX 95, S2) | S1, S2 |

**What go-xkms decides, and what this project decides.** go-xkms defines the
xkmsd-to-device wire protocol (`hsm-device-protocol`, go-xkms #1521, still open), and with
it the set of algorithms the device must expose to xkmsd (S9). go-xkms also leaves the
algorithm of a signing key to configuration, never hard-coding it (S9 `transparency-log`
row). Which algorithms the enclave holds, and so which keys stay in hardware, is decided in
this repository (#97). The recommendation above fits inside the set go-xkms already offers
(RSA, ECDSA, Ed25519, ML-DSA-44/65/87, ML-KEM-512/768/1024; S9). go-xkms notes that its
ML-KEM-512 comes from CIRCL and sits outside the Go Cryptographic Module, and that ML-DSA
needs Go Cryptographic Module v1.26.0 or later (S9). That favours ML-KEM-768/1024 and
argues against ML-KEM-512.

## 7. What could not be confirmed

1. Which of the S1 algorithms and key sizes the i.MX 95 enclave firmware accepts. The only
   per-SoC public statements are the README limitations (no HMAC, Key Exchange or Key
   Import) and the test suite's revision gates.
2. Whether ML-DSA works on the i.MX 95, and from which firmware version. The firmware release
   notes are not public.
3. The silicon revision (B0 or later) of the SoC on this FRDM-IMX95-PRO board.
4. Whether plain ECDH, CMAC, the stand-alone hash service, Ed25519 and RSA work on the i.MX 95.
5. The DRBG construction and entropy rating of the enclave's random-number service.
6. Any certification of the i.MX 95 enclave (FIPS 140-3, Common Criteria, SESIP, PSA). None
   was found in S7 or S8.
7. RM00284 and the i.MX 95 Security Reference Manual are not public. The SPEC claims that
   cite them were not checked against this survey.

## 8. Questions for the owner

1. **Classical signing algorithm for enclave-held device keys.**
   Options: (a) ECDSA P-256 with SHA-256; (b) ECDSA P-384 with SHA-384; (c) Ed25519.
   Recommendation: (b), falling back to (a) if the i.MX 95 firmware rejects P-384. Ed25519
   support on the i.MX 95 is not confirmed in public sources.
2. **Post-quantum signing.**
   Options: (a) classical only for now; (b) a hybrid pair of ECDSA and ML-DSA-65, once
   silicon later than B0 and firmware 2.0.7 or later are confirmed on the board; (c)
   ML-DSA only.
   Recommendation: (b). ML-DSA support on the i.MX 95 is not public, and a hybrid pair keeps
   the device working if it turns out to be absent.
3. **Silicon revision of this board.** Is the SoC revision B0 or later? ML-DSA (and SM2)
   depend on it in NXP's tests.
   Options: (a) the owner reads it from the board's documentation or its boot log; (b) a
   later lane reads it from the boot log of a board the owner has booted.
   Recommendation: (a). No fuse or life-cycle step is involved either way.
4. **Enclave firmware and library pin** (with #80, ELE firmware sourcing).
   Options: (a) firmware 2.0.7 with library `lf-6.18.37-2.1.0`; (b) firmware 2.0.6 with
   `lf-6.18.20-2.0.0`, which has no ML-DSA in the library.
   Recommendation: (a). It is the only public pairing whose library has ML-DSA.
5. **ML-KEM.** The enclave offers none publicly.
   Options: (a) ML-KEM-768 or ML-KEM-1024 in go-xkms on the Cortex-A55 Linux side, with its
   private key sealed by an enclave-held AES-256 key; (b) no key encapsulation on the device
   until NXP publishes enclave support; (c) ML-KEM-512.
   Recommendation: (a) with ML-KEM-768, if the protocol in go-xkms #1521 needs key
   encapsulation at all. The trade-off: the ML-KEM key is in the clear in Linux memory while
   it is used, which falls short of the row's rule that keys never leave the enclave in the
   clear. (c) is advised against, because go-xkms's ML-KEM-512 is outside the Go
   Cryptographic Module (S9).
6. **Integrity without HMAC.** HMAC is not supported on the i.MX 95 (S2).
   Options: (a) AES-256-GCM; (b) AES-CMAC; (c) HMAC computed outside the enclave.
   Recommendation: (a). It is in S1, and the README lists no i.MX 95 limitation for it.
   Confirming it on the board remains open.
7. **Key import versus the oem-key-provisioning row.** The README says the HSM Key Import
   API is not supported on the i.MX 95 (S2). The oem-key-provisioning row in docs/SPEC.md
   plans an import of a wrapped key.
   Options: (a) the owner confirms from RM00284 that the OEM import path is a different
   enclave service; (b) the row is revised to generate keys in the enclave only.
   Recommendation: no recommendation. Public sources cannot settle it.
8. **Certification.** No FIPS 140-3 or Common Criteria certificate was found for the
   i.MX 95 enclave (S7, S8).
   Options: (a) make no certification claim for the device; (b) require a certified module
   for the keys that need one (for example the board's SE051, whose role is still open in
   docs/SPEC.md and whose certification this lane did not check, or an external HSM); (c) ask NXP about plans.
   Recommendation: (a) now. Choose (b) if a customer requirement for certified key storage
   appears.
