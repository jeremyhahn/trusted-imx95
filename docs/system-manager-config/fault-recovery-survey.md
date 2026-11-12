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
reasons were read. `mx95frdm.cfg` is the 15x15 FRDM, **not this device**:
the 19x19 FRDM-IMX95-PRO uses `configs/other/mx95frdm-pro.cfg` with the
EVK board port, and that file lacks the NoC fault entries
(`public-source-survey.md` items 11-16). Every "FRDM file" or "FRDM
configuration" value below is **reference only**; the PRO value is
unconfirmed unless that survey states it. All descriptions below are summaries in this
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
| S9 | SM SCMI protocol reference, `sm/rpc/scmi/proto.md` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/rpc/scmi/proto.md | yes |
| S10 | FRDM board low-level code, `boards/mcimx95frdm/board.c` and `board.h` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3/boards/mcimx95frdm | yes |
| S11 | FRDM SM board port, `boards/mcimx95frdm/sm/brd_sm.c` (in S1) | same tag | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/boards/mcimx95frdm/sm/brd_sm.c | yes |

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

The SM's own watchdog on the FRDM board port is WDOG2 (S10):

- It is clocked from the 32 kHz low-power clock with a timeout of about two
  seconds (S10).
- The SM refreshes it from its periodic board timer tick (S11), so a hung SM
  stops refreshing it.
- During SM start-up it resets the chip directly; once the board port has
  finished initialising, it is switched to raise an FCCU fault instead
  (S11), which gives the SM a chance to record the event (fault 18 in S5)
  before the FCCU's delayed reaction resets the system.
- In debug-monitor or test builds, the board port turns the watchdog off when
  the SM exits (S11). Production builds instead report a system error
  (S11). A secure deployment must not ship a monitor or test build.

The same start-up code also stops the analogue temperature sensor from
issuing its own warm reset, so that over-temperature is handled as an FCCU
fault (S11; fault 0 in S5).

Not confirmed: the WDOG3, WDOG4 and WDOG5 timeouts. They are set by the
software on the A55 and M7, not by the SM, and were not surveyed.

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

Step 4 is a hardware backstop, but only for a fault that has reached the
FCCU: such a fault that the SM itself cannot handle (for example because the
M33 is hung) still ends in a system reset. It does not cover an SCMI request
that the SM never services. A software fault set over the FuSa SCMI protocol
(section 8) exists only once the SM has accepted the request; whether an
accepted software fault is then raised through the FCCU, and so gets the
delayed reaction, is **not confirmed** by the sources read. A request that is
pending or unacknowledged raises no fault at all, so the FCCU timer never
starts.

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
board-specific (S5). The FRDM board port keeps it in the first four
general-purpose registers of the battery-backed non-secure module (BBNSM),
and clears it when it is read back at the next boot (S11). It therefore
survives a reset but not a loss of the battery-backed supply, and it sits in
a *non-secure* module (see question 5).

LMs can read the reasons back over SCMI: the LMM protocol has a per-LM reset
reason query and an LM event notification, and the Misc protocol has a
system reset reason query (S9).

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
- Ship a production SM build, not a debug-monitor or test build (S11:
  those builds turn the SM watchdog off on exit).

## 8. Path from a Cortex-M7 tamper or fault response to the System Manager

The M7 talks to the SM only through SCMI over a messaging unit. In the FRDM
configuration the M7 is SCMI agent 0, on its own messaging unit at high
priority, with a command channel, a notification channel and a priority
channel, all with a CRC32 check (S6).

The SCMI permissions the FRDM file grants the M7 decide what a tamper
response on the M7 can ask the SM to do (S6, S9):

| M7 wants to | SCMI request (S9) | FRDM grant to the M7 (S6) |
|-------------|-------------------|---------------------------|
| Raise or clear a software fault, so that the SM applies its configured reaction (for example `FAULT_SW4` resets the system, `FAULT_SW3` resets an LM group) | FuSa protocol, fault set | `FUSA ALL` |
| Reset, shut down or boot the Cortex-A55 LM | LMM protocol, reset, shutdown, boot (privileged) | `LMM_2 ALL` |
| Reset or power off the whole system | System power protocol | `SYS ALL` |
| Power off a power domain or peripheral it owns | Power and clock protocols | only resources listed as owned by LM1 |
| Read why an LM or the system last reset | LMM reset reason, Misc reset reason | `LMM_2 ALL` covers the A55 LM; the rule for its own LM and for Misc was not confirmed |

The secure A55 agent (AP-S, normally TF-A) is also granted `SYS ALL`, so it
can reset or power off the whole system too. The non-secure A55 agent
(Linux) gets only notifications of M7 LM state and system power state
(S6).

Two routes therefore exist, and the owner should pick one (question 3):

1. **Software fault route.** The M7 sets one of the software faults it owns
   through the FuSa protocol; the SM applies the reaction the board
   configuration lists for that fault. The policy lives in this repository's
   configuration, and the M7 only states *that* something happened. The
   fault exists only once the SM accepts the request; an unacknowledged
   request raises nothing and starts no FCCU timer (section 5.1, question 3).
2. **Direct command route.** The M7 issues LMM or system power requests
   itself (shut down the A55 LM, power off domains, reset the system). The
   policy lives in the M7 firmware.

What belongs where:

| Piece | Repository |
|-------|------------|
| SM board configuration (`.cfg`), FCCU setup (`eMcem_Cfg.c`), board-port reactions (`BRD_SM_CustomFault()`) | this repository, row `system-manager-config` |
| Tamper detection, decision and SCMI calls on the M7 | trusted-firmware, `imx95` and `hsm-self-defence` rows (not surveyed here) |
| Key zeroisation in the EdgeLock secure enclave | not the SM: the M7 owns its own ELE messaging unit in the FRDM file (`MU_ELE5`, S6); the request goes from the M7 to the ELE directly. This repository's `secure-key-handling` and `hsm-self-defence` rows. |
| Linux-side watchdog driver and reaction to LM events | not surveyed; owner of the A55 software |

Not confirmed: which SCMI client the trusted-firmware M7 image uses, and
whether it already calls the FuSa protocol; that repository was not read.

## 9. What could not be confirmed

- **NXP i.MX 95 Reference Manual (IMX95RM)** and the **i.MX 95 Security
  Reference Manual**: not public without an NXP account, so not reached. They
  are needed for the full FCCU fault list, the reset controller (SRC)
  behaviour, the watchdog-to-FCCU routing and the tamper pins. SPEC already
  lists them as missing.
- **NXP *System Manager User Guide* PDF** published with each Linux BSP
  release: not reached from this lane; the in-tree `sm/doc` files (S2 to S5)
  were used instead. Whether they match the PDF for the BSP the board ships
  with is not confirmed.
- **Which imx-sm tag the board's BSP ships.** The survey read
  `rel_imx_sm_2026q3`; the tag in the delivered boot image was not checked.
- **A55 lockup.** No i.MX 95 A55 lockup entry was found in S5 or S8; how an
  A55 lockup without a watchdog is detected is not confirmed.
- **Default `eMcem_Cfg.c` contents for i.MX 95.** S5 lists the faults the
  non-FuSa SM enables; the C file itself (immediate and delayed reaction
  signals per fault) was not read.
- **FuSa SM build.** The SAF/FuSa features beyond notifications are
  described by S2 as out of scope of the public docs; not surveyed.
- **WDOG3/4/5 timeouts and whether the M7 and Linux images arm them.**
- **trusted-firmware's M7 SCMI client** (section 8).

## 10. Questions for the owner

1. **Reaction to a Cortex-M7 hang or lockup** (`FAULT_M7_LOCKUP`,
   `FAULT_M7_RESET`, `FAULT_WDOG5`).
   Options: (a) `lm_reset` as in the FRDM file, the M7 restarts alone;
   (b) `lm_shutdown`, the M7 stays off until the next boot;
   (c) `sys_reset`, the whole board restarts.
   Recommendation: (c) `sys_reset`. In this design the M7 runs the trusted
   firmware and the tamper response; restarting it alone leaves the A55
   running with no supervisor while it comes back (S3, S6). The sources do not
   settle it: it depends on whether a hung M7 counts as a security event.

2. **Reaction to a Cortex-A55 watchdog timeout** (`FAULT_WDOG3`,
   `FAULT_WDOG4`).
   Options: (a) `lm_reset` as in the FRDM file; (b) `lm_shutdown`;
   (c) `fusa`, so the M7 decides.
   Recommendation: (a) `lm_reset`. The M7 keeps running and is notified, and
   the reset reason stays readable over SCMI (S3, S9).

3. **How the M7 tamper response reaches the SM.**
   Options: (a) software fault route: the M7 sets a software fault and the
   reaction is in this repository's configuration; (b) direct command
   route: the M7 issues LMM and system power requests; (c) both, with (a) as
   the last resort.
   Recommendation: (c), **not yet fully supported**. Use (a) for the final
   reaction, because it is declarative and reviewable here; use (b) for the
   staged steps (power off the A55 LM and the PHYs) before it. Both routes are
   SCMI requests the SM must service. The FCCU's delayed system reset (S3, S4)
   covers a fault the FCCU has accepted, not a request the SM never
   acknowledges (section 5.1). One partial backstop is sourced: if the SM is
   hung, it stops refreshing its WDOG2, whose timeout becomes FCCU fault 18
   and then the delayed system reset (S5, S10, S11, section 4). Nothing read
   covers an SM that is alive but does not service the request (for example a
   stalled messaging unit or a dropped message). An independently triggered
   reaction for that case, such as the M7 escalating on a missing
   acknowledgement through a hardware path that does not depend on the SM, is
   **unresolved**: no source read names one. The tamper-shutdown requirement
   stands; this route does not yet meet it under that failure, and the owner
   must not treat it as complete until such a reaction is named with its
   source.

4. **SCMI permissions of the secure A55 agent.** The FRDM file grants AP-S
   `SYS ALL` (S6).
   Options: (a) keep it; (b) reduce it to notifications, so that only the
   M7 and the SM can reset or power off the system.
   Recommendation: none from the sources. (b) narrows who can reset the board,
   but TF-A's PSCI system reset and power-off on the A55 depend on it. The
   owner should confirm what TF-A needs.

5. **Where reset records are kept.** The FRDM port uses BBNSM general-purpose
   registers (S11).
   Options: (a) keep them there; (b) also forward each record to the M7 over
   SCMI and keep a signed log in trusted-firmware; (c) move them to secure
   storage in a custom board port.
   Recommendation: (b). It needs no change to the SM, and the record
   survives in the trusted firmware's log even if the BBNSM is cleared.
   Whether BBNSM GPRs can be written by non-secure software is not
   confirmed (section 9).

6. **Which software faults the M7 owns, and their reactions.** The FRDM file
   gives the M7 `FAULT_SW0` (`fusa`) and `FAULT_SW1` (`lm_reset`), and leaves
   `FAULT_SW3` (`grp_reset`) and `FAULT_SW4` (`sys_reset`) to the SM (S6).
   Options: (a) keep them; (b) assign one software fault to the M7 per tamper
   severity, for example LM shutdown of the A55, system shutdown, and system
   reset.
   Recommendation: (b), with the mapping agreed with trusted-firmware's
   `hsm-self-defence` row.

7. **Which imx-sm release to pin.**
   Options: (a) the tag in the NXP BSP the board ships with; (b) the latest
   tag at the time of build (`rel_imx_sm_2026q3` at this survey).
   Recommendation: (a). It keeps the SM consistent with the vendor's tested
   BSP, and it means checking each FRDM default in this survey against that
   tag.
