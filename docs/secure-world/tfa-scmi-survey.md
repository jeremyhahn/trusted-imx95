# Secure world: TF-A BL31 and SCMI on the i.MX 95 (survey)

Status: draft survey for issue #96, row `secure-world` of [SPEC.md](../SPEC.md).
Public sources only; every claim cites a source from the [Sources](#sources) list.

## 1. Scope and method

This survey covers the EL3 firmware (TF-A BL31) of the Cortex-A55 cluster on
the NXP i.MX 95 of the FRDM-IMX95 board. It explains how BL31 depends on the
System Manager (SM) on the Cortex-M33, what in its build affects security, and
how it is packaged and authenticated at boot. It is input to the row's
decision on the secure world and to issues #32 (boot chain) and #55 (code
signing).

Method: source trees were read at the tags or commits listed under
[Sources](#sources). Statements are summaries in this document's own words.
Values (addresses, option names) are quoted from source. Where a statement
is an inference and not something a source states, the text says so. No
build was run, and nothing was run on hardware. No key, fuse, life-cycle or
provisioning step is described as a procedure here.

## 2. What TF-A provides for the i.MX 95

### 2.1 Upstream TF-A

Upstream TF-A [S1] carries an i.MX 95 port at `plat/imx/imx9/imx95`, built with
`make PLAT=imx95 bl31`. It is present in tag `v2.15.0` and on `master` as surveyed
(2026-11-11); `master` also has sibling ports `imx94` and `imx952` sharing
`plat/imx/imx9/common` [S1, S2]. Facts below are from `v2.15.0` unless marked.

- **BL31 only, reset to BL31.** The port's `platform.mk` sets `RESET_TO_BL31 := 1`
  and builds no BL1 or BL2 [S2]. The upstream i.MX 9 platform page gives the boot
  chain as BootROM, then U-Boot SPL, then BL31, then U-Boot proper, then Linux; SPL,
  not TF-A, loads the next images [S3].
- **Cores.** One cluster of six Cortex-A55 cores (`PLATFORM_CORE_COUNT` 6), cold
  boot on a single CPU, hardware-assisted coherency, GIC-600 through the GICv3
  driver, Cortex-A55 erratum 1530923 workaround on [S2].
- **Memory.** BL31 links at `0x8A200000` with a 256 KiB limit (`0x8A240000`);
  the default BL32 window is `0x8C000000`, 32 MiB (`BL32_BASE`/`BL32_SIZE`,
  overridable on the make line) [S2].
- **Console.** LPUART at `0x44380000`; BL31 registers it with boot scope only,
  so it is not used at runtime after handing over to the normal world [S2].
- **Platform setup.** `bl31_platform_setup` queries the EdgeLock Enclave (ELE)
  for SoC information over the ELE messaging unit at `0x47540000`, releases the
  GMID, and then sets up the SCMI client [S2].
- **SiP services.** The port compiles NXP's i.MX SiP handler
  (`imx_sip_handler.c`, `imx_sip_svc.c`) [S2]; which SiP calls are enabled for
  the i.MX 95 was not traced function by function (see section 6).

The upstream TF-A documentation page for i.MX 9 still only names `imx93` as a
build target and does not describe the i.MX 95 port [S3]; the port is
documented by its source only.

### 2.2 NXP TF-A (imx-atf)

NXP's fork [S4] is what NXP's Linux BSP releases build. Surveyed: branch
`lf_v2.14`, head commit `af9eb2c` (2026-09-01). The i.MX 95 port is at the same
path and shares the upstream structure, memory map and SCMI client; its
`platform.mk` differs from upstream `v2.15.0` only in what follows [S2, S4]:

- **Extra SiP calls that drive other cores.** `imx95_m7.c` adds an SRC SiP
  service that lets the normal world set the Cortex-M7 reset address, prepare
  it, start it, stop it and query it. Depending on the SM configuration, it does
  this by core control or by booting and shutting down the M7 logical machine,
  and on stop it resets the M7 agent's SCMI configuration. `imx95_lmm.c` adds
  an LMM SiP service that boots or force-shuts down a logical machine whose
  number the caller passes, without an allow-list in TF-A [S4]. Both act with
  the rights of the secure SCMI agent (section 2.4), so whatever bounds them is
  in the SM configuration, not in TF-A.
- **SCMI base protocol** is compiled in (agent discovery for the M7 code)
  [S4].
- **Trusty.** With `SPD=trusty` an FF-A shared-memory helper is added [S4].

Upstream `v2.15.0` exposes on the i.MX 95 only the generic i.MX SiP calls
plus SoC-information query; the M7 and LMM services are NXP-only [S2, S4].
A normal-world kernel that starts the M7 through Linux remoteproc on NXP's
BSP depends on the SRC SiP call, according to the fork's own code comments
and function names; that dependency was not checked against the kernel (see
section 6).

### 2.3 PSCI

The i.MX 95 PSCI back end [S2, `imx95_psci.c` and `imx9_psci_common.c`]
implements CPU on and off, CPU and cluster suspend with finish handlers, system
suspend (`get_sys_suspend_power_state`, with DRAM retention code in
`imx9_sys_sleep.c`), power-down, system reset and system off. None of these
touch power or clock hardware directly. Each is turned into SCMI requests to
the System Manager: setting a core's reset (entry) address, starting a core,
setting its low-power mode and sleep mode, setting wake sources, and, for
system reset and off, an SCMI system power state request [S2]. CPU entry
points from the normal world are checked by `imx_validate_ns_entrypoint`
before use [S2].

### 2.4 Reaching the System Manager over SCMI

BL31 is an SCMI *agent*; the System Manager (SM) firmware on the Cortex-M33 is
the SCMI *platform* [S2, S5, S6]. In the upstream port [S2]:

- **Transport.** A shared-memory mailbox: the SCMI payload area sits at
  `0x44221000`, and the doorbell is a write to the general control register of
  messaging unit MU1 at `0x44220000` (`MU_SECURE_BASE`, the secure-side MU).
  The generic Arm CSS SCMI driver (`drivers/arm/css/scmi`) does the framing,
  with a lock that serialises the cores.
- **Protocols used.** SCMI base, power domain and system power from the
  generic driver, plus an NXP vendor extension (`drivers/nxp/scmi/vendor/
  scmi_imx9.c`) for CPU control: start, reset address, low-power mode, sleep
  mode, wake masks. Power "mix" and memory slice indices for the i.MX 95 are
  listed in `imx95_scmi_def.h`.
- **Which agent BL31 is.** The SCMI channel BL31 uses, and the permissions it
  carries, are set by the SM configuration, not by TF-A. In NXP's SM, each
  SCMI agent is bound to a messaging-unit channel and a security state, and
  agents are grouped into logical machines (LM); the SM configuration tool
  decides which resources each agent may touch [S5, S6]. The port does not
  check that its MU1 channel really is the secure agent's channel; it relies
  on the SM configuration for that [S2].
- **ELE.** Separately from SCMI, BL31 talks to the EdgeLock Enclave over its
  own MU for SoC information and the GMID release [S2].

## 3. Build options that matter for security

Defaults below are from the upstream build-options guide at `v2.15.0` [S7],
and the platform values from the i.MX 95 `platform.mk` [S2, S4].

| Option | Default | What it means for this board |
|---|---|---|
| `DEBUG` | 0 (release) | A debug build turns on assertions and crash dumps by default and is larger; the BL31 region is only 256 KiB [S2, S7]. Ship release. |
| `LOG_LEVEL` | 20 (notice) in release, 40 (info) in debug [S7] | The console is the boot-scope LPUART (section 2.1); a lower level prints less about the memory map and the boot. |
| `ENABLE_ASSERTIONS` | follows `DEBUG` [S7] | Can be turned on in a release build to keep input checks that are written as `assert()`. |
| `CRASH_REPORTING` | follows `DEBUG` [S7] | Dumps register state to the console on an unexpected exception. |
| `ENABLE_STACK_PROTECTOR` | `none` [S7] | The guide recommends `strong` where wanted; the platform must supply a canary source, which this lane did not find in the i.MX 95 port (section 6). |
| `BRANCH_PROTECTION` | 0 [S7] | Needs Armv8.3 pointer authentication or Armv8.5 BTI. The Cortex-A55 is an Armv8.2-A core [S10], so not applicable. |
| `HARDEN_SLS` | 0 [S7] | Compiler hardening against straight-line speculation; costs code size only. |
| `SEPARATE_CODE_AND_RODATA` | 0 [S7] | Puts code and read-only data on separate pages so data is not executable; costs some of the 256 KiB. |
| `SPD` | none | `opteed` or `trusty` makes BL31 enter a BL32 at `BL32_BASE` [S2]. No SPD means no secure OS, and BL31 alone in EL3. |
| `SPD=spmd` with `SPMD_SPM_AT_SEL2` or `SPMC_AT_EL3` | off [S7] | Secure partitions under FF-A. S-EL2 needs `FEAT_SEL2` (Armv8.4), which the A55 lacks [S7, S10]; the EL3 SPMC is the variant the guide gives for older cores. The i.MX 95 port wires up only `opteed` and `trusty` [S2]. Not confirmed to build or run on i.MX 95. |
| `BL32_BASE`, `BL32_SIZE` | `0x8C000000`, 32 MiB [S2] | Must match the secure DDR window in the SM configuration (section 4) and OP-TEE's own load address. |
| `SYS_PWR_FULL_CTRL` | 0 [S2] | Platform switch in the SCMI system-power path; its exact effect was not traced (section 6). |
| `IMX_SIP_*` services | built in, no switch [S2, S4] | NXP's fork adds M7 and LMM SiP calls (section 2.2) that cannot be compiled out by an option; removing them is a patch. |

**OP-TEE.** Upstream OP-TEE (`master`, 2026-11; latest tag `4.11.0`) has an
`mx95evk` flavour in `plat-imx` [S8]. It uses the ELE over an MU and disables
the CAAM, SNVS, OCOTP and TZC-380 drivers on this SoC. There is no FRDM flavour
upstream; a board port, or the EVK flavour with board values overridden, would
be needed. This lane did not check that the DDR size and UART in the EVK
flavour fit the FRDM-IMX95.

## 4. Resources that stay secure-only

On the i.MX 95 the secure/non-secure split of peripherals and memory is not set
by TF-A: the System Manager programs the resource-domain controllers from its
build-time configuration [S5, S6]. TF-A's own view is only its MMU map and the
`BL31_BASE`..`BL31_LIMIT` and BL32 windows [S2]. So "what stays secure" is a
question about the SM configuration chosen for the board, which belongs to
the `system-manager-config` row.

NXP's SM repository ships a configuration for the FRDM board,
`configs/mx95frdm.cfg` [S5]. That file is for the 15x15 FRDM-IMX95 board, not
the FRDM-IMX95-PRO (machine `imx95-19x19-lpddr5-frdm-pro`), which names an SM
configuration `mx95frdm-pro` whose source is unconfirmed
([upstream-survey.md](upstream-survey.md)). Everything in this section is
therefore **unverified for the PRO** until that configuration is read. As
published in `mx95frdm.cfg`:

- The Cortex-A55 side is one logical machine, `LM2` "AP", holding two SCMI
  agents: `AP-S`, marked secure, on MU1 (the MU BL31 uses, section 2.4), and
  `AP-NS`, not secure, on MU3 for Linux and U-Boot.
- Owned by the secure agent with secure-only read/write permission: the six
  A55 cores and the A55 platform (cluster), the Arm PLL, the A side of MU1, and
  two ELE messaging units (`MU_ELE1`, `MU_ELE2`). It is also given the
  performance protocol for the A55, full system-protocol rights (`SYS ALL`),
  and the low-power interface settings of the A55's UARTs, GPIOs, CANs and
  watchdogs 3 and 4.
- Memory with secure-only execute permission: 256 KiB of OCRAM at
  `0x20480000` and DDR `0x8A000000`..`0x8DFFFFFF` (64 MiB). That DDR range
  covers BL31 at `0x8A200000` and the default BL32 window `0x8C000000`, 32 MiB,
  from section 2.1.
- Faults from software and from watchdogs 3 and 4 reset only the AP logical
  machine.

The SM configuration guide [S6] notes that the resource-domain hardware can
only split secure from non-secure, and that whatever the non-secure side can
reach, the secure side can reach too. The design point that follows: the
non-secure agent must not hold the CPU, PLL, MU1 or ELE MUs, or the secure
DDR window. In the 15x15 board's `mx95frdm.cfg` it does not [S5]; for the PRO
this is **unverified**. This lane did not audit the
whole non-secure resource list line by line (see section 6).

## 5. Placement in the boot container and verification (input to #32, #55)

**Image layout.** NXP's `imx-mkimage` (tag `lf-6.12.49_2.2.0`, `iMX95/soc.mak`
and `Readme.imx95`) [S9] builds `flash.bin` from two AHAB containers:

1. **First container**, read by the boot ROM: the ELE firmware (`-append`
   of the AHAB image), optionally an OEI (DDR set-up image) for the M33, the
   System Manager for the Cortex-M33 (`-m33`, into M33 TCM), optionally the M7
   image, and U-Boot SPL for the A55 (`-ap ... a55`). The `MSEL` value given here
   is passed to the SM and selects its boot mode.
2. **Second container**, `u-boot-atf-container.img`, appended after the first
   at a 1 KiB-aligned offset: `bl31.bin` loaded at `ATF_LOAD_ADDR`
   (`0x8A200000`, the same as `BL31_BASE`), `u-boot-hash.bin` at
   `UBOOT_LOAD_ADDR` (`0x90200000`) and, if a `tee.bin` is present, OP-TEE at
   `TEE_LOAD_ADDR` (`0x8C000000`, the same as `BL32_BASE`). All three are
   tagged for core `a55`. `-sw_version` sets a container software version
   when `ROLLBACK_INDEX_IN_CONTAINER` is given; it is enforced only by a
   consumer that reads it (section 5). Container format version 2
   is used for the i.MX 95 B0 silicon.

So BL31 never sits in the ROM-loaded container. U-Boot SPL, running on the
A55, loads it from the second container. SPL then jumps to BL31, which enters
U-Boot proper (and BL32 first, if `SPD` is set) [S3, S9, S11].

**Verification.** In U-Boot's i.MX container loader (`master`, 2026-07-06,
`common/spl/spl_imx_container.c` and `arch/arm/mach-imx/ele_ahab.c`) [S11],
when `CONFIG_AHAB_BOOT` is enabled, SPL asks the ELE to authenticate the second
container's header, which carries the signature, before it loads anything.
It then asks the ELE to check each loaded image (BL31, U-Boot, OP-TEE)
against the hash in that header, and finally releases the container. Without
`CONFIG_AHAB_BOOT`, SPL loads the images without any check [S11]. Whether a
failed check stops the boot also depends on the device's life cycle: an open
part only logs ELE events, a closed part refuses. That is NXP's AHAB model as
the U-Boot code and its `ahab_close`/`ahab_status` commands present it [S11];
the behaviour per life-cycle state was not confirmed from an NXP document
(see section 6).

Inputs for #32 (boot chain) and #55 (signing), stated as facts from the
sources above:

- BL31 and BL32 are authenticated by the same container signature as U-Boot
  proper. There is no separate TF-A signature and no TF-A Trusted Board Boot,
  since BL2 is not used [S2, S9, S11].
- The chain of trust is: ROM and ELE check container 1 (SM, SPL); SPL, through
  the ELE, checks container 2 (BL31, BL32, U-Boot). It holds only if SPL is
  built with `CONFIG_AHAB_BOOT` [S11].
- Rollback of container 2 involves two separate mechanisms, which must not be
  confused (see [firmware-update-survey.md](firmware-update-survey.md) §5.1,
  §5.2):
  - the container's **fuse version** (`fuse_version`) is the hardware floor,
    checked by the ELE against a fuse-backed version. The exact comparison the
    ELE makes on the i.MX 95 is **unconfirmed** (see section 6). Advancing the
    fused value is irreversible and is not a step any lane runs or scripts;
  - the container's **software version** (`-sw_version`) [S9] is not checked
    by the ELE. In the public sources, only SPL in NXP's Trusty configuration
    (`CONFIG_IMX_TRUSTY_OS`) reads it, against an eMMC RPMB index, and it skips
    the check when no RPMB key is set. In a plain Linux BSP build nothing
    enforces it. So `-sw_version` is rollback protection only where such an
    enforcing consumer is built in and provisioned.
- Load addresses in `soc.mak` must match `BL31_BASE` and `BL32_BASE` in
  TF-A and the secure DDR window in the SM configuration. They do in the
  default values [S2, S5, S9].

## 6. What could not be confirmed

- **NXP documents.** NXP web pages (product pages, the i.MX Linux User's Guide
  and Reference Manual, AHAB and code-signing application notes, the i.MX 95
  reference manual and security reference manual) could not be fetched
  from the lane; www.nxp.com returned HTTP 404 to automated requests. Nothing
  here relies on them. This means: the AHAB behaviour per life-cycle state,
  the ELE's rollback enforcement against fuses, the i.MX 95 TrustZone and
  resource-domain hardware model beyond what the SM documentation says, and
  the CST signing flow for container 2 are **unconfirmed** in this survey.
- **Cortex-A55 architecture level.** Armv8.2-A (hence no PAuth, BTI or
  S-EL2) is stated from the Arm product page [S10], which returned HTTP 403
  to the lane; **unconfirmed** here.
- **SiP surface.** The full list of SiP calls the i.MX 95 build answers, and
  how each checks its arguments, was not traced call by call. Section 2.2
  covers only the M7 and LMM services.
- **Linux dependency on NXP SiP calls** (remoteproc for the M7) was not
  checked against kernel source.
- **`SYS_PWR_FULL_CTRL`.** Its exact effect was not traced.
- **Stack protector.** No `plat_get_stack_protector_canary` was found in the
  i.MX 95 port's sources as listed in `platform.mk` [S2]. That suggests
  `ENABLE_STACK_PROTECTOR` needs a platform addition first; not confirmed by a
  build.
- **SM configuration audit.** Only the A55 secure agent's section of
  `mx95frdm.cfg` was read in full; the non-secure resource list was skimmed.
- **OP-TEE on FRDM.** Upstream OP-TEE has only `mx95evk`; whether its DDR and
  UART values fit the FRDM-IMX95 was not checked.
- **SPMD/FF-A on i.MX 95.** No source shows `SPD=spmd` built or run on this
  SoC.
- **Release alignment.** The NXP branch heads surveyed (`imx-atf`
  `lf_v2.14`, `imx-sm` `master`) were not matched to one NXP BSP release
  tag. `imx-mkimage` was read at release tag `lf-6.12.49_2.2.0`. Matching
  versions across the three repositories is for #32.

## Sources

All reached from the lane on 2026-11-12 unless marked unreachable.

- [S1] Trusted Firmware-A, upstream repository, tag `v2.15.0` (commit
  `da738d5`) and `master` (commit `d70b52d`, 2026-11-11).
  https://github.com/ARM-software/arm-trusted-firmware (mirror of
  https://review.trustedfirmware.org/plugins/gitiles/TF-A/trusted-firmware-a)
- [S2] TF-A `v2.15.0`, i.MX 95 port: `plat/imx/imx9/imx95/` (`platform.mk`,
  `include/platform_def.h`, `include/imx95_scmi_def.h`, `imx95_psci.c`),
  `plat/imx/imx9/common/` (`imx9_bl31_setup.c`, `imx9_psci_common.c`,
  `scmi/scmi_client.c`), `plat/imx/common/imx_sip_svc.c`.
  https://github.com/ARM-software/arm-trusted-firmware/tree/v2.15.0/plat/imx/imx9
- [S3] TF-A documentation, "NXP i.MX 9 Series", `docs/plat/imx9.rst`, `v2.15.0`.
  https://trustedfirmware-a.readthedocs.io/en/v2.15.0/plat/imx9.html
- [S4] NXP `imx-atf`, branch `lf_v2.14`, commit `af9eb2c` (2026-09-01):
  `plat/imx/imx9/imx95/` (`platform.mk`, `imx95_m7.c`, `imx95_lmm.c`),
  `plat/imx/common/imx_sip_svc.c`.
  https://github.com/nxp-imx/imx-atf/tree/lf_v2.14/plat/imx/imx9/imx95
- [S5] NXP `imx-sm` (System Manager), default branch, commit `eec2328`
  (2026-09-03, tagged `android-17.0.0_1.0.0`): `configs/mx95frdm.cfg`.
  https://github.com/nxp-imx/imx-sm/blob/eec232878ab7dd460f5a8f3767d39dc7e9412efa/configs/mx95frdm.cfg
- [S6] NXP `imx-sm`, same commit: configuration guide `sm/doc/config.md`
  (agents, `secure` flag, permission groups, resource-domain notes).
  https://github.com/nxp-imx/imx-sm/blob/eec232878ab7dd460f5a8f3767d39dc7e9412efa/sm/doc/config.md
- [S7] TF-A "Build Options", `docs/getting_started/build-options.rst`, `v2.15.0`.
  https://trustedfirmware-a.readthedocs.io/en/v2.15.0/getting_started/build-options.html
- [S8] OP-TEE OS, `master` as of 2026-11-12 (latest tag seen `4.11.0`),
  `core/arch/arm/plat-imx/conf.mk`.
  https://github.com/OP-TEE/optee_os/blob/master/core/arch/arm/plat-imx/conf.mk
- [S9] NXP `imx-mkimage`, tag `lf-6.12.49_2.2.0` (commit `be80fad`,
  2025-11-14): `iMX95/soc.mak`, `Readme.imx95`.
  https://github.com/nxp-imx/imx-mkimage/tree/lf-6.12.49_2.2.0
- [S10] Arm, "Cortex-A55" product page. https://developer.arm.com/Processors/Cortex-A55
  **Unreachable from the lane (HTTP 403).**
- [S11] U-Boot, `master` commit `ece349a` (2026-07-06):
  `common/spl/spl_imx_container.c`, `arch/arm/mach-imx/ele_ahab.c`.
  https://github.com/u-boot/u-boot/tree/master/arch/arm/mach-imx
- Unreachable, not used: NXP i.MX 95 product page, FRDM-IMX95 board page and
  "Embedded Linux for i.MX Applications Processors" (i.MX Linux User's Guide
  and Reference Manual), all on https://www.nxp.com, HTTP 404 to the lane.

## Questions for the owner

1. **Which TF-A tree is the base?**
   Options: (a) upstream TF-A tag `v2.15.0` or later; (b) NXP `imx-atf`
   `lf_v2.14`; (c) upstream, plus only the NXP patches the board needs,
   carried in this repository.
   Recommendation: (c), leaning towards (a). Upstream already has the i.MX 95
   port with the same memory map and SCMI client [S1, S2]. NXP's extra
   surface is the M7 and LMM SiP calls, which let the normal world start and
   stop other logical machines through the secure agent [S4]. Take those only
   if the M7 must be driven from Linux.

2. **Is there a secure OS (BL32) at all?**
   Options: (a) none, BL31 only; (b) OP-TEE through `SPD=opteed`; (c) Trusty;
   (d) FF-A with `SPD=spmd` and an EL3 SPMC.
   Recommendation: (a) for the first boot chain, with (b) as the next step.
   BL31 alone is the smallest secure surface. OP-TEE has an upstream i.MX 95
   flavour [S8], and the port wires up `opteed` [S2]. (d) has no i.MX 95
   evidence (section 6). The answer also decides what the row's
   "TrustZone software" covers (SPEC.md, row `secure-world`).

3. **Should NXP's M7 and LMM SiP services be in the build?**
   Options: (a) keep them as NXP ships them; (b) remove them and start the M7
   from the SM's boot list (`MSEL`) only; (c) keep them with an allow-list of
   logical-machine IDs in TF-A.
   Recommendation: (b) if the M7 firmware does not need to be restarted
   from Linux, otherwise (c). Today `imx95_lmm.c` passes a caller-chosen
   LM ID to the SM with the secure agent's rights [S4]. Depends on the
   `system-manager-config` row.

4. **Release build settings.**
   Options: (a) NXP BSP defaults; (b) `DEBUG=0`, `LOG_LEVEL` at most 20,
   `ENABLE_ASSERTIONS=1`, `HARDEN_SLS=1`, `SEPARATE_CODE_AND_RODATA=1`,
   with `ENABLE_STACK_PROTECTOR=strong` once a canary source is added.
   Recommendation: (b), checked against the 256 KiB BL31 limit [S2, S7].
   `BRANCH_PROTECTION` does not apply to the A55 (unconfirmed, [S10]).

5. **Who owns the secure resource list?**
   Options: (a) start from NXP's `mx95frdm.cfg` unchanged; (b) a
   project-owned SM configuration derived from it and reviewed against this
   survey's section 4.
   Recommendation: (b), in the `system-manager-config` row. TF-A's
   isolation rests entirely on that file: the secure DDR window, MU1, the ELE
   MUs and the CPUs [S5, S6]. The starting file for the PRO is the
   unconfirmed `mx95frdm-pro`, not the 15x15 board's `mx95frdm.cfg`.

6. **Container 2 authentication (for #32 and #55).**
   Options: (a) build SPL with `CONFIG_AHAB_BOOT` and sign container 2 with
   the same key set as container 1; (b) as (a), plus an anti-rollback floor
   for container 2 that a confirmed consumer enforces: the container fuse
   version checked by the ELE, and `-sw_version` only together with an
   enforcing consumer (for example an SPL rollback check against a
   provisioned RPMB index) that is built in and shown to refuse an older
   container; (c) no authentication of container 2 during development.
   Recommendation: (b) as the target and (a) at least, from the first
   signed build. Without `CONFIG_AHAB_BOOT`, BL31 is loaded unchecked [S11].
   Setting `-sw_version` alone is not (b): with no enforcing consumer, older
   signed BL31/BL32 containers stay bootable. Until the fuse-version
   comparison (section 6) and an enforcing consumer are confirmed, container 2
   has no confirmed rollback protection, and the SPEC.md anti-rollback
   requirement for it stays open. Committing a fuse version is irreversible
   and is not described here as a step to run.

7. **Which versions to pin?**
   Options: (a) one NXP BSP release tag across `imx-atf`, `imx-sm`,
   `imx-mkimage` and U-Boot; (b) upstream TF-A and U-Boot with NXP's SM and
   mkimage at a release tag.
   Recommendation: none from the sources alone. This survey used branch
   heads for two NXP trees (section 6). Pick in #32 once question 1 is
   answered.
