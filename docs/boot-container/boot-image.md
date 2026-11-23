# Boot image on the test PKI (provisional)

Status: **PROVISIONAL**, the assembly slice of issue #161 in the `boot-container` row of
[docs/SPEC.md](../SPEC.md). Every value marked *default* below is a lane's choice, not the owner's,
and is open to change. Signing tool: SPSDK 3.13.0, the owner's decision in
[signing-tool-options.md](signing-tool-options.md); chip: i.MX 95 B0 (SPSDK family `mimx9596`,
revision `b0`).

`make boot-image-test` assembles the full boot image from its inputs, signs it with a throwaway
test PKI, verifies it and tamper-tests it. It never touches a board, a real block device, a fuse, the
life cycle or RPMB, and it writes no key: the four ECDSA P-384 test SRKs are generated in a `mktemp -d`
directory outside the clone and deleted on exit, and the `.bcf` fuse script `nxpimage ahab export`
writes is deleted unread. The SRK table hash it prints belongs to the test PKI only.

```sh
make boot-image-test                  # inputs, image, verify, tamper; out/boot-image/
make m7-image                         # build the Cortex-M7 idle image; boot-image-test then takes it
make boot-image-test BI_M7=<file>     # another Cortex-M7 image for that entry (also BI_UBOOT, BI_ELE)
make boot-image-inputs                # only collect the inputs (pins checked first)
```

The image, `inputs.txt` and a `SHA256SUMS` over both go to `out/boot-image/` (`BI_OUT`), which is
git-ignored. The pinned SPSDK venv is the one of [signing-pipeline.md](signing-pipeline.md).

## Containers and order (default)

`scripts/ahab/boot-image.yaml` writes three OEM containers, in this order, each signed with test SRK 0 of
a four-key table:

| # | Container | Image entries (SPSDK name, core) | Input |
|---|---|---|---|
| 1 | ELE | `ele`, core `ele` | `ele.bin` |
| 2 | System Manager and M7 | `system_manager`, `cortex-m33`; `executable`, `cortex-m7-1`, load `0x00000000`, entry `0x303C0000` | `m33_image.bin`, `m7_image.bin` |
| 3 | Cortex-A55 | `atf`, `uboot`, `tee`, all `cortex-a55` at SPSDK's default addresses | `bl31.bin`, `u-boot.bin`, `tee.bin` |

The M7 entry is laid out as `scripts/ahab/m7-container.yaml` lays it out
([m7-load-path-survey.md](m7-load-path-survey.md) §3, §5). The order and the grouping into containers
are a default: the boot ROM's order of copy, authenticate and start is **missing** (IMX95RM, see
[architecture.md](architecture.md) "Missing"). `scripts/ahab/container-manifest.yaml` (the policy
checker's manifest, #12) describes a different split (an NXP container, then an M7-only OEM container,
then a data-only A55 container); this image does not satisfy it and is not checked against it.

## Inputs and their pins

`scripts/boot-image-inputs.sh --collect` copies the six inputs and writes `inputs.txt`
(`name`, `real` or `STAND-IN`, SHA-256). `--check` validates the pins offline (it is in `make test`);
`--fetch DIR` downloads the two pinned sources and fails closed on a SHA-256 mismatch.
[`boot-container/inputs.lock`](../../boot-container/inputs.lock) holds the pins, for the BSP release
`lf-6.18.37-2.1.0` that `system-manager/sm.lock` and `secure-world/bsp.lock` pin (provisional until
#14 Q2).

| Input | Source | Pin |
|---|---|---|
| System Manager `m33_image.bin` | `make system-manager`, `out/system-manager/` | `system-manager/sm.lock` |
| Cortex-M7 image `m7_image.bin` | `make m7-image` (idle image, see below), `out/m7-image/`; or `BI_M7=<file>` | [`boot-container/m7-idle.lock`](../../boot-container/m7-idle.lock) (source digest) and the Arm toolchain pin of `system-manager/sm.lock` |
| BL31 `bl31.bin`, `tee.bin` | `make secure-world`, `.secure-world/out/` | `secure-world/bsp.lock` |
| U-Boot `u-boot.bin` | a build of NXP's `uboot-imx`, branch `lf_v2026.04` | commit `bb41975a…` and the SHA-256 of its source archive, in `inputs.lock` |
| ELE firmware `ele.bin` | NXP's `firmware-ele-imx` 2.0.7 installer | the installer's SHA-256 in `inputs.lock` |

`inputs.lock` also records that `meta_imx_commit` equals `META_IMX_COMMIT` of `secure-world/bsp.lock`;
`--check` fails if the two differ. The U-Boot and ELE values were read from the meta-imx recipes at
that commit (`u-boot-imx-common_2026.04.inc`, `firmware-ele-imx_2.0.7.bb`) and each digest was also
computed from the downloaded file. A U-Boot or ELE binary you pass in is **not** checked against a pin:
the pins cover the sources, and nothing here ties a built binary to its source.

## Stand-ins

An input with no file becomes a **STAND-IN** payload: a 4 KiB random blob whose first line says
`STAND-IN <name>: not a real image`. It is signed like a real payload, so the container, signature and
hash checks are real for it, but the image is not bootable. `inputs.txt` and the run's last lines say
how many entries are stand-ins. The target uses `make system-manager` and `make secure-world` output
when it is there, and `make m7-image` output likewise. The run recorded here (2026-11-23, lane #161) had four real inputs and two stand-ins:

| Input | State | SHA-256 |
|---|---|---|
| `m33_image.bin` (System Manager) | **real**, `make system-manager`, reproducible over two builds | `83d1e019f10f5b285080e83207de1450a3e381346ff6d7c7c280a1c64c878d9b` |
| `bl31.bin` (TF-A) | **real**, `make secure-world` | `5a81a6f5d98f21724c578a9034f4dba29a14cf3aaccd63f12d493eb3e88be6d8` |
| `tee.bin` (OP-TEE, fTPM and PKCS#11 early TAs) | **real**, `make secure-world` | `224b0a6a71532fe63429ab3e6430bca85d3b39a4fa3981fd2796f0c7f1535fb0` |
| `m7_image.bin` (M7 idle image) | **real**, `make m7-image`, reproducible over two builds | `ab43a5326db854314a98d1efbd72b448e2a5afcbe579fc8f7da9c864b0dc6e60` |
| `u-boot.bin` | STAND-IN | random per run |
| `ele.bin` | STAND-IN | random per run |

All six entries, real and stand-in, were signed, verified (3 of 3 containers) and tamper-rejected. The
blockers of the two stand-ins:

- **U-Boot**: the pinned source archive downloads and matches its SHA-256 (checked in the lane), and the
  pinned Arm aarch64 toolchain of `secure-world/bsp.lock` is there, but `make imx95_19x19_frdm_pro_defconfig`
  stopped at `bison: not found`. The lane host has no bison, flex, bc, swig, setuptools or gnutls
  headers, no Docker, and an empty apt index; installing host packages was out of scope. The platform
  image's Yocto build (#14) is the intended builder. Until then pass `BI_UBOOT=<file>` (not tied to its
  source, see above).
- **ELE firmware**: the installer's SHA-256 matched when downloaded in the lane, but unpacking it needs a
  person to accept NXP's licence agreement, so the script never unpacks it. Pass `BI_ELE=<file>`. On a
  device this position is NXP's own container; here it is an OEM-signed `ele` entry (see "Containers").

## The Cortex-M7 idle image

`make m7-image` (`scripts/m7-image-build.sh`) builds [`boot-container/m7-idle/`](../../boot-container/m7-idle/):
a vector table, a reset handler that sets the stack pointer and clears `.bss`, a default handler that sleeps
in `WFI` for every other exception, and a `main` that sleeps in `WFI`. It is **not** the production M7
firmware; that is the owner's choice. It exists so the M7 entry of the image holds a real ARMv7E-M program
that the host checks can parse, sign and tamper-test. It does nothing on a board; whether it starts there is
unconfirmed (step (c) below).

- **Source**: written in this repository, no vendor code. The one public M7 demo found,
  NXP's MCUXpresso SDK `hello_world`, needs the `mcux-component` repository, whose licence is an NXP
  click-through: downloading it counts as acceptance. The lane fetched `mcux-component` once while exploring,
  before reading that licence, built nothing from it and deleted it. Nothing from it, from `mcuxsdk-examples`
  or from any other NXP-licensed repository is in this repository.
- **Compiler**: the Arm GNU toolchain 15.2.rel1 that `system-manager/sm.lock` pins, by the same URL and
  SHA-256 (read from that file, so the two cannot drift). The tarball is cached in `out/m7-image/cache`
  (copied from `out/system-manager/cache` when `make system-manager` has downloaded it), checked on every
  run, and a mismatch fails closed.
- **Pin**: `boot-container/m7-idle.lock` holds the SHA-256 of `startup.c`, `main.c` and `m7-idle.ld`; the
  build and `--check` refuse sources that differ.
- **Reproducible**: the script builds twice, in two directories, with `-g0` and `--build-id=none`, and fails
  unless both SHA-256 are equal (`ab43a532…c6e60` in the run above, 116 bytes).
- **Addresses**: the link origin `0x00000000` is the M7's own view of its TCM, the load address in
  [m7-load-path-survey.md](m7-load-path-survey.md) §3 and §5 and in `scripts/ahab/m7-container.yaml`; the
  AHAB entry point `0x303C0000` is unchanged. The window is **64 KiB** at that origin, this image's own
  budget; the real ITCM and DTCM sizes and split are **unconfirmed** (survey U2, IMX95RM not read). The stack
  top is the end of that window, in the same flat binary. Whether the TCM needs ECC initialisation before
  it is written is **unconfirmed** too (survey, "Left open").
- **Test**: `test/m7_image_test.sh` checks the pins, refuses a toolchain of another SHA-256, and (when the
  tarball is cached; it never downloads) checks that the ELF is ARMv7E-M Thumb-2, that vector word 0 is a
  stack pointer inside the linker's window, that the reset vector is odd and inside the image, and that two
  builds agree.

## What the test checks

1. `nxpimage ahab verify` accepts the whole image, and its log shows three containers authenticating
   against the OEM test SRK with one signature each.
2. `nxpimage ahab parse` writes six payloads, and each input is the prefix of its parsed payload (SPSDK pads
   the System Manager, BL31, U-Boot and tee entries to 1 KiB; the U-Boot padding is not all zero bytes).
3. For each of the six signed payloads, one byte in the middle of the payload is flipped in a copy of the
   image and `nxpimage ahab verify` must fail. The run stops on the first accepted tamper.

`test/boot_image_test.sh` (in `make test`) runs these on stand-in inputs, with the pin checks, the
stand-in labelling, the fail-closed fetch and an independent byte flip through `boot-image.sh verify`.

## What step (c) on the board would check

The brief's "step (c)" is read here as the on-board run of
[dev-boot-workflow-survey.md](dev-boot-workflow-survey.md) §8 step 3: the accepted image loaded in the
OEM open life cycle, and the enclave's events and info read back afterwards. It would show only that this
image starts on this board at its silicon revision; it says nothing about the signing root, because an
OEM-open device holds no SRK hash (§7 there). Nothing in this repository does it, and the test PKI image
cannot pass a closed device, whose fuses hold another SRK hash. What it would add to the host checks:
whether the enclave accepts the container order and entry layout chosen above, whether each core starts
at the stated address, and what the event log says. Each of those is unconfirmed until IMX95RM and the
Security Reference Manual are read.

## Left open

- Whether the container order, the grouping and the M7 addresses above are what the ROM expects.
- The production Cortex-M7 firmware (owner's choice) in place of the idle image, and the TCM size and ECC.
- Real inputs for the two stand-ins (U-Boot, ELE), and a pin that ties a built U-Boot to its source.
- `container_version` is SPSDK's default; `fuse_version` and `sw_version` are 0 for this test image only.
- The relation to `scripts/ahab/container-manifest.yaml` (a different split) is for #12 to settle.
