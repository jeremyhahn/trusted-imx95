# ftpm — image configuration

> **Status: PROPOSED** · Scope: trusted-imx95 `ftpm`, the image build (configuration only) · Last verified: 2026-11-22
> How the firmware TPM is configured into the platform image. The design is [README.md](README.md); conflicts with it
> are defects in this file. Issue #140. Everything below is a **provisional default**: the owner has not answered the
> [open questions](README.md#open-questions-for-the-owner), and they stay open.

The recipes have been parsed, the TA and OP-TEE with the early TA compiled and the kernel `.config` checked under bitbake ([below](#what-the-build-host-showed)); the image build result is recorded there too. Nothing here programs a key, a fuse, a life-cycle
state or the RPMB key, and no step to do so is scripted or documented as a command to run.

## What is built

| Part | Where | Provisional default |
|---|---|---|
| Kernel driver | `platform-image/recipes-kernel/linux/files/ftpm.cfg`, listed in the `linux-imx` bbappend | `CONFIG_TCG_TPM=y` and `CONFIG_TCG_FTPM_TEE=y`, built in, so `/dev/tpmrm0` exists once `tee-supplicant` has started. Both symbols are in `platform-image/kernel-required.txt` |
| TA recipe | `platform-image/recipes-security/optee/optee-ftpm_4.10.0.bb` | `optee_ftpm` 4.10.0 on `ms-tpm-20-ref`, at the commits [secure-world/build.md](../secure-world/build.md#the-pins) pins and `secure-world/bsp.lock` holds; no floating revision |
| OP-TEE OS | `optee-os_%.bbappend` and `optee-os-tadevkit_%.bbappend`, with the shared `optee-ftpm-flags.inc` | `CFG_EARLY_TA=y` with the fTPM TA (UUID in the bbappend) in `EARLY_TA_PATHS` and the PKCS#11 TA in `CFG_IN_TREE_EARLY_TAS`, and the NV storage flags chosen by `TRUSTED_IMX95_FTPM_NV`: `reefs` (default) `CFG_REE_FS=y`, `CFG_RPMB_FS=n`; `rpmb` `CFG_REE_FS=y`, `CFG_RPMB_FS=y`, `CFG_RPMB_WRITE_KEY=n`, `CFG_RPMB_TESTKEY=n` |
| TPM ordering point | `platform-image/recipes-security/optee/trusted-imx95-tee-nv/trusted-imx95-tpm.target`, installed and enabled (`multi-user.target.wants`) by `trusted-imx95-tee-nv_1.0.bb` | `Requires=` and `After=dev-tpmrm0.device`, `After=tee-supplicant@teepriv0.service`; a TPM user orders itself after it. A repo target, not systemd's `tpm2.target`, which is pulled in only once the device exists ([survey item 6 (e)](../secure-world/ta-options-survey.md#unconfirmed-items)). No ordering cycle with the BSP's `tee-supplicant@.service` (`DefaultDependencies=no`, `Before=sysinit.target`): the target is ordered after it and before nothing. `systemd-analyze verify` on a temporary root holding the target and the NV units passed; the BSP's supplicant unit was not in that root, so the cycle check against it is by reading its ordering only |
| Debug image | `trusted-imx95-image-debug.bb` | tpm2-tools; the production image does not carry it |

## The defaults, each provisional

1. **NV storage chosen by one selector, `TRUSTED_IMX95_FTPM_NV`** ([question 1](README.md#open-questions-for-the-owner),
   owner ruling 1234). `reefs`, the default, is for development boards: the NV is in the OP-TEE REE file system
   (`CFG_REE_FS=y`, `CFG_RPMB_FS=n`; the TA's `CFG_FTPM_TA_TEE_STORAGE_ID` is `TEE_STORAGE_PRIVATE_REE`). `rpmb` is the
   production selection: the NV is in the eMMC RPMB (`CFG_RPMB_FS=y`, REE FS stays on for the PKCS#11 TA and other
   objects; the TA's storage ID is `TEE_STORAGE_PRIVATE_RPMB`). Any other value stops the parse, and the debug image
   skips itself under `rpmb` (`bb.parse.SkipRecipe`, so every other recipe, the production image included, still parses). In neither set does an option let OP-TEE program the RPMB key: `CFG_RPMB_WRITE_KEY=n` and
   `CFG_RPMB_TESTKEY=n` are set explicitly in the `rpmb` set, so RPMB writes fail until the provisioning station has
   programmed the key after OEM close ([rpmb-survey.md](../secure-key-handling/rpmb-survey.md) §5 and §10). That step is
   outside this repository. **Nothing was parsed or built with `rpmb`** (no bitbake here). Under `reefs` the limits
   are: **no rollback protection** (root on Linux can restore an older copy of the files). The NV is kept on the
   `tee-data` partition when the root partition is rewritten; a full `.wic` flash is the reprovisioning path: it
   recreates `tee-data` empty and so erases the fTPM NV and all OP-TEE REE-FS storage, which destroys the TPM's seeds
   and with them the EK (SPEC row `ftpm`, owner, 2026-11-25).
2. **The TA is `optee_ftpm` 4.10.0** (ms-tpm-20-ref), as an early TA linked into `tee.bin`
   ([question 2](README.md#open-questions-for-the-owner)).
3. **The kernel driver is built in**, not a module. The trace ([ta-options-survey.md](../secure-world/ta-options-survey.md#unconfirmed-items),
   item 6 (d)) shows this does not change when the device appears: the TA is put on the TEE bus only after
   `tee-supplicant` opens `/dev/teepriv0`.
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

### Compile run (same host, 2026-11-22)

| Command | Exit status |
|---|---|
| `make platform-image-hosttools` | 0 |
| `PLATFORM_IMAGE_PARSE_FORCE=1 make platform-image-parse` | 0 |
| `bitbake -c compile optee-ftpm` (first, then with `LIBGCC_LOCATE_CFLAGS`) | 1, twice: the link could not find `libgcc.a`, then the `.ta` signing step lacked Python `cryptography` |
| `bitbake optee-ftpm` (stripped ELF only) | 0 |
| `bitbake optee-os` (early TA) | 0: the build holds `early_ta_bc50d971-d4c9-42c4-82cb-343fb7f37896.o` |
| `make platform-image-kernel-config` with `ftpm.cfg` | 0: 33 required symbols, `TCG_TPM=y` and `TCG_FTPM_TEE=y` among them |

Fixes: the TA's make arguments gain `LIBGCC_LOCATE_CFLAGS=--sysroot=${STAGING_DIR_HOST}`, so the cross compiler finds
`libgcc.a`; and `do_compile` builds only `<uuid>.stripped.elf`, not the signed `.ta`, because an early TA is linked
into `tee.bin` and needs no signature, so no signing key is involved. `O=${B}` is not honoured by the TA's Makefile:
the output is in `${S}`, and the deploy task installs from there.

### Image build

`bitbake trusted-imx95-image-debug` first stopped (exit 1) at `imx-m7-demos` `do_unpack`: that recipe needs the Freescale
EULA accepted (`ACCEPT_FSL_EULA`). **Accepting it awaits the owner**; the layer does not set it. NXP's wic flow pulled
`imx-boot`, and with it `imx-m7-demos`, in through `WKS_FILE_DEPENDS`. The image now uses its own wks
(`platform-image/files/wic/trusted-imx95.wks`, no boot container: this repository's boot-container flow writes that,
with the M7 image) and removes `imx-boot` from `WKS_FILE_DEPENDS`, so the EULA gate is not reached. The wks was first
not found (exit 1 at `do_image_wic`): BitBake looks in `<layer>/files/wic`, not `<layer>/wic`.

| Command | Exit status |
|---|---|
| `bitbake optee-os` (fTPM and PKCS#11 early TAs) | 0: `early_ta_` objects for `bc50d971-…` and `fd02c9da-…` are in the build |
| `bitbake trusted-imx95-image-debug` | 0 (4698 tasks), with `optee-client`, `trusted-imx95-tee-nv` and the wic image |

`tee-supplicant` is enabled at boot by `trusted-imx95-tee-nv`, which also mounts the `tee-data` partition on `/data`
(its REE-FS storage is `/data/tee`) before the supplicant starts; the NV therefore persists across a reboot and a rewrite of the root partition, and a full-image flash erases it
([README](README.md#nv-storage)). Not run on a board.

The wic's GPT, read from the image: `boot` (256 MiB, FAT, holds `Image` and the `imx95-19x19-frdm-pro*.dtb` files),
`root` (1 GiB) and `tee-data` (64 MiB). The wks follows the BSP's boot-partition layout and leaves out only the raw
`imx-boot` entry; the image drops the `mcore-demos/` entries of `IMAGE_BOOT_FILES` (imx-m7-demos, EULA). The rootfs has
the `/data` mountpoint. A rewrite of the root partition keeps the NV; a full-image flash recreates `tee-data` empty
and so erases it (SPEC row `ftpm`, owner, 2026-11-25).

### Reproducible build

ROADMAP `ftpm` (b) asks for a byte-for-byte rebuild check. `make platform-image-repro-check REPRO_A=<dir> REPRO_B=<dir>`
([what it compares](../platform-image/build.md)) is that check. It was tested only on synthetic
deploy directories (`test/platform_image_repro_check_test.sh`); **no two-build run was made** (no bitbake in this lane).
Unconfirmed until one is:

- The deploy paths: `optee-ftpm/<uuid>.stripped.elf` (from the recipe's `do_deploy`), `tee.bin`, `Image` and
  `imx95-19x19-frdm-pro*.dtb` directly in the deploy directory (the machine's names; the checker fails if one is absent).
- That the image emits one rootfs archive: the image adds `IMAGE_FSTYPES += "tar"` (provisional); the check refuses
  zero or several `*.rootfs*.tar*` files.
- That the archive keeps xattrs, ACLs and capabilities: the image sets `IMAGE_CMD_TAR` with `--format=posix --xattrs --xattrs-include='*' --acls`, so the repro check compares them; not yet confirmed on a real build.
- Whether wic draws the GPT GUIDs per build (they are not compared), and the disk GUID.
- Whether the FAT `boot` partition is reproducible (volume ID and directory timestamps are the suspects); the check
  fails if it is not, which would show it.
- Whether `tee.bin`, the kernel and the DTBs embed anything per build (the fallback `SOURCE_DATE_EPOCH` is expected to
  hold them).

Still open:

- The board check ([secure-world/build.md](../secure-world/build.md#step-c-on-the-board)).



## Effective OP-TEE storage flags and the device tree's fTPM node (lane 140-ftpm-s2)

Read from shallow fetches of the pinned commits (not copied; cited only).

**`CFG_REE_FS` and `CFG_RPMB_FS` in the built OP-TEE.** `nxp-imx/imx-optee-os` `99f40897dd1f`:

- Default: `mk/config.mk:161` is `CFG_REE_FS ?= y`; `mk/config.mk:170` is `CFG_RPMB_FS ?= n`
  (`CFG_REE_FS_INTEGRITY_RPMB` follows `CFG_RPMB_FS` at `mk/config.mk:174`). `CFG_REE_FS_TA ?= y` is at `:380`,
  `CFG_SECSTOR_TA ?=` at `:706` and `CFG_SECSTOR_TA_MGMT_PTA ?=` at `:710`.
- Platform override: none. `core/arch/arm/plat-imx/conf.mk` exists, and a search of `core/arch/arm/plat-imx` for
  `REE_FS` and `RPMB` found no match.
- Effective value with our recipe (`optee-ftpm-flags.inc`, default `TRUSTED_IMX95_FTPM_NV = "reefs"`, on the make
  command line through `EXTRA_OEMAKE`): `CFG_REE_FS=y`, `CFG_RPMB_FS=n`. A command-line value wins over `?=`, so the
  recipe and the default agree; the recipe's line is explicit, not load-bearing. No recipe change was needed.
  `CFG_REE_FS_TA=n` and `CFG_SECSTOR_TA_MGMT_PTA=n` stay set explicitly, as the defaults above are `y`.
  `test/platform_image_ftpm_test.sh` already fails when the `reefs` set drops either flag.
- Not read: the meta-imx recipe's own `EXTRA_OEMAKE` (a platform-wide flag there would be visible only on a parse).

**The device tree's fTPM node.** `nxp-imx/linux-imx` `6e694eda40aa`, `arch/arm64/boot/dts/freescale/`:

- Files searched: the whole `freescale/` directory (1121 files) for `ftpm` and `microsoft,ftpm`; the FRDM-IMX95 board
  is `imx95-15x15-frdm.dts`, which includes only `imx95.dtsi` (`imx95-15x15-frdm.dts:11`), and `imx95.dtsi` includes
  only dt-bindings and local `imx95-*.h` headers (`imx95.dtsi:5-14`). No match. The `firmware` node at
  `imx95.dtsi:368` holds `scmi` and no OP-TEE or fTPM node, and no `linaro,optee` string occurs in the `imx95*` files.
- The driver's compatible is `microsoft,ftpm` (`drivers/char/tpm/tpm_ftpm_tee.c:312`); without a node the platform
  path never probes, and the driver binds through the TEE bus (`tpm_ftpm_tee.c:328-345`) when the TA's device is
  enumerated, which is the scan `tee-supplicant` triggers once it runs.
- Meaning for `trusted-imx95-tpm.target`: no node, so nothing probes the fTPM before `tee-supplicant`; the ordering
  (`After=tee-supplicant@teepriv0.service`, `dev-tpmrm0.device`) holds as written.
- Limit: only the kernel tree's DTS was read. U-Boot or the boot container may add or patch nodes at boot (the
  absence of an OP-TEE node in the kernel DTS suggests the firmware node is added at runtime); that was not read.
