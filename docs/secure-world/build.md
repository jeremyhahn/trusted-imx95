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
architecture and each tool and stops, naming any that is missing. The project's Alpine (musl) `toolchain` stage cannot
run Arm's glibc-hosted toolchain or install the lock's glibc wheels, so `make docker-run` does not build this. CI uses
the Dockerfile's `secure-world` stage instead (`make docker-build-sw`; below). The earlier builds ran in a Debian 13
container on a build node with no Docker.

## The pins

The release is **provisional**: `docs/platform-image/build-system-options.md` (on #137, not yet on this branch)
recommends it, and the owner has not chosen the BSP baseline yet (#14 Q2). Changing the release means re-reading
every value below from the new release's manifest and recipes and editing the lock file. No other file changes.

| Pin | Value | Read from |
|---|---|---|
| NXP Linux BSP release | `lf-6.18.37-2.1.0`; `imx-manifest` commit `0c44ab18abe471b4326037b61893f4e69b6fc182` | The tag, peeled |
| meta-imx | `rel_imx_6.18.37_2.1.0`, commit `2eb758f42cfb96042344815b7dd7755b06ba1e3b` | `imx-6.18.37-2.1.0.xml` in that manifest |
| TF-A | Upstream Arm TF-A, tag `v2.15.0`, peeled commit `da738d5eae93af342fdc4995dd3c05acb4c9d757`, fetched from the GitHub mirror `ARM-software/arm-trusted-firmware` | The newest release tag of `git.trustedfirmware.org/TF-A/trusted-firmware-a.git`; its tree has `plat/imx/imx9/imx95` |
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

- **TF-A is upstream Arm TF-A**, as docs/SPEC.md says, at the release tag `v2.15.0` with `PLAT=imx95 SPD=opteed`.
  It is not the BSP release's `imx-atf` fork, whose revision the release carries. `make secure-world` builds this
  BL31 with the pinned OP-TEE. That the BL31 boots and starts this OP-TEE on the board is not checked: upstream's
  `BL32_BASE` (`0x8C000000`) and the OP-TEE flavour's secure memory start were read as the same address, not run.
  **Known gap:** NXP's fork adds SiP services that upstream `v2.15.0` lacks on the i.MX 95: the Cortex-M7 (SRC) and
  logical-machine (LMM) calls in `imx95_m7.c` and `imx95_lmm.c`. Linux's remoteproc for the M7 may depend on them, and
  a System Manager SCMI path that starts or stops another logical machine from Linux needs them. Whether the
  board needs them is open ([tfa-scmi-survey.md](tfa-scmi-survey.md), section 2.2 and the questions on NXP's SiP
  services); until it is answered, those calls are absent from the build.
- **The OP-TEE platform is `imx-mx95evk`.** This OP-TEE tree has no FRDM-IMX95-PRO flavour: `mx95evk` is the only
  i.MX 95 flavour in `core/arch/arm/plat-imx/conf.mk`, and the release's OP-TEE recipe maps the `mx95` machines to
  it. The FRDM-Pro machine is one of them through the shared `imx95-evk.inc`; that this mapping applies was not
  checked further. Whether its DDR size and console UART suit the FRDM-IMX95-PRO is checked on the board in
  step (c).

### BSP-only TF-A services

What NXP's `imx-atf` carries that upstream `v2.15.0` lacks on the i.MX 95, from the public sources in
[tfa-scmi-survey.md](tfa-scmi-survey.md) section 2.2, each with its consumer:

| Service | Consumer | State |
|---|---|---|
| SRC SiP call for the Cortex-M7 (`imx95_m7.c`: set reset address, prepare, start, stop, query) | Linux remoteproc for the M7, on NXP's BSP (by the fork's code comments; not checked against the kernel) | **Open** |
| LMM SiP call (`imx95_lmm.c`: boot or force-shutdown a logical machine) | A Linux-side start or stop of another logical machine over the secure SCMI agent; no consumer found in this repository | **Open** |
| SCMI base protocol compiled in | Agent discovery for the M7 code; no other consumer found | **Open** (follows the M7 call) |
| FF-A shared-memory helper with `SPD=trusty` | none found: this build uses `SPD=opteed` | Not needed |

The three open rows are one question for the owner (survey question 3): whether the M7 is driven from Linux. Until it
is answered, the build omits them.

## The flags

TF-A: `PLAT=imx95 SPD=opteed bl31`, the upstream TF-A imx95 platform build arguments this repository uses.

OP-TEE, set on each OP-TEE make:

| Flag | Why |
|---|---|
| `PLATFORM=imx-mx95evk CFG_ARM64_core=y` | The i.MX 95 flavour; a 64-bit core |
| `CFG_TEE_CORE_LOG_LEVEL=0 CFG_TEE_TA_LOG_LEVEL=0` | The release recipe's log levels |
| `CFG_REE_FS=y CFG_RPMB_FS=n` | Secure storage on the REE file system by default. RPMB needs its key programmed, once and irreversibly: the owner's decision ([ftpm/README.md](../ftpm/README.md#nv-storage)) |
| `CFG_REE_FS_TA=n CFG_SECSTOR_TA_MGMT_PTA=n` | No TA is loaded from the file system. The PTA that installs TAs into REE FS storage needs REE FS TA support and would not link |
| `CFG_PKCS11_TA=y` | The PKCS#11 TA (already the default; stated) |
| `CFG_EARLY_TA=y` | Early TAs, linked into `tee.bin` |
| `EARLY_TA_PATHS=<fTPM TA's stripped ELF>` | The fTPM TA, UUID `bc50d971-d4c9-42c4-82cb-343fb7f37896`, as an early TA |
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

The hashes below are of the final configuration: both OP-TEE builds set `CFG_REE_FS_TA=n` and
`CFG_SECSTOR_TA_MGMT_PTA=n`. The second flag is needed because `core/pta/secstor_ta_mgmt.c` (`install_ta`) references
`ree_fs_check_update_ta_version`, which `CFG_REE_FS_TA=n` leaves out, so the image did not link without it. The secure
storage TA management PTA installs TAs into REE FS storage, which this build does not load from.

`make secure-world` checks this itself (#166). It runs the build twice, each in its own clean directory
(`work/build-1`, `work/build-2`; the work directory is recreated on each run, the pinned source and toolchain cache is
shared and hash-checked), and compares `bl31.bin` and `tee.bin` by SHA-256. Only when both are byte-identical does it
publish them, with `SHA256SUMS` (the agreed hashes) and `build-info.txt` (which ends with the `reproducible: yes` line
and both hashes). On a difference it publishes nothing and fails naming the artefact and both hashes:

```text
secure-world-build: tee.bin build 1 <sha256-of-build-1>, build 2 <sha256-of-build-2>
secure-world-build: tee.bin differs: build 1 <sha256-of-build-1>, build 2 <sha256-of-build-2>
secure-world-build: not reproducible: the two clean builds differ; nothing published
```

On a match the end of the output is:

```text
secure-world-build: bl31.bin build 1 <sha256>, build 2 <sha256>
secure-world-build: tee.bin build 1 <sha256>, build 2 <sha256>
secure-world-build: reproducible, two clean builds identical, <out>:
<sha256>  bl31.bin
<sha256>  tee.bin
```

`test/secure_world_build_test.sh` covers a match and a difference with stubbed builds (no network). The hashes below
were first matched by hand on 2026-11-21, at the upstream TF-A v2.15.0 pin (`da738d5e`; the earlier hashes were of the
imx-atf pin and are superseded), on a Debian 13 (trixie) x86_64 host with the pinned toolchain, each build with an
empty work, output and cache directory and the default `SOURCE_DATE_EPOCH`; the scripted check has not yet been run
against the real sources and toolchain (provisional until a host with network access runs it). The BSP stays
provisional exactly as `bsp.lock` says (release `lf-6.18.37-2.1.0`, #14 Q2).

| Build | `bl31.bin` SHA-256 | `tee.bin` SHA-256 |
|---|---|---|
| 1 | `5a81a6f5d98f21724c578a9034f4dba29a14cf3aaccd63f12d493eb3e88be6d8` | `224b0a6a71532fe63429ab3e6430bca85d3b39a4fa3981fd2796f0c7f1535fb0` |
| 2 | `5a81a6f5d98f21724c578a9034f4dba29a14cf3aaccd63f12d493eb3e88be6d8` | `224b0a6a71532fe63429ab3e6430bca85d3b39a4fa3981fd2796f0c7f1535fb0` |

The hashes belong to one build configuration, pinned by a digest that `test/secure_world_build_test.sh` recomputes:
every non-comment, non-blank line of `secure-world/bsp.lock`, the script's two UUID assignments, its `optee_flags`
array and every `make` build step (`bl31`, `optee-devkit`, `ftpm` with its flags, and `optee`), whitespace squeezed.
The test fails when any pin, toolchain or wheel line of the lock, or any build argument or flag, differs from the
configuration recorded here, so hashes cannot outlive a pin or flag change. Record the new digest together with new
hashes.

Build configuration digest: `8838ce34f6dffb1f1b315feca398963c111f5ab898117f3fb66376f3761a23d3`

Not tested: a second host, another `uv` or Python patch release, and a different `SOURCE_DATE_EPOCH`.

**In CI as its own job, not in `make test`.** The build fetches about 150 MB, runs twice (about two minutes
each) and needs the network, so the `secure-world-build` job in `ci.yml` runs it in the project's devcontainer
Dockerfile, its `secure-world` stage (docs/SPEC.md: CI runs in the project's devcontainer image). The stage is on
`python:3.13-slim-bookworm` pinned by digest (glibc 2.36, CPython 3.13), takes its Debian packages from a dated
snapshot.debian.org archive, and installs `uv` from a hash-pinned wheel; every pin is in `scripts/tool-pins.sh` (`SW_*`),
and `make build` checks the Dockerfile matches. No setup step runs on the runner: the job builds the image
(`make docker-build-sw`) and runs `make secure-world` in it through `scripts/in-toolchain-image.sh`, with sources, build
trees and output under the container's `$TMPDIR`.

*Scope.* `preflight` selects the inputs: its `secure_world` output is `false` only on a pull request whose changed files
all miss `SECURE_WORLD_PATTERN` (`secure-world/`, the script, the pin file, the Dockerfile, `in-toolchain-image.sh`,
`image-tag.sh`, the unit test, the `Makefile`, `ci.yml`). The job's own `if:` ends in
`needs.preflight.outputs.secure_world != 'false'`, so a README-only PR skips the whole job (image build, setup and
build) and the CI Gate counts it passed (mode `sw`). A push, schedule, manual run or the full tier always builds.
`make test` runs only the offline lock check and the script's unit tests.

*Wheel platform tags.* The lock's wheels (identified by SHA-256 on PyPI) are `cryptography-50.0.2-cp311-abi3-
manylinux_2_28_x86_64`, `cffi-2.1.1-cp313-cp313-manylinux2014_x86_64`, and `pycparser` and `pyelftools` as `py3-none-any`.
Offline check on a CPython 3.13.5, x86_64, glibc 2.41 host, run as `python3 -I -m pip debug --verbose` and looking up
each tag in the compatible-tags list: all three tags are accepted. The image's glibc 2.36 is above the 2.28 floor, but
that host is not the image. The authoritative check is in the `secure-world` stage: a `RUN` runs the same
`pip debug --verbose` in the image and fails the image build if any of the three tags is missing. That `RUN` has not
run yet (no Docker where this was written).

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

The `secure-world` (a) and (b) and `ftpm` (a) states below belong in [ROADMAP.md](../../ROADMAP.md). This survey could
not write that file: the survey's write guard protects it.

- `secure-world` (a): pinned in `secure-world/bsp.lock`, release `lf-6.18.37-2.1.0` provisional (#14 Q2).
- `secure-world` (b): `make secure-world` builds both artefacts with a SHA-256 manifest; builds twice in clean directories and fails unless both
  artefacts are byte-identical ([Reproducibility](#reproducibility)). The `secure-world-build` CI job runs `make secure-world` in the devcontainer Dockerfile's digest-pinned glibc `secure-world` stage, when secure-world inputs change, and is in the CI Gate. Nothing has run on the board.
- `ftpm` (a): OP-TEE side built: `optee_ftpm` 4.10.0 on the pinned `ms-tpm-20-ref`, an early TA, NV in REE FS. The
  kernel's `CONFIG_TCG_FTPM_TEE` remains, with the image build.
