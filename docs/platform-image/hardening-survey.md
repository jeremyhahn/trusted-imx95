# Platform image: kernel and userspace hardening survey

Status: survey for the owner's decision (issue #74). Documentation only; nothing
here is built, run or scripted.

## 1. Scope and versions surveyed

The board holds signing keys (see [SPEC.md](../SPEC.md), row platform-image), so
the Linux image must make it hard for root, or a compromised service, to read
kernel memory, load unsigned code into the kernel, or replace the running kernel.
This survey asks which kernel and userspace settings get us there, which of them
NXP's BSP already sets, and how xkmsd (go-xkms's daemon) should be confined.

Versions surveyed (all public, read on 2026-11-12):

| Item | Version or tag | Where |
| --- | --- | --- |
| NXP kernel | `lf-6.18.37-2.1.0` (Makefile: 6.18.37), the newest `lf-6.18` tag; branch `lf-6.18.y` points at the same commit | [S1] |
| NXP defconfig | `arch/arm64/configs/imx_v8_defconfig` at that tag | [S1] |
| Upstream hardening fragments | `kernel/configs/hardening.config`, `arch/arm64/configs/hardening.config` at that tag | [S1] |
| KSPP recommended settings | site repository commit `04b2a2c` (2026-05-14) | [S2] |
| meta-imx | branch `wrynose-6.18.37-2.1.0`, head `2eb758f` (2026-11-10), Yocto codename `wrynose` | [S3] |
| meta-freescale | branch `wrynose`, head `2d08c05` (2026-11-05) | [S5] |

Method: the defconfig is a minimal file; options it does not name take their
Kconfig defaults. To compare it with KSPP I resolved the full configuration
from the tag's Kconfig tree with Kconfiglib [S4], with no fragments added. I did
not build the kernel. Two caveats follow from that:

- Kconfiglib does not know two keywords that 6.18's Kconfig uses
  (`transitional`, a bare `modules`); I rewrote them in a scratch copy into forms it
  accepts. Neither changes a security option.
- The `cc-option` and `as-instr` probes ran against the host's x86 gcc, not an
  aarch64 toolchain. Options that depend on such probes (Shadow Call Stack,
  BTI, MTE, kCFI) show as absent here and are marked *toolchain-dependent* below.
  A real `make imx_v8_defconfig` with the Yocto cross toolchain is needed to
  confirm them (Q1).

## 2. Sources

Every claim below names one of these. Text is summarised, never copied.

- [S1] NXP, *linux-imx* kernel source, tag `lf-6.18.37-2.1.0`,
  https://github.com/nxp-imx/linux-imx/tree/lf-6.18.37-2.1.0 — files cited by path.
- [S2] Kernel Self Protection Project, *Recommended Settings*, site commit `04b2a2c`
  (2026-05-14), https://kspp.github.io/Recommended_Settings
  (source: https://github.com/KSPP/kspp.github.io/blob/master/Recommended_Settings.md).
- [S3] NXP, *meta-imx* Yocto layer, https://github.com/nxp-imx/meta-imx (§5 gives the branch).
- [S5] Freescale community, *meta-freescale* Yocto layer, branch `wrynose`
  (head `2d08c05`, 2026-11-05), https://github.com/Freescale/meta-freescale.
- [S6] Linux man-pages project, *kernel_lockdown(7)*, `master` as of 2026-11-12,
  https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man7/kernel_lockdown.7.
- [S7] OpenEmbedded, *openembedded-core*, branch `wrynose` (head `2285da0`,
  2026-11-06), https://git.openembedded.org/openembedded-core
  (`meta/recipes-core/systemd/`, systemd 259.5).
- [S8] Yocto Project, *Releases* wiki page, read 2026-11-12,
  https://wiki.yoctoproject.org/wiki/Releases.
- [S9] systemd, *systemd.exec(5)* and *systemd.resource-control(5)*, tag `v259.5`,
  https://github.com/systemd/systemd/tree/v259.5/man.
- [S10] Yocto Project, *meta-selinux*, branch `wrynose` (head `18ee2df`),
  https://git.yoctoproject.org/meta-selinux — branch seen; recipes not read.
- [S11] Yocto Project, *meta-security*, branch `wrynose` (head `2703974`),
  https://git.yoctoproject.org/meta-security — branch seen; recipes not read.
- [S4] Ulf Magnusson, *Kconfiglib*, `master`, https://github.com/ulfalizer/Kconfiglib
  (the tool used to resolve the configuration; not a security source).

## 3. Kernel hardening baseline (KSPP)

KSPP [S2] publishes one list of options for all architectures plus a short
arm64 list. Against the resolved `imx_v8_defconfig` [S1], 47 of the 124 generic
and arm64 entries already match and 77 do not. Several of the 77 are symbols
that no longer exist in 6.18 (`DEBUG_RODATA`, `DEBUG_CREDENTIALS`,
`REFCOUNT_FULL`, `RANDOM_TRUST_CPU`, `RANDOM_TRUST_BOOTLOADER`,
`DEBUG_SET_MODULE_RONX`, `PAGE_POISONING_ZERO`); KSPP keeps them for older
kernels, and they can be ignored.

Already set by NXP (resolved values) [S1]: `STRICT_KERNEL_RWX`,
`STRICT_MODULE_RWX`, `STACKPROTECTOR_STRONG`, `INIT_STACK_ALL_ZERO`,
`VMAP_STACK`, `RANDOMIZE_BASE`, `UNMAP_KERNEL_AT_EL0`, `ARM64_PAN`, `ARM64_E0PD`,
`ARM64_EPAN`, `SECCOMP_FILTER`, `STRICT_DEVMEM`, `IOMMU_DEFAULT_DMA_STRICT`,
`BPF_JIT_ALWAYS_ON`, `BPF_UNPRIV_DEFAULT_OFF`; and off: `PROC_KCORE`,
`HIBERNATION`, `BINFMT_MISC`, `KPROBES`, `FTRACE`, `USERFAULTFD`, `COMPAT_BRK`.
`ARM64_PTR_AUTH_KERNEL` resolves to y, but pointer authentication is an
Armv8.3 feature; whether the i.MX95's Cortex-A55 cores implement it is not
confirmed here (Q1), and without it the option is inert.

Not set by NXP, grouped by what they cost (my grouping, KSPP's options) [S2]:

- **Cheap, no expected driver impact:** `HARDENED_USERCOPY`,
  `SLAB_FREELIST_RANDOM`, `SLAB_FREELIST_HARDENED`, `SLAB_BUCKETS`,
  `RANDOM_KMALLOC_CACHES`, `SLAB_MERGE_DEFAULT=n`, `SHUFFLE_PAGE_ALLOCATOR`,
  `LIST_HARDENED`, `BUG_ON_DATA_CORRUPTION`, `SCHED_STACK_END_CHECK`,
  `FORTIFY_SOURCE`, `SECURITY_DMESG_RESTRICT`, `RANDOMIZE_KSTACK_OFFSET_DEFAULT`,
  `INIT_ON_ALLOC_DEFAULT_ON`, `SYN_COOKIES`, `LDISC_AUTOLOAD=n`,
  `LEGACY_PTYS=n`, `LEGACY_TIOCSTI=n`, `PROC_MEM_NO_FORCE`, `DEBUG_WX`,
  `STATIC_USERMODEHELPER`, `DEFAULT_MMAP_MIN_ADDR=65536`, `ARM64_SW_TTBR0_PAN`
  (redundant where PAN is in hardware), `ZERO_CALL_USED_REGS`.
- **Runtime cost:** `INIT_ON_FREE_DEFAULT_ON`, `PAGE_TABLE_CHECK(_ENFORCED)`,
  `KFENCE`, `UBSAN_BOUNDS` with `UBSAN_TRAP`, `DEBUG_LIST`, `DEBUG_SG`,
  `DEBUG_NOTIFIERS`, `DEBUG_VIRTUAL`, `SCHED_CORE`.
- **Behaviour changes:** `PANIC_ON_OOPS=y` with `PANIC_TIMEOUT=-1` (an oops
  reboots the board at once), `MAGIC_SYSRQ_DEFAULT_ENABLE=176` (NXP: `0x1`, all
  SysRq functions), `COMPAT=n` (no 32-bit userspace), `INET_DIAG=n`.
- **Toolchain-dependent (unconfirmed, §1):** `SHADOW_CALL_STACK`,
  `UNWIND_PATCH_PAC_INTO_SCS`, `ARM64_BTI_KERNEL`, `ARM64_MTE`,
  `KASAN_HW_TAGS`, `CFI_CLANG`. BTI and MTE are Armv8.5 features; if the
  Cortex-A55 lacks them (unconfirmed) they are moot on this SoC.
  In 6.18's Kconfig [S1], `SHADOW_CALL_STACK` depends on a compiler probe
  (`ARCH_SUPPORTS_SHADOW_CALL_STACK`), and `CFI_CLANG` is a transitional name
  for kCFI. Whether the wrynose gcc passes those probes, or a clang build is
  needed, is unconfirmed.

The tag also carries upstream's own fragments, `kernel/configs/hardening.config`
and `arch/arm64/configs/hardening.config` [S1], which can be merged with
`make imx_v8_defconfig hardening.config`. They cover most of the cheap group
above. Merging them, then adding the rest of §4, is the smallest change to
NXP's tree (Q1).

## 4. Lockdown LSM, module signing, /dev/mem and kexec

All values are from the resolved `imx_v8_defconfig` [S1]; the target values
are KSPP's [S2].

| Setting | NXP | KSPP | Note |
| --- | --- | --- | --- |
| `SECURITY_LOCKDOWN_LSM` | n | y | NXP's `CONFIG_LSM` string names `lockdown`, but the LSM is not built, so the name has no effect. |
| `SECURITY_LOCKDOWN_LSM_EARLY` | absent | y | Needed so lockdown applies before modules load. |
| `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` | absent | y | Integrity mode stops changes to the running kernel; confidentiality mode also stops reads of kernel memory. Which interface falls in which mode is unconfirmed (§6, Q4). |
| `MODULES` | y | n | 517 options are `=m` in the resolved config; see §6. |
| `MODULE_SIG`, `MODULE_SIG_FORCE`, `MODULE_SIG_ALL`, `MODULE_SIG_SHA512` | n | y | KSPP's fallback when modules must stay. |
| `DEVMEM` | y | n | `STRICT_DEVMEM` is y; `IO_STRICT_DEVMEM` is n. |
| `DEVPORT` | y | — | `/dev/port`; lockdown blocks it. |
| `KEXEC` | y | n | `KEXEC_FILE` is y and `KEXEC_SIG` is n; `CRASH_DUMP` is y. |
| `SECURITY_YAMA`, `SECURITY_LANDLOCK` | n | y | Both are in NXP's `CONFIG_LSM` string but not built. |
| `SECURITY_SELINUX`, `SECURITY_APPARMOR` | n | — | No MAC LSM is built; see §8. |
| `IMA`, `EVM`, `DM_VERITY` | n | — | Not in KSPP's list; relevant to a signed root filesystem (verified-boot survey, not this one). |

With lockdown built and early, module signing forced, and `/dev/mem`,
`/dev/port` and `kexec` removed, root on the running board cannot load
unsigned kernel code or read kernel memory through the usual interfaces.
Removing `MODULES` entirely is stronger but conflicts with the BSP (§6).

## 5. What NXP's lf-6.18 defconfig and meta-imx already set

meta-imx branch `wrynose-6.18.37-2.1.0` (head `2eb758f`, 2026-11-10) [S3]
builds `linux-imx` from branch `lf-6.18.y` at the same commit as tag
`lf-6.18.37-2.1.0`, and for every i.MX9 machine names `imx_v8_defconfig` as
`KBUILD_DEFCONFIG` (`meta-imx-bsp/recipes-kernel/linux/linux-imx_6.18.bb`).
The recipe adds no configuration fragment of its own, and it stops the build
if the older `DELTA_KERNEL_DEFCONFIG` variable is set; it points to
kernel-yocto configuration fragments as the supported way to change the
configuration. So the kernel meta-imx builds is the configuration in §3–§4,
unchanged. Its `layer.conf` lists `wrynose` among the Yocto releases it is
compatible with; the Yocto release number for that codename is not confirmed
here.

The FRDM-IMX95-PRO's machine is `imx95-19x19-lpddr5-frdm-pro`, with its own
device tree, U-Boot configuration, System Manager configuration and LPDDR5
DDR selection ([build-system options §2](build-system-options.md),
[boot-media survey §3.1](boot-media-survey.md)). This survey read the 15x15
FRDM machine file `imx95-15x15-lpddr4x-frdm.conf` in meta-imx-bsp [S3]
instead, not the PRO's. That file adds the `nxpiw612-sdio` Wi-Fi feature and a
dozen device-tree variants (camera, display, audio, NPU, RPMsg). Whether the
PRO machine sets the same features is **unverified**; the machine-specific
points below carry that caveat (Q6).
meta-freescale `wrynose` (head `2d08c05`, 2026-11-05) [S5] carries the shared
`linux-imx.inc`; it has no i.MX95 FRDM machine of its own.

meta-imx's distros (`fsl-imx-*` in `meta-imx-sdk/conf/distro`) [S3] are
display stacks (Wayland, XWayland, framebuffer) with a `-minimal` variant; the
one I read removes only `x11`. None of the files I found in meta-imx enables
SELinux or AppArmor. In short, NXP sets the baseline in §3 and nothing more:
no lockdown, no module signing, `/dev/mem` and `kexec` present, no MAC LSM.

## 6. Conflicts with the BSP's drivers

From the files above. None of this was tested on a board; each item is a
likely conflict, to be confirmed in the first hardened build (Q2).

- **`MODULES=n`.** The resolved config has 517 options as `=m` [S1], and
  meta-imx builds out-of-tree modules: `kernel-module-imx-gpu-viv`,
  `kernel-module-isp-vvcam`, `kernel-module-nxp-wlan` (pulled in by the Wi-Fi
  machine features of the 15x15 machine; whether the PRO machine pulls it in
  is **unverified**, §5), `kernel-module-dpdk-extras`, and `cryptodev-linux`
  (`meta-imx-bsp/recipes-kernel/`) [S3]. Out-of-tree modules cannot be built
  in, so `MODULES=n` means dropping them. The hardened image could keep
  modules and force signatures instead.
- **`MODULE_SIG_FORCE`.** In-tree modules are signed at `modules_install` with
  `MODULE_SIG_ALL`. Whether the Yocto `module` class signs out-of-tree modules
  with the same key is not confirmed (Q2). If it does not, those modules fail
  to load. The signing key is created at kernel build time; where it is kept,
  or whether it is thrown away after the build, is the owner's call (Q3). A key
  made fresh at each build changes the certificate embedded in the kernel and
  every module signature, so identical sources would no longer reproduce
  ([reproducible-build survey, question 2](reproducible-build-survey.md)).
- **`DEVMEM=n`.** NXP test tools that poke registers (for example a
  `memtool`-style utility in imx-test) need `/dev/mem`. I did not find them
  in the image recipes I read, so this is unconfirmed. A production image
  should not need them.
- **Lockdown and debugfs.** The lockdown man page [S6] says lockdown stops
  debugfs use, along with `/dev/mem`, `/dev/kcore`, kprobes, BPF access to
  kernel memory, and module parameters that name hardware addresses. The BSP
  enables `DEBUG_FS` [S1], and some vendor tools read it (GPU and power
  profiling; unconfirmed). Which of these restrictions apply in integrity mode
  and which only in confidentiality mode is set by `enum lockdown_reason` in
  `include/linux/security.h` [S1]; this lane could not read that header, so
  the split is unconfirmed (Q4).
- **`KEXEC=n`, `CRASH_DUMP=n`.** No BSP dependency found; meta-imx does not
  use kexec to boot.
- **OP-TEE and the ELE driver.** `TEE`, `OPTEE` and `IMX_SEC_ENCLAVE` are
  built in [S1]. None of the hardening options above removes them.
- **`COMPAT=n`.** It drops 32-bit userspace. Some vendor binaries may be
  32-bit; I did not check (Q2).
- **Toolchain options** (SCS, kCFI) depend on compiler support (§3). meta-imx
  has a `clang-layer` dynamic layer [S3], but a clang-built `linux-imx` is
  not confirmed.

## 7. Minimal userspace

The board's job is to run xkmsd and the services it needs, not a display
stack. meta-imx's own distros [S3] are built around Wayland, XWayland or a
framebuffer; their `-minimal` variants remove X11 but keep the NXP base
(`fsl-imx-base.inc`, not read here). OE-core `wrynose` (head `2285da0`,
2026-11-06) [S7] ships systemd 259.5, the version §8 is written against.
Yocto 6.0 "Wrynose" was released in April 2026 and is supported until April
2030, per the Yocto Project releases page [S8].

A minimal image for this row would:

- start from OE-core's `core-image-minimal` pattern rather than an `fsl-image-*`
  or `imx-image-*` image, and add only the kernel, firmware
  (`firmware-ele-imx`, which the board's machine adds for i.MX95 [S3]), systemd,
  xkmsd and its runtime needs;
- leave out shells and debug tools in the production image (no `bash`, no
  `gdb`, no `strace`, no `imx-test`, no package manager), and put them in a
  separate debug image that never holds production keys;
- mount the root filesystem read-only (verified-boot survey covers dm-verity;
  `DM_VERITY` is off in NXP's config [S1]);
- leave out the optional M7 demo images and camera, display and audio
  device-tree variants the machine file lists [S3], if the product does not
  use them.

I did not build such an image; what xkmsd needs at run time is go-xkms's to
say (Q7).

## 8. Confining xkmsd

xkmsd is go-xkms's daemon; this repository only packages it. Three layers
are available, from cheapest to most work.

**systemd sandboxing (systemd 259.5) [S9].** Every directive below exists in
the v259.5 `systemd.exec(5)` and `systemd.resource-control(5)` sources:

- filesystem: `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`,
  `ProtectProc=invisible`, `ProcSubset=pid`, writable state only under a
  `StateDirectory`;
- devices: `PrivateDevices=yes`, or `DevicePolicy=closed` with `DeviceAllow`
  for the ELE and any HSM device node only (the node names are unconfirmed);
- privilege: `DynamicUser=yes` or a fixed system user, `NoNewPrivileges=yes`,
  an empty or minimal `CapabilityBoundingSet`, `RestrictSUIDSGID=yes`,
  `LockPersonality=yes`, `MemoryDenyWriteExecute=yes`, `UMask=0077`;
- kernel: `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`,
  `ProtectClock`, `ProtectControlGroups`, `RestrictNamespaces=yes`,
  `RestrictRealtime=yes`;
- syscalls: `SystemCallFilter=@system-service`, `SystemCallArchitectures=native`
  (needs `SECCOMP_FILTER`, which NXP sets [S1]);
- network: `RestrictAddressFamilies` to the families xkmsd uses,
  `IPAddressAllow`/`IPAddressDeny` (needs `CGROUP_BPF`, which NXP sets [S1]);
- secrets: `LoadCredentialEncrypted` for any key material at rest (whether
  this fits the ELE-held keys is go-xkms's design; unconfirmed).

`systemd-analyze security` scores a unit against these settings [S9]. A Go
binary does not generate code at run time, so `MemoryDenyWriteExecute` should
not break it; this has not been tested with xkmsd.

**Landlock and Yama.** Both are in NXP's `CONFIG_LSM` string but not built
[S1]. Building them costs little; Landlock lets xkmsd restrict its own file
access, which go-xkms would have to code (Q8).

**A MAC LSM (SELinux or AppArmor).** Neither is built [S1]. In 6.18's Kconfig
SELinux needs `SECURITY_NETWORK`, `AUDIT`, `NET` and `INET`, and AppArmor needs
`SECURITY` and `NET` [S1]; NXP has `SECURITY_NETWORK` off. The Yocto layers
that carry them, meta-selinux and meta-security (AppArmor), both have a
`wrynose` branch [S10] [S11]; I did not read their recipes, so their state on
wrynose is unconfirmed. A MAC policy confines xkmsd even if it is compromised
as root, which systemd sandboxing alone does not; the cost is writing and
keeping a policy for the whole image.

## 9. What could not be confirmed

- The full configuration came from Kconfiglib with a host compiler, not from
  `make imx_v8_defconfig` with the aarch64 cross toolchain (§1). PAC, BTI,
  MTE, SCS and kCFI are unconfirmed, and so is whether the Cortex-A55 has the
  PAC, BTI and MTE extensions.
- Which lockdown restrictions fall in integrity and which in confidentiality
  mode (`include/linux/security.h` was not read).
- Whether the Yocto module class signs out-of-tree modules.
- Whether any NXP tool in a minimal image needs `/dev/mem`, debugfs or 32-bit
  userspace.
- The machine features of `imx95-19x19-lpddr5-frdm-pro`, the PRO's machine
  (§5). This lane read the 15x15 FRDM machine file instead, so the
  machine-dependent points in §5 and §6 are unverified for the PRO.
- The device nodes and syscalls xkmsd uses (go-xkms owns them).
- The state of meta-selinux and meta-security on wrynose.
- NXP's i.MX Linux security reference documents, which SPEC.md lists as
  missing from `references/`; no NXP PDF was read.

## 10. Questions for the owner

1. **Kernel baseline.** (a) NXP's `imx_v8_defconfig` as is; (b) plus upstream's
   `hardening.config` fragments; (c) (b) plus the rest of KSPP's cheap group (§3)
   in a project fragment. *Recommendation: (c), applied as a kernel-yocto
   fragment, since meta-imx rejects `DELTA_KERNEL_DEFCONFIG` [S3]. Confirm the
   toolchain-dependent options with a real cross build first.*
2. **Modules.** (a) keep modules unsigned; (b) keep modules, force signatures
   (`MODULE_SIG_FORCE`, SHA-512) and build only the drivers the board uses;
   (c) `MODULES=n`. *Recommendation: (b). (c) drops the out-of-tree BSP modules
   (§6); (a) leaves the biggest gap.*
3. **Module signing key.** (a) a key made per build and thrown away after
   signing; (b) a long-lived project key held offline. (a) leaves no key to
   steal, but it conflicts with the reproducible-build goal: a fresh key changes
   the kernel's embedded certificate and every module signature, so identical
   sources do not reproduce ([reproducible-build survey, question 2](reproducible-build-survey.md)).
   *Recommendation: (b), with the key held offline (for example in the HSM),
   and the public certificate of each release treated as a pinned build input,
   so the kernel that embeds it reproduces. Signing then runs as a separate
   step: the unsigned kernel and modules are the reproducible payloads, and the
   module signatures are verified separately against the pinned certificate.
   Whether the Yocto kernel and `module` classes can sign in a separate step is
   not confirmed and is to be validated. No source settles this; it is a policy
   choice for the owner.*
4. **Lockdown mode.** (a) none; (b) integrity; (c) confidentiality, early.
   *Recommendation: (c) for production (KSPP's setting [S2]), with a separate
   debug image if debugfs-based tools are needed. Revisit if the split (§9)
   puts a needed interface in confidentiality.*
5. **/dev/mem, /dev/port, kexec, SysRq, oops.** (a) keep NXP's defaults;
   (b) `DEVMEM=n`, `DEVPORT=n`, `KEXEC=n`, `KEXEC_FILE=n`, `CRASH_DUMP=n`,
   SysRq restricted, `PANIC_ON_OOPS=y`. *Recommendation: (b), per KSPP [S2]; no
   BSP dependency was found (§6).*
6. **Machine.** The sibling surveys already name the PRO's machine,
   `imx95-19x19-lpddr5-frdm-pro` ([build-system options §2](build-system-options.md),
   [boot-media survey §3.1](boot-media-survey.md)). What is still open is a
   re-check of §5 and §6 against that machine file, which this survey did not
   read. *Recommendation: re-read the PRO machine file before the first
   hardened build, and keep the machine-dependent points unverified until
   then.*
7. **Userspace.** (a) an `fsl-imx-*-minimal` distro image; (b) a project image
   built from `core-image-minimal`, with a separate debug image.
   *Recommendation: (b).*
8. **xkmsd confinement.** (a) systemd sandboxing only; (b) (a) plus Landlock
   and Yama; (c) (b) plus SELinux or AppArmor. *Recommendation: (b) now: it
   needs no policy language and NXP's `CONFIG_LSM` already names both. Decide
   (c) after go-xkms states xkmsd's device and network needs, and after
   checking meta-selinux and meta-security on wrynose.*
9. **SELinux or AppArmor**, if 8(c). *No recommendation from these sources;
   SELinux also needs `SECURITY_NETWORK` turned on (§8).*
