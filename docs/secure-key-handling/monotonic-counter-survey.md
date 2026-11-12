# Monotonic counters on the i.MX 95: a survey

Row: secure-key-handling ([SPEC.md](../SPEC.md)). Issue #128. Status: draft survey for the owner, from public sources only.

## 1. Scope and method

This survey covers the monotonic counters an i.MX 95 board can use for replay and rollback protection:

- the EdgeLock secure enclave's counter;
- fuse-based anti-rollback of AHAB boot containers;
- the eMMC RPMB write counter.

For each one it gives the public API, the wear limit, and what happens across a reset, a power cut and a board replacement. Then it maps them to the board's protocols.

Only public sources were used: NXP's GitHub repositories and upstream project source, each at the tag named in §2. Vendor text is summarised, not quoted. Anything a public source didn't settle is marked **not confirmed** and listed in §6. Nothing here runs or scripts a fuse, life-cycle or provisioning step.

## 2. Sources surveyed

| Id | Title | Version | URL |
|---|---|---|---|
| S1 | NXP `imx-secure-enclave` (ELE/SECO HSM and SHE user-space library) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave |
| S2 | NXP `imx-mkimage` (boot container builder) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-mkimage |
| S3 | NXP `uboot-imx` (`arch/arm/mach-imx/ele_ahab.c`, `doc/imx/ahab/`) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx |
| S4 | OP-TEE `optee_os` (`core/tee/tee_rpmb_fs.c`, `core/tee/tee_ree_fs.c`, `core/arch/arm/plat-imx/conf.mk`) | tag `4.8.0` | https://github.com/OP-TEE/optee_os |
| S5 | JEDEC JESD84-B51, Embedded MultiMediaCard (e•MMC) Electrical Standard 5.1 | 5.1 | https://www.jedec.org/standards-documents/docs/jesd84-b51 (**not reached**: the page needs a login) |
| S6 | NXP `imx-optee-os` (`core/arch/arm/plat-imx/conf.mk`, `core/drivers/crypto/ele/ele.c`) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-optee-os |

`lf-6.18.37-2.1.0` was the newest NXP Linux BSP release tag in these repositories when this survey was written. The repository's private references (RM00284, AN14861, AN14471) were not used as sources. Where [SPEC.md](../SPEC.md) already cites them, this survey only points to SPEC.md.

## 3. Counters available on the i.MX 95

### 3.1 EdgeLock secure enclave counters

Source: [S1] `imx-secure-enclave` at tag `lf-6.18.37-2.1.0`.

**What it is.** The enclave (ELE) keeps a monotonic counter in OTP fuses. Each step burns one fuse bit, so it can't be reset or rolled back. The HSM library uses it to protect the key store from rollback. The key store itself lives in external storage, outside the enclave ([S1] `include/hsm/mainpage.h`, the NVM-writing section).

**Public API.** The library at that tag gives these entry points:

| Entry point | What it does | Where in [S1] |
|---|---|---|
| `STRICT_OPERATION` flag on key-store open, key generation, import, delete, key exchange and key-group management | Writes the changed key-store blocks to external storage and moves the OTP counter on by one, except past `max_updates_number` or with no counter split written, where the update is accepted with a warning and the counter does not move (see below and §4). Changes made without the flag stay in enclave RAM, and a reset loses them. | `include/hsm/internal/hsm_key_store.h`, `hsm_key_generate.h`, `hsm_importkey.h`, `hsm_delete_key.h`, `hsm_key_exchange.h`, `hsm_manage_key_group.h` |
| `..._FLAGS_MONOTONIC` / `..._MONOTONIC_COUNTER` flags | Used with the SYNC flags; the request finishes only after the counter has moved on, subject to the cap and split cases in the rows around it | same headers |
| `max_updates_number` (key-store create) | Caps how many counter steps one key store may use. Past the cap the enclave still accepts updates but stops moving the counter on, so those later updates are not protected from rollback. | `include/common/key_store.h` |
| `HSM_KEY_STORE_COUNTER` (error 0x10) | Returned once the cap is reached | `include/hsm/internal/hsm_utils.h` |
| `hsm_dev_mono_counter()` | Splits the counter fuse words between the ELE HSM, the V2X HSM and V2X SHE. The split can be written **once per device**, and all the words must be allocated. If no split is written, counter operations return a warning and give **no rollback protection**. An all-zero request reads the stored split back. | `include/hsm/internal/hsm_dev_mono_counter.h` |
| `get_info` → `chip_monotonic_counter` | Reads back a 16-bit chip counter value | `include/common/get_info.h` |

The ELE platform's message map sends the mono-counter request to the enclave ROM (`MT_SAB_DEV_MONO_COUNTER := ${ROM}` in `src/plat/ele/sab_msg.def`). The SECO and "prime" platforms mark it as not supported. So on ELE parts the call goes to ROM firmware. The i.MX 95 is an ELE part: [S6] builds its ELE driver for `mx95`. In the repository's private references, RM00284 §3.24 covers this command; it was not used here.

**Wear limit.** The counter is limited by the number of fuse bits. The library says this plainly and tells callers to batch several updates under one strict operation. The only number it gives is about 1620 updates for the i.MX 8QXP B0 ([S1] `mainpage.h`). **No public figure for the i.MX 95** was found: neither the number of counter fuse words nor the bits per word. The library's test (`test/common/test_dev_mono_counter.c`) uses splits that add up to two different totals, so the total can't be worked out from it either.

**Not a general-purpose counter.** No call in [S1] lets an application read or step a counter it names for its own data. The only counter an application sees is the one behind the key store, which moves when the key store changes. To protect any other data (an audit log, for example), the application has to tie it to a key-store change or use another counter (§3.3).

### 3.2 Fuse-based anti-rollback (AHAB container version)

Sources: [S2] `imx-mkimage` at tag `lf-6.18.37-2.1.0`; [S3] `uboot-imx` at tag `lf-6.18.37-2.1.0`.

**What it is.** Each AHAB container header has two version fields, set when the image is built:

- `fuse_version`, 8 bits, set with `-fuse_version`;
- `sw_version`, 16 bits, set with `-sw_version`.

Both widths are in [S2] `src/mkimage_imx8.c`, which masks the arguments to 0xFF and 0xFFFF, and `README` describes both flags. The i.MX 95 make rules pass `-sw_version $(ROLLBACK_INDEX_IN_CONTAINER)` when that variable is set ([S2] `iMX95/soc.mak`). That is how NXP's build carries a software rollback index in the boot container. The same rules never set `fuse_version`, so it stays at its default of 0.

**Public API.** U-Boot's `ahab_commit` command ([S3] `arch/arm/mach-imx/ele_ahab.c`) asks the enclave to burn into fuses any new SRK revocation and firmware-version information found in the NXP (ELE firmware) and OEM containers that just booted. The command help says this in its own words. The same file has an enclave failure code named `ELE_BAD_MONOTONIC_COUNTER_FAILURE_IND`, This suggests the enclave reports a container whose version is below the fused counter as a failure of its own; see "Not confirmed" below. This is the boot-time counter. The fuse burn happens only when someone runs commit; booting a newer image doesn't raise the floor by itself.

**Wear limit.** Every raise of the floor burns fuses and can't be undone. The fuse field's width bounds how many raises are possible. An 8-bit `fuse_version` allows at most 255 raises above 0. Whether the i.MX 95 fuse field is that wide, and whether it is coded as a value or as a thermometer of bits, is **not confirmed**: it is in IMX95RM and the i.MX 95 Security Reference Manual, which are not public.

**Not confirmed.**

- Whether the ROM, or the ELE firmware, compares `fuse_version` against fuses on the i.MX 95. The failure code above suggests so, but no public source states the rule for this part.
- Which software, if any, checks `sw_version`. Nothing in the parts of [S3] surveyed (`arch/arm/mach-imx`, `doc/imx/ahab`) reads it. It is a software index, not one the hardware enforces.
- Whether the NXP ELE firmware container and the OEM containers share one fuse counter or use separate ones.

### 3.3 eMMC RPMB write counter

Sources: [S4] OP-TEE `optee_os` at tag `4.8.0`; [S5] the JEDEC eMMC standard (JESD84-B51), not reached.

**What it is.** An eMMC device's Replay Protected Memory Block (RPMB) partition has a 32-bit write counter inside the eMMC. Each authenticated write must carry the current value, and the device steps the counter on by one. Every write is MACed with a key programmed once into the eMMC. A replayed write carries an old counter value, so the device rejects it. All of this is visible in OP-TEE's driver ([S4] `core/tee/tee_rpmb_fs.c`):

- the request type that reads the counter;
- the 4-byte counter field in each frame;
- the check that the returned counter equals the previous value plus one;
- the result code `RPMB_RESULT_WR_CNT_EXPIRED` (0x80), which means the counter can't move further.

**Public API.** No interface gives the counter to an application directly. OP-TEE uses it inside its RPMB file system, which backs trusted applications' persistent objects (GlobalPlatform TEE Internal Core API storage). OP-TEE can also keep the REE file system's root hash in RPMB (`CFG_REE_FS_INTEGRITY_RPMB` in [S4] `core/tee/tee_ree_fs.c`). That gives the encrypted files on the Linux file system rollback protection. A secure-world service that needs a counter keeps it in an RPMB-backed object. Each update of that object is one or more authenticated writes, so each update moves the eMMC counter on.

**Key.** OP-TEE derives the RPMB MAC key from the platform's hardware unique key (`tee_rpmb_key_gen` in [S4] `tee_rpmb_fs.c`). It programs the key into the eMMC only if it is built with `CFG_RPMB_WRITE_KEY`, and programming happens once per eMMC device. On the i.MX 95, upstream OP-TEE 4.8.0 ([S4] `core/arch/arm/plat-imx/conf.mk`, the `mx95` flavour) turns off CAAM, SNVS and OCOTP. Unlike the i.MX 93 flavour just above it, it does **not** enable `CFG_IMX_ELE`. NXP's fork [S6] `imx-optee-os` at tag `lf-6.18.37-2.1.0` does enable `CFG_IMX_ELE` for `mx95` (`core/arch/arm/plat-imx/conf.mk`). Its `tee_otp_get_hw_unique_key()` asks the enclave for a key derived from a fixed context string, and panics if the enclave fails (`core/drivers/crypto/ele/ele.c`). So with NXP's fork, the RPMB key is bound to this SoC's enclave. With upstream 4.8.0, where the i.MX 95 hardware unique key comes from is **not confirmed**. If it falls back to OP-TEE's default key, RPMB gives no protection. The board should therefore use NXP's fork, or an upstream release that has the ELE driver for `mx95`.

**Wear limit.** The counter is 32 bits. Once it reaches its maximum the device reports the counter expired and refuses further authenticated writes. OP-TEE has the result code for this case. About 4.29 × 10⁹ writes will not run out in the life of a board. The binding limit is the eMMC's flash endurance. This survey doesn't cover that; it depends on the part. The board's eMMC part, and whether it has RPMB, is **not confirmed** here: the board user manual is in the private references. The JEDEC standard [S5] needs a login and was not reached, so the counter's width and the expiry behaviour are confirmed only through OP-TEE's handling of them.

## 4. Which protocols need replay protection

The protocols are the ones [SPEC.md](../SPEC.md) names for this board. None of them has a wire format yet; the device side of `hsm-device-protocol` waits on go-xkms #1521. This section says what each one would need. It doesn't set requirements.

| What is protected | Threat | Counter that fits | Why |
|---|---|---|---|
| Enclave key store (`secure-key-handling`, `oem-key-provisioning`) | An older key-store blob is put back into external storage, bringing back a deleted or revoked key | Enclave OTP counter (§3.1) | The enclave checks it whenever an operation carries `STRICT_OPERATION` [S1], but the flag alone is not fail-closed. Past `max_updates_number` updates are still accepted without the counter moving, and with no counter split written the enclave returns warnings and gives no rollback protection (§3.1). The caller must therefore treat any counter warning or `HSM_KEY_STORE_COUNTER` as a failure. It must also confirm that the counter split is configured, and that the counter advanced (for example with the `MONOTONIC` sync flags or a `chip_monotonic_counter` read before and after), before it treats a persistent update, such as a key deletion or rotation, as committed. Otherwise an older blob can restore a key the caller believes is gone, against [SPEC.md](../SPEC.md)'s `secure-key-handling` row. Whether these checks are enough on the i.MX 95 is **unconfirmed** until tested on the board's firmware. |
| Boot firmware: the OEM container with the Cortex-M7 image, the ELE firmware container (`boot-container`) | An older signed image with a known flaw is booted | AHAB `fuse_version` with `ahab_commit` (§3.2); `sw_version` as a software index | The boot path enforces the fused floor before any OEM code runs [S2][S3]. Fuses are few, so it suits security releases only. |
| Linux-side and secure-world software above the boot container | An older image is booted | `sw_version`, or a version index kept in RPMB by the secure world (§3.3) | No fuse cost. It needs a secure-world component to check it, and which one is the open `secure-world` question. |
| Audit records (signing log, key-use log) | Records are cut back to an earlier state | RPMB-backed object holding a sequence number or hash-chain head (§3.3) | The enclave counter can't be named by applications and wears out [S1]. RPMB's 32-bit counter doesn't run out in practice [S4]. The head stops cut-back only if the component writing it is isolated from Linux root and has exclusive use of the audit key; otherwise only history already committed to an off-board verifier is protected. That isolation is unconfirmed on this device ([audit-trail-survey.md](audit-trail-survey.md) §4.1). |
| Key-use requests over `hsm-device-protocol` | A captured request is replayed | A per-session nonce or sequence number held in RAM; no persistent counter | Within a session RAM is enough. Across reboots, a fresh session nonce from the device (RNG) makes the board's monotonic store unnecessary, so the counter's wear is never spent. |
| Attestation (`device-lifecycle`) | Old evidence is replayed | A verifier-supplied nonce | Freshness comes from the verifier's challenge, so the board needs no counter. Whether the i.MX 95 enclave's attestation command takes a verifier nonce was **not confirmed** from a public source. |

## 5. Survival across reset, power cut and board replacement

This is input to #62 and #82.

| Counter | Reset | Power cut during an update | Board replacement |
|---|---|---|---|
| Enclave OTP counter (§3.1) | Survives: it is in fuses. Key-store changes made without `STRICT_OPERATION` are lost [S1]. | **Not confirmed.** [S1] says an update counts only once the strict operation is acknowledged. It doesn't say what order the fuse burn and the external write happen in. If the fuse is burnt and the blob isn't written, the stored blob could be refused as a rollback. The recovery path isn't documented publicly. | Doesn't move with the board. The fuses and the key-store blob both belong to the old SoC. The new board starts with its own counter and an empty key store. |
| AHAB fuse version (§3.2) | Survives: it is in fuses. | Raising it is a separate, explicit `ahab_commit` after a successful boot [S3], so a cut during an update leaves the old floor in place. A cut during the fuse burn itself: **not confirmed**. | Doesn't move. The new SoC has its own floor, and it stays at the factory value until commit is run on the new board. Until then an older signed image would boot on it. |
| eMMC RPMB counter (§3.3) | Survives: it is in the eMMC. | Each authenticated write either completes or doesn't. That atomicity is a JEDEC property [S5], **not confirmed** in this lane. OP-TEE re-reads the counter after a failed write before it trusts its cached value [S4]. | Doesn't move. The counter is in the eMMC, and the MAC key comes from this SoC's enclave [S6]. An eMMC moved to another SoC can't be written by it. Whether the board's eMMC is soldered is **not confirmed** here. |

What follows from this: none of the three counters carries over to a replacement board. Continuity across a board replacement (key identity, firmware floor, the audit sequence) has to come from outside the board, and the new board has to be enrolled as a new device. Which component keeps that state, go-xkms or go-trusted-platform, is for #62 and #82 to decide.

## 6. Not confirmed

- The i.MX 95's count of enclave counter fuse words, the bits per word, and so the number of strict operations available (§3.1).
- Whether the V2X HSM and SHE, which `hsm_dev_mono_counter` can be given words for, exist on the i.MX 95 or not (§3.1).
- How the i.MX 95 compares and encodes `fuse_version`, and whether the ELE firmware and the OEM containers share a fuse field (§3.2).
- Which component checks `sw_version` on the i.MX 95 boot path (§3.2).
- Whether the enclave's strict operation is atomic across a power cut (§5).
- Whether the i.MX 95 enclave reliably reports an unconfigured counter split or a reached `max_updates_number` to the caller, and how a caller confirms that a given strict operation advanced the counter (§3.1, §4, §7 question 2).
- Where the hardware unique key comes from in upstream OP-TEE 4.8.0 for `mx95` (§3.3).
- The board's eMMC part, its RPMB size and its endurance. The JEDEC eMMC standard [S5] (needs a login).
- The NXP SE051 on the board: SE05x applets offer counter objects, but the SE051 documentation is missing (see [SPEC.md](../SPEC.md)), so it was not surveyed.
- IMX95RM and the i.MX 95 Security Reference Manual are not public and were not used.

## 7. Questions for the owner

1. **How should the enclave counter fuse words be split?** This is a one-time fuse step that belongs to `oem-key-provisioning`; nothing is run here.
   - (a) all words to the ELE HSM;
   - (b) a split that keeps words for V2X HSM or SHE;
   - (c) leave it unwritten, which means no key-store rollback protection [S1].

   Recommendation: (a), provided it is confirmed that the i.MX 95 has no V2X or SHE users. [S1] requires every word to be allocated and allows the split to be written only once.
2. **When should key-store changes use `STRICT_OPERATION`?**
   - (a) on every change;
   - (b) once per provisioning or rotation session, after a batch of changes;
   - (c) (b) plus a `max_updates_number` cap at key-store creation.

   Recommendation: (c), on a fail-closed condition. [S1] advises batching because the counter wears out, and the cap keeps one key store from using up every fuse. But past the cap the enclave keeps accepting updates without rollback protection (§3.1). So under (c) the caller must reject `HSM_KEY_STORE_COUNTER` and every counter warning, confirm that the counter split is configured, and confirm that the counter advanced before it reports a change as committed. Once the cap is reached it must refuse further persistent key changes (deletion, rotation, import) rather than accept unprotected ones. Replacing the key store then becomes an owner decision. That the enclave reports these conditions reliably on the i.MX 95 is **unconfirmed** (§6).
3. **How should firmware anti-rollback work?**
   - (a) `fuse_version` with `ahab_commit` on every release;
   - (b) `fuse_version` raised only for security fixes, with `sw_version` (or a secure-world index) on every release;
   - (c) a software index only.

   Recommendation: (b). Fuses are finite and the field is 8 bits wide in the container [S2]. Who checks `sw_version` stays open.
4. **Where should audit records and other application counters live?**
   - (a) an RPMB-backed object in OP-TEE;
   - (b) tied to a strict enclave key-store update;
   - (c) off the board, signed by the board and ordered by the server.

   Recommendation: (a) if the `secure-world` row picks OP-TEE. Otherwise (c). (b) spends a finite fuse resource on non-key data [S1].
5. **Which OP-TEE should the board run?**
   - (a) NXP's `imx-optee-os`;
   - (b) upstream `optee_os`.

   Recommendation: (a) until upstream is confirmed to derive the `mx95` hardware unique key from the enclave. [S6] does this; [S4] 4.8.0 does not show it.
6. **What happens when a board is replaced?**
   - (a) treat it as a new device: new enrolment and new keys, and the old device is revoked in go-xkms / go-trusted-platform;
   - (b) try to carry state over to the new board.

   Recommendation: (a). §5 shows no counter, and no enclave-held key, leaves the SoC.
7. **Should the non-public i.MX 95 manuals be requested from NXP** (IMX95RM, the Security Reference Manual), to settle the fuse questions in §6?
   - (a) yes, under NDA;
   - (b) no, and design for the worst case.

   No recommendation; it is a business decision.
