# secure-key-handling: RNG and entropy survey (i.MX 95)

> **Status: SURVEY (informative)** · Row: secure-key-handling ([SPEC.md](../SPEC.md)) · Issue #110 · Surveyed: 2026-11-12
> Public sources only. Vendor text is summarised, never copied. Anything not confirmed from a source is marked **unconfirmed**.

## 1. Scope and method

This survey covers where the i.MX 95's random numbers come from, how Linux, OP-TEE and U-Boot reach them, any public health-test or certification claims, how early in boot good entropy is available, and where this board's keys should get their randomness. It answers issue #110 for the secure-key-handling row of [SPEC.md](../SPEC.md).

Method: I read the public source trees at the tags in §2, fetched them on 2026-11-12, and searched the public NIST CSRC validation lists. Vendor documents in [references/](../references/README.md), such as RM00284, are not used as sources here. Each claim carries a source tag `[Sn]`. A claim with no tag, or marked **unconfirmed**, is not established by a public source. Nothing here was run on a board.

## 2. Sources surveyed

| Tag | Source | Version | URL |
|---|---|---|---|
| S1 | NXP Linux kernel for i.MX (`linux-imx`): `drivers/firmware/imx/{se_ctrl.c, ele_base_msg.[ch], ele_fw_api.[ch], ele_trng.c, Kconfig}`, `drivers/char/hw_random/{core.c, optee-rng.c}` | tag `lf-6.12.49-2.2.0` | https://github.com/nxp-imx/linux-imx/tree/lf-6.12.49-2.2.0 |
| S2 | Mainline Linux: `drivers/firmware/imx/` listing, `drivers/char/hw_random/` | `master` at `v7.4-rc2` | https://github.com/torvalds/linux |
| S3 | NXP OP-TEE for i.MX (`imx-optee-os`): `core/drivers/crypto/ele/{ele.c, crypto.mk}`, `core/arch/arm/plat-imx/conf.mk` | tag `lf-6.12.49-2.2.0` | https://github.com/nxp-imx/imx-optee-os/tree/lf-6.12.49-2.2.0 |
| S4 | Upstream OP-TEE (`optee_os`): `core/drivers/crypto/ele/`, `core/arch/arm/plat-imx/conf.mk`, `core/pta/{hwrng.c, sub.mk}`, `core/crypto/rng_fortuna.c`, `core/arch/arm/kernel/boot.c` | tag `4.9.0` | https://github.com/OP-TEE/optee_os/tree/4.9.0 |
| S5 | NXP U-Boot for i.MX (`uboot-imx`): `drivers/misc/imx_ele/ele_api.c`, `drivers/rng/{ele_rng.c, Kconfig}`, `board/freescale/imx95_frdm/spl.c`, `configs/imx95_15x15_frdm_defconfig`, `arch/arm/mach-imx/imx9/scmi/soc.c` | tag `lf-6.12.49-2.2.0` | https://github.com/nxp-imx/uboot-imx/tree/lf-6.12.49-2.2.0 |
| S6 | NIST CSRC, Entropy Source Validations, vendor search "NXP" | fetched 2026-11-12 | https://csrc.nist.gov/projects/cryptographic-module-validation-program/entropy-validations/search |
| S7 | NIST CSRC, Entropy Certificate #E244, "RNG4_ES i.MX93" | B1, validated 2025-04-25 | https://csrc.nist.gov/projects/cryptographic-module-validation-program/entropy-validations/certificate/244 |
| S8 | NIST CSRC, CMVP validated modules, vendor "NXP", status Active | fetched 2026-11-12 | https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search |
| S9 | NIST CSRC, CMVP Modules In Process list | fetched 2026-11-12 | https://csrc.nist.gov/Projects/cryptographic-module-validation-program/modules-in-process/modules-in-process-list |

**Not reached:** NXP's i.MX 95 product pages on nxp.com (HTTP 404 on `https://www.nxp.com/products/i.MX-95` and `https://www.nxp.com/products/i.MX95`). **Not used:** the i.MX 95 Reference Manual (IMX95RM), the i.MX 95 Security Reference Manual, the EdgeLock enclave firmware release notes and the SE051 documentation. None was found among the public sources reached, and SPEC lists all of them as missing. Whether NXP publishes any of them without a login is **unconfirmed**.

## 3. The i.MX 95's random sources

- **The enclave's TRNG and DRBG.** Every public software stack surveyed (Linux, OP-TEE, U-Boot) gets hardware randomness on the i.MX 95 from the EdgeLock secure enclave firmware, through the same three messages: start RNG, read TRNG state, get random. None of them touches an RNG peripheral register directly. [S1, S3, S5]
- The TRNG state reply has two parts: the TRNG itself and the enclave's RNG context (its DRBG). Both must report ready before random data is served. [S3, S5]
- The Linux driver's comment describes the enclave's output as a CTR_DRBG reseeded from the TRNG, used in the NIST SP 800-90C RBG3(RS) way (16-byte reads, a reseed per read) on other SoCs. Whether that per-read reseed happens on the i.MX 95, where the reseed flag is not sent, is **unconfirmed** (§4.1). [S1]
- **No CAAM.** NXP's and upstream OP-TEE both force the CAAM driver off for the i.MX 95 flavour. So the CAAM RNG that older i.MX parts expose (and that the Linux `caam_rng` hwrng uses) does not apply here. [S3, S4]
- **No CPU RNG instruction.** The Cortex-A55 is an Armv8.2-A core. The `RNDR` instruction (FEAT_RNG) belongs to Armv8.5-A, so Linux's `arch_get_random` has no CPU source on this SoC. This comes from the architecture versions, not from an i.MX 95 document, and is **unconfirmed** for this part.
- **The SE051** on the board (SPEC row secure-key-handling) is a secure element and presumably has its own RNG, but that is **unconfirmed**. Its documentation is not in the references and it was not surveyed; whether it is used is a question for the owner (§10).
- The hardware entropy source inside the enclave is not named in any i.MX 95 source found. NXP has a NIST SP 800-90B entropy-source validation for "RNG4_ES i.MX93" (§6). Whether the i.MX 95 enclave uses the same RNG4 noise source is **unconfirmed**.

## 4. How Linux reaches them

### 4.1 NXP's kernel (linux-imx, tag `lf-6.12.49-2.2.0`) [S1]

- The enclave is reached through NXP's secure-enclave driver (`drivers/firmware/imx/se_ctrl.c`, Kconfig `IMX_SEC_ENCLAVE`), which talks to the enclave firmware over a Messaging Unit. It is built as a module by default (`default m if ARCH_MXC`). It binds to the device-tree compatible `fsl,imx95-se`. [S1]
- On the i.MX 95 the driver's interface table starts the enclave's RNG context at probe (an "ELE start RNG" request, message id `0xA3`, in `ele_base_msg.c`) and then registers a kernel hwrng (`ele_trng.c`, Kconfig `IMX_ELE_TRNG`, `default y` once the enclave driver is enabled). [S1]
- The hwrng is named `ele-trng` and declares quality 1024, the maximum: the kernel's hwrng core credits it with full entropy per bit read and, being the best-quality source, selects it as the current rng and feeds it to the kernel's random pool through `add_hwgenerator_randomness` (`drivers/char/hw_random/core.c` in the same tag). [S1]
- Each hwrng read becomes an enclave "get random" request (message id `0xCD`, `ele_fw_api.c`) of at most 16 bytes. A comment in the driver says this follows the RBG3(RS) construction of NIST SP 800-90C: a CTR_DRBG is reseeded with 256 bits of entropy and then yields 128 full-entropy bits. [S1]
- The driver sets a "blocking reseed" flag (wait for TRNG entropy, then reseed the DRBG) on every request **except on the i.MX 95 and i.MX 94**, where the flag is left clear. Why the flag is withheld on the i.MX 95, and whether the enclave firmware then still reseeds per request, is not stated in the source and is **unconfirmed**. [S1]
- The same table gives the i.MX 95 a second interface of V2X type with its own start-RNG hook (`v2x_start_rng`), but no hwrng on it. [S1]
- The driver also exposes the enclave's message interface to user space as character devices. [S1] NXP's user-space enclave library (`imx-secure-enclave`) presumably reaches the enclave through them; that library was not surveyed, so this is **unconfirmed**.

### 4.2 Mainline Linux

- Mainline Linux (`torvalds/linux`, `master` at `v7.4-rc2`) has no EdgeLock Enclave driver in `drivers/firmware/imx/` and so no `ele-trng` hwrng; it carries only the SCU and System Manager drivers there. [S2] An image built on a mainline kernel would have no enclave hwrng unless the NXP driver is carried as a patch.
- Mainline does have the generic OP-TEE hwrng (`drivers/char/hw_random/optee-rng.c`), which reads random bytes from a pseudo trusted application in OP-TEE (§5); NXP's tag carries the same driver. [S1, S2]

## 5. How OP-TEE reaches them

### 5.1 NXP's OP-TEE (imx-optee-os, tag `lf-6.12.49-2.2.0`) [S3]

- For the i.MX 95 platform flavours (the only one listed is `mx95evk`; there is no FRDM-IMX95 flavour, so which flavour this board builds with is **unconfirmed**) the platform makefile forces the CAAM driver off and enables the enclave driver (`CFG_IMX_ELE ?= y`) over the Messaging Unit. [S3]
- The enclave driver (`core/drivers/crypto/ele/ele.c`) uses three enclave commands for randomness: start RNG (`0xA3`), TRNG state (`0xA4`) and get random (`0xCD`), the same ids the Linux driver uses. The TRNG state reply carries two fields, the TRNG state and the RNG-context state, and the driver treats anything but "both ready" as busy. [S3]
- OP-TEE asks the enclave for its ASLR seed early in its own boot (`plat_get_aslr_seed`): it starts the RNG, polls the TRNG state until ready with a 10 ms time-out (panicking on time-out), and reads the seed with the "no reseed" flag. A comment there says the TRNG must be started earlier in boot to have gathered enough entropy. [S3]
- **By default OP-TEE does not use the enclave for its runtime randomness on the i.MX 95.** The ELE makefile (`core/drivers/crypto/ele/crypto.mk`) sets `CFG_WITH_SOFTWARE_PRNG ?= y`, with a comment that defects in the enclave firmware stop OP-TEE and the Linux driver from using the RNG at the same time; OP-TEE's runtime RNG is then OP-TEE's software PRNG, and the enclave's `hw_get_random_bytes` path (also "no reseed") is compiled only when that option is turned off, which the comment says is safe only with the Linux enclave driver disabled. [S3] Which enclave firmware versions have this defect, and whether a later one fixes it, is **unconfirmed**: no public NXP errata or release note found in this survey names it.

### 5.2 Upstream OP-TEE (`OP-TEE/optee_os`, tag `4.9.0`) [S4]

- Upstream carries the same enclave driver (`core/drivers/crypto/ele/ele.c`) with the same `CFG_WITH_SOFTWARE_PRNG ?= y` default and the same comment about concurrent use by OP-TEE and Linux; the i.MX 95 flavour list there is also `mx95evk` only. [S4] (My first listing, through the GitHub contents API, missed the `crypto/ele` directory; the shallow clone of tag `4.9.0` shows it.)
- OP-TEE offers randomness to the normal world through a hardware-RNG pseudo TA (`core/pta/hwrng.c`, built only with `CFG_HWRNG_PTA`), which Linux reads through the `optee-rng` hwrng (§4.2). The i.MX platform makefile does not mention `CFG_HWRNG_PTA` in either tree, so by default no `optee-rng` hwrng appears beside `ele-trng`; whether a global default turns it on was not checked and is **unconfirmed**. [S3, S4]
- Upstream's software PRNG is `core/crypto/rng_fortuna.c`; how it is seeded on the i.MX 95 when the enclave path is compiled out was not traced and is **unconfirmed**. [S4]

## 6. Health tests and certification claims

- **Entropy-source validations (NIST ESV, SP 800-90B).** On 2026-11-12 the NIST ESV search lists five NXP certificates. Four are named "RNG4_ES": E106 (2023-12-11), E184 and E185 (2024-09-03), and E244 "RNG4_ES i.MX93", version B1 (2025-04-25, physical noise source, 0.827708 bits of entropy per 1-bit sample, lab EWA-Canada). The fifth is E148, for JCOP 4.5 on P71D600. [S6, S7] **None names the i.MX 95.**
- **Module validations (NIST CMVP, FIPS 140-3).** The active NXP certificates on 2026-11-12 are 5139 (SE052F), 4839 (i.MX8 DXL V2X), 4837 (i.MX8 DXL SECO HSM) and 4679 (JCOP 4.5 on P71D600). [S8] **None covers the i.MX 95 or its EdgeLock enclave.** In the modules-in-process list as fetched, no row names NXP. [S9] The list changes often, so this is a point-in-time reading.
- **Health tests.** No public source found describes the i.MX 95 enclave's TRNG health tests (the SP 800-90B repetition-count and adaptive-proportion tests, or NXP's own). The software only shows their effect: a TRNG or RNG-context state other than ready, which callers treat as busy (§3). Health-test behaviour, and what the enclave does when a test fails, is **unconfirmed**. It is probably in the i.MX 95 Security Reference Manual, which SPEC lists as missing.
- NXP's public i.MX 95 product pages could not be reached from the lane (HTTP 404 on two URLs tried), so NXP's marketing claims for the enclave (for example any SESIP, PSA or FIPS "designed for" claims) are **unconfirmed**.

## 7. Entropy early in boot

The surveyed sources show this order for the FRDM-IMX95 board. It is NXP's BSP `lf-6.12.49-2.2.0`; the boot ROM and enclave firmware steps before SPL are not public and are **unconfirmed**. The U-Boot sources used (`board/freescale/imx95_frdm`, `imx95_15x15_frdm_defconfig`) are for the 15x15 FRDM-IMX95 board, not the FRDM-IMX95-PRO (machine `imx95-19x19-lpddr5-frdm-pro`), which has no confirmed U-Boot defconfig ([upstream-survey.md](../secure-world/upstream-survey.md)). Steps 1 and 2 are therefore **unverified for the PRO**; the order is read from source and was not observed on any board.

1. **U-Boot SPL** (`board/freescale/imx95_frdm/spl.c`, `spl_board_init`) sends the enclave "start RNG" command as soon as SPL's board init runs. It prints a message and goes on if the command fails. [S5]
2. **U-Boot proper** reads random data only through the enclave RNG driver (`drivers/rng/ele_rng.c`, `CONFIG_IMX_ELE_RNG`, `default n`). That driver first polls the TRNG state for up to 5 ms. The FRDM defconfig (`imx95_15x15_frdm_defconfig`) does not set `CONFIG_IMX_ELE_RNG`, `CONFIG_DM_RNG` or any KASLR option, so a default FRDM U-Boot probably does not write a `kaslr-seed` into the kernel's device tree. The i.MX 9 SCMI SoC code does this only when `CONFIG_DM_RNG` is on. Whether some other Kconfig selects these options was not checked: **unconfirmed**. [S5]
3. **OP-TEE** starts the RNG again and polls the TRNG state with a 10 ms time-out to get its ASLR seed. It panics if the TRNG is still busy, so a TRNG that is not ready stops the boot rather than giving a weak seed. Its later runtime randomness comes from its software PRNG by default (§5.1). [S3]
4. **Linux** gets enclave entropy only once the `se_ctrl` driver probes. That driver is a module by default (`IMX_SEC_ENCLAVE` `default m`), so in a default build `ele-trng` exists only after the root file system is mounted and the module is loaded. Until then the kernel pool is seeded from its other inputs (interrupt and boot-time jitter, plus a device-tree `kaslr-seed` or `rng-seed` if the boot loader gave one). [S1]

**What key generation must wait for.**
- Keys generated *inside the enclave* (SPEC row: the enclave's key store) take their randomness from the enclave's own DRBG. They do not depend on the Linux pool. The surveyed host-side drivers wait for the TRNG and RNG context to report ready before asking for random data (§3); that the enclave itself refuses to serve random data before then is inferred from those drivers, not from an enclave specification, and is **unconfirmed**. That SPL has started the RNG long before any key operation holds for the 15x15 FRDM SPL source read here; on the PRO it is **unverified**, and since SPL goes on when the start command fails, a key operation must not assume the RNG was started. Whether the HSM key-generation API waits on its own for the RNG context, or fails when it was never started, is **unconfirmed**: RM00284 is the reference, and this survey did not use it because it is not a public source.
- Any key or nonce generated *on the Linux side* (for example by xkmsd, if go-xkms generates anything there) must wait until the kernel pool is initialised: `getrandom(2)` without `GRND_NONBLOCK` blocks until then. To get the hardware boost, it should also wait until `ele-trng` is registered (`/sys/class/misc/hw_random/rng_current` reads `ele-trng`). Building `IMX_SEC_ENCLAVE` into the kernel (`=y`) brings the hwrng forward to driver probe time, before user space starts. [S1]

## 8. Recommendation

1. **Long-term keys get their randomness inside the enclave.** Generate every long-term board key with the enclave's own key generation, so the key never leaves the enclave and never touches a Linux or OP-TEE RNG. This follows from the SPEC row, which already places keys in the enclave's key store. It also gives the shortest chain: one DRBG and one entropy source, both inside the enclave (§3). The open points are the enclave's health-test behaviour and the lack of an i.MX 95 entropy certificate (§6).
2. **Randomness outside the enclave comes from Linux `getrandom(2)`**, blocking, with the enclave hwrng feeding the pool. Build NXP's `IMX_SEC_ENCLAVE` and `IMX_ELE_TRNG` into the kernel (`=y`) so `ele-trng` is present before user space starts (§4.1, §7). Never read `/dev/hwrng` directly in application code. Mainline kernels have no enclave hwrng (§4.2), so the image must use NXP's kernel or carry the driver.
3. **Keep OP-TEE on its default software PRNG** (`CFG_WITH_SOFTWARE_PRNG=y`) while the Linux enclave driver is in use. NXP's own makefile warns that the enclave firmware cannot serve both at once (§5.1). How that PRNG is seeded must be confirmed before OP-TEE generates any key (§9).
4. **Optionally, enable the enclave RNG in U-Boot** (`CONFIG_DM_RNG`, `CONFIG_IMX_ELE_RNG`). Then U-Boot writes a `kaslr-seed` and the kernel gets enclave entropy before the module loads (§7). This is a boot-container decision for that row; it is recommended, not required.
5. **What go-xkms decides.** Whether xkmsd generates or wraps any secret on the Linux side (session keys, nonces, transport keys of `hsm-device-protocol`), and so whether point 2 matters for keys at all, is go-xkms's to decide. So is the RNG interface xkmsd calls. This repository only provides a seeded `getrandom(2)` and the enclave's key generation. Which side calls the enclave HSM API (A55 Linux or M7) is the existing SPEC open question, and it decides whose RNG path is used for key generation.

## 9. What could not be confirmed

- Why the Linux driver sends no "blocking reseed" flag on the i.MX 95, and whether the enclave reseeds per request anyway (§4.1).
- Which enclave firmware versions have the defect that stops OP-TEE and Linux sharing the RNG, and whether any release fixes it (§5.1).
- How OP-TEE's software PRNG is seeded on the i.MX 95 when the enclave path is compiled out (§5.2).
- Which OP-TEE platform flavour the FRDM-IMX95 board builds with: only `mx95evk` exists (§5.1).
- Whether a global OP-TEE default enables `CFG_HWRNG_PTA` (§5.2).
- Whether another U-Boot Kconfig option turns on `DM_RNG` or `IMX_ELE_RNG` for the FRDM board (§7).
- The enclave's TRNG noise source, its health tests and its failure behaviour. Whether the i.MX 95 shares the RNG4 source of ESV E244 (§3, §6).
- Any FIPS 140-3, SP 800-90B, SESIP or other certification for the i.MX 95 enclave. None was found (§6).
- Whether the enclave's HSM key generation waits for the RNG context or fails when it is not started (§7).
- The boot ROM's and enclave firmware's RNG behaviour before SPL (§7).
- That the Cortex-A55 lacks `RNDR`. This comes from architecture versions, not from an i.MX 95 document (§3).

## 10. Questions for the owner

1. **Where do long-term board keys get their randomness?**
   Options: (a) the enclave's internal key generation only; (b) generated on the A55 Linux side from `getrandom(2)`, then imported into the enclave; (c) the SE051's RNG; (d) a mix, combining sources before import.
   Recommendation: (a). The key never leaves the enclave and only one RNG is trusted (§8 point 1). (b) and (d) put a key in the clear in Linux memory, against the SPEC row.
2. **How is the Linux enclave driver built?**
   Options: (a) built in (`=y`), so `ele-trng` exists from driver probe; (b) a module (NXP's default), so it exists only after the root file system loads it.
   Recommendation: (a). It shortens the window in which the Linux pool has no hardware input (§7).
3. **Does U-Boot pass an enclave-seeded `kaslr-seed` to Linux?**
   Options: (a) enable `DM_RNG` and `IMX_ELE_RNG` in the board's U-Boot config; (b) leave NXP's FRDM default, which appears to have neither.
   Recommendation: (a), decided in the boot-container row. It is cheap and gives early entropy and KASLR. Sources do not show any cost beyond the 5 ms ready poll (§7).
4. **What is OP-TEE's runtime RNG?**
   Options: (a) the software PRNG (NXP's default), with its seed source confirmed first; (b) the enclave RNG (`CFG_WITH_SOFTWARE_PRNG=n`), which NXP says is safe only with the Linux enclave driver disabled.
   Recommendation: (a) while Linux uses the enclave hwrng (§5.1). Revisit only if a public NXP release note says the firmware defect is fixed.
5. **Is a certified entropy source a requirement?**
   Options: (a) require an SP 800-90B (ESV) or FIPS 140-3 certificate that names the i.MX 95 enclave, and block release until NXP provides one; (b) accept NXP's RNG4 certificates for other parts (E244, i.MX 93) as indicative, and record the gap; (c) no certification requirement.
   Recommendation: none from sources. No i.MX 95 certificate was found (§6). If (a) or (b), the owner should ask NXP whether the i.MX 95 enclave uses the RNG4 B1 source.
6. **Does go-xkms generate secrets on the Linux side?**
   Options: (a) no: xkmsd only forwards requests to the enclave, and all secrets are generated there; (b) yes: xkmsd generates session or transport secrets with `getrandom(2)`.
   Recommendation: this is go-xkms's decision (§8 point 5). This repository should state its RNG contract (blocking `getrandom(2)` with `ele-trng` current) in either case.
7. **Should NXP be asked for the missing documents?**
   Options: (a) request the i.MX 95 Security Reference Manual and the enclave firmware release notes, to settle the reseed flag, the health tests and the concurrency defect (§9); (b) proceed on the public sources only.
   Recommendation: (a). Most items in §9 are probably answered there, and SPEC already lists both as missing.
