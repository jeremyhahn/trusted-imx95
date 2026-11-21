# SE051 role options beside the EdgeLock secure enclave

Status: survey for the owner (issue #34), row `secure-key-handling`.
Surveyed: 2026-11-12, from public sources only.

## Why this exists

The `secure-key-handling` row in [SPEC.md](../SPEC.md) puts the board's keys in
the EdgeLock secure enclave (ELE). It also notes an NXP SE051 secure element on
the board (U28, I2C2, address 0x48, J4 control header, from UM12527). Two things
are left open for the owner: whether the SE051 holds any key, and what it does
beside the enclave. This document lists the options the public software
supports, what each costs, and what could not be confirmed.

Nothing here runs, scripts or describes in detail any fuse, life-cycle,
provisioning or key-rotation step. Where an option needs one, it says so and
leaves the step to the `oem-key-provisioning` row.

## Sources

| # | Source | Version surveyed | URL | Reached |
|---|---|---|---|---|
| S1 | NXP Plug & Trust middleware, mini package (README.rst, ChangeLog.md) | tag `v04.07.01` (latest GitHub release, 2025-08-05) | https://github.com/NXP/plug-and-trust | yes |
| S2 | NXP Plug & Trust Nano package (README.rst) | tag `v1.3.0` (latest release, 2024-06-17) | https://github.com/NXPPlugNTrust/nano-package | yes |
| S3 | OpenSSL provider for EdgeLock SE05x (README.md) | tag `v01.01.03` (latest release, 2025-08-05) | https://github.com/NXPPlugNTrust/se05x-openssl-provider | yes |
| S4 | PKCS#11 library for EdgeLock SE05x (README.md) | tag `v4.7` (latest release, 2024-08-01) | https://github.com/NXPPlugNTrust/se05x-pkcs11 | yes |
| S5 | OP-TEE OS: `core/drivers/crypto/se050/crypto.mk`, `core/drivers/crypto/se050/sub.mk`, `core/drivers/crypto/ele/crypto.mk`, `core/arch/arm/plat-imx/conf.mk` | tag `4.9.0` (newest release tag) | https://github.com/OP-TEE/optee_os | yes |
| S6 | OP-TEE documentation, "Cryptographic implementation" (`architecture/crypto.rst`), section on the NXP SE05X family | `master` at commit `ae74963fa4e2` | https://github.com/OP-TEE/optee_docs/blob/master/architecture/crypto.rst | yes |
| S7 | NXP fork of OP-TEE OS (tree listing and `plat-imx/conf.mk` only) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-optee-os | yes, partly |
| S8 | NXP SE051 product page | — | https://www.nxp.com/products/SE051 | **no** (the site returned "page not available" / 404 to the lane) |
| S9 | SE051 data sheet | — | https://www.nxp.com/docs/en/data-sheet/SE051-DATA-SHEET.pdf | **no** (404 to the lane) |
| S10 | AN12973, SE051 default configuration (named by S2 as the source of the SE051's default Platform SCP03 keys) | — | https://www.nxp.com/webapp/Download?colCode=AN12973 | **no** (needs an NXP account; not tried) |
| S11 | Full Plug & Trust middleware package (named by S1 as the complete package) | — | https://www.nxp.com/products/:SE050 | **no** (404 to the lane) |
| S12 | Foundries.io `fio-se05x-cli` and their SE05x documentation (named by S6) | — | linked from S6 | **no** (the documentation URL tried returned 404; the CLI was not surveyed) |

[SPEC.md](../SPEC.md) cites UM12527 (the FRDM-IMX95 board user manual) for the
part's placement. UM12527 is in the private vendor repository and was not read
by this lane. The board facts below come from SPEC.md as written.

## What the public sources establish

### The part and its host software

- The Plug & Trust middleware supports the SE050, SE051, SE052 and A5000
  families over I2C with the T=1-over-I2C protocol. A build selects the SE051
  feature set with applet version `07_02`, and there is a separate SE051 variant
  build with SPAKE support (S1, README "CMAKE Options").
- The mini package is tested on a Raspberry Pi under Linux. The full package,
  which also covers i.MX Linux, is only on nxp.com (S1, README introduction).
  The OpenSSL provider has been tested on an i.MX 8M Quad EVK with Yocto (S3).
  Neither source names the i.MX 95.
- The host can authenticate to the part in several ways: no session, a user
  ID, an AES key, an EC key, or Platform SCP03 (an encrypted and MAC'd I2C
  channel based on GlobalPlatform SCP03), alone or combined with one of the
  others (S1, `PTMW_SE05X_Auth`). Release v04.07.00 added AES-256 Platform SCP03
  keys (S1, ChangeLog).
- The part ships with default Platform SCP03 keys, published by NXP in an
  application note (AN12973 for the SE051). The Nano package tells product
  builders to store the SCP03 keys securely (S2, "PlatformSCP03"). A device
  that keeps the published defaults has a channel that any host who knows the
  note can open.
- Release v04.05.00 turned off the creation of ECC and RSA private keys at the
  APDU layer of the middleware (S1, ChangeLog). It does not say whether
  generation inside the part is still available through other calls. **Not
  confirmed.**
- If several threads or processes use the part, they must go through NXP's
  access manager (S1, ChangeLog v04.07.01). One session at a time is the rule
  for every host stack surveyed.
- Linux user space can reach the part through OpenSSL 3 (S3: EC and RSA key
  generation, sign and verify, ECDH, CSR, random numbers) or through PKCS#11
  v2.40 (S4: EC P-192 to P-521, RSA up to 4096, import, delete and public
  export of keys and certificates, AES, HMAC, random numbers). For multi-step
  sign, verify and HMAC, the PKCS#11 library computes the digest of large inputs
  on the host (S4).

### OP-TEE support

- Upstream OP-TEE has an SE05x crypto driver (`CFG_NXP_SE05X`). It provides
  RSA, ECC, AES-CTR, a random number generator, a die identifier, an SCP03
  pseudo-TA and a raw APDU pseudo-TA (S5, `se050/crypto.mk`).
- The driver opens SCP03 early in boot by default (`CFG_CORE_SE05X_SCP03_EARLY`)
  and can hand I2C traffic to the Linux I2C driver after boot through RPC
  (`CFG_CORE_SE05X_I2C_TRAMPOLINE`, default on) (S5). The OP-TEE documentation
  recommends sending the traffic through Linux unless the part owns its bus.
  If Linux carries it, SCP03 must be on before OP-TEE leaves the secure world,
  so that Linux only ever sees encrypted, MAC'd frames (S6).
- The driver can rotate the SCP03 keys at boot or on request from the normal
  world. Both are off by default. One debug option prints the new keys, and
  another erases the part's whole NVM at boot (S5). These are provisioning
  actions and belong to `oem-key-provisioning`; this document only records
  that they exist.
- OP-TEE's driver cannot update the SE05x firmware. The OP-TEE documentation
  warns that this can leave a lasting attack surface and may limit regulatory
  compliance (S6).
- OP-TEE does not implement the GlobalPlatform TEE Secure Element API. It
  exposes the part as one shared session behind its crypto API, its PKCS#11 TA
  and the APDU interface (`libseetec`). Mainline cannot yet import keys or
  certificates held in the part into OP-TEE's PKCS#11 token (S6).
- The default I2C bus number for the driver is 2 (S5). Whether OP-TEE's bus
  numbering matches the board's "I2C2" is **not confirmed**.

### Interactions with the enclave on the i.MX 95 in OP-TEE

- OP-TEE 4.9.0 has an `mx95evk` platform flavour that turns on the ELE driver
  (`CFG_IMX_ELE`) and forces CAAM, SNVS and OCOTP off (S5, `plat-imx/conf.mk`).
  The FRDM-IMX95 board has no flavour of its own in 4.9.0. **Not confirmed**
  whether `mx95evk` fits the FRDM board.
- The SE05x glue code in OP-TEE builds its I2C back end only with `CFG_IMX_I2C`
  (the i.MX I2C controller driver) or `CFG_STM32_I2C` (S5, `se050/sub.mk`).
  The i.MX 95 uses LPI2C controllers. Whether OP-TEE 4.9.0 has a usable
  secure-world I2C driver for this board is **not confirmed**; without one,
  the driver cannot open its first session before Linux boots.
- When the ELE driver is on, OP-TEE uses its software PRNG, because of an ELE
  firmware problem with sharing the RNG between OP-TEE and Linux (S5,
  `ele/crypto.mk`). The SE05x RNG driver does the opposite: it forces the
  software PRNG off (S5, `se050/crypto.mk`). Enabling both is untested, and
  the result is **not confirmed**.
- With the SE05x driver on, the die identifier OP-TEE uses (and the
  hardware-unique-key subkey compatibility path) comes from the SE05x rather
  than from the SoC's OTP (S5, `plat-imx/conf.mk`). Whether that also applies
  to the ELE path on the i.MX 95 is **not confirmed**. Either way, it would tie
  OP-TEE's derived keys to the secure element, which is a design decision in
  its own right.
- NXP's fork of OP-TEE (S7, `lf-6.18.37-2.1.0`) has the same `se050` and `ele`
  driver directories and the same die-ID rule. Its i.MX 95 defaults were not
  compared line by line.

### Not established by any reachable source

- Which SE051 variant (A, C, E, H, …) and applet version is fitted to U28, and
  whether it carries any NXP-provisioned identity keys or certificates. This
  needs the board BOM or UM12527, plus the SE051 data sheet.
- The part's certification level, NVM size and key types. The data sheet and
  product page were not reachable (S8, S9).
- What the J4 header controls (enable, reset, power) and whether the part can
  be held disabled. The board facts are from UM12527 by way of SPEC.md only.
- Whether anything else shares I2C2. This decides whether OP-TEE can own the
  bus (S6).
- Whether NXP's i.MX 95 Linux BSP ships or enables the Plug & Trust middleware
  or the OpenSSL provider.

## Options

| | Option | What the SE051 does | Key holder | Main costs and risks (sources) |
|---|---|---|---|---|
| A | Unused | Nothing; the firmware and the OS never open a session | ELE only | None to the key tier. The part keeps its published default SCP03 keys (S2), so any code that can reach I2C2 can open a session. That code holds no project key, but disabling the part is still worth confirming (open item: J4). |
| B | Secondary identity or attestation key | Holds one key pair of its own, separate from every ELE key (for example, a device identity or a supply-chain certificate) | ELE for the project keys; SE051 for that one key | Needs SCP03 key rotation and a provisioning step (S5), owned by `oem-key-provisioning`. Needs one host stack to own the part: OP-TEE (S5, S6) or Linux (S3, S4) or the M7 (S1 port layer). OP-TEE cannot update the part's firmware (S6). |
| C | Entropy or monotonic-storage helper | Random numbers or binary objects only, no keys | ELE | The OP-TEE RNG driver and the ELE software PRNG pull in opposite directions (S5). Adds a second trust anchor for a function the enclave already covers. |
| D | Copy or backup of ELE keys | — | — | **Excluded by SPEC**: enclave keys never leave it in the clear. Not supported by any source surveyed. |

## Questions for the owner

1. **Does the SE051 hold any key?**
   Options: (a) no, it is unused (Option A); (b) yes, one identity or
   attestation key that is separate from the enclave (Option B); (c) no keys,
   only RNG or object storage (Option C).
   Recommendation: **(a)**. SPEC already makes the enclave the key tier. The
   OP-TEE driver cannot update the part's firmware (S6). On the i.MX 95 the
   driver's I2C back end and its RNG and die-ID choices clash with the ELE
   setup, or cannot be confirmed (S5). A second anchor adds provisioning work
   and gives the key tier nothing it lacks. Revisit if a customer needs an
   identity that is certified on its own, apart from the SoC.

2. **If the SE051 is used, which side owns it?**
   Options: (a) OP-TEE in the secure world (`CFG_NXP_SE05X`), with SCP03 opened
   early and I2C either owned or passed through Linux (S5, S6); (b) Linux user
   space through OpenSSL 3 or PKCS#11 (S3, S4); (c) the Cortex-M7, through the
   middleware's platform port layer (S1).
   Recommendation: **(a)**, if Q1 is not (a). It is the only option where Linux
   never holds the SCP03 keys, and the OP-TEE documentation describes it for
   this case (S6). It depends on the open I2C-driver question above and should
   follow the answer on which side calls the ELE HSM API (the other open
   question in this row).

3. **Is the part to be held disabled if unused?**
   Options: (a) leave it powered and idle; (b) keep it disabled through the J4
   header or the board's enable line, if the hardware allows; (c) rotate its
   SCP03 keys to secrets nobody holds, through `oem-key-provisioning`.
   Recommendation: none yet. The J4 function and the part's enable wiring
   could not be confirmed from public sources. (b) is preferred if UM12527
   supports it, because it needs no provisioning step.

4. **Who owns SCP03 key rotation, if the part is used?**
   Options: (a) the `oem-key-provisioning` row, with the rest of the
   provisioning flow; (b) a separate step in this row.
   Recommendation: **(a)**. It is a one-time NVM change of the same kind as the
   other provisioning steps. OP-TEE's rotation options are off by default and
   include ones that leak or erase keys (S5), so they need the same review.

5. **Add the SE051 documents to `references/`?**
   Options: (a) the owner or Software fetches the SE051 data sheet, AN12973 and
   the full Plug & Trust package (S9 to S11, NXP account) into the private
   vendor repository; (b) decide Q1 without them.
   Recommendation: **(a)** if Q1 is (b) or (c). If Q1 is (a), the BOM entry
   (variant) and the J4 description from UM12527 are enough.
