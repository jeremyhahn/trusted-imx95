# System Manager watchdog and fault recovery: survey

Row: `system-manager-config` ([SPEC](../SPEC.md)). Issue #98. Documentation only.

Status: draft survey for the owner. Public sources only. Nothing here was
built, flashed or run on a board; every statement is read from the source
tree and its bundled documentation at the tag given below.

## 1. Scope and method

The survey answers three questions for the NXP FRDM-IMX95-PRO:

1. How NXP's System Manager (SM), running on the Cortex-M33, handles
   watchdogs, faults and resets per logical machine (LM), what it does when
   the Cortex-M7 or the Cortex-A55 hangs or faults, and which reset reasons it
   records.
2. Which board configuration options choose those policies, and which a
   secure deployment should set.
3. How a tamper or fault response on the Cortex-M7 (trusted-firmware) reaches
   the SM, and what belongs to other repositories.

Method: the public `nxp-imx/imx-sm` repository was cloned at one release
tag and its documentation (`sm/doc/*.md`), the i.MX 95 FRDM configuration
(`configs/mx95frdm.cfg`) and the headers that define reactions and reset
reasons were read. All descriptions below are summaries in this
repository's words; no vendor text is copied. File references are to paths
inside that tag.

## 2. Sources surveyed

| # | Title | Version / tag | URL | Reached |
|---|-------|---------------|-----|---------|
| S1 | NXP i.MX System Manager source, `nxp-imx/imx-sm` | `rel_imx_sm_2026q3` (latest tag at the time of the survey, 2026-11-12) | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3 | yes |
| S2 | SM architecture guide, `sm/doc/arch.md` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md | yes |
| S3 | SM configuration guide, `sm/doc/config.md` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md | yes |
| S4 | SM implementation notes, `sm/doc/imp.md` (in S1), section "Example Fault Flow" | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/imp.md | yes |
| S5 | SM debug guide, `sm/doc/debug.md` (in S1), reset records and i.MX 95 fault table | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/debug.md | yes |
| S6 | i.MX 95 FRDM board configuration, `configs/mx95frdm.cfg` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg | yes |
| S7 | LMM reaction definitions, `sm/lmm/lmm_sys.h` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/lmm/lmm_sys.h | yes |
| S8 | i.MX 95 reset reasons, `devices/MIMX95/sm/dev_sm_system.h` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/devices/MIMX95/sm/dev_sm_system.h | yes |

Sources that this survey needed but did not reach are listed in section 9.

## 3. Logical machines and the SM's role

The SM partitions the SoC into logical machines. Each LM has a boot order, a
domain ID, a safety type and a list of resources it owns; the SM is the only
software that may reset or power them (S2, S3).

The FRDM configuration (S6) defines three LMs:

| LM | Name | Runs on | Boot | Safety type (`safe=`) | RPC |
|----|------|---------|------|-----------------------|-----|
| LM0 | SM | Cortex-M33 | first | F-EENV (`safe=feenv`) | none |
| LM1 | M7 | Cortex-M7 | second, `skip=1` | S-EENV (`safe=seenv`) | SCMI |
| LM2 | AP | Cortex-A55 (secure and non-secure agents) | third, `skip=1` | default (N-EENV; S3 says the default safety type is non-safe) | SCMI |

`skip=1` means a missing image for that LM in the boot container is not an
error (S3). In the FRDM file the M7 LM is the *safe* execution environment
(S-EENV): it is the LM that the SM notifies of faults whose reaction is
`fusa` (S3, S6).

## 4. Watchdogs

The i.MX 95 has watchdogs WDOG1 to WDOG5 that the SM knows by name (S5, S8).
In the FRDM configuration (S6) they are assigned as follows:

| Watchdog | Owner LM (S6) | Use as read from S5 and S6 |
|----------|---------------|----------------------------|
| WDOG1, WDOG2 | LM0 (SM) | The SM's own watchdogs. S5 lists WDOG1/WDOG2 interrupts as M33 exceptions, and a WDOG2 timeout as FCCU fault 18 with the M33 PC as syndrome. |
| WDOG5 | LM1 (M7) | M7 watchdog. Timeout is FCCU fault 21; FRDM reaction `lm_reset` of LM1. |
| WDOG3, WDOG4 | LM2 (AP) | A55 watchdogs. Timeouts are FCCU faults 19 and 20; FRDM reaction `lm_reset` of LM2. |

So a hung Cortex-M7 that stops feeding WDOG5, or a hung Cortex-A55 that
stops feeding WDOG3/WDOG4, does not reset the whole chip under the FRDM
configuration: the watchdog timeout is routed as an FCCU fault to the SM,
which resets only the owning LM (S5, S6). This holds only if the software
on that core actually arms its watchdog; the SM configuration assigns the
watchdog but whether the M7 firmware or Linux starts it is the business of
those images (see section 8).

Not confirmed: how often and from where the SM services WDOG1/WDOG2, and the
timeout values; see section 9.

## 5. Faults and resets per logical machine

### 5.1 The fault path

Read from S2 and S4, a fault is handled as follows:

1. The hardware fault collection unit (FCCU) raises an interrupt to the
   Cortex-M33. The SM uses NXP's eMCEM component (the FCCU driver) for this
   even when it is not built as a functional-safety SM (S2).
2. The eMCEM handler records a reset record and hands the fault to the
   device layer, which hands it to the LM manager (LMM) (S4).
3. The LMM looks up the reaction configured for that fault, lets the board
   port record or print it, lets the FuSa component send notifications or
   override the reaction, and then performs the reaction (S4).
4. If the SM marks the fault recovered, the FCCU interrupt is re-armed. If it
   does not, the FCCU starts its own timer and, when it expires, applies the
   *delayed* reaction, a system reset; S3 gives the period as about 300 ms on
   i.MX 95 (S3, S4).

Step 4 is a hardware backstop: a fault that the SM itself cannot handle
(for example because the M33 is hung) still ends in a system reset.

### 5.2 Reactions

The SM's reaction to each fault is one of the following (S3, S7):
system reset, system shutdown, LM-group reset, LM-group shutdown, LM reset,
LM shutdown, custom board handling (`BRD_SM_CustomFault()`), FuSa
notification only (the S-EENV must clear the fault through the SCMI FuSa
protocol), or none. Every reaction also sends FuSa fault notifications when
the fault is set and cleared (S3).

### 5.3 Per-LM behaviour in the FRDM configuration

From S6 (`FAULT_*` lines, each listed under the LM that owns it):

| Fault | Owner LM | Reaction | Effect |
|-------|----------|----------|--------|
| `FAULT_M7_LOCKUP` | M7 | `lm_reset` | A Cortex-M7 lockup resets the M7 LM only. |
| `FAULT_M7_RESET` | M7 | `lm_reset` | A Cortex-M7 software reset request resets the M7 LM only. |
| `FAULT_WDOG5` | M7 | `lm_reset` | M7 watchdog timeout resets the M7 LM. |
| `FAULT_SW0` | M7 | `fusa` | Software fault 0: notification to the S-EENV, which must clear it. |
| `FAULT_SW1` | M7 | `lm_reset` | Software fault 1 resets the M7 LM. |
| `FAULT_WDOG3`, `FAULT_WDOG4` | AP | `lm_reset` | A55 watchdog timeout resets the AP LM. |
| `FAULT_SW2` | AP | `lm_reset` | Software fault 2 resets the AP LM. |
| `FAULT_SW3` | SM | `grp_reset` | Software fault 3 resets an LM group. |
| `FAULT_SW4` | SM | `sys_reset` | Software fault 4 resets the system. |
| `FAULT_DRAM` | SM | `sys_reset` | DDR multi-bit ECC error resets the system. |
| `FAULT_MAIN_NOC`, `FAULT_MEGA_NOC`, `FAULT_CENTRAL_NOC` | SM | `sys_reset` | Interconnect mission faults reset the system. |

A fault of the SM itself (a Cortex-M33 exception, lockup, or WDOG1/WDOG2
expiry) always ends in a reset; S5 states that exceptions always reset.

Not confirmed: what an A55 *lockup* (as opposed to a watchdog timeout) does
on i.MX 95. S5's i.MX 95 tables list M7 lockup and reset request but no
A55 lockup entry; see section 9.

## 6. Reset reasons recorded

S8 defines the i.MX 95 reset reasons the SM can report. In summary:
power-on reset; Cortex-M33 lockup, software request or exception;
Cortex-M7 lockup or software request; FCCU (with the fault ID as error ID);
JTAG and JTAG software reset; EdgeLock secure enclave (ELE) reset;
temperature sensor panic; WDOG1 to WDOG5; battery-backed module boot or
shutdown (button or RTC); a software-requested reset (with the requesting
agent); an SM error or exit (with the error status); a FuSa global recovery;
and a PMIC fault.

S5 describes how each event is written to a *reset record* with a
reaction (boot, shutdown, reset), the reason, an optional error ID, optional
extended syndrome words and the LM that caused it. Two limits matter for a
secure deployment (S5):

- Resets that go straight to the reset controller cannot save any extra
  information, and the record is lost if the reset controller loses power.
- ELE-originated resets (abort, glitch, voltage or frequency detectors) are
  recorded as ELE group faults, but the syndrome does not tell those causes
  apart.

The record is saved by a board-port function, so where it is stored is
board-specific (S5); see section 9.

## 7. Board configuration options that choose the policy

All of the following are lines in the board's `.cfg` file, processed by
the SM's configtool into C headers (S3), except the FCCU setup, which is a
C source file.

| Option | Where | What it chooses | Source |
|--------|-------|-----------------|--------|
| `LMn ... safe=` | LM line | Safety type of the LM: F-EENV, S-EENV or N-EENV (default). The S-EENV receives `fusa` fault notifications. | S3, S6 |
| `LMn ... boot=`, `skip=` | LM line | Boot order, and whether a missing image is tolerated. | S3, S6 |
| `MODE msel=..., boot=` | LM section | Per boot mode (mSel) boot behaviour. | S3, S6 |
| `FAULT_<name> OWNER, reaction=<r>[, lm=<n>]` | LM section | The reaction to one FCCU fault and the LM it acts on (defaults to the LM it is listed under). | S3, S6 |
| `WDOGn OWNER` | LM section | Which LM owns a watchdog instance. | S6 |
| `eMcem_Cfg.c` (copied into the board's config directory) | C source | Which FCCU faults are enabled, and the immediate and delayed hardware reactions for each; not set by the configtool. | S3 |
| `BRD_SM_CustomFault()`, `BRD_SM_ShutdownRecordSave()` | board port C code | Custom reaction and where reset records are stored. | S3, S5 |

What a secure deployment should set is the owner's decision (section 10);
the survey's reading of the sources is:

- Keep hardware and interconnect faults (`FAULT_DRAM`, NoC faults) on
  `sys_reset`, as the FRDM file does: an LM-level reset cannot be trusted to
  clean up a shared bus or memory fault.
- Keep the M7 as the only S-EENV, so that only the trusted firmware receives
  and clears `fusa` faults.
- Keep the M7 and A55 watchdog faults on `lm_reset` only if the M7 must keep
  running while Linux restarts; if a hung M7 is itself a security event,
  `sys_reset` or `lm_shutdown` is the stricter choice.
- Keep the FCCU delayed reaction (system reset) enabled, so that an SM that
  cannot handle a fault still resets the chip.
