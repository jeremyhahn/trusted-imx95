# device-lifecycle: public survey of EdgeLock device attestation on the i.MX 95

> **Status: SURVEY, for the owner's decision** · Row: device-lifecycle (#25) · Issue: #40 · Surveyed: 2026-11-12
>
> This record uses public sources only. Each claim cites a source from the [Sources](#sources) table as **[Sn]**. Vendor text is summarised, never copied. Anything the sources did not show is marked **unconfirmed**. The record builds nothing, and it runs or scripts no fuse, life-cycle or provisioning step.

## Question

[docs/SPEC.md](../SPEC.md) (row `device-lifecycle`) leaves two things open for the owner: what evidence the board presents to go-trusted-platform's control plane, and what root that evidence chains to. This survey sets out what the public material shows about four things:

- the evidence the EdgeLock secure enclave (ELE) can produce;
- the key and certificate chain behind that evidence;
- the nonce and freshness;
- how the evidence could reach a remote verifier.

## 1. What evidence the enclave can produce

### 1.1 Device attestation (ELE command 0xDB)

NXP's public ELE library, `imx-secure-enclave`, has a device attestation call, `hsm_dev_attest`, which runs inside an open HSM session [S1].

- **Fields returned [S1].** The response describes the chip and the enclave:
  - the SoC ID and SoC revision;
  - the life-cycle value;
  - the state of the security subsystem state machine;
  - the chip's unique identifier;
  - a SHA-256 over the enclave's ROM patch fuses;
  - the first 256 bits of the hash of the installed enclave firmware;
  - the caller's nonce, echoed back, and a nonce from the firmware;
  - a signature.
- **Versions [S1].** There are three versions of the response:
  - version 2 adds the OEM SRK hash (the hash of the OEM's boot-signing root keys), the IMEM state, the CSAL state and the TRNG state;
  - version 3 adds a second OEM SRK hash for post-quantum keys.
- **Version used on the i.MX 95 [S1].** The library chooses the version from the SoC ID and revision. On the i.MX 95 it uses version 2 for revisions A0 and A1, and version 3 for revision B0 and later. Version 1 is not used on the i.MX 95.
- **Signed region [S1].** The library returns a buffer that runs from the start of the device-information block to the end of the nonce, and marks it as the data the signature covers. The signature is 96 bytes.
- **Signature algorithm: unconfirmed.** A 96-byte signature fits an ECDSA P-384 signature (r‖s), but that is an inference. No public source read here names the algorithm.
- **No verification in the library's own test [S1].** The test only prints the buffer; it does not check the signature.
- **Command code [S1, S3].** The library sends this request through the ELE message interface. U-Boot's ELE status decoder names the command `ELE_ATTEST_REQ` (0xDB), and an indication `ELE_MUST_ATTEST_FAILURE_IND` (0xB7) [S3]. Neither source says what the 0xB7 indication means for a device in the field: **unconfirmed**.

### 1.2 Public key attestation

- **The call [S1].** The same library has `hsm_pub_key_attest`. It attests the public key of an asymmetric key held in the enclave's key store, using a second key from the store as the attesting key.
- **Algorithms [S1].** CMAC, or ECDSA with SHA-224, SHA-256, SHA-384 or SHA-512.
- **Challenge and output [S1].** The call takes a caller-supplied challenge. It returns what the library calls a certificate, encoded as a signed TLV buffer.
- **Opening the call [S1].** It runs inside a signature-generation service flow.
- **Not confirmed:**
  - the layout of the TLV certificate;
  - whether the attesting key can itself be chained to an NXP or OEM root;
  - which key types may serve as the attesting key.

Together, the two calls could give:

- **device attestation (1.1):** which chip this is, in which life cycle, running which enclave firmware, and under which OEM boot-signing root;
- **public key attestation (1.2):** that a particular key, for example one that go-xkms uses, lives in that chip's key store.

### 1.3 Get-info (ELE command 0xDA)

- **What it returns [S2, S4, S5].** The get-info request, which carries no signature, is used by three parties: NXP's Linux driver [S2], OP-TEE's ELE driver [S4] and SPSDK's `nxpele` tool [S5]. Its response includes the attestation API version [S4, S5].
- **Use.** It identifies the device, but it is not evidence, because nothing in it is signed.

### 1.4 What the enclave evidence does not cover

- **Not measured.** None of the fields in 1.1 is a measurement of the Linux image, the kernel or user space [S1].
- **What it does show.** The OEM SRK hash identifies the signing root that AHAB secure boot checks containers against. That is signing-root identity evidence, not image attestation. Every image signed under the same root gives the same hash, so the evidence cannot tell them apart. The hash also does not show that the Linux kernel and user space were verified, or that verification was enforced, on this boot. AHAB's verification rules are documented in IMX95RM and the Security Reference Manual, which are not public and are listed as missing in [SPEC](../SPEC.md).
- **Not present.** No public source read here shows a measured-boot log (in the style of a TPM PCR or a DICE chain) that the ELE keeps or signs: **unconfirmed / not found**.

## 2. Key and certificate chain

- **Root of the device attestation signature: unconfirmed.** The sources read here do not say which key signs the device attestation response. They do not say whether that key is per device or per product, how its public key or certificate is published, or whether NXP runs a CA for it. NXP's HSM API reference (RM00284 §3.12, cited in [SPEC](../SPEC.md)) is a vendor document; this lane did not read it, and it may answer these questions.
- **Public key attestation.** The chain behind it is also unconfirmed. Its root is whatever key the caller names as the attesting key [S1], so the trust in it depends on how that key was put in place.
- **OEM import route.** SPEC's `oem-key-provisioning` row describes the vendor's key-exchange-and-import flow (AN14861, RM00284 §3.20). That flow could install an OEM-owned attesting key. Whether such an imported key may be used to attest other keys is **unconfirmed**.
- **EdgeLock 2GO.** NXP's provisioning service is documented in SPSDK's `el2go-host` tool [S5]. That tool talks to "EdgeLock 2GO NXP Provisioning Firmware" on MCU-class devices: it creates device groups and secure objects and provisions them, and it names MCX N parts for per-product provisioning. Two things are **unconfirmed**:
  - that EdgeLock 2GO supports the i.MX 95;
  - that it issues device attestation certificates.

  The provisioning-methods note that SPSDK links to (NXP AN14544) was not read.

## 3. Nonce and freshness

- **Two nonces [S1].** The verifier's nonce is 16 bytes in versions 2 and 3 (4 bytes in version 1, which the i.MX 95 does not use). The enclave echoes it back and adds a nonce of its own. Both sit inside the signed region.
- **Freshness.** A verifier that picks a fresh random nonce for each request, and checks the echo, gets freshness without needing a clock on the device. That is the challenge-response model of the RATS architecture [S7].
- **Not confirmed:**
  - what the firmware nonce is for;
  - whether the enclave rate-limits or counts attestation requests.

## 4. Carrying the evidence to a remote verifier

- **Software path on the Cortex-A55 [S1, S2, S6].**
  - The public library runs in Linux user space [S1].
  - It reaches the enclave through the misc devices that NXP's kernel driver `se_ctrl` creates, one for each messaging-unit channel [S2].
  - Mainline Linux, at v7.4-rc2, has no ELE driver in `drivers/firmware/imx` [S6]. The A55 path therefore depends on NXP's kernel tree for now.
- **Cortex-M7 path: unconfirmed.** No public source read here shows the Cortex-M7 sending ELE requests. This ties to SPEC's open question about which side calls the HSM API.
- **OP-TEE [S4].**
  - OP-TEE enables its ELE driver by default for the `mx95evk` flavour. It uses get-info and the enclave's key derivation, which it uses for the OP-TEE hardware unique key.
  - It does not call device attestation.
  - OP-TEE's own attestation pseudo-TA signs with an RSA key that OP-TEE generates.
  - Its Veraison attestation pseudo-TA uses the PSA token format. It describes itself as a proof of concept that is not anchored to a platform root of trust.

  Neither pseudo-TA, as it stands, gives evidence rooted in the enclave.
- **Formats.** The RATS architecture [S7] defines roles that fit this board:
  - the attester is the board;
  - the verifier is go-trusted-platform's control plane;
  - the relying party is go-xkms or the fleet policy.

  Raw enclave evidence could be carried as-is, or wrapped in an Entity Attestation Token. The EAT specification (RFC 9711) and the PSA token RFC were **not read in this lane**, so how well they fit is unconfirmed.
- **Verifier side [S8].** go-trusted-platform (v0.1.0-alpha) lists `hsm-device-lifecycle` as a future feature that has not started (its issue #884). Its public specification shows no verifier for ELE evidence.

## Sources

| # | Title | Version surveyed | URL |
|---|---|---|---|
| S1 | NXP `imx-secure-enclave` (ELE HSM library): `include/hsm/internal/hsm_dev_attest.h`, `hsm_pub_key_attest.h`, `src/common/sab_msg/sab_dev_attest.c`, `src/common/se_global_info.c`, `test/common/test_dev_attest.c` | branch `lf-6.18.20_2.0.0`, tag `lf-6.18.20-2.0.0`, commit d7e1180 (2026-06-09) | https://github.com/nxp-imx/imx-secure-enclave |
| S2 | NXP `linux-imx`: `drivers/firmware/imx/se_ctrl.c`, `ele_base_msg.[ch]` | branch `lf-6.18.y`, commit 6e694ed (2026-09-08) | https://github.com/nxp-imx/linux-imx |
| S3 | NXP `uboot-imx`: `arch/arm/mach-imx/ele_ahab.c`, `arch/arm/include/asm/mach-imx/ele_api.h` | branch `lf_v2026.04`, commit bb41975 (2026-09-03) | https://github.com/nxp-imx/uboot-imx |
| S4 | OP-TEE `optee_os`: `core/drivers/crypto/ele/ele.c`, `core/arch/arm/plat-imx/conf.mk`, `core/pta/attestation.c`, `core/pta/veraison_attestation/README.md` | `master`, commit 3a19c71 (2026-11-11); latest tag 4.9.0-rc1 | https://github.com/OP-TEE/optee_os |
| S5 | NXP SPSDK: `spsdk/ele/ele_message.py`, `ele_constants.py`, `docs/apps/el2go-host.rst` | `master`, commit e104adf (2026-11-03); latest tag v3.9.0 | https://github.com/nxp-mcuxpresso/spsdk |
| S6 | Linux mainline: `drivers/firmware/imx/` | v7.4-rc2, commit 9d66f26 (2026-11-11) | https://github.com/torvalds/linux |
| S7 | RFC 9334, Remote ATtestation procedureS (RATS) Architecture, as cited by S4's Veraison README | RFC 9334 (not re-read in this lane) | https://datatracker.ietf.org/doc/rfc9334 |
| S8 | go-trusted-platform: `docs/SPEC.md` (row `hsm-device-lifecycle`), `ROADMAP.md` | `main`, commit 641fd51 (2026-11-11), VERSION 0.1.0-alpha | https://github.com/jeremyhahn/go-trusted-platform |

### Sources not reached or not read (unconfirmed)

- NXP RM00284, EdgeLock Enclave HSM API (§3.12 device attestation): a vendor document in the private reference set, not read here.
- NXP AN14544, EdgeLock 2GO provisioning methods: https://docs.nxp.com/bundle/AN14544/page/topics/edgelock_2go_provisioning_methods.html (not read).
- i.MX 95 Reference Manual (IMX95RM) and the i.MX 95 Security Reference Manual: not public, listed as missing in [SPEC](../SPEC.md).
- RFC 9711 (Entity Attestation Token) and the IETF PSA attestation token document (draft-tschofenig-rats-psa-token, cited by S4): not read.
- Veraison services: https://github.com/veraison/services (not read).
- NXP public product pages for EdgeLock 2GO and for the FRDM-IMX95-PRO silicon revision: not read.

## Questions for the owner

1. **What evidence does the board present?**
   - (a) The enclave's device attestation response alone (1.1).
   - (b) (a) plus a public key attestation (1.2) for each key go-xkms uses.
   - (c) (a) or (b) wrapped in an Entity Attestation Token by a Linux agent.
   - (d) Evidence from an OP-TEE pseudo-TA.

   *Recommendation:* (b), carried verbatim. Only (a) and (b) are produced by the enclave itself [S1]. The OP-TEE pseudo-TAs, by their own account, are not rooted in the platform [S4]. A token wrapper (c) can be added later without changing what the enclave signs.

2. **What root does the evidence chain to?**
   - (a) An NXP-published attestation key or CA.
   - (b) The board's attestation public key and chip UID, recorded at provisioning in a trusted facility and pinned by go-trusted-platform (trust on first use, at the factory).
   - (c) An OEM attesting key imported through the key-exchange flow (SPEC `oem-key-provisioning`).

   *Recommendation:* none yet; the sources do not support one. (a) cannot be confirmed from public material (section 2). Ask NXP, or read RM00284 §3.12, before choosing. If (a) is not available, (b) is the reversible fallback.

3. **Which response versions are accepted, and how is freshness enforced?**
   - (a) Accept version 2 and version 3, with a 16-byte verifier nonce per request.
   - (b) Accept version 3 only, which means i.MX 95 revision B0 or later.

   *Recommendation:* (a), with the verifier choosing the nonce and checking the echo [S1, S7]. The silicon revision on the FRDM-IMX95-PRO is **unconfirmed**; if it is B0 or later, (b) costs nothing.

4. **How is the image attested?**
   - (a) Rely on AHAB secure boot, with the OEM SRK hash in the evidence (1.4). This gives signing-root identity evidence only, not image attestation.
   - (b) (a) plus a measured-boot or IMA log from the Linux side, signed by a key held in the enclave and attested under question 1(b).
   - (c) Defer image attestation.

   *Recommendation:* image attestation stays **unresolved (missing)**. (a) can be carried now, but only as evidence of the signing root, not of the booted image (1.4). The enclave evidence does not measure the Linux image [S1]. Image attestation needs evidence that binds trusted measurements of the booted image to the device and to the verifier's challenge. (b) is a candidate once the `hsm-self-defence` question on the IMA log is answered, but whether its measurements can be trusted and bound in this way is unconfirmed.

5. **Which side calls the attestation API?** (This is SPEC's open question on the HSM API caller.)
   - (a) The Cortex-A55 Linux side, through `imx-secure-enclave` and NXP's `se_ctrl` driver.
   - (b) The Cortex-M7.

   *Recommendation:* (a). It is the only path the public sources show [S1, S2]. Note that it depends on NXP's kernel tree, because mainline has no ELE driver [S6]. The M7 path is unconfirmed.

6. **Should EdgeLock 2GO be used for provisioning or attestation certificates?**
   - (a) Yes.
   - (b) No.
   - (c) Decide after NXP confirms i.MX 95 support.

   *Recommendation:* (c). The public tooling shows only MCU support [S5].

7. **Over which channel is the evidence carried?**
   - (a) go-xkms's `hsm-device-protocol`.
   - (b) go-trusted-platform's enrollment and attestation API.

   *Recommendation:* none here. Both sides belong to other repositories (go-xkms #1521; go-trusted-platform #884 [S8]), and this repository writes no requirement before they decide.
