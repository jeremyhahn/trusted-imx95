# secure-key-handling: RNG and entropy survey (i.MX 95)

> **Status: SURVEY (informative)** · Row: secure-key-handling ([SPEC.md](../SPEC.md)) · Issue #110 · Surveyed: 2026-11-12
> Public sources only. Vendor text is summarised, never copied. Anything not confirmed from a source is marked **unconfirmed**.

## 1. Scope and method

## 2. Sources surveyed

## 3. The i.MX 95's random sources

## 4. How Linux reaches them

### 4.1 NXP's kernel (linux-imx, tag `lf-6.12.49-2.2.0`) [S1]

- The enclave is reached through NXP's secure-enclave driver (`drivers/firmware/imx/se_ctrl.c`, Kconfig `IMX_SEC_ENCLAVE`), which talks to the enclave firmware over a Messaging Unit. It is built as a module by default (`default m if ARCH_MXC`). It binds to the device-tree compatible `fsl,imx95-se`. [S1]
- On the i.MX 95 the driver's interface table starts the enclave's RNG context at probe (an "ELE start RNG" request, message id `0xA3`, in `ele_base_msg.c`) and then registers a kernel hwrng (`ele_trng.c`, Kconfig `IMX_ELE_TRNG`, `default y` once the enclave driver is enabled). [S1]
- The hwrng is named `ele-trng` and declares quality 1024, the maximum: the kernel's hwrng core credits it with full entropy per bit read and, being the best-quality source, selects it as the current rng and feeds it to the kernel's random pool through `add_hwgenerator_randomness` (`drivers/char/hw_random/core.c` in the same tag). [S1]
- Each hwrng read becomes an enclave "get random" request (message id `0xCD`, `ele_fw_api.c`) of at most 16 bytes. A comment in the driver says this follows the RBG3(RS) construction of NIST SP 800-90C: a CTR_DRBG is reseeded with 256 bits of entropy and then yields 128 full-entropy bits. [S1]
- The driver sets a "blocking reseed" flag (wait for TRNG entropy, then reseed the DRBG) on every request **except on the i.MX 95 and i.MX 94**, where the flag is left clear. Why the flag is withheld on the i.MX 95, and whether the enclave firmware then still reseeds per request, is not stated in the source and is **unconfirmed**. [S1]
- The same table gives the i.MX 95 a second interface of V2X type with its own start-RNG hook (`v2x_start_rng`), but no hwrng on it. [S1]
- The driver also exposes the enclave's message interface to user space as character devices, which is how NXP's user-space HSM library reaches the enclave (see §4.3). [S1]

### 4.2 Mainline Linux

- Mainline Linux (`torvalds/linux`, `master` at `v7.4-rc2`) has no EdgeLock Enclave driver in `drivers/firmware/imx/` and so no `ele-trng` hwrng; it carries only the SCU and System Manager drivers there. [S2] An image built on a mainline kernel would have no enclave hwrng unless the NXP driver is carried as a patch.
- Mainline does have the generic OP-TEE hwrng (`drivers/char/hw_random/optee-rng.c`), which reads random bytes from a pseudo trusted application in OP-TEE (§5); NXP's tag carries the same driver. [S1][S2]

## 5. How OP-TEE reaches them

### 5.1 NXP's OP-TEE (imx-optee-os, tag `lf-6.12.49-2.2.0`) [S3]

- For the i.MX 95 platform flavours (the only one listed is `mx95evk`; there is no FRDM-IMX95 flavour, so which flavour this board builds with is **unconfirmed**) the platform makefile forces the CAAM driver off and enables the enclave driver (`CFG_IMX_ELE ?= y`) over the Messaging Unit. [S3]
- The enclave driver (`core/drivers/crypto/ele/ele.c`) uses three enclave commands for randomness: start RNG (`0xA3`), TRNG state (`0xA4`) and get random (`0xCD`), the same ids the Linux driver uses. The TRNG state reply carries two fields, the TRNG state and the RNG-context state, and the driver treats anything but "both ready" as busy. [S3]
- OP-TEE asks the enclave for its ASLR seed early in its own boot (`plat_get_aslr_seed`): it starts the RNG, polls the TRNG state until ready with a 10 ms time-out (panicking on time-out), and reads the seed with the "no reseed" flag. A comment there says the TRNG must be started earlier in boot to have gathered enough entropy. [S3]
- **By default OP-TEE does not use the enclave for its runtime randomness on the i.MX 95.** The ELE makefile (`core/drivers/crypto/ele/crypto.mk`) sets `CFG_WITH_SOFTWARE_PRNG ?= y`, with a comment that defects in the enclave firmware stop OP-TEE and the Linux driver from using the RNG at the same time; OP-TEE's runtime RNG is then OP-TEE's software PRNG, and the enclave's `hw_get_random_bytes` path (also "no reseed") is compiled only when that option is turned off, which the comment says is safe only with the Linux enclave driver disabled. [S3] Which enclave firmware versions have this defect, and whether a later one fixes it, is **unconfirmed**: no public NXP errata or release note found in this survey names it.

### 5.2 Upstream OP-TEE (`OP-TEE/optee_os`, tag `4.9.0`) [S4]

- Upstream carries the same enclave driver (`core/drivers/crypto/ele/ele.c`) with the same `CFG_WITH_SOFTWARE_PRNG ?= y` default and the same comment about concurrent use by OP-TEE and Linux; the i.MX 95 flavour list there is also `mx95evk` only. [S4] (My first listing, through the GitHub contents API, missed the `crypto/ele` directory; the shallow clone of tag `4.9.0` shows it.)
- OP-TEE offers randomness to the normal world through a hardware-RNG pseudo TA (`core/pta/hwrng.c`, built only with `CFG_HWRNG_PTA`), which Linux reads through the `optee-rng` hwrng (§4.2). The i.MX platform makefile does not mention `CFG_HWRNG_PTA` in either tree, so by default no `optee-rng` hwrng appears beside `ele-trng`; whether a global default turns it on was not checked and is **unconfirmed**. [S3][S4]
- Upstream's software PRNG is `core/crypto/rng_fortuna.c`; how it is seeded on the i.MX 95 when the enclave path is compiled out was not traced and is **unconfirmed**. [S4]

## 6. Health tests and certification claims

## 7. Entropy early in boot

## 8. Recommendation

## 9. What could not be confirmed

## 10. Questions for the owner
