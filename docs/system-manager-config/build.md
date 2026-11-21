# System Manager build: pins, command and reproducibility

Row: `system-manager-config` ([SPEC.md](../SPEC.md)). Issues #133, #13. Builds on
[sm-build-survey.md](sm-build-survey.md) and [m7-resource-map-survey.md](m7-resource-map-survey.md).

NXP's System Manager (SM), the Cortex-M33 firmware, stays NXP's code. This repository pins it, builds it, and will
own its board configuration. Nothing here is flashed or signed: the image is a build output only.

## 1. The command and the pins

```sh
make system-manager                          # = scripts/sm-build.sh system-manager/sm.lock
make docker-run CMD='make system-manager'    # the same, in the devcontainer image (see section 7)
```

The pins are in [`system-manager/sm.lock`](../../system-manager/sm.lock). They are **provisional**: they follow
NXP's BSP release `imx-6.18.37-2.1.0`, the baseline `docs/platform-image/build-system-options.md`
recommends (on #137, not yet on this branch), which the owner has not chosen yet (#14 Q2).

| Pin | Value | Where it was read |
|---|---|---|
| Repository | `https://github.com/nxp-imx/imx-sm` | public |
| Tag | `lf-6.18.37-2.1.0` (annotated; `rel_imx_sm_2026q3` names the same commit) | `git ls-remote` |
| Commit | `eec232878ab7dd460f5a8f3767d39dc7e9412efa` | the tag, peeled |
| Board configuration | `mx95frdm-pro`, file `configs/other/mx95frdm-pro.cfg` | meta-imx machine `imx95-19x19-lpddr5-frdm-pro` ([sm-build-survey.md](sm-build-survey.md) §5) |
| Configuration SHA-256 | `37d8f4c2b324cdc8dafb1de3f3f741850c86ca2e842880b9fdbdc16db72c1d63` | the file at the commit |
| Monitor mode | `M=2`, as meta-imx's recipe passes it; production's choice is open ([sm-build-survey.md](sm-build-survey.md) §10 Q4) | |
| Toolchain | Arm GNU Toolchain `15.2.rel1`, x86_64 host, `arm-none-eabi` | imx-sm's `TC_VERSION` default |
| Toolchain SHA-256 | `597893282ac8c6ab1a4073977f2362990184599643b4c5ee34870a8215783a16` | Arm's published `.sha256asc`, and the download |

What the script does, in order:

1. Parses the lock (never sources it): only the known keys, each once, each in its expected form (`--check` stops
   here, offline).
2. Downloads the toolchain tarball once into `out/system-manager/cache/`, checks its SHA-256 on every run and
   extracts it fresh.
3. Fetches the tag once into a bare cache and fails unless it names the pinned commit.
4. Builds twice, each in its own fresh clone (`tree-1/`, `tree-2/`): checks the `.cfg` against its SHA-256, then
   runs `make config=mx95frdm-pro cfg` and `make config=mx95frdm-pro M=2 all`, as meta-imx's recipe does, with
   `SM_CROSS_COMPILE` set to the pinned toolchain and `SOURCE_DATE_EPOCH` set to the commit's time.
5. Writes `m33_image.bin`, `SHA256SUMS` and `sm-manifest.txt` (every pin, both builds' digests, the verdict) to
   `out/system-manager/` (gitignored), and fails unless the two images are byte-identical.

[`test/sm_build_test.sh`](../../test/sm_build_test.sh) runs the script offline against a fake repository and
toolchain: the good path, the cache, a non-reproducible build, a failing build, every pin mismatch and every
malformed lock.

## 2. The reproducibility result

**Reproducible.** `make system-manager` was run twice on 2026-11-20 in the lane's Linux x86_64 container, each run
building twice in clean trees. All four images are byte-identical, and the two runs wrote identical manifests:

| | SHA-256 of `m33_image.bin` (188036 bytes) |
|---|---|
| Run 1, build 1 and build 2 | `10ec33fe9ff80cbbda962cb08c524dd58f1e2b67f29d0b55671e49fda723af96` |
| Run 2, build 1 and build 2 | `10ec33fe9ff80cbbda962cb08c524dd58f1e2b67f29d0b55671e49fda723af96` |

Build time: about 80 s a run (two builds) with the downloads cached; a first run also downloads the 155 MB
toolchain and the tag, which took about 2 minutes on the lane's link.

The first two clean builds differed in four bytes: the build date and time. imx-sm's `sm/makefiles/build_info.mak`
writes them into the generated `build_info.h` with `date +FORMAT`, which ignores `SOURCE_DATE_EPOCH`. Rather than
patch NXP's makefile, the script puts a small `date` first on the build's PATH that answers `date +FORMAT` with
the commit's time in UTC (`1788454215`, 2026-09-03) and passes any other call to the real `date`. The second tree
lives at another path, so the image does not depend on the build directory either.

The same header also carries `SM_BRANCH`, `SM_BUILD` and `SM_COMMIT` from git. With the script's one-commit fetch
of the tag they are `HEAD`, `1` and `0xeec23287`; `SM_BUILD` is the first-parent commit count, so a full
clone gives another value. An image NXP's BSP build makes from the same commit may differ in it; that was not
checked.

## 3. Where the configuration lives

- The source of truth is NXP's `configs/other/mx95frdm-pro.cfg` at the pinned commit, the base: the
  lock pins its SHA-256 and the build fails if it differs. This repository holds no copy; its delta is the patch
  of section 6 (proposed, pending the owner, #13).
- `make cfg` turns it into the C headers in `configs/mx95frdm-pro/` of the build tree; they are build output,
  regenerated on every build, never carried.
- The file names the 19x19 EVK board port (`board=mcimx95evk`); its header comment still says "MX95 EVK".

## 4. How this repository will carry its own changes

No change is made yet. When one is needed:

1. Add `system-manager/mx95frdm-pro.cfg.patch`, a unified diff against the pinned upstream file, reviewed as a
   diff in the pull request that adds it. The upstream file stays the base, so the reviewed change is the whole
   change, and a new NXP release is a rebase of the patch.
2. The lock gains the patch's SHA-256; the script applies it after the upstream SHA-256 check, before `make cfg`,
   and writes both digests to the manifest.
3. If the change grows past a patch, the alternative of [sm-build-survey.md](sm-build-survey.md) §8 item 2 applies:
   a new `.cfg` under a new name in `configs/`, beside NXP's unmodified file. Either way imx-sm itself is not
   forked.
4. Every change rebuilds the image, and with it the boot container, which must be re-signed with the OEM key
   ([sm-build-survey.md](sm-build-survey.md) §7). No key is used here.

## 5. The Cortex-M7 resources against the configuration's sections

The pinned `mx95frdm-pro.cfg` was read for the resources [m7-resource-map-survey.md](m7-resource-map-survey.md)
names. This settles most of that survey's §8 item 1 for this device. The M7 is LM1 (`name="M7"`, SCMI agent 0);
"the M7's section" below is that LM's block. A **finding** is a change this repository would need; none is made.

| Resource (survey §6) | Section of the `.cfg` | State at the pinned commit |
|---|---|---|
| M7 CPU `CPU_M7P`, power `PD_M7` | M7 LM, start/stop lines for `msel` 0, 1, 2 | Granted: the SM powers `PD_M7` and starts the CPU at LM start; `PD_M7` is also an M7 `test` resource |
| `M7P` (brings `PERF_M7`, `CLK_M7SYSTICK`) | M7 LM, Resources | Granted: the M7 owns `M7P` |
| `CLK_M7`, `CLK_BUSM7`, `CLK_ENET` | SM LM (LM0), API, the group changed through the Performance protocol | SM-held; the M7 reaches `CLK_M7` only through `PERF_M7` |
| `PERF_M7` explicit API line | M7 LM, API | **Not present.** Whether `M7P` ownership alone allows `PERFORMANCE_LEVEL_SET` (PRIV) is #107's; a `PERF_M7` line may be needed |
| M7 console `LPUART7`; `LPUART3` | M7 LM, Resources | Granted: `LPUART7` owned; `LPUART3` owned as a `test` resource |
| Pins `GPIO_IO36`, `GPIO_IO37` (also `GPIO_IO14`, `GPIO_IO15`) | M7 LM, Pins | Granted, all four. What they are wired to on the PRO is unconfirmed |
| M7 timers, CAN, watchdog, mailboxes (`LPIT1`, `LPTMR1/2`, `LPTPM1`, `CAN_FD1`, `WDOG5`, `MU5_A`, `MU7_B`, `MU8_B`, `IRQSTEER_M7`, `TSTMR2`) | M7 LM, Resources | Granted |
| EdgeLock mailbox `MU_ELE5` | M7 LM, Resources | Granted |
| Memory: M7MIX TCMs, DDR `0x80000000`..`0x89FFFFFF` executable | M7 LM, Memory | Granted |
| SCMI channel: MU 9 (test MU 8), three CRC32-checked SMT channels | M7 LM, RPC Interface | Present |
| A55 LM control `LMM_2` | M7 LM, API | Granted, all rights |
| System power `SYS` | M7 LM, API | Granted, all rights (survey §9 Q4: "keep") |
| Fault reactions: M7 lock-up, M7 reset, `WDOG5`, `SW1` | M7 LM, Faults | Present, each `lm_reset`; `SW0` to the FuSa reaction. **Finding:** fail-open for the tamper responder; needs `sys_reset` or `sys_shutdown` ([fault-recovery-survey.md](fault-recovery-survey.md) §10 Q1) |
| `PD_NETC`, `NETC*`, `NETC_EMDIO0`, `BLK_CTRL_NETCMIX`, `PIN_ENET1_*`/`PIN_ENET2_*` | A55 non-secure agent (`AP-NS`), Resources and Pins | Owned by `AP-NS`, not the M7. **Finding:** only if the owner picks survey §9 Q1 (b) or Q2 (c); option (a), `LMM_SHUTDOWN` of LM2, needs no change |
| Reset domains, `PD_WAKEUP` | none for the M7 | Not granted; whether the M7 needs them is still unconfirmed (survey §8 items 4, 5) |

Two further points the file shows: LM1 carries `skip=1` (as LM2 does), whose effect on when the SM boots the M7 is
not documented in the sources read; and the SM's own debug UART is `LPUART2` (instance 2), owned by LM0.

So the M7 firmware of trusted-firmware's `imx95` row can run on the pinned configuration as it stands, and the
tamper response by `LMM_SHUTDOWN` or `SYSTEM_POWER_STATE_SET` is granted. The changes the findings point to are
the M7 fault reactions and, depending on #107, a `PERF_M7` grant.

## 6. This repository's delta: the M7 fault reactions fail closed

**Proposed, pending owner approval (#13).** The choice between `sys_reset` and `sys_shutdown` is the owner's. The
fault-recovery survey recommends `sys_reset` ([fault-recovery-survey.md](fault-recovery-survey.md) §10 Q1, option (c),
or (d) `sys_shutdown` if a restart loop is a concern), so the patch takes `sys_reset`. **Nothing was flashed, signed
or run on a board.**

The delta is [`system-manager/patches/0001-m7-faults-fail-closed.patch`](../../system-manager/patches/0001-m7-faults-fail-closed.patch),
a unified diff against `configs/other/mx95frdm-pro.cfg` at the pinned commit. It changes four lines of the M7 LM
(LM1) Faults block, and nothing else; `FAULT_SW0` (the FuSa reaction) and every other line are unchanged.

| Line (upstream) | Before | After |
|---|---|---|
| 433 `FAULT_M7_LOCKUP` | `lm_reset` | `sys_reset` |
| 434 `FAULT_M7_RESET` | `lm_reset` | `sys_reset` |
| 436 `FAULT_SW1` | `lm_reset` | `sys_reset` |
| 437 `FAULT_WDOG5` | `lm_reset` | `sys_reset` |

Why: the M7 runs the trusted firmware and the tamper response. `lm_reset` restarts the M7 alone and leaves the A55
running unsupervised, which is fail-open. `sys_reset` restarts the A55 with the M7. The survey section it rests on
is [fault-recovery-survey.md](fault-recovery-survey.md) §9 (the M7 faults bullet) and §10 Q1. A restart loop on a
persistent fault is the cost; `sys_shutdown` would avoid it and keep the board off until power is cycled.

Mechanism: [`sm.lock`](../../system-manager/sm.lock) gains `sm_patch_sha256` (the patches concatenated in name order)
and `sm_patched_config_sha256` (the file after they apply). `scripts/sm-build.sh` checks the patches' digest before
downloading anything, then in each build checks the upstream file's SHA-256, applies each patch in order with
`git apply`, checks the patched file's SHA-256, and builds. Either digest differing stops the build.
`test/sm_build_test.sh` covers both checks offline, and checks that the committed patch changes only those four
fault lines, each from `lm_reset` to `sys_reset` or `sys_shutdown`. Section 4's plan is thus followed, with the patch
under `system-manager/patches/`. Any change rebuilds the image and the boot container, which must be re-signed.

`make system-manager` with the patch ran on 2026-11-21 in the lane's container: both builds are byte-identical,
`m33_image.bin` SHA-256 `3ef1c54c829a8bd775dfc3d4f263eb06d8a61e565a3f4f74025d51d9a82f6e85`. The image is a build
output only.

## 7. Not confirmed

- The run recorded in section 2 was in the lane's Linux x86_64 container, not the devcontainer image. The
  devcontainer image is Alpine (musl) and Arm's toolchain is glibc-hosted, so the image's toolchain stage now
  installs `gcompat` (Alpine's glibc loader and shims), and `test/sm_build_test.sh` checks that. **The real
  compiler has not yet built the System Manager in the image on the lane's node** (no Docker there). The CI job
  `system-manager-build` runs `make sm-toolchain-check` (`scripts/sm-toolchain-check.sh` in the image): it runs
  `make system-manager` with the real pinned toolchain, then checks the compiler starts, `m33_image.bin` and the
  manifest exist and the linked `.elf` is an ARM ELF. The result of its first run is not recorded here yet. If
  `gcompat` is not enough to start the compiler, the base image would have to change, which is the owner's choice (#14).
- Host tools the script needs: git, curl, tar, xz, make, perl and coreutils. imx-sm's README also names `gcc`,
  `g++-multilib` and `srecord`; the lane's container had `gcc`, and whether the build uses any of the three was not
  checked.
- The monitor mode for production images (`M=2` here), the BSP release (#14 Q2) and the boot container target
  stay open.
