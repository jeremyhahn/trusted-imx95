# Monotonic counters on the i.MX 95: a survey

Row: secure-key-handling ([SPEC.md](../SPEC.md)). Issue #128. Status: draft survey for the owner, from public sources only.

## 1. Scope and method

## 2. Sources surveyed

## 3. Counters available on the i.MX 95

### 3.1 EdgeLock secure enclave counters

Source: [S1] `imx-secure-enclave` at tag `lf-6.18.37-2.1.0`.

**What it is.** The enclave (ELE) keeps a monotonic counter in OTP fuses. Each step burns one fuse bit, so it can't be reset or rolled back. The HSM library uses it to protect the key store from rollback. The key store itself lives in external storage, outside the enclave ([S1] `include/hsm/mainpage.h`, the NVM-writing section).

**Public API.** The library at that tag gives these entry points:

| Entry point | What it does | Where in [S1] |
|---|---|---|
| `STRICT_OPERATION` flag on key-store open, key generation, import, delete, key exchange and key-group management | Writes the changed key-store blocks to external storage and moves the OTP counter on by one. Changes made without the flag stay in enclave RAM, and a reset loses them. | `include/hsm/internal/hsm_key_store.h`, `hsm_key_generate.h`, `hsm_importkey.h`, `hsm_delete_key.h`, `hsm_key_exchange.h`, `hsm_manage_key_group.h` |
| `..._FLAGS_MONOTONIC` / `..._MONOTONIC_COUNTER` flags | Used with the SYNC flags; the request finishes only after the counter has moved on | same headers |
| `max_updates_number` (key-store create) | Caps how many counter steps one key store may use. Past the cap the enclave still accepts updates but stops moving the counter on, so those later updates are not protected from rollback. | `include/common/key_store.h` |
| `HSM_KEY_STORE_COUNTER` (error 0x10) | Returned once the cap is reached | `include/hsm/internal/hsm_utils.h` |
| `hsm_dev_mono_counter()` | Splits the counter fuse words between the ELE HSM, the V2X HSM and V2X SHE. The split can be written **once per device**, and all the words must be allocated. If no split is written, counter operations return a warning and give **no rollback protection**. An all-zero request reads the stored split back. | `include/hsm/internal/hsm_dev_mono_counter.h` |
| `get_info` → `chip_monotonic_counter` | Reads back a 16-bit chip counter value | `include/common/get_info.h` |

The ELE platform's message map sends the mono-counter request to the enclave ROM (`MT_SAB_DEV_MONO_COUNTER := ${ROM}` in `src/plat/ele/sab_msg.def`). The SECO and "prime" platforms mark it as not supported. So on ELE parts, the i.MX 95 among them, the call goes to ROM firmware.

**Wear limit.** The counter is limited by the number of fuse bits. The library says this plainly and tells callers to batch several updates under one strict operation. The only number it gives is about 1620 updates for the i.MX 8QXP B0 ([S1] `mainpage.h`). **No public figure for the i.MX 95** was found: neither the number of counter fuse words nor the bits per word. The library's test (`test/common/test_dev_mono_counter.c`) uses splits that add up to two different totals, so the total can't be worked out from it either. In the repository's private references, RM00284 §3.24 covers this command. It isn't a public source and isn't quoted here.

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

**Key.** OP-TEE derives the RPMB MAC key from the platform's hardware unique key (`tee_rpmb_key_gen` in [S4] `tee_rpmb_fs.c`). It programs the key into the eMMC only if it is built with `CFG_RPMB_WRITE_KEY`, and programming happens once per eMMC device. On the i.MX 95, upstream OP-TEE 4.8.0 ([S4] `core/arch/arm/plat-imx/conf.mk`, the `mx95` flavour) turns off CAAM, SNVS and OCOTP. Unlike the i.MX 93 flavour just above it, it does **not** enable `CFG_IMX_ELE`. Where the i.MX 95 hardware unique key comes from in upstream OP-TEE, and in NXP's fork `imx-optee-os`, is **not confirmed**. The RPMB key is only as strong as that source. If the platform falls back to a default key, RPMB gives no protection.

**Wear limit.** The counter is 32 bits. Once it reaches its maximum the device reports the counter expired and refuses further authenticated writes. OP-TEE has the result code for this case. About 4.29 × 10⁹ writes will not run out in the life of a board. The binding limit is the eMMC's flash endurance. This survey doesn't cover that; it depends on the part. The board's eMMC part, and whether it has RPMB, is **not confirmed** here: the board user manual is in the private references. The JEDEC standard [S5] needs a login and was not reached, so the counter's width and the expiry behaviour are confirmed only through OP-TEE's handling of them.

## 4. Which protocols need replay protection

## 5. Survival across reset, power cut and board replacement

## 6. Not confirmed

## 7. Questions for the owner
