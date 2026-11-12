# System Manager configuration: resource isolation survey (TRDC)

Row: `system-manager-config` ([SPEC.md](../SPEC.md)). Issue #55.

## Scope

This survey covers how the i.MX 95 isolates cores, bus masters and memory
from one another, and how NXP's System Manager (SM) sets that isolation up
through the Trusted Resource Domain Controller (TRDC). It asks what a board
configuration for the FRDM-IMX95-PRO must decide, and what is decided today
by NXP's reference configuration.

It uses public sources only, summarised in this repository's own words.
Nothing here was built, flashed, fused or provisioned. No life-cycle or fuse
step is described as a procedure.

Survey date: 2026-11-12.

Issue #55's own text could not be read from the lane (no forge credentials);
this survey works from the `system-manager-config` row in
[SPEC.md](../SPEC.md) and the issue title.

## Sources

Each source is cited below by its tag in square brackets.

| Tag | Title | Version surveyed | URL | Reached |
|-----|-------|------------------|-----|---------|
| [SM-ARCH] | imx-sm reference manual source, Architecture chapter, `sm/doc/arch.md` | tag `rel_imx_sm_2026q3`, commit `eec2328` (2026-09-03) | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md | yes |
| [SM-CFGDOC] | imx-sm reference manual source, Configuration chapter, `sm/doc/config.md` (TRDC, configtool commands, resources, permissions) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md | yes (overview, TRDC and configtool sections) |
| [SM-MON] | imx-sm reference manual source, Monitor chapter, `sm/doc/monitor.md` | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/monitor.md | yes (opening section only) |
| [SM-PRO] | imx-sm `configs/other/mx95frdm-pro.cfg` (i.MX95 19x19 FRDM PRO) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg | yes (domain, LM, agent and memory sections; parts of the resource lists skipped) |
| [META-MACHINE] | nxp-imx/meta-imx, `meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf` | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf | yes |
| [META-SM] | nxp-imx/meta-imx, `meta-imx-bsp/recipes-bsp/imx-system-manager/imx-system-manager.inc` | tag `rel_imx_6.18.37_2.1.0` | https://github.com/nxp-imx/meta-imx/blob/rel_imx_6.18.37_2.1.0/meta-imx-bsp/recipes-bsp/imx-system-manager/imx-system-manager.inc | yes |
| [SMCT] | nxp-imx/imx-smct, "System Manager Config Tool CLI" | not checked | https://github.com/nxp-imx/imx-smct | no, named by [SM-CFGDOC] only |
| [LINUX-DTS] | Linux, `arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts` | branch `master` | https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/freescale/imx95-19x19-frdm-pro.dts | no, not read |
| [SCMI] | Arm, System Control and Management Interface, DEN0056 (SM implements version 3.2 per [SM-ARCH]) | "latest" | https://developer.arm.com/documentation/den0056/latest/ | no, not read |

Not reached, listed as unconfirmed: NXP's i.MX 95 Reference Manual
(IMX95RM) and the i.MX 95 Security Reference Manual. Both sit behind NXP's
documentation login and were not tried.

The imx-sm files were read from a shallow clone of tag
`rel_imx_sm_2026q3`; the meta-imx files were fetched from GitHub's raw file
service at the tag named.

## Findings

### The System Manager's isolation role

1. On the i.MX 95 the SM runs bare metal on the Cortex-M33 in the always-on
   domain, acting as the system control processor. The Cortex-A55 and
   Cortex-M7 are "user" cores that reach system resources only through SCMI
   calls to the SM. NXP does not support adding customer workloads to the
   M33 [SM-ARCH].
2. The SM's first stated role is to keep cores from interfering with one
   another. It does this by taking exclusive control of the resource domain
   controllers and loading their configuration before it starts any other
   core [SM-ARCH].
3. Once the TRDC is programmed, software on the A55 and M7 can no longer
   touch the power, clock, reset and PMIC hardware directly; their drivers are
   replaced by SCMI clients [SM-ARCH].
4. The SM groups cores and resources into *logical machines* (LMs), each with
   its own SCMI instance and its own boot, reset, suspend and shutdown life
   cycle. A normal SCMI call affects only the caller's LM, and an LM's agent
   list shows only its own agents. NXP describes each LM as fully isolated
   from the others. Whole-SoC reset or shutdown, and control of another LM,
   are vendor extensions (extra system power states and the NXP LMM
   protocol) granted per agent [SM-ARCH].
5. Inside an LM, each SCMI agent (for example TF-A, a hypervisor, each VM,
   the M7 firmware) gets its own channel and its own per-protocol,
   per-resource rights. The rights and the RDC policy are static: they come
   from configuration headers, usually generated by the configtool, and are
   compiled into the SM binary [SM-ARCH], [SM-CFGDOC].
6. LM0 is always the SM itself, and many resources must stay exclusively
   with it (the M33, power-management IP, PMIC, FCCU, most bus clocks and the
   always-on power domains) [SM-CFGDOC], [SM-ARCH].
7. The SM owns the fault collection unit (FCCU) and applies a configured
   reaction to each fault: reset or shut down the system or one LM, a board
   reaction, a notification, or nothing [SM-ARCH].

### How the System Manager programs the TRDC

8. Each TRDC instance on the SoC is identified by a letter (the docs use A,
   H, W and others as examples). Its programming lives in `config_trdc.h` as
   one encoded register-write sequence per instance. The SM replays a
   sequence whenever the power mix that holds that TRDC comes back up after
   losing state, so isolation is reapplied after low-power exits, not only at
   cold boot [SM-CFGDOC].
9. The sequence is a list of writes (single, block, fill, zero, repeat) at
   offsets relative to the TRDC base. A *conditional* write is skipped when
   the SM is built with the RDC disabled (`R=0`); NXP uses it for the write
   that turns the TRDC on. NXP notes `R=0` only has effect where the EdgeLock
   enclave has not already enabled the TRDC, such as some emulation or
   simulation setups [SM-CFGDOC].
10. The TRDC has three kinds of element, each configured from the `.cfg`
    file [SM-CFGDOC]:
    - **MDAC** (master domain assignment): tags each bus master's
      transactions with a domain ID (DID), a secure or non-secure
      attribute, a privileged or user attribute, and for some masters a
      stream ID. A master can be given a DID other than its LM's, or be left
      unassigned.
    - **MBC** (memory block checker): per-block permissions over a
      peripheral or memory, used for peripheral slots and for TCM- or
      OCRAM-style memories cut into fixed blocks.
    - **MRC** (memory region checker): permissions over address ranges,
      used for large memories such as DDR.
11. A permission is 16 bits: four 4-bit read/write/execute groups for
    secure-privileged, secure-user, non-secure-privileged and
    non-secure-user. The configtool has named values from `none` to `full`
    (for example `sec_rw`, `nspriv_rw`, `rw`) [SM-CFGDOC].
12. Access control is two separate checks. **API access** is per SCMI agent
    and is enforced by the SM on each call over the agent's messaging unit.
    **TRDC access** is per DID and is enforced by the hardware on every bus
    transaction. Each LM is one DID; all the agents of an LM share it
    [SM-CFGDOC].
13. Consequence for this project: inside one LM, the TRDC can separate
    agents only by the secure / non-secure attribute, and the model assumes
    anything a non-secure agent may reach is also reachable from secure. So
    TF-A and Linux on the A55 can be told apart by TRDC only through
    TrustZone; two cores that must be isolated from each other in hardware
    need two LMs (two DIDs) [SM-CFGDOC].
14. Some domains are not LMs: the configtool has `DOMn` sections for
    masters such as the EdgeLock enclave and the debug port, and some DIDs
    are fixed by the SoC (NXP's example gives ELE as DID 0 and MTR as DID 1).
    A `DEBUG` command names the DID used by the debug access port and trace,
    which is given access to everything; an MRC entry can opt out of that
    with `nodbg` [SM-CFGDOC]. NXP recommends the standard DID map in the TRDC
    section of the SoC reference manual, which this lane could not read.
15. The EdgeLock enclave may leave some MRC regions set up after loading the
    boot container; the SM clears four by default, more if configured
    [SM-CFGDOC].
16. NXP's worked example gives LM0 (the SM, DID 2) the M33, its TCMs as
    secure RWX, and a debug UART as secure RW; it gives the M7 its own LM
    (DID 4) with one SCMI agent and a UART. It notes the M7 always has full
    access to its own TCM, so no memory rule is written for it
    [SM-CFGDOC].

### What the FRDM-IMX95-PRO configuration isolates today

NXP's FRDM PRO configuration is `configs/other/mx95frdm-pro.cfg` [SM-PRO].
NXP says files under `configs/other` are shipped as they are and are not
maintained or tested as part of an SM release [SM-CFGDOC]. Its header
comment and `MAKE` line still name the i.MX95 EVK and the `mcimx95evk` board
port [SM-PRO], so it reads as an EVK configuration adapted for the FRDM PRO.

17. **Domains outside any LM** [SM-PRO]:
    - `DOM0` "ELE" at DID 0: the EdgeLock enclave gets read/write data
      access to the M33 system TCM, part of OCRAM and all of DDR
      (`0x8000_0000` to `0x8_7FFF_FFFF`), with the DDR rule marked `nodbg`.
      It also owns one EDMA2 channel pair and a V2X block. A comment in the
      file warns that sharing EDMA2's management port may not be safe when
      FuSa software uses EDMA2.
    - `DOM10` "ISP" at DID 10, with no rules shown in the part read.
    - `DOM12` "V2X" at DID 12: its masters bypass the secure and privileged
      attributes; it may write one 16 MiB DDR window
      (`0x8B00_0000`–`0x8BFF_FFFF`) and read the rest of DDR.
18. **LM0 "SM"** (DID 2, no RPC, boot order 1, FuSa F-EENV): secure-only
    access to the M33 ROM and TCMs, part of the M7 mix, the safety and
    monitoring IP (FCCU, STCUs, CMUs, EIM/ERM), the PMIC I2C pins and its
    debug UART. Faults `SW3`, `SW4` and `DRAM` are routed to a group or
    system reset [SM-PRO].
19. **LM1 "M7"** (DID 4, SCMI, boot order 2, safe S-EENV): one SCMI agent
    on MU 9 with three channels (command, notification, priority), CRC32
    checked. The agent is not marked `secure` for SCMI, but the M7's bus
    transactions are tagged secure by its MDAC. It owns CAN_FD1, its own
    watchdog (WDOG5), timers, two UARTs, several MUs, the ELE messaging
    unit 5 and a V2X SHE instance; it reads the fuse shadow block (FSB) and
    the system counter. Memory: two M7-mix ranges and DDR
    `0x8000_0000`–`0x89FF_FFFF` (160 MiB) with full permissions. It may use
    the LMM protocol on LM2, and the system power protocol, so the M7 can
    boot, reset or stop the A55 machine and the system [SM-PRO].
20. **LM2 "AP"** (DID 3, SCMI, boot order 3, the monitor's default LM): the
    six A55 cores and the A55 platform. Agent 1 "AP-S" is marked secure (in
    practice TF-A) on MU 1, owns the MU and ELE messaging units 1 and 2, and
    the A55 PLL. Its CPU MDAC setting is `sa=bypass`, so A55 transactions
    keep the TrustZone attribute the core gives them. Secure-only memory:
    256 KiB of OCRAM and DDR `0x8A00_0000`–`0x8DFF_FFFF` (64 MiB) with
    secure RWX [SM-PRO].

21. **LM2, agent 2 "AP-NS"** (same DID 3, non-secure, MU 3): Linux. Its
    masters are tagged non-secure. It owns nearly every application
    peripheral (display, camera, CAN 2–5, EDMA1, network, storage pins,
    XSPI, GPU window) and gets non-secure memory [SM-PRO]:
    - DDR `0x8800_0000`–`0x89FF_FFFF` (32 MiB) with full permissions;
    - DDR from `0x8E00_0000` to the top of DDR, full permissions;
    - parts of OCRAM, a 4 GiB FlexSPI window and the GPU window.
22. **Observations from reading the DDR rules together** (this survey's
    reading, not a statement by NXP) [SM-PRO], [SM-CFGDOC]:
    - The M7's window (`0x8000_0000`–`0x89FF_FFFF`) and Linux's first
      window (`0x8800_0000`–`0x89FF_FFFF`) overlap by 32 MiB. Only the
      lower 128 MiB is the M7's alone. The file does not say what the
      shared 32 MiB is for; shared memory for inter-core messaging is a
      plausible reading but was not confirmed.
    - The A55 secure window (`0x8A00_0000`–`0x8DFF_FFFF`) is not granted to
      Linux. Because the secure agent shares DID 3 with Linux, the secure
      side can also reach everything Linux can.
    - The V2X domain may write `0x8B00_0000`–`0x8BFF_FFFF`, inside the A55
      secure window, and read the rest of DDR. Its purpose there is not
      stated.
    - The EdgeLock domain can read and write all of DDR.
    - The M7 is a separate DID and cannot reach the A55 secure window or
      Linux's high DDR; Linux cannot reach the M7-only 128 MiB. This is the
      hardware boundary between the two LMs.
    - The M7 has LMM rights over LM2 and system power rights, while Linux
      only gets notifications about LM1. So in NXP's layout the M7 is the
      more privileged machine.

### Gaps for this project's cores

23. The SPEC row says the M7 firmware of trusted-firmware's `imx95` row gets
    its clocks, power and resources through SCMI, and that
    `hsm-self-defence` acts on power domains and PHYs
    ([SPEC.md](../SPEC.md)). NXP's FRDM PRO layout already makes the M7 a
    separate LM with its own DID, LMM rights over the A55 machine and system
    power rights [SM-PRO]. Isolation for the project is therefore mostly a
    matter of choosing what moves between the two LMs, not building the
    split.
24. To let the M7 power off a PHY or a power domain the A55 uses, it needs
    SCMI API rights on that power domain or reset (`PD_*`, `RST_*`); TRDC
    rights are not needed for SCMI calls, since the SM does the work
    [SM-CFGDOC]. In NXP's layout the M7 has no `PD_*` rights over A55
    peripherals beyond its own mix [SM-PRO]. This is a gap for
    `hsm-self-defence`.
25. ELE messaging units 1 and 2 go to the A55 (secure agent) and ELE
    messaging unit 5 to the M7 [SM-PRO]. Which side calls the EdgeLock HSM
    API is an open SPEC question (`secure-key-handling`); the TRDC layout
    must give that side its MU and deny it to the other.
26. The debug DID is given access to everything unless a rule says `nodbg`
    [SM-CFGDOC]. Whether the FRDM PRO file sets `DEBUG` was not confirmed
    (the part that would hold it was not read). Debug access is otherwise
    governed by life cycle and the enclave, which this survey does not
    cover.

### How the isolation reaches the board

27. NXP's Yocto layer builds the SM for the FRDM PRO machine with
    `SYSTEM_MANAGER_CONFIG = "mx95frdm-pro"` [META-MACHINE], and the SM
    recipe runs `make cfg` before compiling, so the headers, including
    `config_trdc.h`, are regenerated from the `.cfg` file on every build
    [META-SM]. A project configuration can therefore be kept as one `.cfg`
    file and reviewed as text.
28. The same recipe builds with debug-monitor mode `M=2` unless overridden
    [META-SM]. In that mode the SM enters its UART monitor when a character
    arrives on the SM debug UART. NXP states that only `M=0` is valid for
    production, as the monitor changes timing [SM-MON]. The monitor's full
    command set was not reviewed here.

## Not confirmed

- Issue #55's text (no forge access from the lane).
- The i.MX 95 reference manual (IMX95RM) TRDC chapter: the instance list,
  the standard DID map, which masters each MDAC covers, the block sizes of
  each MBC and the number of MRC regions. NXP's documents defer to it
  [SM-CFGDOC]; it is behind NXP's login and was not tried.
- The i.MX 95 Security Reference Manual: whether the EdgeLock enclave locks
  the TRDC configuration or checks it, and how TRDC behaves across
  life-cycle states.
- The part of `mx95frdm-pro.cfg` not read (lines with the remaining SM
  resources, the rest of the Linux peripheral list), including whether a
  `DEBUG` DID is set.
- The device-level resource definitions in
  `devices/MIMX95/configtool/device.cfg`, which turn names such as
  `DDR` or `CAN_FD1` into MBC/MRC entries. Not read; the ranges above are
  as written in the board file.
- The purpose of the 32 MiB DDR window shared by the M7 and Linux, and of
  the V2X write window inside the A55 secure range.
- Whether Linux's device tree for the FRDM PRO reserves the M7 and secure
  DDR ranges to match the SM file. The upstream file exists
  [LINUX-DTS]; it was not read.
- What the SMCT tool [SMCT] adds over the in-tree configtool.
- The SCMI specification [SCMI] itself; the SM's use of it is taken from
  [SM-ARCH].

## Questions for the owner

1. **How many logical machines, and which cores in each?**
   - (a) Keep NXP's three: SM (M33), M7, AP (all six A55 cores, secure and
     non-secure agents in one DID).
   - (b) Split the A55 into two LMs (for example a small isolated Linux
     beside the main one), each with its own DID.
   - (c) Fold the M7 into the AP machine.

   Recommendation: (a). The M7–A55 hardware boundary is already there and
   is what the SPEC rows assume [SM-PRO], [SM-CFGDOC]; (c) would remove it.
   Choose (b) only if a second A55 workload needs a hardware boundary from
   Linux.
2. **Is the M7 the more privileged machine?** NXP's file gives the M7
   LMM control over the A55 machine and system power rights [SM-PRO].
   - (a) Keep that: the M7 can stop, reset or power off the A55 side, as
     the `hsm-self-defence` row needs.
   - (b) Make the two peers: neither can control the other's life cycle.
   - (c) Reverse it.

   Recommendation: (a), since the tamper response in SPEC acts from the M7
   ([SPEC.md](../SPEC.md)).
3. **Which power domains, resets and PHYs may the M7 cut?** It needs SCMI
   rights on each one; it has none over A55 peripherals today [SM-PRO],
   [SM-CFGDOC].
   - (a) A named list (for example the network and PCIe PHYs, the display
     and camera mixes, USB).
   - (b) Every A55-side power domain.

   Recommendation: (a), with the list taken from the `hsm-self-defence`
   row once it names its targets. No source here decides the list.
4. **What happens to the 32 MiB DDR window both the M7 and Linux can
   reach?** [SM-PRO]
   - (a) Keep it as the only shared window and use it for inter-core
     messaging, read and written through a defined protocol.
   - (b) Shrink it to what the messaging needs.
   - (c) Remove it and use only the messaging units.

   Recommendation: (b), once the shared window's real use is confirmed;
   the sources do not say why it is 32 MiB.
5. **Which side owns the EdgeLock enclave's messaging units?** NXP gives
   MU 1 and 2 to the A55 secure agent and MU 5 to the M7 [SM-PRO].
   - (a) Leave both sides with an ELE MU.
   - (b) Give the HSM API MU to one side only and remove the other.

   Recommendation: (b), following whatever the `secure-key-handling`
   question decides; this survey cannot choose the side.
6. **Do we keep NXP's V2X and ISP domains as they are?** The V2X domain can
   write a window inside the A55 secure range [SM-PRO].
   - (a) Keep NXP's rules.
   - (b) Remove the V2X write window if the project does not use V2X.

   Recommendation: (b) if V2X is unused, after IMX95RM or NXP confirms what
   the window is for.
7. **Debug monitor and debug DID in the shipped SM.**
   - (a) Build with `M=0` and no `DEBUG` DID for anything flashed beyond the
     bench.
   - (b) Keep NXP's defaults (`M=2`) on development boards only.

   Recommendation: (a) for any build that is not a bench build, as NXP says
   only `M=0` is valid for production [SM-MON], [META-SM]; (b) on the bench.
8. **Where does the project's SM configuration live and start from?**
   - (a) A copy of `mx95frdm-pro.cfg` at a pinned SM tag, kept in this
     repository and changed by review.
   - (b) A file written from scratch.

   Recommendation: (a). The NXP file is shipped untested and still names the
   EVK board port [SM-CFGDOC], [SM-PRO], so pin the tag and review each
   change against the row's needs.
9. **Do we need the reference manual before we change any rule?** The DID
   map and MBC/MRC limits come from IMX95RM, which is missing.
   - (a) Yes: get IMX95RM (and the Security Reference Manual) first.
   - (b) No: change only rules expressed through names that NXP's
     `device.cfg` already defines.

   Recommendation: (a) for any new DID or memory split; (b) is enough for
   SCMI API rights such as question 3.
