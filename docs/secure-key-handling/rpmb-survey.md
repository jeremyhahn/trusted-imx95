# eMMC RPMB use survey (secure-key-handling)

Status: survey for the owner's decision. Issue #62, row `secure-key-handling` (#17).
Documentation only: nothing here is run, scripted or provisioned.

## 1. Scope and method

The question is whether, and how, the board should use the Replay Protected Memory
Block (RPMB) of its eMMC for state that must not be rolled back: secure storage,
anti-rollback counters, or the EdgeLock enclave's key store. This file surveys
public sources only: upstream project documentation and source, NXP's public
GitHub repositories and NXP's public web pages. Every source is listed in §8
with its title, version and URL; the bracketed numbers in the text, such as [S1],
refer to that list. The text summarises the sources in our own words. Where a
source was read on a moving branch (`master`), the date read is 2026-11-12.
What could not be confirmed is collected in §7.

## 2. What RPMB provides

- RPMB is a small partition of an eMMC device defined by the JEDEC eMMC
  standard (JESD84-B51). Reads and writes to it are authenticated with an
  HMAC-SHA256 over each data frame, keyed by a secret the eMMC holds, and every
  authenticated write advances a write counter inside the device, so an old
  frame cannot be replayed [S1]. The JEDEC standard itself was not read (§7).
- The authentication key is written into the eMMC once for the lifetime of the
  device; until it is written the partition cannot be used, and after it is
  written it cannot be changed [S1].
- A single-block write to RPMB is atomic per the eMMC standard, as OP-TEE's
  design relies on [S1].
- RPMB does not encrypt: confidentiality is up to the software that writes it.
  OP-TEE, for example, encrypts file data itself before writing it [S1].
- Because the write counter lives in the eMMC and not in the SoC, RPMB gives a
  rollback guarantee only while the eMMC chip itself is not replaced and its
  key stays secret. This is our inference from the mechanism above, not a
  statement of any source.

## 3. The board's eMMC

- The upstream Linux device tree for the board (`imx95-19x19-frdm-pro.dts`,
  model "NXP FRDM-IMX95-PRO") describes `usdhc1` as a non-removable, 8-bit
  device with SD and SDIO disabled, that is an eMMC, and `usdhc2` as a 4-bit
  slot with card detect, that is the SD card [S12]. RPMB is an eMMC feature,
  so only the `usdhc1` device is in scope.
- The eMMC part number, its eMMC version (RPMB needs 4.41 or later; U-Boot
  checks for this [S7]) and its RPMB partition size are not given in any public
  source read here (§7). The board user manual (UM12527) is held in the
  project's private references and was not used for this survey.
- U-Boot's `mmc info` prints the RPMB capacity, and `mmc bootpart-resize` can
  change the boot and RPMB partition sizes on parts that allow it [S7]. Both
  are noted for a later, owner-approved step; neither is run here.

## 4. Software that uses RPMB

### 4.1 OP-TEE secure storage

- OP-TEE has two secure storage back ends: one on the normal world's file
  system (`CFG_REE_FS`, the default) and one on the eMMC RPMB partition
  (`CFG_RPMB_FS`). Both can be built in together; a trusted application picks
  one with a storage identifier [S1].
- Under the GlobalPlatform rollback protection levels, OP-TEE reports level
  1000 (hardware controlled by the TEE) when the RPMB back end is built in, and
  no rollback protection without it [S1].
- With both back ends built in, the REE file system keeps a hash of its state
  in a file in RPMB, so RPMB anchors the larger REE store against rollback
  [S1]. In 4.11.0 this is on by default whenever the RPMB back end is
  (`CFG_REE_FS_INTEGRITY_RPMB ?= $(CFG_RPMB_FS)`) [S2].
- OP-TEE has no eMMC driver. Every RPMB frame travels through the normal world:
  OP-TEE builds and authenticates the frame, and the Linux side carries it to
  the device [S1]. The normal world can drop or delay frames, but cannot forge
  or replay them without the key.
- OP-TEE keeps a small file system of its own in the partition (a header, a
  file allocation table, data growing down from the end), and encrypts file
  data with AES-CBC using per-file keys wrapped by a key derived from the
  hardware unique key (HUK) and the TA's UUID; the allocation table itself is
  not encrypted [S1].

### 4.2 Linux kernel and tee-supplicant

Two routes carry OP-TEE's RPMB frames to the eMMC on the Linux side:

- **tee-supplicant (user space).** The OP-TEE client daemon opens the kernel's
  RPMB character device for the eMMC (`/dev/mmcblk<N>rpmb`) and passes frames
  through the MMC ioctl interface [S4]. It can also be built with an RPMB
  emulation mode that keeps a fake partition in memory, for testing only [S1,
  S4]. On this route secure storage works only once the root file system is up
  and the daemon runs.
- **In-kernel routing.** Linux v6.12 added an RPMB subsystem (`CONFIG_RPMB`,
  depending on `MMC`) and the MMC block driver registers each eMMC RPMB
  partition with it [S5]. The kernel's OP-TEE driver can then route RPMB frames
  itself, without tee-supplicant, when OP-TEE announces it supports this; the
  kernel reports the model in use to user space through sysfs
  (`rpmb_routing_model`) [S6]. OP-TEE 4.11.0 announces the capability by
  default (`CFG_RPMB_ANNOUNCE_PROBE_CAP ?= y`) [S2]. In-kernel routing lets
  RPMB-backed storage work early in boot, before user space.
- OP-TEE 4.11.0 can pick which eMMC to use by its CID when the board has more
  than one RPMB device (`CFG_RPMB_WRITE_KEY_CID` for key programming; the
  supplicant's `--rpmb-cid` option) [S1, S2]. The FRDM board has one eMMC, so
  this matters only if an SD card with RPMB were ever present (§3).

### 4.3 U-Boot

- U-Boot v2026.10 has RPMB support behind `CONFIG_SUPPORT_EMMC_RPMB`, which
  brings in an `mmc rpmb` command with sub-commands to program the key, read
  and write authenticated blocks and read the write counter [S7]. The `key`
  sub-command is the irreversible step of §5; it is named here only so the
  owner knows it exists.
- U-Boot can also serve OP-TEE's RPMB requests itself, routing frames to the
  eMMC before Linux runs [S7]. Its OP-TEE AVB trusted application support
  (`CONFIG_OPTEE_TA_AVB`, default `y` when OP-TEE is enabled) reads and writes
  Android Verified Boot rollback indexes through OP-TEE secure storage, which
  on an RPMB-backed build means RPMB [S7]. A test command, `optee_rpmb`,
  reads and writes named values in OP-TEE's RPMB storage [S7].
- So RPMB can serve boot-time rollback state (U-Boot, before the kernel) as
  well as run-time state (Linux, §4.2), through the same OP-TEE file system.
- NXP's U-Boot fork (`nxp-imx/uboot-imx`, branch `lf_v2026.04`) was not read
  for i.MX 95 board defaults (§7).

### 4.4 mmc-utils

- mmc-utils v1.0 has `rpmb` commands to program the key, read the write
  counter, read and write authenticated blocks, and manage the eMMC's
  secure write protection through RPMB [S8]. The kernel's mmc-tools page
  describes the counter, read and write functions [S9].
- OP-TEE's documentation names mmc-utils as the tool for programming the key
  from the normal world in a factory [S1].

## 5. The RPMB authentication key

The key is the decision that cannot be undone: once written into the eMMC it
stays for the life of that chip [S1].

- **Derived, not stored.** OP-TEE derives the RPMB key from the platform's HUK
  (through its HUK sub-key mechanism, with the eMMC's CID as input) rather
  than storing it [S1, S3]. It masks the CID's product-revision and CRC
  fields first, so an eMMC firmware update does not change the key [S3]. A hard-coded test key exists (`CFG_RPMB_TESTKEY`,
  default `n` in 4.11.0) for development only [S1, S2].
- **The HUK must be secret and stable.** The derivation is only as good as the
  HUK. OP-TEE's documentation notes that secure SoCs give a different HUK
  depending on whether the boot ROM enforces signed images; so a key written
  while the board is still open will not match the key derived after it is
  closed, and RPMB access would then fail for good [S1]. OP-TEE provides a
  platform hook, `plat_rpmb_key_is_ready()`, for a platform to refuse key
  programming until the device is in its final security state [S1, S3].
- **Who writes the key.** Two ways are documented [S1]:
  1. *OP-TEE writes it on first use* (`CFG_RPMB_WRITE_KEY=y`, default `n`).
     The key then passes in the clear through the normal world, which relays
     the programming frame; OP-TEE's documentation advises this only for test
     or development, and warns that the normal world can trigger it to learn
     the key, and that a factory-only OP-TEE image is not a full defence [S1,
     S2].
  2. *A factory tool in the normal world writes it* (for example mmc-utils,
     §4.4, or U-Boot, §4.3), with the key computed from the HUK by a script
     OP-TEE provides (`scripts/derive_rpmb_key.py`). This requires the HUK, or
     the derived key, to be known outside OP-TEE during manufacturing [S1].
- Neither way is free: option 1 exposes the key on the device at run time;
  option 2 exposes it in the factory. Which risk the owner accepts is
  question 2 in §9.
- **Anti-rollback of trusted applications.** OP-TEE 4.11.0 can keep the TA
  version floor in RPMB rather than the REE file system
  (`CFG_TA_VERSION_DB_RPMB`, default `n`), so the normal world cannot reset it
  by deleting files [S2].

## 6. RPMB beside the EdgeLock enclave

- **OP-TEE's HUK on the i.MX 95 comes from the enclave.** Upstream OP-TEE
  4.11.0 builds the ELE driver for the `mx95evk` flavour and gets its HUK by
  asking the enclave to derive a key from a fixed context string; boot stops
  if the enclave does not answer [S10]. NXP's fork, tag `lf-6.18.37_2.1.0`,
  enables the same driver for the i.MX 95 [S11]. So the RPMB key of §5 would
  be bound to the enclave's own device secret. Neither platform file sets
  `CFG_RPMB_FS`, so RPMB storage is off by default on the i.MX 95 in both
  [S2, S10, S11].
- **Neither tree has an FRDM flavour.** Both list only `mx95evk` for the
  i.MX 95 [S10, S11]. A board port, or the EVK flavour with board changes, is
  needed before any of §4.1 applies to this board.
- **Inputs to the RPMB key can change with configuration.** In 4.11.0 the
  i.MX platforms use a backward-compatible derivation that mixes the die ID
  into the RPMB and storage keys; enabling the SE05x driver turns that mode
  off and takes the die ID from the SE05x instead [S2, S10, S14]. Our
  inference: a build that changes these options after the RPMB key is written
  would derive a different key and lose RPMB access. The SE051 on the board
  (SPEC row `secure-key-handling`) therefore bears on the RPMB decision.
- **The enclave's key store does not use RPMB.** NXP's secure enclave library
  ships an NVM daemon that saves the enclave's storage as a file on the Linux
  file system, by default under `/etc/ele/` [S13]. The SPEC row records that
  the enclave protects its key store from rollback with its own monotonic
  counter (RM00284 §2.4.2, a non-public NXP document). If that holds, RPMB
  adds nothing to the key store's rollback protection, and the key store does
  not need it. This could not be confirmed from a public source (§7).
- **Where RPMB would still help.** State that lives in OP-TEE, not in the
  enclave: OP-TEE secure storage, the REE FS integrity hash, the TA version
  floor, and boot-time rollback indexes read by U-Boot [S1, S2, S7]. Whether
  the project has any such state depends on the SPEC row's open question of
  which side calls the HSM API.

## 7. What could not be confirmed

1. JEDEC JESD84-B51 (eMMC 5.1), the RPMB standard itself: a JEDEC document,
   not read. §2 rests on OP-TEE's summary of it [S1].
2. NXP's FRDM-IMX95 public product pages: the URLs tried returned 404 from
   the lane. The eMMC part, its version and its RPMB size are unconfirmed.
3. Whether the enclave-derived HUK differs between the OEM open and OEM
   closed life cycles. OP-TEE says secure SoCs generally do this [S1]; no
   public NXP source read here says so for the i.MX 95 enclave.
4. The enclave's own anti-rollback mechanism for its key store: from the SPEC
   row (RM00284), not from a public source.
5. NXP's Yocto recipes (`meta-imx`) and U-Boot fork (`uboot-imx`,
   `lf_v2026.04`): not read, so NXP's shipped defaults for `CFG_RPMB_FS`,
   `CONFIG_SUPPORT_EMMC_RPMB` and tee-supplicant on the i.MX 95 are
   unconfirmed. NXP's fork of the OP-TEE ELE driver was not read; the upstream
   one was [S10].
6. Which tagged Linux release first carries the FRDM-IMX95-PRO device tree:
   read on `master` only [S12].
7. The NXP secure enclave library was read at its default branch head, not
   at a release tag [S13].

## 8. Sources

All read 2026-11-12. Paths are within the named repository at the named
version.

- [S1] OP-TEE documentation, "Secure storage" (`architecture/secure_storage.rst`),
  `master`. https://github.com/OP-TEE/optee_docs/blob/master/architecture/secure_storage.rst
  (rendered at https://optee.readthedocs.io/en/latest/architecture/secure_storage.html)
- [S2] OP-TEE OS 4.11.0, build configuration `mk/config.mk`.
  https://github.com/OP-TEE/optee_os/blob/4.11.0/mk/config.mk
- [S3] OP-TEE OS 4.11.0, RPMB file system `core/tee/tee_rpmb_fs.c`.
  https://github.com/OP-TEE/optee_os/blob/4.11.0/core/tee/tee_rpmb_fs.c
- [S4] OP-TEE client 4.11.0, tee-supplicant RPMB handler
  `tee-supplicant/src/rpmb.c`.
  https://github.com/OP-TEE/optee_client/blob/4.11.0/tee-supplicant/src/rpmb.c
- [S5] Linux v6.12: `drivers/misc/Kconfig` (`config RPMB`),
  `drivers/misc/rpmb-core.c` (absent in v6.11), `drivers/mmc/core/block.c`.
  https://github.com/torvalds/linux/tree/v6.12/drivers/misc
- [S6] Linux `master`, OP-TEE driver RPC handling `drivers/tee/optee/rpc.c`.
  https://github.com/torvalds/linux/blob/master/drivers/tee/optee/rpc.c
- [S7] U-Boot v2026.10: `drivers/mmc/Kconfig`, `cmd/mmc.c`,
  `drivers/tee/optee/rpmb.c`, `drivers/tee/optee/Kconfig`, `cmd/optee_rpmb.c`.
  https://github.com/u-boot/u-boot/tree/v2026.10
- [S8] mmc-utils v1.0, `mmc.c` command table.
  https://git.kernel.org/pub/scm/utils/mmc/mmc-utils.git/tree/mmc.c?h=v1.0
- [S9] Linux kernel documentation, "MMC tools introduction"
  (`Documentation/driver-api/mmc/mmc-tools.rst`), `master`.
  https://docs.kernel.org/driver-api/mmc/mmc-tools.html
- [S10] OP-TEE OS 4.11.0: `core/drivers/crypto/ele/ele.c`,
  `core/arch/arm/plat-imx/conf.mk`.
  https://github.com/OP-TEE/optee_os/tree/4.11.0/core/drivers/crypto/ele
- [S11] NXP `imx-optee-os`, tag `lf-6.18.37_2.1.0`,
  `core/arch/arm/plat-imx/conf.mk`.
  https://github.com/nxp-imx/imx-optee-os/blob/lf-6.18.37_2.1.0/core/arch/arm/plat-imx/conf.mk
- [S12] Linux `master`, `arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts`.
  https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts
- [S13] NXP `imx-secure-enclave`, default branch at commit
  `d7e1180b7f7d` (2026-06-09; latest tag `lf-6.18.37-2.1.0`): `README`,
  `src/common/nvm/nvmd.conf`. https://github.com/nxp-imx/imx-secure-enclave
- [S14] OP-TEE OS 4.11.0, SE05x die ID `core/drivers/crypto/se050/core/die_id.c`.
  https://github.com/OP-TEE/optee_os/blob/4.11.0/core/drivers/crypto/se050/core/die_id.c

## 9. Questions for the owner

Writing the RPMB key cannot be undone on a given eMMC (§5). Until these are
answered, no RPMB key is written on the project's board.

1. **Does the project use RPMB at all?**
   - (a) No. OP-TEE (if used) keeps secure storage on the REE file system
     with no rollback protection [S1]; the enclave's key store relies on the
     enclave's own counter (§6).
   - (b) As a rollback anchor: `CFG_RPMB_FS=y`, keeping the REE FS integrity
     hash and the TA version floor in RPMB, bulk data on the REE FS [S1, S2].
   - (c) As the main secure store for OP-TEE data.
   - Recommendation: (b), if OP-TEE holds any state of its own; it is the only
     option OP-TEE rates as hardware rollback protection, and keeps RPMB use
     small [S1, S2]. If the answer to the SPEC row's HSM-caller question leaves
     OP-TEE with no state, (a).
2. **Who writes the RPMB key, and how?**
   - (a) OP-TEE on the device (`CFG_RPMB_WRITE_KEY=y`), gated by
     `plat_rpmb_key_is_ready()` and pinned to the eMMC's CID
     (`CFG_RPMB_WRITE_KEY_CID`) [S1, S2, S3].
   - (b) A factory tool (mmc-utils or U-Boot) with the key computed off the
     device [S1, S7, S8].
   - Recommendation: none firm. OP-TEE advises (b) for production and warns
     against (a) [S1], but on the i.MX 95 the HUK is derived inside the enclave
     [S10], so for (b) the key would first have to be taken off the device,
     which is the exposure (a) has. Decide together with the
     `oem-key-provisioning` row's provisioning flow.
3. **When is the key written, relative to closing the life cycle?**
   - (a) After the device is OEM closed. (b) Before.
   - Recommendation: (a). OP-TEE warns that a key written before the device
     is secured may stop working after [S1]; whether the enclave's HUK changes
     at close is unconfirmed (§7, item 3), so (a) is the safe order.
4. **What fixes the inputs to the key?** The SE051's role, and the OP-TEE
   options that feed the derivation (`CFG_NXP_SE05X`,
   `CFG_CORE_HUK_SUBKEY_COMPAT_USE_OTP_DIE_ID`), must not change after the key
   is written (§6).
   - (a) Settle the SE051's role first, then freeze these options in the
     board's OP-TEE configuration. (b) Leave them open.
   - Recommendation: (a).
5. **How do RPMB frames reach the eMMC?**
   - (a) In the kernel (Linux v6.12 or later, `CONFIG_RPMB`) [S5, S6].
   - (b) tee-supplicant in user space [S4].
   - (c) Also U-Boot, for boot-time rollback indexes [S7].
   - Recommendation: (a), as OP-TEE 4.11.0 announces it by default [S2] and it
     works before user space; add (c) only if verified boot needs rollback
     indexes in U-Boot.
6. **Should anything of the enclave's be kept in RPMB?**
   - (a) No: the NVM daemon keeps the enclave's storage file on the root file
     system (`/etc/ele/` by default) [S13], protected by the enclave's counter.
   - (b) Yes, move it under OP-TEE's RPMB storage.
   - Recommendation: (a), provided the owner confirms the enclave's counter
     covers the key store on the i.MX 95 (§7, item 4); the sources read give
     no RPMB path for the enclave.
7. **Board port.** Neither OP-TEE tree has an FRDM-IMX95-PRO flavour (§6).
   - (a) Use the `mx95evk` flavour with board changes. (b) Add an FRDM
     flavour.
   - Recommendation: none; this belongs to the trusted-firmware row and is
     noted here because RPMB storage depends on it.
