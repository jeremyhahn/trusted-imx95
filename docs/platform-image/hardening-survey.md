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
| meta-imx | see §5; the Yocto release it pins is listed there | [S3] |

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
  `SHADOW_CALL_STACK` and `CFI_CLANG` need a clang-built kernel in 6.18's
  Kconfig, which the Yocto default (gcc) does not give (unconfirmed for
  meta-imx).

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
| `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` | absent | y | Confidentiality also blocks reading kernel memory (e.g. via BPF, perf, tracefs); integrity only blocks changing it. |
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

TODO (meta-imx kernel recipe and any config fragments it applies)

## 6. Conflicts with the BSP's drivers

TODO

## 7. Minimal userspace

TODO

## 8. Confining xkmsd

TODO

## 9. What could not be confirmed

TODO

## 10. Questions for the owner

TODO
