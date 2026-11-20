# secure-world — the pinned, reproducible build

> **Status: REFERENCE** · Scope: trusted-imx95 `secure-world` steps (a) and (b), `ftpm` step (a) · Last verified: 2026-11-20
> How BL31 and OP-TEE are built here. The design is [architecture.md](architecture.md) and [ftpm/README.md](../ftpm/README.md); conflicts with them are defects in this file.

`make secure-world` builds the Cortex-A secure world from public sources pinned in
[secure-world/bsp.lock](../../secure-world/bsp.lock): TF-A BL31 for i.MX 95 with the OP-TEE dispatcher, and OP-TEE
OS with the fTPM TA and the PKCS#11 TA linked in as early TAs. Nothing is flashed or signed for the board. No RPMB key
is programmed and no fuse is touched. Issue #134; the board check is step (c), [below](#step-c-on-the-board).

## The command

```sh
make secure-world
# or, choosing the directories:
make secure-world SW_WORK=/path/to/work SW_OUT=/path/to/out SW_CACHE=/path/to/cache
```

`scripts/secure-world-build.sh` does the work. By default it uses `trusted-imx95/secure-world/` under
`$XDG_CACHE_HOME` (or `~/.cache`) for `work/` (sources and build trees, recreated on every run) and `cache/` (the
toolchain tarball and the wheels, reused only after their SHA-256 matches again). It writes the artefacts to
`.secure-world/out/` in the checkout, which git ignores. The sources stay outside the checkout because `make security`'s
tree scan reads every file under it, ignored or not, and the fetched TF-A tree carries test private keys. `scripts/secure-world-build.sh --check-lock` checks the
lock file offline and builds nothing; `test/secure_world_build_test.sh` runs it in `make test`.

The output directory holds:

| File | What it is |
|---|---|
| `bl31.bin` | TF-A BL31, `PLAT=imx95 SPD=opteed`, release build |
| `tee.bin` | OP-TEE OS, `core/tee-raw.bin` of the build, which the release's recipe also deploys as `tee.bin` |
| `SHA256SUMS` | `sha256sum` of the two, checkable with `sha256sum -c SHA256SUMS` |
| `build-info.txt` | The lock file's digest, the commits, the flags, the toolchain and `SOURCE_DATE_EPOCH` |

**Host.** x86_64 Linux with glibc, with `git`, `curl`, `make`, `tar`, `xz`, `sha256sum`, CPython 3.13 and `uv` on
`PATH`, and network access to the pinned URLs only: github.com, developer.arm.com and PyPI. The script checks the
architecture and each tool and stops, naming any that is missing. The project's devcontainer image is Alpine (musl)
and cannot run Arm's glibc-hosted toolchain, so `make docker-run` does not build this. The earlier builds ran in a
Debian 13 container on a build node with no Docker.

## The pins

The release is **provisional**: `docs/platform-image/build-system-options.md` (on #137, not yet on this branch)
recommends it, and the owner has not chosen the BSP baseline yet (#14 Q2). Changing the release means re-reading
every value below from the new release's manifest and recipes and editing the lock file. No other file changes.

| Pin | Value | Read from |
|---|---|---|
| NXP Linux BSP release | `lf-6.18.37-2.1.0`; `imx-manifest` commit `0c44ab18abe471b4326037b61893f4e69b6fc182` | The tag, peeled |
| meta-imx | `rel_imx_6.18.37_2.1.0`, commit `2eb758f42cfb96042344815b7dd7755b06ba1e3b` | `imx-6.18.37-2.1.0.xml` in that manifest |
| TF-A | `nxp-imx/imx-atf`, branch `lf_v2.14`, commit `af9eb2c1748ee3abc0ead7dc76e462f50c573036` | `imx-atf_2.14.bb` in meta-imx |
| OP-TEE OS 4.10 | `nxp-imx/imx-optee-os`, branch `lf-6.18.37_2.1.0`, commit `99f40897dd1fc28b4c792773b167e3db629db2ff` | `optee-os_4.10.0.imx.bb` in meta-imx |
| fTPM TA | `OP-TEE/optee_ftpm`, tag `4.10.0`, commit `a09269b15de635e1816fe832e26adfbfb44c5455` | The tag, peeled |
| TPM 2.0 reference | `microsoft/ms-tpm-20-ref`, commit `98b60a44aba79b15fcce1c0d1e46cf5918400f6a` | The commit `optee_ftpm`'s README names |
| Toolchain | Arm GNU Toolchain 15.2.Rel1 (GCC 15.2.1), `aarch64-none-linux-gnu`, tarball SHA-256 `9a685b335bd709d683a8c782253c37e8c36c10e6924e59e39d4769b02132eb43` | Arm's published `.sha256asc`. GCC 15 matches the release's Yocto (`GCCVERSION 15.%`) |
| Python wheels | `cryptography` 50.0.2, `cffi` 2.1.1, `pycparser` 3.12, `pyelftools` 0.33, each by SHA-256 | PyPI |

OP-TEE 4.10 has no fTPM TA in its own tree, so the TA is `optee_ftpm` at the tag matching that version, as
[ftpm/README.md](../ftpm/README.md) question 2 asks. `optee_ftpm` uses OP-TEE's crypto and `libmbedtls`, so
`ms-tpm-20-ref`'s `wolfssl` submodule is not fetched. `uv` itself is not pinned; it only installs the hash-checked
wheels.

Two choices here differ from the wording elsewhere:

- **TF-A is NXP's `imx-atf` fork**, the one the release carries, as the brief for this step directs. Owner ruling 771
  says "upstream TF-A". Whether mainline TF-A builds an i.MX 95 BL31 that works with this OP-TEE was not checked. The
  owner needs to confirm which of the two the ruling means.
- **The OP-TEE platform is `imx-mx95evk`.** This OP-TEE tree has no FRDM-IMX95-PRO flavour: `mx95evk` is the only
  i.MX 95 flavour in `core/arch/arm/plat-imx/conf.mk`, and the release's OP-TEE recipe maps the `mx95` machines to
  it. The FRDM-Pro machine is one of them through the shared `imx95-evk.inc`; that this mapping applies was not
  checked further. Whether its DDR size and console UART suit the FRDM-IMX95-PRO is checked on the board in
  step (c).

## The flags

TF-A: `PLAT=imx95 SPD=opteed bl31`, the release recipe's arguments for a machine with the `optee` feature.

OP-TEE, set on each OP-TEE make:

| Flag | Why |
|---|---|
| `PLATFORM=imx-mx95evk CFG_ARM64_core=y` | The i.MX 95 flavour; a 64-bit core |
| `CFG_TEE_CORE_LOG_LEVEL=0 CFG_TEE_TA_LOG_LEVEL=0` | The release recipe's log levels |
| `CFG_REE_FS=y CFG_RPMB_FS=n` | Secure storage on the REE file system by default. RPMB needs its key programmed, once and irreversibly: the owner's decision ([ftpm/README.md](../ftpm/README.md#nv-storage)) |
| `CFG_PKCS11_TA=y` | The PKCS#11 TA (already the default; stated) |
| `CFG_EARLY_TA=y` | Early TAs, linked into `tee.bin` |
| `EARLY_TA_PATHS=<fTPM TA's stripped ELF>` | The fTPM TA, UUID `bc50d971-d4c9-42c4-82cb-343fb7f37896`, as an early TA (ruling 927) |
| `CFG_IN_TREE_EARLY_TAS=pkcs11/fd02c9da-306c-48c7-a49c-bbd827ae86ee` | The PKCS#11 TA as an early TA too, so `tee.bin` carries both and neither depends on the root file system |

The fTPM TA is built against the TA dev kit of a first OP-TEE build with the same flags. It uses
`CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE`, so its NV is in REE FS storage explicitly.
`CFG_TA_MEASURED_BOOT` stays off, the TA's default ([ftpm/README.md](../ftpm/README.md#measured-boot)).

The release's BSP installs the PKCS#11 TA as a file under `/lib/optee_armtz` on the root file system. Here it is
early instead. If an image also ships that file, which copy OP-TEE loads is to be checked in step (c).

**TA signing key.** The TAs are signed with the upstream OP-TEE default test key, `keys/default_ta.pem` in the
fetched `optee_os` tree. Its private half is public, so the signature proves nothing. An early TA is part of `tee.bin`
and is not loaded through the signature check. The build sets `CFG_REE_FS_TA=n`, so OP-TEE rejects every TA
loaded from the file system and the public key is trusted for nothing. No key is in this repository and the build writes none to it. Replacing the key belongs to the
`secure-key-handling` and `boot-container` rows.

## Reproducibility

`SOURCE_DATE_EPOCH` defaults to the pinned OP-TEE commit's committer time (`1788777083`).

**No hash is recorded for the final configuration, and no reproducibility is claimed for it.** Two clean builds of
`scripts/secure-world-build.sh` at b4f0e41 were run on 2026-11-20 (x86_64 Linux host, the pinned toolchain). The
OP-TEE image does not link with `CFG_REE_FS_TA=n`: `core/pta/secstor_ta_mgmt.c` (`install_ta`) references
`ree_fs_check_update_ta_version`, which that setting leaves out. No `bl31.bin` or `tee.bin` of this configuration
exists. The hashes recorded earlier (two builds, equal) were of the configuration before `CFG_REE_FS_TA=n`, so they
are withdrawn. The script needs a fix first (for example `CFG_SECSTOR_TA_MGMT_PTA=n`, not tried here); then two clean
builds are to be run and their hashes recorded here.

The configuration the hashes will belong to is pinned by a digest, which `test/secure_world_build_test.sh` recomputes
from the script (its `optee_flags` array and its final OP-TEE make call, whitespace squeezed). The test fails when the
script's OP-TEE configuration differs from the one recorded here, so hashes cannot outlive a flag change. Record the
new digest together with the new hashes.

OP-TEE configuration digest: `4d0805bed0428d1b9efce71a9c5507e0fb3c8f5257f78a7ab25a3d94bf116cc2`

Not tested: a second host, another `uv` or Python patch release, and a different `SOURCE_DATE_EPOCH`.

**Not in CI.** The build fetches about 150 MB, runs for about two minutes and needs the network. `make test`
runs only the offline lock check and the script's unit tests.

## Step (c) on the board

Step (c) is not done here. It needs the boot container to carry these images (`boot-container` row). It runs on the
lab's board host, one lane at a time, and any boot-media change is announced first. It will check:

1. The TF-A and OP-TEE banners in the boot log show these builds: TF-A's build message and OP-TEE's version line,
   with their commits and the `SOURCE_DATE_EPOCH` date.
2. `/dev/tee0` and `/dev/teepriv0` are present.
3. The PKCS#11 TA answers: `pkcs11-tool --module <OP-TEE's libckteec> --list-slots` lists OP-TEE's slots.
4. The fTPM TA answers once the kernel has `CONFIG_TCG_FTPM_TEE` (`ftpm` row): `/dev/tpmrm0` appears after
   `tee-supplicant` starts, and a TPM2 `GetRandom` or `GetCapability` succeeds.
5. The TPM's NV and the PKCS#11 tokens survive a reboot in REE FS storage, which is the supplicant's storage
   directory on the root file system.
6. Whether the `mx95evk` flavour's memory map and console suit the FRDM-IMX95-PRO.
7. `xtest`, if the image ships it.

## ROADMAP state

The `secure-world` (a) and (b) and `ftpm` (a) states below belong in [ROADMAP.md](../../ROADMAP.md). This lane could
not write that file: the lane's write guard protects it.

- `secure-world` (a): pinned in `secure-world/bsp.lock`, release `lf-6.18.37-2.1.0` provisional (#14 Q2).
- `secure-world` (b): `make secure-world` is meant to build both artefacts with a SHA-256 manifest, but the OP-TEE
  image does not link with `CFG_REE_FS_TA=n` (see [Reproducibility](#reproducibility)); no build of the final
  configuration exists. Not in CI. Nothing has run on the board.
- `ftpm` (a): OP-TEE side built: `optee_ftpm` 4.10.0 on the pinned `ms-tpm-20-ref`, an early TA, NV in REE FS. The
  kernel's `CONFIG_TCG_FTPM_TEE` remains, with the image build.
