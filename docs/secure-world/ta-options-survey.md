# Secure world: OP-TEE trusted application options survey (fTPM, PKCS#11 TA)

Row: secure-world ([SPEC.md](../SPEC.md), tracking issue #16). Documentation only: nothing here is built, pinned,
fused or provisioned.

## Scope

This survey asks which OP-TEE trusted applications (TAs) the FRDM-IMX95-PRO's secure world could run on the
Cortex-A55 side for go-xkms, and how they compare with calling the EdgeLock enclave's HSM API directly. It covers:

- OP-TEE's upstream i.MX 95 platform status at a named tag;
- the firmware TPM TA (fTPM, built on Microsoft's TPM 2.0 reference implementation) and its storage needs;
- the OP-TEE PKCS#11 TA;
- for each: where keys live, what persists and where, what an attacker on the Linux side can reach, and which go-xkms
  backend (TPM2 or PKCS#11) would use it.

Out of scope, cited only:

- the TF-A, OP-TEE and U-Boot upstream survey: #32;
- RPMB storage: #62;
- memory protection (TrustZone address space and resource domain configuration): #63;
- the EdgeLock HSM API survey: #51.

## Sources

Tags are the newest release tags on 2026-11-12. "Read" means the lane read the file at that tag; build files and
documentation were read, C sources were not (see [Unconfirmed items](#unconfirmed-items)).

| ID | Title | Version or tag | URL |
|---|---|---|---|
| S1 | OP-TEE os, i.MX platform build configuration `core/arch/arm/plat-imx/conf.mk` (read) | 4.9.0 | https://github.com/OP-TEE/optee_os/blob/4.9.0/core/arch/arm/plat-imx/conf.mk |
| S2 | OP-TEE os, EdgeLock enclave driver build file `core/drivers/crypto/ele/crypto.mk` (read); driver source `ele.c` (not read) | 4.9.0 | https://github.com/OP-TEE/optee_os/tree/4.9.0/core/drivers/crypto/ele |
| S3 | OP-TEE os, PKCS#11 TA build options `ta/pkcs11/sub.mk` and `user_ta.mk` (read) | 4.9.0 | https://github.com/OP-TEE/optee_os/tree/4.9.0/ta/pkcs11 |
| S4 | OP-TEE documentation, "Platforms supported" (`general/platforms.rst`, read) | optee_docs master at commit ae74963 (2026-11-04) | https://optee.readthedocs.io/en/latest/general/platforms.html |
| S5 | OP-TEE documentation, NXP platform page and security disclaimer (`architecture/platforms/nxp.rst`, read) | as S4 | https://optee.readthedocs.io/en/latest/architecture/platforms/nxp.html |
| S6 | OP-TEE documentation, "Secure storage" (`architecture/secure_storage.rst`, read: background, key manager, REE FS hash state, caveats) | as S4 | https://optee.readthedocs.io/en/latest/architecture/secure_storage.html |
| S7 | OP-TEE fTPM TA, `README.md`, `sub.mk`, `Makefile` (read) | 4.9.0 | https://github.com/OP-TEE/optee_ftpm/tree/4.9.0 |
| S8 | Microsoft TPM 2.0 Reference Implementation (pinned by S7, not read) | commit 98b60a44aba79b15fcce1c0d1e46cf5918400f6a | https://github.com/microsoft/ms-tpm-20-ref |
| S9 | OP-TEE client (`libckteec`, the PKCS#11 library for the normal world; tag listed, not read) | 4.9.0 | https://github.com/OP-TEE/optee_client/tree/4.9.0 |
| S10 | NXP's OP-TEE fork for its Linux BSP (tag listed, not read) | lf-6.18.37-2.1.0 | https://github.com/nxp-imx/imx-optee-os |
| S11 | NXP RM00284, EdgeLock Enclave Hardware Security Module API, §3.4, §3.8, §3.12, §3.45 (private context repository, not reachable from the lane; section topics as cited in SPEC.md) | Rev. 4.5 | private: `jeremyhahn/vendor-nxp`, `docs/edgelock/RM00284.pdf` |
| S12 | trusted-imx95 `docs/SPEC.md`, rows secure-world and secure-key-handling (read) | base 4b753a7 | [../SPEC.md](../SPEC.md) |

Missing vendor documents a fact below needs: the i.MX 95 Applications Processor Reference Manual (IMX95RM) and the
i.MX 95 Security Reference Manual. Neither is in [references/](../references/README.md).

## OP-TEE on the i.MX 95

Upstream status at OP-TEE os 4.9.0 (S1):

- The i.MX 95 is built with `PLATFORM=imx` and one flavour, `mx95evk` (NXP's i.MX 95 EVK). There is no flavour for
  the FRDM-IMX95-PRO. Running on our board needs either a new flavour or `mx95evk` with board overrides (DDR size,
  console UART); which is right is #32's question.
- The flavour forces the 64-bit core, sets six cores by default, uses the LPUART console, and turns on the
  messaging-unit driver and the EdgeLock enclave (ELE) driver. It forces off the CAAM, SNVS, OCOTP and TZC380
  drivers that older i.MX parts use: on the i.MX 95, OP-TEE reaches hardware security through the enclave, not
  through a CAAM.
- Unlike the i.MX 93 flavour, the i.MX 95 flavour does not force OP-TEE's crypto driver layer off (S1). Whether the
  ELE driver registers any crypto operations with that layer was not confirmed (S2, C source not read).
- All 64-bit i.MX flavours force TF-A as the boot firmware below OP-TEE and use the Arm crypto extensions (S1). The
  TF-A side is #32.
- The defaults for every i.MX flavour enable the PKCS#11 TA (`CFG_PKCS11_TA`), the attestation pseudo-TA and the
  embedded tests (S1). The fTPM TA is not part of optee_os; it is a separate repository built as an early or
  user TA (S7).
- The defaults place secure DRAM (30 MiB) and the shared-memory window (2 MiB) at the top of the first DDR region
  whose size the `mx95evk` defaults set to 2 GiB, with a second, non-secure DDR region above 4 GiB (S1). Our
  board's memory size is in UM12527, which the lane did not read; the overrides it implies are #32's.
- With the ELE driver enabled, the build defaults OP-TEE to a software PRNG. The build file's comment gives the
  reason: the enclave firmware does not let OP-TEE and the Linux kernel use the enclave's RNG at the same time, so
  runtime enclave RNG in OP-TEE needs the kernel's enclave driver off (S2). This is also the only evidence in the
  read sources that both worlds talk to the enclave concurrently; which messaging unit each world owns is an
  IMX95RM / Security Reference Manual fact and is missing.

The OP-TEE documentation's supported-platforms table does not list any i.MX 95 board (S4): the documentation lags
the source. NXP's platform page (S5) states that OP-TEE's default i.MX security configuration is left open
(non-secure), that NXP's own releases are not production-ready implementations, and that using upstream instead of
NXP's releases may change features and security level. NXP's fork (S10) carries BSP release tags up to
lf-6.18.37-2.1.0; what it adds for the i.MX 95 beyond upstream was not surveyed (#32).

TrustZone configuration on the i.MX 95 (which controller isolates secure DRAM, and its default state) needs IMX95RM
and the Security Reference Manual, both missing; it is #63's topic. Every "Linux cannot read it" claim below holds
only once #63 has locked secure DRAM away from the normal world.

## fTPM TA

What it is (S7): an OP-TEE TA that runs Microsoft's TPM 2.0 reference implementation (S8, pinned at commit
98b60a4) as a firmware TPM. It builds against an external checkout of the reference code, uses mbed TLS for hashes
and OP-TEE's internal API for symmetric and big-number maths, and can optionally take a measured-boot event log
from the boot firmware through an OP-TEE system call (`CFG_TA_MEASURED_BOOT`, off by default, 1 KiB log by default).

- **Where keys live.** TPM keys are created and used inside the TA, in secure DRAM on the Cortex-A55. Primary seeds
  and NV data are TA-private state. How the TA derives its endorsement primary seed (`platform/EPS.c`), and whether
  it ties to the hardware unique key, was not confirmed (C source not read). The enclave's key store is not used.
- **What persists and where.** The TPM's NV memory is kept as OP-TEE persistent objects in the storage selected by
  `CFG_FTPM_TA_TEE_STORAGE_ID`, default `TEE_STORAGE_PRIVATE` (S7). That identifier selects the REE file system
  store when it is built in, otherwise RPMB (S6). REE FS objects are encrypted and integrity-protected with keys
  derived from the platform's hardware unique key (HUK) and the TA's UUID, and are written to the Linux file system
  by `tee-supplicant` (S6). When both REE FS and RPMB storage are built in, OP-TEE keeps a hash of the REE FS state
  in RPMB; without RPMB the REE FS state has no rollback anchor (S6). RPMB is #62's topic. The documentation also
  warns that a platform without a hardware unique key implementation falls back to a constant key, which leaves
  the stored objects readable and copyable to other devices (S6); whether the i.MX 95 port implements it is
  unconfirmed (item 1 below).
- **What a Linux-side attacker reaches.** Root on Linux can send any TPM command to the fTPM (the Linux kernel's
  firmware-TPM driver exposes it as an ordinary TPM device: general knowledge, not read at a tag here); TPM
  authorisation and policy still apply. Root can delete or replace the encrypted NV files (denial of service, and
  rollback unless RPMB anchors them), and can stop `tee-supplicant`, which stalls the TA's storage. Root cannot read
  key material unless secure DRAM is reachable (#63) or the HUK path is weak (unconfirmed for the i.MX 95).
- **go-xkms backend.** The TPM2 backend, through the Linux TPM device.
- **What it gives beyond the enclave.** A standard TPM 2.0 interface (PCRs, quotes, sealing to PCR policy) that
  existing TPM tooling and go-xkms's TPM2 backend already speak. It is a software TPM: no physical tamper
  resistance beyond the A55 secure world, and its keys are not in the enclave.

## PKCS#11 TA

What it is (S1, S3): OP-TEE's own PKCS#11 token, built into optee_os (UUID `fd02c9da-306c-48c7-a49c-bbd827ae86ee`)
and enabled by default on i.MX. The normal world reaches it through `libckteec` in optee_client (S9), a PKCS#11
library that forwards calls to the TA. Build defaults at 4.9.0: three tokens, a 32 KiB TA heap, TEE-identity-based
login enabled, raw RSA (`CKM_RSA_X_509`) disabled, key digest and check-value attributes enabled (S3).

- **Where keys live.** Token objects and keys are created and used inside the TA in A55 secure DRAM; OP-TEE's
  software crypto does the operations. The enclave's key store is not used by the upstream TA (no ELE hook was found
  in the build files; the C source was not read to confirm).
- **What persists and where.** Token objects persist as the TA's OP-TEE persistent objects (REE FS by default, or
  RPMB), with the same HUK-derived protection and the same rollback caveat as the fTPM (S6; #62).
- **What a Linux-side attacker reaches.** Root can open sessions on the token through `libckteec` or `/dev/tee*`.
  Use of private objects needs a login: a PIN, or with TEE-identity login, an identity the TEE assigns to the calling
  client (S3). Root can watch PIN entry in Linux, delete or roll back the stored token files, and deny service.
  Sensitive, non-extractable keys stay inside the TA under the same #63 condition as above.
- **go-xkms backend.** The PKCS#11 backend, with `libckteec` as the module.

## Comparison with calling the enclave HSM API directly

The secure-key-handling row of SPEC.md (S12) already places the board's keys in the enclave's key store, never in
the clear outside it, with signing and data storage through the HSM API (RM00284 §3.4, §3.8) and attestation
through §3.12; the Generic Crypto APIs are not available on the i.MX 95 (RM00284 §3.45). RM00284 was not reachable
from the lane (S11); the section topics are taken from SPEC.md and nothing about the API's calls is stated here.
The HSM API's detail is #51.

| | fTPM TA | PKCS#11 TA | Enclave HSM API, direct |
|---|---|---|---|
| Keys live | A55 secure DRAM, in the TA | A55 secure DRAM, in the TA | Enclave key store (RM00284 §3.4 per SPEC.md) |
| Persists | OP-TEE objects, REE FS or RPMB (#62) | OP-TEE objects, REE FS or RPMB (#62) | Enclave key store, its rollback counter (RM00284 §2.4.2 per SPEC.md); export format and location: #51 |
| Root on Linux reaches | TPM commands under TPM auth; storage files; supplicant | Token under PIN or TEE identity; storage files; supplicant | Whatever the caller's messaging unit allows: IMX95RM / Security Reference Manual, missing; #51 |
| Depends on | OP-TEE, TF-A, HUK path, #63 | OP-TEE, TF-A, HUK path, #63 | The enclave firmware; no OP-TEE needed if Linux calls it |
| Interface | TPM 2.0 | PKCS#11 | NXP HSM API, no standard interface |
| Matches SPEC.md key tier | No: keys outside the enclave | No: keys outside the enclave | Yes |

A fourth shape, a custom TA that exposes PKCS#11 or TPM-like commands but keeps the keys in the enclave by calling
the HSM API from the secure world, is not upstream. It would need OP-TEE's ELE driver to expose the HSM key-store
calls, which was not confirmed at 4.9.0 (S2), and the RNG caveat in S2 shows that sharing the enclave between the
worlds has firmware limits.

## Fit with go-xkms backends

go-xkms's repository was not read in this lane; the backend names are those in the brief, and how each backend is
configured is unconfirmed.

- **TPM2 backend.** The fTPM is the only option here that it can use unchanged. Keys would be fTPM keys, not enclave
  keys, so using it for custody keys departs from the secure-key-handling row. It could serve measured boot and a
  TPM quote as device evidence, which is the device-lifecycle row's open question.
- **PKCS#11 backend.** The PKCS#11 TA through `libckteec` works with it unchanged, but again keys are outside the
  enclave. A PKCS#11 module whose keys are in the enclave (in Linux over the HSM API, or as a custom TA) would keep
  the backend and the SPEC key tier; none was found upstream.
- **An enclave backend.** go-xkms calling the HSM API directly (or through a thin device-side service) matches the
  SPEC key tier, but is a non-standard interface and is go-xkms's design, not this repository's.

## Unconfirmed items

1. The lane's read guard blocked reading C sources, so these are unconfirmed at 4.9.0: what the OP-TEE ELE driver
   implements (HUK, die ID, RNG, any key-store call), whether OP-TEE's HUK on the i.MX 95 comes from the enclave,
   how the fTPM derives its endorsement seed, and whether the PKCS#11 TA has any hardware key hook.
2. That the i.MX 95 OP-TEE port runs on the FRDM-IMX95-PRO: there is no flavour for it upstream; DDR size and
   console UART need UM12527 (not read here) and #32.
3. TrustZone isolation of secure DRAM on the i.MX 95, and its default state: needs IMX95RM and the Security
   Reference Manual (missing); #63.
4. Which messaging unit each world uses to reach the enclave, and whether both may use it at once beyond the RNG
   caveat: needs IMX95RM and the Security Reference Manual (missing); #51.
5. RM00284's content (S11): not reachable from the lane; only SPEC.md's section topics are used.
6. The Linux kernel's firmware-TPM driver and its start-up dependency on `tee-supplicant`: general knowledge, no
   kernel tag read here.
7. NXP's fork (S10): what it changes for the i.MX 95 was not surveyed.
8. go-xkms's TPM2 and PKCS#11 backend configuration: go-xkms not read.

## Owner questions

1. **Does the secure world run any TA for key custody?**
   - (a) No TA for custody: keys stay in the enclave per secure-key-handling; OP-TEE, if present, serves other roles.
   - (b) The OP-TEE PKCS#11 TA for go-xkms's PKCS#11 backend.
   - (c) The fTPM for go-xkms's TPM2 backend.
   - (d) Both (b) and (c).

   Recommendation: (a). Both TAs keep keys in A55 secure DRAM, not in the enclave, which the secure-key-handling row
   rules out for the board's keys (S12), and both rest on unconfirmed HUK and TrustZone facts.
2. **How does go-xkms reach enclave keys?**
   - (a) Directly from Linux over the HSM API.
   - (b) Through a custom TA that calls the HSM API from the secure world and exposes PKCS#11 to Linux.
   - (c) From the Cortex-M7 (the open question already in SPEC.md).

   Recommendation: none yet; it waits on #51 (what the HSM API offers each world) and the missing IMX95RM and
   Security Reference Manual (messaging-unit ownership).
3. **Is the fTPM wanted for measured boot and device evidence, beside the enclave's attestation (RM00284 §3.12)?**
   - (a) No: enclave attestation only.
   - (b) Yes: fTPM quotes over a measured-boot log, keys not used for custody.

   Recommendation: (a) until the device-lifecycle row decides what evidence the device presents; (b) adds a
   software TPM whose roots are not in the enclave.
4. **Which OP-TEE tree, if OP-TEE is used?**
   - (a) Upstream optee_os with a new FRDM-IMX95-PRO flavour.
   - (b) Upstream with `mx95evk` and board overrides.
   - (c) NXP's fork at an lf- release tag.

   Recommendation: defer to #32, which surveys the TF-A, OP-TEE and U-Boot trees.
5. **If a TA stores anything, where?**
   - (a) REE FS only.
   - (b) RPMB only.
   - (c) REE FS with RPMB as the rollback anchor.

   Recommendation: defer to #62; the sources show REE FS alone has no rollback anchor (S6).
6. **Which world owns the enclave's RNG at runtime?**
   - (a) Keep OP-TEE's software PRNG default and leave the kernel's enclave driver on (S2).
   - (b) Turn the kernel's enclave driver off and give OP-TEE the enclave RNG.

   Recommendation: (a) unless a TA is adopted under question 1; it only matters if OP-TEE generates keys.
