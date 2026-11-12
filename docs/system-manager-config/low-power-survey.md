# System Manager low-power modes: security survey

Row: `system-manager-config` ([SPEC](../SPEC.md)). Issue #114. Documentation only.

Status: draft survey from public sources. Nothing here is decided until the owner
answers the questions at the end.

## 1. Sources surveyed

All sources are public and were read on 2026-11-12. Section references below use
the short names in the first column.

| Short name | Title | Version | URL |
|---|---|---|---|
| SM-ARCH | NXP i.MX System Manager, `sm/doc/arch.md` (Architecture) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md |
| SM-FRDM-CFG | NXP i.MX System Manager, board configuration `configs/mx95frdm.cfg` (FRDM-IMX95) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg |
| SM-CONFIG | NXP i.MX System Manager, `sm/doc/config.md` (Configuration, configtool) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md |
| SM-MONITOR | NXP i.MX System Manager, `sm/doc/monitor.md` (debug monitor commands) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/monitor.md |
| SM-DEV | NXP i.MX System Manager, `sm/doc/dev.md` (Developer's Guide, build options) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/dev.md |
| SM-PORT | NXP i.MX System Manager, `sm/doc/port.md` (Porting Guide, board design and NXP board ports) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/port.md |
| SM-RN | NXP i.MX System Manager, `sm/doc/rn_cl.md` (2026Q3 change list) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/rn_cl.md |
| SM-DEBUG | NXP i.MX System Manager, `sm/doc/debug.md` (Debug Guide) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/debug.md |
| OPTEE-PORT | OP-TEE documentation, `architecture/porting_guidelines.rst` ("Power Management / PSCI") | `optee_docs` master at commit `ae74963`, 2026-11-04 | https://github.com/OP-TEE/optee_docs/blob/ae74963fa4e296815d7e4382a39769ed87622f1a/architecture/porting_guidelines.rst |
| TFA-IMX9 | Trusted Firmware-A documentation, `docs/plat/imx9.rst` (NXP i.MX 9 Series) | upstream master at commit `d70b52d`, 2026-11-12 | https://github.com/ARM-software/arm-trusted-firmware/blob/d70b52dedc4eba74386098a9033eec1e9cb522fa/docs/plat/imx9.rst |

Everything below is a summary in this repository's own words. No vendor text is
copied.

## 2. Low-power modes the System Manager controls

### 2.1 Who owns power management

- On the i.MX 95 the System Manager (SM) runs bare-metal on the Cortex-M33 in the
  always-on domain; the Cortex-A55 and Cortex-M7 are its clients and reach power,
  clock and reset only through SCMI over messaging units, because the TRDC blocks
  their direct access to that hardware (SM-ARCH, "Overview", "System View").
- The SM divides the SoC into logical machines (LMs). Boot, shutdown, reset,
  suspend and wake are per LM; an ordinary SCMI system call from an agent acts on
  its own LM, not on the whole SoC. Whole-SoC shutdown or reset is a separate,
  vendor-defined power state with restricted access (SM-ARCH, "Logical Machines").
- The SM aggregates the power states requested by the LMs into one system power
  state, and enters the low-power state from its idle loop (SM-ARCH, "SM
  Framework").
- The SM owns the DDR controller, PHY and PLL and handles them across power-state
  changes; and whenever a power domain ("mix") is powered up or reset, the SM
  reloads that mix's TRDC configuration through the EdgeLock Enclave (ELE)
  (SM-ARCH, "Physical Architecture").
- Security services do not pass through the SM: clients talk to the ELE (and V2X)
  directly (SM-ARCH, "SCFW versus SM").

### 2.2 The power states, from largest to smallest scope

The SM's debug-monitor command set (SM-MONITOR) is the most compact public list
of the power operations the SM implements; each command maps onto an LMM or
device function that clients reach through SCMI. Grouped by scope:

| Scope | States and operations | How a client asks |
|---|---|---|
| Whole SoC | Power off (optionally graceful), reset, reset into a chosen boot stage (primary, secondary, recovery, serial download) | Vendor-defined states of the SCMI System Power protocol, restricted to agents granted `SYS` (SM-ARCH, "Logical Machines") |
| System sleep | When every LM has suspended, the SM's idle loop puts the SoC into a configured system sleep mode, with mode and flags the SM holds (`ssm`, `idle`) | Indirect: each LM suspends itself; the system sleeps only when all are suspended (SM-MONITOR, SM-ARCH "SM Framework") |
| One LM | Boot, shut down (optionally graceful), reset with a reason, suspend, wake, power up | Its own agents through the SCMI System Power protocol; another LM's agents through the LMM protocol if granted `LMM_n` (SM-ARCH) |
| One power domain ("mix") | Off or on | SCMI Power protocol, per `PD_*` grant (SM-ARCH, "SM Framework") |
| One CPU | Start, hold, stop, boot vector; CPU low-power mode and the peripheral low-power interface (`PERLPI_*`) wake hooks | NXP CPU protocol, per `CPU_*`/`PERLPI_*` grant (SM-ARCH, SM-CONFIG) |

In Linux and TF-A terms: upstream TF-A builds BL31 for `PLAT=imx95` and boots
it after the SPL and before U-Boot and Linux (TFA-IMX9), and in the FRDM
configuration TF-A is the secure agent `AP-S` of the AP LM (SM-FRDM-CFG). So a
Linux `suspend-to-RAM` goes through PSCI to TF-A, which asks the SM to suspend
the LM; TFA-IMX9 itself says nothing about low power, so this path is read from
the agent grants, not from a TF-A document; the M7 does the
same for its own LM. The exact set of system sleep modes (which mixes, PLLs and
DDR self-refresh each one keeps) is defined in the SM's device code for the
i.MX 95 and in the i.MX 95 Reference Manual; neither was read for this survey
(see section 7).

## 3. Wake sources

### 3.1 The hardware rule

- Only a wake source whose IP stays powered can wake the system from a mode that
  turns its mix off. GPIO1 is the only GPIO block in the always-on mix; GPIO2-5
  are in the WAKEUP mix, so to turn the WAKEUP mix off every external wake signal
  has to arrive through GPIO1 (SM-PORT, "Board design" notes before the board
  ports).
- NXP's board pattern is to route PMIC interrupts and other wake signals to an
  I2C bus expander on the same always-on I2C bus as the PMIC, and the expander's
  interrupt to GPIO1, which the SM owns (SM-PORT, same section).
- Per-peripheral wake through the low-power interface (`PERLPI_*`: CAN, GPIO2-5,
  LPUARTs, WDOG3/4 on the AP) is a separate path, configured through the CPU
  protocol by the agent granted that resource (SM-CONFIG, SM-FRDM-CFG).

### 3.2 Wake sources on the FRDM LPDDR5 board port

The `mcimx95frdm` port (SM-PORT, "NXP i.MX95 FRDM") is for the i.MX 95 LPDDR5
15x15 FRDM board. The SM owns LPI2C1, GPIO1 and LPUART2. On LPI2C1 sit the PF09
and PF53 PMICs, a PCAL6408A bus expander and a PCA2131 RTC; their interrupts and
the board wake lines go to the expander, and its interrupt to GPIO1 pin 10. The
port exposes these board controls, each of which can notify on change and also
wake the system:

| Control | Wake line |
|---|---|
| `BRD_SM_CTRL_SD3_WAKE` | SD3 (expander pin 0) |
| `BRD_SM_CTRL_PCIE1_WAKE` | PCIe 1 (pin 4) |
| `BRD_SM_CTRL_UART_WAKE` | UART (pin 5) |
| `BRD_SM_CTRL_PCIE2_WAKE` | PCIe 2 (pin 6) |
| `BRD_SM_CTRL_BUTTON` | on/off button (pin 7) |
| `BRD_SM_RTC_PCA2131` / `BRD_SM_CTRL_PCA2131` | external RTC alarm |

Besides the board lines, the SM's own BBM protocol gives the on-chip BBNSM RTC
alarm and the on/off button as wake events (SM-ARCH, "SM Framework"; SM-FRDM-CFG
grants `RTC` and `BUTTON`).

In the shipped configuration (SM-FRDM-CFG) the four board wake controls are
granted to Linux (`AP-NS`) as notifications; the M7 gets the button notification
and full control of the PCA2131 RTC; Linux gets the on-chip RTC in full and the
PCA2131 RTC as privileged-only.

The port also keeps its shutdown record (fault and reset reason) in BBNSM
general-purpose registers GPR0-3 and advises that no agent be given access to
them (SM-PORT, "NXP i.MX95 FRDM").

**Not confirmed:** whether the owner's FRDM-IMX95-PRO is the LPDDR5 15x15 board
that `mx95frdm` targets. The SM release notes say the LPDDR4 FRDM board must use
the EVK configuration (`mx95evk`) because only the LPDDR5 board has the different
PMICs (SM-RN, SM-444). The board's own user manual (UM12527, in the private
references) would settle it; see question 1.

## 4. Secure state in each mode

The public sources say much less here than about modes and wake sources. What
they support, and what they leave open, per element:

| Element | LM suspend / system sleep (DDR kept) | Mix power-down | LM shutdown or reset, SoC reset |
|---|---|---|---|
| TRDC isolation (memory and peripheral firewalls, incl. the secure DDR carve-outs) | Kept while its mix is powered. | Lost with the mix; the SM rewrites it from the static configuration, through the ELE, every time a TRDC's mix powers up (SM-ARCH, "Physical Architecture"; SM-DEBUG, "Hardware Access Issues"). | Rewritten at boot from the same static configuration. |
| Other mix registers | Kept. | Lost; restored only by the per-mix sequences in `config_user.h` or by the owning client (SM-CONFIG, "User"). | Reset. |
| EdgeLock Enclave key store and session state | **Not confirmed.** The SM does not route security services; clients talk to the ELE directly (SM-ARCH, "SCFW versus SM"), so what the ELE keeps across a system sleep is the ELE's behaviour, documented in the ELE API manual and the i.MX 95 Security Reference Manual, not in public sources. | **Not confirmed.** | **Not confirmed** whether volatile key slots survive; a reset is expected to clear them, but no public source read here states it. |
| OP-TEE secure memory | Lives in DDR (the `AP-S` section of SM-FRDM-CFG grants the secure A55 world a DDR range); its content survives only if the system sleep mode keeps DDR in self-refresh, which is **not confirmed** for each i.MX 95 sleep mode. | Unaffected unless the DDR mix is powered down. | Lost. |
| OP-TEE CPU and secure-IP state | OP-TEE's generic platform template stubs the CPU suspend, resume and system-off hooks; a production platform must itself save and restore CPU state, secure IP registers and memory-firewall settings (OPTEE-PORT, "Power Management / PSCI"). Whether OP-TEE's i.MX 95 platform does this was **not confirmed** (its source was not read). | — | — |
| Cortex-M7 | Its LM suspends and wakes independently of the AP LM (SM-ARCH, "Logical Machines"). | `PD_M7` is the M7's own domain; powering it off loses TCM content. | The M7 LM can be reset or rebooted by the SM on its faults (`lm_reset` on lockup, reset and WDOG5 in SM-FRDM-CFG) or by any agent granted `LMM_1`. |

**Re-authentication on wake.** No public source read here says that the device
re-authenticates any image when it resumes from suspend; resume continues from
the code already in memory. The SM architecture notes that the TRDC configuration
can change depending on a client's state and on whether its code is being
reloaded and authenticated (SM-ARCH, "Physical Architecture"), which suggests the
LM boot path (not the resume path) runs through the ELE. That an LM *boot* after
shutdown or reset re-authenticates the image from the boot container is a
reasonable reading but is **not confirmed** by a public source. The SM's own
debug guide leaves its suspend/resume section empty at this tag (SM-DEBUG,
"Suspend/Resume Debug").

Consequence for the design: anything that must not survive in DDR across a
suspend (keys in OP-TEE or Linux memory, session secrets) is only protected by
the TRDC carve-outs and by the fact that DDR is not readable while the SoC
sleeps. Physical attacks on DDR during a long sleep are outside what these
sources address.

## 5. What a secure deployment should allow

These are this survey's proposals, each tied to the source that supports it. None
is decided until the owner answers section 8.

1. **Only the secure worlds may change the system power state.** Keep Linux
   (`AP-NS`) at `SYS NOTIFY`, as the reference file already does, so that every
   AP suspend or shutdown passes through TF-A (SM-FRDM-CFG, SM-CONFIG). Give the
   M7 `SYS ALL` only if `hsm-self-defence` needs it to shut the SoC down on
   tamper; otherwise reduce it.
2. **Restrict cross-LM control to the tamper path.** `LMM_2 ALL` lets the M7
   reset or power off the AP LM, which the SPEC's `hsm-self-defence` row needs.
   The reverse grant (`LMM_1`) should stay notify-only for Linux, as shipped, so
   the A55 normal world cannot stop or reboot the M7 (SM-FRDM-CFG).
3. **Allow LM suspend, not mix power-down, as the default low-power mode**, until
   the ELE's behaviour across power-down is confirmed. A suspend with DDR in
   self-refresh keeps OP-TEE and TRDC state; a mix power-down relies on the SM
   rewriting TRDC through the ELE and on correct register restore (SM-ARCH,
   SM-CONFIG). Whole-SoC shutdown stays available for tamper response.
4. **Keep wake sources to the ones the product uses**, and keep each in the LM
   that owns it. On this board every external wake line comes through the
   SM-owned expander on GPIO1 (SM-PORT), so a wake source is enabled by granting
   its `BRD_SM_CTRL_*_WAKE` control to an agent, and disabled by not granting it.
   For an HSM, the candidates are the on/off button, the RTC alarm and the network
   (PCIe or Ethernet). The UART and SD3 wake lines serve debug and removable
   media and have no HSM use; drop them.
5. **No debug monitor and no test code in production.** The SM debug monitor
   can suspend, wake, shut down and reset any LM, write memory and read or write
   fuses from its UART; NXP states it is not for production and that test code
   must be compiled out with `M=0` (SM-MONITOR, SM-DEV, SM-RN SM-399).
6. **Keep the shutdown record private.** BBNSM GPR0-3 hold the SM's fault and
   reset record and should not be granted to any agent (SM-PORT).
7. **Fault reactions should fail closed.** A DRAM or NoC fault already resets
   the system in the reference file; the M7 faults reset only the M7 LM. Whether
   an M7 fault should instead reset or shut down the whole SoC, since the M7
   carries the tamper response, is a question for the owner (SM-FRDM-CFG).
8. **Disable auto-boot on events that an attacker can cause.** The `auto=` key
   can boot an LM on a button press (SM-CONFIG); the reference file does not set
   it, and a deployment should keep it unset unless the owner wants power-on by
   button.

## 6. How the board configuration restricts modes and wake sources

### 6.1 The shipped FRDM configuration

NXP's SM tree has a configuration for the 15x15 FRDM-IMX95, `configs/mx95frdm.cfg`
(SM-FRDM-CFG). It is **not this device's**: the 19x19 FRDM-IMX95-PRO uses
`configs/other/mx95frdm-pro.cfg` with the EVK board port
(`public-source-survey.md` items 11-16). The table below is reference only;
every PRO grant it does not share with that survey is unconfirmed. It is a tool input: `configtool.pl` turns it into the
`configs/mx95frdm/*.h` headers compiled into the SM, so access rights are fixed
at build time and cannot be changed by a client at run time (SM-ARCH, "System
View"). What it grants, read at tag `rel_imx_sm_2026q3`:

| LM | Agent(s) | Power-related rights granted |
|---|---|---|
| LM0 "SM" (Cortex-M33) | none (no RPC) | Owns GPC, CCM, SRC, BBNSM, DDR controller/PHY/PLL, ELE MU0, FCCU, both SM watchdogs. Fault reactions: system reset for DRAM and NoC faults. |
| LM1 "M7" | `M7` (MU 9, CRC-checked channels) | Full System protocol (`SYS ALL`), full control of LM2 the AP (`LMM_2 ALL`), FuSa protocol, the board PMIC-RTC and button notifications. Its own power domain `PD_M7` is only exposed with the `test` flag. Fault reactions: M7 lockup, M7 reset, WDOG5 → reset of the M7 LM. |
| LM2 "AP" (Cortex-A55), secure agent `AP-S` (MU 1) | TF-A / secure world | Full System protocol (`SYS ALL`), A55 performance (DVFS) and the low-power-interface (`PERLPI_*`) wake hooks of the CAN, GPIO, LPUART and WDOG3/4 peripherals. |
| LM2 "AP", non-secure agent `AP-NS` (MU 3) | Linux | System protocol **notifications only** (`SYS NOTIFY`), LM1 notifications only (`LMM_1 NOTIFY`), RTC and button (both marked `test`), and board wake notifications for UART, PCIe 1/2 and SD3 wake pins. |

Points that matter for security:

- In the shipped file the non-secure Linux agent cannot itself set a system power
  state; system suspend and shutdown requests from Linux must go through the
  secure agent, which in practice is TF-A's PSCI (SM-FRDM-CFG, LM2 sections).
- The M7 LM may boot, reset, power off and (per the LMM protocol) control the AP
  LM, and has full System protocol rights. This matches the SPEC's plan that the
  M7 acts on the system for `hsm-self-defence`, but it also means a compromised
  M7 can put the whole board into any power state the SM supports.
- Several grants carry the `test` key (button and RTC for Linux, `PD_M7`). In the
  configtool syntax this only marks the resource as a target of the SM's own SCMI
  unit tests; it does not restrict or widen the grant (SM-CONFIG, "Configtool
  Resources"). The file is NXP's reference configuration for the evaluation
  board, not a hardened one.

### 6.2 The levers a deployment configuration has

All of these are build-time settings in the board's `.cfg` (SM-CONFIG,
"Configtool Commands", "Configtool Resources"):

- **`SYS` per agent** sets the agent's rights on the SCMI System Power protocol
  (shutdown, reset, suspend and the vendor whole-SoC states). Granting `NOTIFY`
  instead of `ALL` leaves the agent able to hear about power-state changes but not
  to request them, as the FRDM file already does for Linux.
- **`LMM_n` per agent** sets the agent's rights over another LM through the LMM
  protocol (boot, reset, shut down, and notifications).
- **`PD_*`, `CPU_*`, `PERLPI_*` per agent** decide which power domains, CPU
  low-power settings and peripheral low-power-interface wake hooks an agent may
  touch. An agent that is not listed for a resource has no API access to it.
- **`BRD_SM_CTRL_*_WAKE` and `BUTTON`** decide which agents receive board wake
  and button events; **`auto=`** on an `LMn` line can make an LM boot on an event
  such as the button.
- **`FAULT_* reaction=`** sets what the SM does on a fault (reset or shut down the
  system or an LM, hand it to FuSa, or nothing).
- **`start=`/`stop=`** on power-domain and voltage lines fix the order in which
  the SM powers an LM's domains up and down when that LM boots or stops.
- **`MBC`/`MRC` memory and peripheral permissions per domain ID** set the TRDC
  isolation; the SM reapplies them, through the ELE, whenever a mix powers up
  again (SM-ARCH, "Physical Architecture").
- Per-mix register restore sequences and functions in `config_user.h` run when a
  mix powers up after losing state (SM-CONFIG, "User"). Anything a deployment
  sets in a mix's registers that is not restored here, or by the owning client,
  is lost across a power-down of that mix.

## 7. Not confirmed

Things this survey could not confirm from public sources, and the source that
would settle each:

- **The list of i.MX 95 system sleep modes** and what each keeps (mixes, PLLs,
  DDR self-refresh, oscillators). Defined in the SM's i.MX 95 device code
  (`devices/MIMX95/sm/dev_sm_system.c`, not read: the lane may not read source
  code outside its repository) and in the i.MX 95 Reference Manual (IMX95RM),
  which this repository lists as missing.
- **The ELE's behaviour across suspend, mix power-down and reset**: which key
  store contents are volatile, whether sessions must be reopened, and whether the
  ELE re-checks anything on wake. Needs the ELE API reference (RM00284, private
  references) and the i.MX 95 Security Reference Manual (missing).
- **Re-authentication of images on resume** versus on LM boot. Not stated in any
  public source read.
- **OP-TEE's i.MX 95 suspend handling** (its `plat-imx` code was not read) and
  **TF-A's i.MX 95 PSCI suspend handling** (NXP's `imx-atf` fork and upstream
  `plat/imx/imx95` code were not read; TFA-IMX9 covers only the build).
- **The Linux binding for the i.MX 95 SCMI vendor protocols**
  (`Documentation/devicetree/bindings/firmware/nxp,imx95-scmi.yaml`) was fetched
  but could not be read under the lane's rules on code files.
- **Which SM configuration fits the owner's FRDM-IMX95-PRO** (`mx95frdm` for the
  LPDDR5 15x15 board, or `mx95evk` for the LPDDR4 board) (SM-RN, SM-444).
- **What the SM's alternative configuration tool, SMCT
  (https://github.com/nxp-imx/imx-smct), adds**; not surveyed.

Unreachable sources: none. Every public URL tried was reachable; the gaps above
come from documents that are not public or from code the lane was not allowed to
read.

## 8. Questions for the owner

1. **Which SM board configuration is the base for this board?**
   Options: (a) `mx95frdm` (LPDDR5 15x15 FRDM); (b) `mx95evk` (LPDDR4 FRDM,
   which the SM treats as EVK-compatible); (c) a new file copied from one of
   them. Recommendation: (c), copied from whichever of (a) or (b) matches the
   board's memory and PMICs per UM12527, since NXP's files are reference
   configurations and the SM docs advise copying one for a new configuration
   (SM-DEV, SM-RN SM-444).
2. **Which low-power modes may the product use?**
   Options: (a) none: the board runs or is off; (b) LM suspend with DDR kept
   (suspend-to-RAM), no mix power-down beyond what suspend does; (c) all modes
   the SM supports, including deep sleep with mixes off. Recommendation: (a) for
   an always-on HSM, or (b) if power saving is required; not (c) until the ELE's
   behaviour across power-down is confirmed (section 4, section 7).
3. **Which agents may set the system power state?**
   Options: (a) TF-A (`AP-S`) and the M7, as shipped; (b) TF-A only, the M7
   notify-only; (c) the M7 only, TF-A notify-only. Recommendation: (a), because
   the M7 needs whole-SoC shutdown for `hsm-self-defence` and Linux is already
   notify-only (section 5, items 1 and 2).
4. **Which wake sources are allowed?**
   Options: (a) on/off button only; (b) button and RTC alarm; (c) button, RTC
   and network (PCIe or Ethernet wake); (d) all board wake lines, as shipped
   (adds UART and SD3). Recommendation: (b) if low power is allowed at all;
   network wake only if remote wake is a product requirement, since it lets a
   remote party change the device's power state (section 3, section 5 item 4).
5. **What happens when the M7, which carries the tamper response, faults?**
   Options: (a) reset the M7 LM only, as shipped; (b) reset the whole SoC; (c)
   shut the SoC down. No public source supports one option over another; the
   choice depends on whether an M7 fault is treated as a possible attack. This
   survey leans to (b), so that the tamper path is never silently absent.
6. **Must secrets be cleared from DDR before suspend?**
   Options: (a) no, rely on the TRDC carve-outs while asleep; (b) yes, the
   secure world wipes session keys and re-derives them from the ELE on resume;
   (c) forbid suspend (question 2 (a)). Recommendation: none until the ELE's
   behaviour is confirmed (section 7); (c) is the safe default.
7. **Should the deployment configuration be built with the SM's configtool or
   with NXP's SMCT?** Options: (a) configtool, in the SM tree; (b) SMCT.
   Recommendation: (a), the only one surveyed here; SMCT was not surveyed.
