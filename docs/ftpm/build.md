# ftpm — image configuration

> **Status: PROPOSED** · Scope: trusted-imx95 `ftpm`, the image build (configuration only) · Last verified: 2026-11-22
> How the firmware TPM is configured into the platform image. The design is [README.md](README.md); conflicts with it
> are defects in this file. Issue #140. Everything below is a **provisional default**: the owner has not answered the
> [open questions](README.md#open-questions-for-the-owner), and they stay open.

The recipes have been parsed and the TA source fetched under bitbake ([below](#what-the-build-host-showed)); nothing is built. Nothing here programs a key, a fuse, a life-cycle
state or the RPMB key, and no step to do so is scripted or documented as a command to run.

## What is built

| Part | Where | Provisional default |
|---|---|---|
| Kernel driver | `platform-image/recipes-kernel/linux/files/ftpm.cfg`, listed in the `linux-imx` bbappend | `CONFIG_TCG_TPM=y` and `CONFIG_TCG_FTPM_TEE=y`, built in, so `/dev/tpmrm0` exists once `tee-supplicant` has started. Both symbols are in `platform-image/kernel-required.txt` |
| TA recipe | `platform-image/recipes-security/optee/optee-ftpm_4.10.0.bb` | `optee_ftpm` 4.10.0 on `ms-tpm-20-ref`, at the commits [secure-world/build.md](../secure-world/build.md#the-pins) pins and `secure-world/bsp.lock` holds; no floating revision |
| OP-TEE OS | `optee-os_%.bbappend` and `optee-os-tadevkit_%.bbappend`, with the shared `optee-ftpm-flags.inc` | `CFG_EARLY_TA=y` with the fTPM TA (UUID in the bbappend) in `EARLY_TA_PATHS`, `CFG_REE_FS=y`, `CFG_RPMB_FS=n` |
| Debug image | `trusted-imx95-image-debug.bb` | tpm2-tools; the production image does not carry it |

## The defaults, each provisional

1. **NV storage on the OP-TEE REE file system, RPMB off** ([question 1](README.md#open-questions-for-the-owner)).
   The TA sets `CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE`. No RPMB key option is set anywhere in the
   layer. The limits: **no rollback protection** (root on Linux can restore an older copy of the files), and
   **the NV is lost on a rootfs reflash**, which destroys the TPM's seeds and with them the EK.
2. **The TA is `optee_ftpm` 4.10.0** (ms-tpm-20-ref), as an early TA linked into `tee.bin`
   ([question 2](README.md#open-questions-for-the-owner)).
3. **The kernel driver is built in**, not a module.
4. **No EK template is chosen in the image** ([question 3](README.md#open-questions-for-the-owner)). The EK is
   created at first boot by provisioning; RSA 2048 or ECC P-256 stays open.
5. **tpm2-tools only in the debug image**, which never holds production keys.

## Measured-boot gaps

None is closed by this configuration; `CFG_TA_MEASURED_BOOT` stays off. The gaps listed in
[README.md](README.md#measured-boot) all stand:

- Boot ROM and enclave (AHAB): no event log known; verification is not a measurement.
- System Manager (M33): no known event log.
- Cortex-M7 image: measured only by whatever loads it, if at all.
- U-Boot SPL: runs before BL31 and OP-TEE; could only add to a log a later stage forwards.
- TF-A BL31: whether the i.MX 95 port builds TF-A's measured-boot event log is unconfirmed.
- OP-TEE OS and early TAs: not measured by any stage.
- U-Boot proper: needs `CONFIG_TPM2_FTPM_TEE` (unconfirmed for the BSP) and, with REE FS, has no NV path.
- Linux kernel and initramfs: measured only once `/dev/tpmrm0` exists, so anything before `tee-supplicant` is
  measured only if U-Boot extended it.
- Linux user space (IMA): whether IMA is built is `hsm-self-defence`'s open question.

## What the build host showed

Run on the build host as in [platform-image/build-host-check.md](../platform-image/build-host-check.md#repeat-this-run)
(2026-11-22, Yocto wrynose, the lock's layers):

- **Parse.** `make platform-image-hosttools` and `make platform-image-parse` exit 0: 3631 recipes parsed, 0 errors. The
  first parse failed on `tpm2-tools`, which lives in `meta-security/meta-tpm`; that layer (already pinned through
  `meta-security`) is now in `bblayers.conf.template`.
- **`bitbake -e optee-os`** (read with `bitbake-getvar`) holds `CFG_EARLY_TA=y`, the fTPM UUID in `EARLY_TA_PATHS`
  (`bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf`), `CFG_REE_FS=y` and `CFG_RPMB_FS=n`.
- **Recipe name.** `optee-os-tadevkit` exists in meta-imx at the pinned revision
  (`optee-os-tadevkit_4.10.0.imx.bb`); the `%` bbappend applies.
- **Fetch and unpack.** `bitbake -c fetch optee-ftpm` passes with both pins. `-c unpack` failed on `S = "${WORKDIR}/git"`
  (wrynose sets `S` itself), so the assignment is removed and `CFG_MS_TPM_20_REF` points into `${UNPACKDIR}`.
- **License.** The pinned `LICENSE` is Microsoft's two-clause BSD license, not MIT: `LICENSE = "BSD-2-Clause"`, and
  `LIC_FILES_CHKSUM` carries its md5. `bitbake -c populate_lic optee-ftpm` passes. No zero checksum is left.

Still open:

- The TA's make arguments and the dev kit path have not run: `do_compile` was not executed, and no image was built
  (not requested in this run).
- The kernel `.config` check (`make platform-image-kernel-config`) was not repeated with `ftpm.cfg`.
- The board check ([secure-world/build.md](../secure-world/build.md#step-c-on-the-board)).
