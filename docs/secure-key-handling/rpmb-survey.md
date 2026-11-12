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

TODO

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
  (through its HUK sub-key mechanism, with the eMMC's identity as input) rather
  than storing it [S1, S3]. A hard-coded test key exists (`CFG_RPMB_TESTKEY`,
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

TODO

## 7. What could not be confirmed

TODO

## 8. Sources

TODO

## 9. Questions for the owner

TODO
