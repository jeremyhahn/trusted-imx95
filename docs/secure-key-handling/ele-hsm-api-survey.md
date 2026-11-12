# EdgeLock enclave HSM API: public-source survey

> **Status: DRAFT survey for the owner** · Row: `secure-key-handling` · Issue #51 · Surveyed 2026-11-12
> Public sources only. Vendor text is summarised, never copied. Anything this survey could not confirm is marked **Unconfirmed**.

## 1. Purpose and scope

[SPEC.md](../SPEC.md)'s `secure-key-handling` row says the board's keys are generated and kept in the EdgeLock secure enclave (ELE), and are used through the enclave's HSM API. It leaves open which side calls that API: the Cortex-A55 Linux side or the Cortex-M7.
This survey covers what public sources say about that API on the i.MX 95: the software that calls it, where each piece runs, and what each choice brings with it. It ends with questions for the owner.
It does not replace RM00284 (the ELE API reference SPEC.md cites). It runs no fuse, life-cycle or provisioning step, and it scripts none.

## 2. Sources surveyed

All sources are public. Each was reached from the lane on 2026-11-12 unless it is marked unreachable.

| Id | Source | Version surveyed | URL | What was read |
|---|---|---|---|---|
| S1 | NXP, *imx-secure-enclave* (Secure Enclave user-space library) | tag `lf-6.18.37-2.1.0`, commit `4638450`, 2026-09-08; `se_version.txt` gives library 1.1.1 | https://github.com/nxp-imx/imx-secure-enclave | README, `LICENSE`, `se_version.txt`, the NVM daemon's unit and configuration files, the doc/ images, the file layout, and commit messages |
| S2 | NXP, *linux-imx* (NXP's Linux kernel tree) | branch `lf-6.18.y`, commit `6e694ed`, 2026-09-08 | https://github.com/nxp-imx/linux-imx | File layout only: `drivers/firmware/imx/`, `include/uapi/linux/se_ioctl.h`, the `fsl,imx-se-fw.yaml` binding |
| S3 | *Linux* mainline | tag `v7.3`, commit `c03c1a1` | https://github.com/torvalds/linux | File layout of `drivers/firmware/imx/` and the firmware bindings |
| S4 | *OP-TEE optee_os* | tag `4.11.0`, commit `f54190f`, 2026-10-16 | https://github.com/OP-TEE/optee_os | File layout and commit messages for `core/drivers/crypto/ele/` and `core/drivers/imx/mu/` |
| S5 | *U-Boot* | tag `v2026.10`, commit `5508406` | https://github.com/u-boot/u-boot | File layout and commit subjects for `drivers/misc/imx_ele/` and `arch/arm/mach-imx/ele_ahab.c` |
| S6 | NXP, *MCUXpresso SDK core* | branch `main`, commit `b2cee0c`, 2026-10-09 | https://github.com/nxp-mcuxpresso/mcuxsdk-core | File layout of `drivers/elemu/` and its change log (ELEMU driver 2.1.4) |
| S7 | NXP, *mcux-secure-subsystem* (SSS API middleware) | branch `main`, commit `0b420d6`, 2026-10-09; SSS API 2.1.4 | https://github.com/nxp-mcuxpresso/mcux-secure-subsystem | `README.md`, `ChangeLog.txt` and the file layout |

What could not be read:
- The source files of S1 to S7 (C, headers, YAML, Kconfig) were not read. This lane may read code only inside this repository. Each claim above therefore rests on file names, READMEs, change logs, images and commit messages, never on the code itself.
- S1's PDF API references (`doc/ele_hsm_api_document.pdf`, `doc/hsm_api_document.pdf`) could not be rendered: the lane has no PDF tool.
- Issue #51 could not be read: the lane's `gh` is not authenticated. This survey works from the lane brief and SPEC.md.
- lore.kernel.org answered HTTP 403, so the status of any ELE driver series posted to the Linux mailing lists is unknown.
- RM00284 and the other NXP documents SPEC.md cites are in the private reference set, not public. This survey cites them only through SPEC.md.

## 3. The user-space library: imx-secure-enclave

Surveyed at tag `lf-6.18.37-2.1.0` [S1]. The library's own version file gives library 1.1.1 and NVM manager 1.1.1 [S1].

### 3.1 What it is

- NXP's open user-space C library on Linux for the secure-enclave family. It offers three API families: HSM, SHE and V2X PRIME. On the ELE parts only the HSM family applies [S1 README, "Overview"].
- One source tree builds for several hardware IPs. `PLAT=ele` selects the ELE-HSM build [S1 README §2.2].
- The README's platform table marks the i.MX 95 as supported for ELE-HSM. It also lists V2X-SHE and V2X-HSM for the i.MX 95, which run on the separate V2X accelerator, not on the EdgeLock enclave [S1 README Table 1].
- The upstream repository is the GitHub mirror `nxp-imx/imx-secure-enclave`. Its tags follow the NXP Linux BSP release names (`lf-<kernel>-<bsp>`), so a BSP release pins one library version [S1 tag list].
- It is licensed under BSD-3-Clause [S1 `LICENSE`; **Unconfirmed**: the SPDX identifier was not read from the file headers, because this lane may not read code outside the repository].

### 3.2 The call model

- The library's service diagram [S1 `doc/images/hsm_services_ele.png`] shows a tree of handles:
  - a **session**: the route between the caller and the enclave. Random numbers, one-shot hashing, device information and asymmetric generic crypto hang off it;
  - under the session, a **key store** service and a **signature verification** service;
  - under the key store, the **key management**, **cipher**, **signature generation**, **data storage** and **MAC** services.
- The library's code example [S1 `doc/images/code_example_ele.png`] opens a session, then a key store, then a service on the key store, then runs one-shot operations, and closes the session, which closes every service under it.
- The API names (`hsm_open_session`, `hsm_open_key_store_service`, `hsm_open_cipher_service`, `hsm_cipher_one_go`, `hsm_auth_enc`, `hsm_hash_one_go`, `hsm_close_session`) come from that example.
- The repository holds one source file per operation family under `src/common/hsm_api/`, with one header each under `include/hsm/internal/` [S1 directory listing]. By file name, the families are:
  - key generation, import, deletion, attributes and key groups;
  - signing and verification;
  - cipher, authenticated encryption, MAC and hashing;
  - key exchange, key agreement and key derivation;
  - data storage;
  - public-key recovery and public-key attestation;
  - device attestation, device information, the monotonic counter, life-cycle update and fuse writes;
  - blobs and root-KEK export;
  - a "generic crypto" set (`hsm_gc_*`).
- What each file does on the i.MX 95, and which messages the i.MX 95 firmware accepts, was **not confirmed** from the code. The lane may not read code outside the repository, and the PDF API reference (`doc/ele_hsm_api_document.pdf`) could not be rendered in the lane.
- The `hsm_gc_*` files are present in the library. SPEC.md records that the Generic Crypto APIs are not available on the i.MX 95 (RM00284 §3.45). The library therefore builds calls that the i.MX 95 firmware is expected to reject; check this before relying on them.
- The library ships a test program (`test/hsm/hsm_test.c`) and a performance test (`test/hsm/hsm_perf_test.c`) [S1 directory listing].

### 3.3 Persistent key storage: the NVM manager

- The enclave holds no flash of its own for the key store. The library's README describes an NVM manager daemon that serves the enclave firmware as its storage agent. The daemon keeps the key-store blobs, encrypted by the enclave, as files on the Linux filesystem [S1 README "NVM Manager"].
- For ELE parts, the i.MX 95 included, the README names the storage directory `/etc/ele/` [S1 README Table 2]. The shipped configuration names a master file `ele_nvm_master` in that directory, and a messaging-unit session flag [S1 `src/common/nvm/nvmd.conf`].
- The shipped systemd unit starts `nvm_daemon` as root, early, ordered before the initrd root filesystem targets [S1 `src/common/nvm/nvm_daemon.service`].
- What this means for this row:
  - the key store's persistence depends on the Linux root filesystem and on a root daemon there. Whoever writes or rolls back `/etc/ele/` can delete the key store or replay an old one;
  - SPEC.md records that the monotonic counter, advanced by strict operations, is the enclave's defence against replay (RM00284 §2.4.2). This survey did not confirm how the daemon and the counter interact;
  - if the blobs are lost, the keys in them are likely lost too. This is an inference: the sources read do not say whether the enclave can rebuild a key store.

### 3.4 Silicon revision matters

The library's history has commits specific to i.MX 95 revisions [S1 commits `68eeb5c` and `e568b67`, 2025-09/10]:
- On i.MX 95 A1, signature verification with opaque (enclave-held) keys was not supported, so the tests skip it.
- On B1, the library changed its HSM API version check.

Which revision the FRDM-IMX95-PRO carries is **unconfirmed**. It decides which HSM operations the board can do.

## 4. The Linux kernel side

- **NXP's kernel tree carries the driver.** linux-imx `lf-6.18.y` [S2] has a secure-enclave driver set in `drivers/firmware/imx/`:
  - `se_ctrl.c`, the enclave control and messaging-unit driver;
  - `ele_base_msg.c`, `ele_common.c` and `ele_fw_api.c`, the enclave base messages;
  - `ele_trng.c`, a TRNG;
  - `ele_bbsm.c`;
  - `se_msg_sqfl_ctrl.c`.

  It also has a user-space ioctl header `include/uapi/linux/se_ioctl.h` and a device-tree binding `fsl,imx-se-fw.yaml`.
- From that layout, the S1 library most likely reaches the enclave through a character device whose ioctls `se_ioctl.h` defines. The device node names and the ioctl set are **unconfirmed**: the header was not read.
- **Mainline Linux does not have it.** Linux `v7.3` [S3] has none of these files: no `se_ctrl.c`, no `se_ioctl.h`, no `fsl,imx-se-fw.yaml`. Its `drivers/firmware/imx/` holds the SCU, DSP and System Manager (`sm-*`) drivers only.
- What this means for the row: a Linux-side caller needs either NXP's kernel tree or NXP's driver patches carried onto a mainline kernel. The choice is bound to the open question of how the platform image is built (SPEC.md Release criteria).

## 5. Other callers: OP-TEE, U-Boot and the M-core SDK

### 5.1 OP-TEE (Cortex-A55 secure world)

From S4's commit messages:
- OP-TEE supports the i.MX 95's messaging unit to the enclave (`16e0d122`, `2d65d514`, 2024-07-04). It takes the hardware unique key (HUK) and random numbers from the enclave on the i.MX 95 (`3d8c192a`, 2025-07-14).
- OP-TEE has an ECC driver backed by the enclave, with key generation, ECDSA signing and verification (`fc035904`, `404005e8`, `86794e50`, 2026-07-03). Its commit message limits it to the i.MX 91 and i.MX 93.
- That driver uses **plain-text** keys: the enclave writes the private scalar back into memory the caller supplies (`404005e8`).
- The row requires that keys never leave the enclave in the clear. The upstream OP-TEE ECC path therefore does not meet the row's requirement, and it does not build for the i.MX 95.
- OP-TEE has no upstream use of the enclave's opaque key store on the i.MX 95 that this survey could find.

### 5.2 U-Boot

S5 has an ELE messaging-unit driver and API (`drivers/misc/imx_ele/`) and AHAB support (`arch/arm/mach-imx/ele_ahab.c`). By its commit subjects, it serves boot work:
- image authentication;
- fuse read and write;
- showing the life cycle (i.MX 95 support added in `226a606c10`, 2025-09-23);
- voltage-change notices.

None of its commit subjects names the HSM key-store API. The fuse and life-cycle commands are the boot-time path, which this row must not script.

### 5.3 The Cortex-M7 side (MCUXpresso SDK)

- S6 has an ELE messaging-unit driver, `drivers/elemu` (version 2.1.4, by its change log).
- S7, the Secure Subsystem (SSS) API middleware, gives a common crypto and key-store interface to NXP secure-subsystem hardware. It also serves as a Zephyr module [S7 README].
- S7's only port is `port/kw45_k4w1` [S7 layout]. That is a wireless MCU family, not the i.MX 95.
- This survey found **no public library that calls the ELE HSM API from the i.MX 95's Cortex-M7**, and no public statement that the M7 has a messaging unit to the enclave. Both are **unconfirmed**, and RM00284 or IMX95RM would settle them.
- An M7 caller would also need its own storage agent for the key-store blobs, the role S1's NVM daemon plays on Linux (§3.3). No public M7 version of it was found.

## 6. What this means for the row's open question

| | Cortex-A55 Linux (S1 + S2) | Cortex-A55 OP-TEE (S4) | Cortex-M7 (S6, S7) |
|---|---|---|---|
| Public library for the HSM API on the i.MX 95 | Yes: S1 lists the i.MX 95 for ELE-HSM | Only HUK and RNG on the i.MX 95; ECC is i.MX 91/93 and uses plain-text keys | None found |
| Kernel or driver needed | NXP's `lf-6.18.y` driver, not in mainline v7.3 | OP-TEE's own MU driver, upstream | ELEMU driver exists; i.MX 95 M7 access unconfirmed |
| Key-store persistence | NVM daemon, files in `/etc/ele/` on Linux | Not covered upstream | Would have to be written |
| Next to xkmsd (go-xkms, on Linux per SPEC.md) | Same OS | Through a trusted application | Across cores, through a channel still to be defined |
| Attack surface the key store depends on | Linux root and the root filesystem | Secure world, plus Linux for storage if S1's daemon is reused | M7 firmware; isolated from Linux |

On public evidence, only the Cortex-A55 Linux side has a working, maintained HSM-API path on the i.MX 95 today.
The M7 side may give better isolation from Linux, which the `hsm-self-defence` row may want. But it rests on facts this survey could not confirm, and it needs software that does not exist publicly.

## 7. Unconfirmed

1. The ioctl interface and device nodes of S2's driver (`se_ioctl.h` was not read).
2. Which S1 operations the i.MX 95 firmware accepts, per revision. The PDF API reference could not be rendered; RM00284 §3.45 (via SPEC.md) excludes the Generic Crypto APIs.
3. The i.MX 95 revision on the FRDM-IMX95-PRO (A1, B1 or later), and so whether opaque-key signature verification works on it (§3.4).
4. Whether the Cortex-M7 can reach the enclave's messaging unit, and through which unit.
5. How the NVM daemon's blob storage and the enclave's monotonic counter work together against a rolled-back `/etc/ele/`.
6. Whether OP-TEE's use of the enclave (HUK and RNG) and the Linux driver can share the enclave on the same boot, and through which messaging units.
7. Whether an ELE driver series is under review for mainline Linux (lore.kernel.org was unreachable).
8. Issue #51's own text (not readable from the lane).

## 8. Questions for the owner

1. **Which side calls the ELE HSM API?**
   - (a) Cortex-A55 Linux user space, through S1.
   - (b) Cortex-A55 OP-TEE, through new trusted-application work on the opaque key store.
   - (c) The Cortex-M7, through new firmware and a new storage agent.

   *Recommendation:* (a). It is the only path with public, maintained i.MX 95 support (§6). Revisit (c) if RM00284 or IMX95RM confirms M7 access to the enclave.
2. **Which kernel carries the enclave driver?**
   - (a) NXP's `linux-imx` at the BSP branch that matches the library tag.
   - (b) Mainline Linux, carrying NXP's driver patches.
   - (c) Wait for a mainline driver.

   *Recommendation:* (a) while the platform-image build question is open. S3 shows mainline does not have the driver, and S1's tags follow the BSP releases.
3. **Which library version is pinned?**
   - (a) `lf-6.18.37-2.1.0` [S1], with the kernel of the same BSP release.
   - (b) Track the latest BSP tag each release.

   *Recommendation:* (a), pinned by tag and commit, with an update procedure for later.
4. **Where does the key-store blob storage live, and how is rollback handled?**
   - (a) The default, `/etc/ele/` on the root filesystem.
   - (b) A dedicated partition, with every key-store update made as a strict operation so the monotonic counter advances (RM00284 §2.4.2, via SPEC.md).
   - (c) Something else that RM00284 recommends.

   *Recommendation:* (b) as the starting design. The rollback interaction is unconfirmed (§7 item 5) and needs RM00284 to settle.
5. **Which i.MX 95 silicon revision is the target?**
   - (a) Confirm the board's revision and support only that one.
   - (b) Support A1 and B1.

   *Recommendation:* none until the revision is confirmed (§7 item 3). If it is A1, opaque-key signature verification is not available.
6. **May the Generic Crypto (`hsm_gc_*`) calls be used?**
   - (a) No, they are excluded.
   - (b) Yes.

   *Recommendation:* (a). RM00284 §3.45 (via SPEC.md) says they are not available on the i.MX 95.
7. **Does OP-TEE keep using the enclave for its HUK and RNG beside the Linux-side caller?**
   - (a) Yes.
   - (b) No, OP-TEE takes them elsewhere.
   - (c) Defer until the secure-world row is decided.

   *Recommendation:* (c). The sources read do not show whether the two can share the enclave safely (§7 item 6).
8. **May the lane obtain the missing documents?** The i.MX 95 edition or section of RM00284 that lists the HSM API messages per revision, IMX95RM for the messaging units, and a rendered copy of S1's API reference.

   *Recommendation:* yes. Items 1–5 of §7 depend on them.