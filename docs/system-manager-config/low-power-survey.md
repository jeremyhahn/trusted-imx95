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

In Linux and TF-A terms: Linux `suspend-to-RAM` goes through PSCI to TF-A, which
as the secure agent of the AP LM asks the SM to suspend the LM; the M7 does the
same for its own LM. The exact set of system sleep modes (which mixes, PLLs and
DDR self-refresh each one keeps) is defined in the SM's device code for the
i.MX 95 and in the i.MX 95 Reference Manual; neither was read for this survey
(see section 7).

## 3. Wake sources

(to be filled)

## 4. Secure state in each mode

(to be filled)

## 5. What a secure deployment should allow

(to be filled)

## 6. How the board configuration restricts modes and wake sources

### 6.1 The shipped FRDM configuration

NXP's SM tree has a configuration for this board, `configs/mx95frdm.cfg`
(SM-FRDM-CFG). It is a tool input: `configtool.pl` turns it into the
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

(to be filled)

## 8. Questions for the owner

(to be filled)
