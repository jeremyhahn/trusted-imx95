# ftpm — design

> **Status: NORMATIVE** · Scope: trusted-imx95 `ftpm` · Last verified: 2026-11-20
> The detail of the `ftpm` row of [SPEC.md](../SPEC.md). Conflicts with SPEC.md are defects in this file.

Owner ruling 927 (2026-11-18) gives the board a firmware TPM 2.0, so that it is provisioned like any other system
through go-xkms's existing TPM 2.0 workflows: endorse-01, then enroll-01, then device-attest-01 in the `tpm`
format. Issue #140. The SPEC.md row this file details was approved by the owner on 2026-11-21 (PR #138).

Documentation only: nothing here is run, scripted or provisioned. In particular, no RPMB key is programmed and no
fuse is touched; the RPMB key is a provisioning-station step after OEM close (owner ruling 1234), a fuse burn the
owner's decision alone.

Sources are the documents in [references/](../references/README.md) and public upstream projects named in the
text. Facts this repository's surveys already hold are linked, not restated. A version not yet chosen is marked
**to be pinned**; a fact no source read here gives is marked **unconfirmed**.

## Starting point

- Per the ruling, today's board image has no firmware TPM: the kernel's `CONFIG_TCG_FTPM_TEE` is off, and the
  BSP's OP-TEE (4.10, as the ruling reports it) carries the PKCS#11 TA only. The BSP release is pinned, provisionally,
  under the `secure-world` row (`secure-world` step (a), [secure-world/build.md](../secure-world/build.md#the-pins)):
  `lf-6.18.37-2.1.0`, whose recipe builds OP-TEE 4.10.0 (`optee-os_4.10.0.imx.bb`).
- `secure-world` provides TF-A BL31 and OP-TEE ([secure-world/architecture.md](../secure-world/architecture.md#scope-owner-ruling-771)).
  This row owns what the firmware TPM adds on top: the TA, the kernel driver, the TPM's NV storage, the EK and
  measured boot.

## Components and boot order

The A55 boot path, in order. The stages before BL31 are the board's existing boot chain; how the boot container
hands the A55 its first image is in the `boot-container` row and the missing IMX95RM and Security Reference Manual.

1. **Boot ROM and EdgeLock secure enclave.** AHAB verifies each signed container image before it runs
   ([SPEC.md](../SPEC.md), `boot-container` row).
2. **System Manager on the Cortex-M33.** NXP's firmware; the board boots on the M33 (UM12527 §2.3 Table 7).
3. **The A55 loader stage that starts BL31.** In NXP's i.MX flow this is U-Boot SPL loading BL31, OP-TEE and
   U-Boot proper from the boot container; that this holds for the FRDM-IMX95-PRO image is **unconfirmed**.
4. **TF-A BL31** (`secure-world`).
5. **OP-TEE OS with the fTPM as an early TA.** The fTPM TA is OP-TEE's `optee_ftpm` project, which runs
   Microsoft's TPM 2.0 reference implementation (`ms-tpm-20-ref`); it is not part of `optee_os` itself
   ([ta-options-survey.md](../secure-world/ta-options-survey.md#ftpm-ta), S7, S8). Built as an early TA, it is
   linked into the OP-TEE image, so the TA itself needs no file system to load. Its source revision is pinned,
   pending [question 2](#open-questions-for-the-owner): `optee_ftpm` 4.10.0 on the `ms-tpm-20-ref` commit its
   README names, built by `make secure-world` ([secure-world/build.md](../secure-world/build.md#the-flags)).
6. **U-Boot proper.** Upstream U-Boot has a TEE-backed TPM 2.0 driver for the OP-TEE fTPM (`CONFIG_TPM2_FTPM_TEE`);
   whether the BSP's U-Boot builds it for this board is **unconfirmed**. Without it U-Boot cannot extend PCRs.
7. **Linux with `tpm_ftpm_tee`.** The kernel's firmware-TPM driver (`CONFIG_TCG_FTPM_TEE`) finds the TA on the TEE
   bus and registers a TPM 2.0 device; the kernel's resource manager exposes it as `/dev/tpmrm0`. With REE FS
   storage the TA's NV needs `tee-supplicant`, so the device appears only once the supplicant runs
   ([ta-options-survey.md](../secure-world/ta-options-survey.md), unconfirmed item 6). "`/dev/tpmrm0` present at
   boot" therefore means present once the supplicant has started, before any service that uses the TPM.
8. **Users.** go-xkms's TPM 2.0 workflows and go-trusted-platform reach the TPM through `/dev/tpmrm0`.

## NV storage

The TPM's NV memory (seeds, persistent handles, NV indices, counters) is kept as the TA's OP-TEE persistent
objects, in the storage `CFG_FTPM_TA_TEE_STORAGE_ID` selects
([ta-options-survey.md](../secure-world/ta-options-survey.md#ftpm-ta);
[optee-storage-survey.md](../secure-world/optee-storage-survey.md)).

| | RPMB on the board's eMMC | REE file system |
|---|---|---|
| Rollback | The eMMC's write counter anchors the state ([rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §2) | None: root on Linux can restore an older copy of the files |
| Survives a rootfs reflash | Yes, unless the RPMB data is wiped too | A full-image flash recreates `tee-data` empty (wiped); a root rewrite with a different build is wiped on boot; so is any other write of the root file-system image, the same image included (root binding token, see below) |
| Use from U-Boot | U-Boot can serve OP-TEE's RPMB requests itself (unconfirmed for this board) | No `tee-supplicant` before Linux, so U-Boot cannot reach the TPM's NV |
| Precondition | The eMMC's RPMB authentication key is programmed: once, irreversibly ([rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §5) | None |
| Confidentiality | OP-TEE encrypts objects with keys derived from the hardware unique key | The same |

Both rest on OP-TEE's hardware unique key; whether the i.MX 95 port derives it from the enclave is unconfirmed
([ta-options-survey.md](../secure-world/ta-options-survey.md), unconfirmed item 1). Wiping the NV store destroys
the TPM's seeds, and with them the EK the issued certificate names ([EK lifecycle](#ek-lifecycle)).

Owner ruling 1234 (2026-11-23) decides the location: on production devices the NV is in the eMMC RPMB, written
only after OEM close; the REE file system (the root file system) holds it on development boards only. A development
board therefore has no rollback protection, and a root rewrite wipes the NV. Programming the RPMB key is a
provisioning-station step after OEM close and stays out of this repository: nothing here writes it.

The build selects the location with `TRUSTED_IMX95_FTPM_NV`: `reefs` (default, development boards) or `rpmb`
(production). Neither lets OP-TEE program the RPMB key, so RPMB writes fail until the provisioning station has
programmed it after OEM close; nothing was parsed or built with `rpmb` ([build.md](build.md#the-defaults-each-provisional)).
Open, all **unconfirmed**: how OP-TEE's RPMB frames reach the eMMC (`tee-supplicant`, or the kernel's in-kernel RPMB
routing and `CONFIG_RPMB`); whether the pinned OP-TEE 4.10 has `CFG_REE_FS_INTEGRITY_RPMB` (the survey reads it in
4.11.0) and what it means for `tee-nv-wipe` deleting `/data/tee` under `rpmb`; U-Boot's RPMB path on this board.

**Where the NV lives (provisional).** `tee-supplicant` (the BSP's OP-TEE client, enabled in the image) keeps OP-TEE's
REE file system under `/data/tee` (`--fs-parent-path`). `/data` is a separate writable partition, GPT name `tee-data`
(`platform-image/files/wic/trusted-imx95.wks`), mounted by `tee-data-mount.service` before the supplicant starts; the root file system
stays read-only, which is why the NV cannot live on it. The NV therefore persists across a reboot.
Lifecycle (provisional design; it implements the SPEC row `ftpm` requirement that the NV is wiped with the root file system):
- Writing the whole `.wic` is the supported way to reprovision: it recreates `tee-data` empty, so the NV is wiped.
- A root partition rewritten with a different build is caught on boot. The rootfs carries a build identity
  (`/etc/trusted-imx95-rootfs-id`) and the oneshot `tee-nv-wipe.service` runs after the `/data` mount and before
  `tee-supplicant`, which requires it. If `/data/tee-rootfs-id` is missing or differs, it removes everything under
  `/data/tee`, then records the new identity (temporary file, then rename); it fails closed, so a failure stops
  `tee-supplicant` from starting.
- Any write of the root file-system image wipes the NV, the very same image included. The content id cannot tell a
  rewrite of the same image apart, so `tee-nv-wipe` also binds the NV to a **root binding token**: 32 random bytes,
  drawn on the first boot after a wipe and kept in two places, the first 512-byte sector of the root partition (the
  boot-sector padding in front of the ext4 superblock, bytes 0-1023; ext4 does not use it) and `/data/tee-root-token` beside the NV. Because that sector is part of the file-system image itself, any
  write of the image, the whole partition or only the file-system bytes, replaces it, whatever is left
  untouched after the file system. The image holds a **nonzero "unbound" marker** there, not zeros: a sparse writer
  (GNU `dd conv=sparse`, a hole-skipping copy) skips an all-zero block and would keep the old token. The marker
  (`platform-image/files/root-marker.sh`, written into the wic by a post-step of `do_image_wic`) is `TEEUNBND1`, the
  build's rootfs id and `U` filler up to a final newline: no byte is zero. Zeros, the marker, or any value that is not
  this device's saved token is a fresh root. Every boot compares the two tokens (with the content id). A missing, zeroed,
  malformed or unequal token wipes `/data/tee` and writes a fresh token to both places.
- The check fails closed: a token sector that cannot be read, or a root that shows no ext4 superblock with a block
  size of 4096 or more, wipes the NV and stops the unit, so `tee-supplicant` does not start with old state; a token that
  cannot be written stops it too (after the wipe); a saved record that exists but cannot be read stops it and
  touches nothing. The block size matters because with 4096-byte blocks the superblock shares block 0 with the
  padding, so a sparse image copy (which skips all-zero blocks) always writes it; with 1 KiB blocks block 0 is all
  zeros and may be skipped. The wks pins the size (`--mkfs-extraopts "-b 4096"`). No space is reserved: the file
  system fills the partition, and `test/platform_image_ftpm_test.sh` builds one with the wks's own size and options in
  a sparse file and runs the unit on it.
- What was checked for something that covers those bytes: this repository's image has no dm-verity, no signature
  and no digest over the root partition (the root is mounted read-only; dm-verity is only proposed, in the
  [verified-boot survey](../platform-image/verified-boot-survey.md) §3.6). A future dm-verity over the root device
  would verify these bytes (the underlying device data) and the raw write would break it: that design would have
  to move the token out of the verified range or give it up; until then the unit simply fails closed.
- The test rewrites a fixture with `dd bs=512 conv=sparse,notrunc` from the same image and checks that the NV is
  wiped (and, as a control, that a zero sector would have been skipped). The wic post-step is run by the test too: its shell body, cut out of the recipe, on a synthetic sparse wic
  with the wks's geometry, followed by a gzip and a `.bmap` made in the order the image class gives, with
  `scripts/platform-image-check-root-marker.sh` checking every variant and the bmap (each of five mutations fails it).
  Unbuilt: no bitbake run has produced the wic, so the real file name, the real order against a `.bmap` or compression,
  and the bmap's real format are not confirmed. The real build is pending the owner's EULA decision, and its first run
  must be followed by `scripts/platform-image-check-root-marker.sh <deploy-dir>` (the build's `DEPLOY_DIR_IMAGE` for the
  image), which exits nonzero on any variant without the marker or any `.bmap` that does not map it. A flasher that skips the block despite its nonzero content is not a known case.
- Provisional and unbuilt: that wic passes `--mkfs-extraopts` on to `mkfs.ext4` is not checked (no bitbake here); if it
  does not, and the image's block size is smaller than 4096, the unit fails closed on first boot. Writing the token needs
  raw write access to the root's block device while the file system is mounted read-only; a kernel without that
  access stops the unit (fail closed), so it is a boot test item. Where `mke2fs` is absent the test writes the
  fixture's superblock fields by hand instead.
There is no root-only flasher. `/data` is mounted by `tee-data-mount.service`, which picks the `tee-data` partition on
the same disk as `/` (never a global partition label, which could name another medium's NV) and fails closed if there
is none or more than one. The NV is plain files that root on Linux can copy or roll back.

## EK lifecycle

1. **First boot.** The TPM has empty NV. An endorsement key is created from the endorsement primary seed with the
   template the owner picks ([question 3](#open-questions-for-the-owner)), and made persistent if the owner wants
   it at a persistent handle. Nothing is done before the owner approves the template.
2. **No manufacturer certificate.** A discrete TPM ships an EK certificate from its maker; this fTPM has none, and
   nothing on the board vouches for the EK on its own.
3. **endorse-01.** go-xkms's endorse-01 issues the EK certificate, and certifies the fTPM EK only after an EdgeLock
   enclave attestation (owner ruling 1234). What it checks before it signs, and where it
   stores the certificate, are go-xkms's; go-xkms was not read here.
4. **enroll-01**, then **device-attest-01** in the `tpm` format, as go-xkms defines them.
5. **Re-provisioning.** Anything that clears the endorsement hierarchy or wipes the NV store gives the board a new
   EK, and the issued certificate no longer matches it ([question 4](#open-questions-for-the-owner)).

The EK, and any attestation key derived for device-attest-01, are fTPM keys in OP-TEE storage, not enclave keys.
They are the device's TPM identity. The `secure-key-handling` row's requirement that the board's keys stay in the
enclave's key store is unchanged, and no board key moves into the fTPM
([question 7](#open-questions-for-the-owner)).

## Measured boot

A PCR can be extended only once something can talk to the TPM. The fTPM exists from OP-TEE's start, but a stage
reaches it only through OP-TEE, so the measurements of earlier stages reach the PCRs only as an event log handed
forward and replayed.

| Stage | Can it extend the fTPM PCRs? | Gap |
|---|---|---|
| Boot ROM, enclave (AHAB) | No: runs before OP-TEE | No TCG event log from the ROM or the enclave is known; AHAB verification is not a measurement. The enclave's own attestation (RM00284 §3.12) is a separate root |
| System Manager (M33) | No: runs before OP-TEE, on another core | No known event log; unconfirmed |
| Cortex-M7 image | No: another core | Measured, if at all, only by whatever loads it; unconfirmed |
| U-Boot SPL | No: before BL31 and OP-TEE | Could only add to an event log a later stage forwards; unconfirmed |
| TF-A BL31 | Not directly | Upstream TF-A has a measured-boot option that writes an event log; the fTPM TA can take such a log through `CFG_TA_MEASURED_BOOT` (off by default, 1 KiB by default) ([ta-options-survey.md](../secure-world/ta-options-survey.md#ftpm-ta)). Whether the i.MX 95 BL31 port builds it is unconfirmed |
| OP-TEE OS and early TAs | Not by itself | Not measured by any stage read here |
| U-Boot proper | Yes, with `CONFIG_TPM2_FTPM_TEE` and reachable NV (RPMB only) | With REE FS, U-Boot has no NV path; whether the BSP builds the driver is unconfirmed |
| Linux kernel, initramfs | Yes, once `/dev/tpmrm0` exists | Anything before the supplicant starts is measured only if U-Boot extended it |
| Linux user space (IMA) | Yes | Whether IMA is built is `hsm-self-defence`'s open question ([SPEC.md](../SPEC.md)) |

Each "unconfirmed" above is a gap until the board shows otherwise. The depth device-attest-01 needs is
[question 6](#open-questions-for-the-owner).

## Later steps, not this design

The image configuration is in [build.md](build.md) (provisional). The board test ([ROADMAP.md](../../ROADMAP.md), `ftpm`) come after the owner approves this
row. The redeploy is coordinated with Infra together with the xkmsd web-console build and the barrier re-init;
hardware runs happen on the lab's board host, one lane at a time. The boot media does not change (owner ruling
769).

## Open questions for the owner

1. **RPMB key programming. Decided, owner ruling 1234.** The NV is in the eMMC RPMB on production devices, written
   only after OEM close, and in the REE file system on development boards only (no rollback protection; a root
   rewrite wipes the NV). The key programming is a one-time, irreversible provisioning-station step after OEM close
   ([rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §5, §10), outside this repository. Still open
   (TENANT ASK 4, default no): whether a byte-identical root rewrite may keep the NV.
2. **fTPM TA source and revision.** The `ms-tpm-20-ref` TA in OP-TEE's `optee_ftpm`, or an fTPM carried in a newer
   `optee_os`; which revision; and whether the BSP's OP-TEE 4.10 builds it unchanged. Proposed and built
   ([secure-world/build.md](../secure-world/build.md#the-pins)): `optee_ftpm` 4.10.0, which the BSP's OP-TEE 4.10 builds
   unchanged; OP-TEE 4.10 carries no fTPM of its own.
3. **EK template.** RSA 2048 or ECC P-256, the default templates of the TCG EK Credential Profile, and whether the
   EK persists at that profile's default handle.
4. **Re-provisioning.** What clears the TPM (`TPM2_Clear`, a secure-storage wipe, a rootfs reflash under REE FS),
   who may do it, and what happens to the issued EK certificate: revoked, or reissued through endorse-01.
5. **Image scope for the redeploy.** The full image, or only `flash.bin`, `tee.bin` and the kernel. The boot media
   does not change (ruling 769).
6. **Measured-boot depth for device-attest-01.** Which of the gaps above device-attest-01 must close, and whether
   evidence that starts at U-Boot or at the kernel is accepted.
7. **The TPM identity and the key tier.** Confirm that the EK and the attestation keys are the device's TPM
   identity, held outside the enclave, and not board keys under the `secure-key-handling` row.
