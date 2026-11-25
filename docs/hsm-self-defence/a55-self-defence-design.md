# hsm-self-defence: what the Cortex-A55 side can and cannot do (design note)

Status: design note for the owner's decision (issue #26). Documentation only, and
**provisional**, pending the owner's answer on question 7 of the
[tamper survey](tamper-survey.md) and the blockers on #26 (go-xkms and trusted-firmware
`hsm-self-defence` rows, `system-manager-config`, the missing EdgeLock tamper-pin
document). Nothing here was run on a board. No key, fuse or zeroisation procedure is
described, and no protocol or message format is defined.

Scope: what the A55 Linux side should do about tampering, given what the three surveys
found. It consolidates the owner's questions that are scattered across the
[A55 signals survey](a55-signals-survey.md), the [tamper survey](tamper-survey.md) and the
[fault and SCA survey](fault-sca-survey.md). It does not restate their findings; findings
are cited by survey and id, written `a55 F4` (A55 signals survey), `tamper F2` (tamper
survey) and `fault-sca F1` (fault and SCA survey). It does not edit
`system-manager-config`, go-xkms or trusted-firmware content.

All text is a summary in my own words. Vendor text is not quoted.

## Principle: the A55 is a witness

The A55 runs the largest, most exposed software on the board, so it is the side under
attack. It can notice some things and write them down, but a compromised A55 kernel can
also lie, stay silent or switch its own checks off (a55 F7). So the A55 is a witness,
not the root of trust: its reports are hints that a trusted party may weigh, and the
decision to react to tampering belongs to the M7 and the System Manager, which the A55
does not control (tamper F3). Nothing in this note lets an A55 observation be the only
thing standing between an attacker and a key.

One duty follows from owner ruling 1234, which makes the A55 Linux side the caller of the
enclave's key API: when the M7 runs its tamper response, the A55 HSM service quarantines
its key-store sessions. That is a reaction to the M7's event, not an A55 decision; it is
designed, as proposed and pending owner approval, in the
[tamper-response note](a55-tamper-response-design.md).

## Inputs the A55 can use

Trust level "A55-self-reported" means a kernel or process on the A55 produced the
signal and a compromised A55 can forge or suppress it. "SM-reported" means the System
Manager produced the value and the A55 only relays it; a compromised A55 can still hide
it from others, but cannot change what the SM recorded. Every row is to be validated on
the board.

| Input | What it tells you | What it cannot tell you | Trust level | Finding |
|-------|-------------------|-------------------------|-------------|---------|
| SM reset reason read at boot | Why the last reset or shutdown happened, as far as the SM records it | The mapping from a tamper-like fault to a reason code is not confirmed; ELE-originated causes are not told apart; the printout is once to the kernel log | SM-reported (relayed by the kernel) | a55 F4 |
| `ele_stats` counters (`timeout_count`, `recovery_count`, `circuit_breaker_state`) | ELE message timeouts and driver recoveries seen from the A55 | Any ELE tamper or abort event as such; only a failed or slow command shows up | A55-self-reported | a55 F1 |
| Watchdog boot status | That the last restart was a watchdog "card reset", if the watchdog driver in use reports it | Which watchdog the i.MX 95 uses in the tree is not confirmed; says nothing about why the watchdog fired | A55-self-reported (reset flag set by hardware, read by the kernel) | a55 F4 |
| dm-verity events | A hash mismatch on a verified block as an I/O error, a log line and a device-mapper event | Tampering with data never read; a kernel that disables the check; storage state before setup | A55-self-reported | a55 F7 |
| Lockdown mode | The current mode (none, integrity, confidentiality) and denied operations | Whether the reporting kernel is intact; changes made before it started | A55-self-reported | a55 F7 |
| Audit | Policy denials, appraisal failures and configuration changes, as a log a daemon can ship | Events from a compromised kernel or one that disables auditing | A55-self-reported | a55 F7 |
| IMA | Measurement list and appraisal results for selected files | Without a TPM anchor, whether the list was altered by a compromised kernel; not confirmed from source | A55-self-reported | a55 F6 |

The first three rows are confirmed from source in the NXP kernel (a55 F1, a55 F4); the
last four are general kernel knowledge and **not confirmed** (a55 F6, a55 F7).

## What the A55 cannot do

- **See ELE tamper.** The ELE driver gives a command channel and counters, not a tamper
  or failure event (a55 F1). There is no notification to userspace for an aborted ELE.
- **See BBSM tamper status on the i.MX 95.** The kernel's BBSM tamper code is wired for
  the i.MX 93 only (a55 F2), and the BBNSM RTC and power-key drivers expose no tamper or
  violation status (a55 F3). Whether any i.MX 95 tamper source reaches the A55 at all is
  not confirmed.
- **Trust its own kernel after compromise.** Every A55-self-reported input above can be
  forged by a compromised kernel (a55 F7). The kernel's ELE driver and BBSM code are also
  NXP-only and not upstream (a55 F5), which does not change this.
- **Know about the SM's own fault path.** Debug-activation, temperature and watchdog
  faults go through the fault collection unit to the SM (tamper F2); the A55 may only see
  the result as a reset reason, and that mapping is not confirmed (a55 F4).

## What the SM and M7 carry

The detection and reaction path is on the M33 System Manager and the M7, not on the A55.

- **Fault reactions.** The SM maps each fault to a reaction: LM reset, LM-group reset,
  system reset, FuSa notification, and the others listed in
  [fault-recovery survey](../system-manager-config/fault-recovery-survey.md) section 5.2
  and, per fault, section 5.3 (tamper F2). The hardware fault monitors the SM exposes
  are in fault-sca F1. The delayed system reset backstop and its
  limit are in section 5.1 of the same survey.
- **Watchdog routing.** Section 4 of that survey: the A55 watchdogs WDOG3 and WDOG4 are
  assigned to the AP LM, and a timeout becomes an FCCU fault that the SM turns into an
  LM reset of the A55 LM only (15x15 FRDM file, reference; the PRO value is
  **unconfirmed**).
- **Reset reasons.** Section 6 of that survey: which reasons the SM can record and where
  the record is stored; the PRO's store is unconfirmed.
- **The M7's rights.** The M7 may reset or shut down the A55 LM and the system, and it
  owns `FAULT_SW0` and `FAULT_SW1` (tamper F3; fault-recovery survey section 8). Key
  deletion is a request to the ELE, not an SM function (tamper F4, tamper F5). The M7's
  tamper response is the M7's business and is not described here.

Which of those configuration choices the A55 side depends on (all to be validated on
the board, and none is changed by this note):

- **A55 watchdog faults reset only LM2.** The A55 watchdog as a recovery tool works
   only if `FAULT_WDOG3` and `FAULT_WDOG4` have a reaction that restarts the AP LM and
   leaves the M7 running (fault-recovery survey question 2). Whether the PRO file
   has these entries is unconfirmed.
- **The M7 keeps running and is notified** when the A55 LM resets, so that a response
   ladder step that depends on the M7 has a listener. The notification path for Linux
   and for the M7 is described in section 8 of that survey and is partly unconfirmed.
- **The reset reason stays readable over SCMI** after an LM reset (fault-recovery survey
   sections 6 and 10). Whether the non-secure A55 agent may read it on the PRO is
   unconfirmed; the kernel read at boot (a55 F4) depends on it.
- **The M7 is not stopped while the A55 runs** (fault-recovery survey section 7): an
   A55 that keeps running with no tamper responder would make every rung of the ladder
   below pointless.

## Response ladder (provisional)

For an anomaly the A55 itself observes. Each rung is provisional and a higher rung does
not need the lower ones. Which rung applies to which input is the owner's decision.

- Rung 1: **Log only.** Write the observation to the kernel log and the audit log, with the
   input name from the table. This is local to the A55, so a compromised A55 may drop it.
- Rung 2: **Report to the M7 or to go-xkms over an existing channel.** The channel is **not
   decided**: no document on this branch names a channel from the A55 to the M7 for this
   purpose. The report is a hint; the M7 decides what to do with it.
- Rung 3: **Request an LM reset of the A55.** Only if the owner lets the A55 ask for it (question
   2 below); otherwise the A55 reports and the M7 resets the LM (tamper F3). The A55's
   own watchdog (default below) is a related, separate recovery.
- Rung 4: **Leave zeroisation and shutdown to the M7 and ELE path** (tamper F4, tamper F5). The
   A55 never takes part in key deletion on the basis of an observation of its own.

Because the A55 is a witness, the ladder deliberately has no rung where the A55 takes a
strong action by itself.

## Provisional defaults

Each is "default, pending owner". None is a decision.

- **Reset reason at boot** (default, pending owner): read the SM reset reason once at
  boot and keep it in a file readable by the HSM service (a55 F4). The file format and
  its consumer are open (question 1).
- **A55 watchdog** (default, pending owner): keep the A55 watchdog enabled, with a timeout
  to be chosen on the board (a55 F4; fault-recovery survey section 4).
- **debugfs** (default, pending owner): the production image disables debugfs (a55
  question 4), so the SM log is not exposed there (a55 F4), and the reset reason is read
  at boot instead.
- **IMA and audit** (default, pending owner): not in the baseline (a55 questions 1 and 3);
  they depend on a55 F6 being confirmed and on the firmware TPM.

## Board validation list

Every item is to be validated on the board.

- What the kernel prints for the reset reason after each reset cause, including a
  watchdog timeout and an ELE-originated reset (a55 F4).
- Whether the A55 watchdog on the PRO is the one the kernel driver reports as a card
  reset (a55 F4).
- Whether `ele_stats` counters rise after a real ELE abort, and whether the abort line
  reaches the default kernel log (a55 F1).
- Whether any BBSM or ELE tamper source reaches the A55 (a55 F2, a55 F3).
- The mapping from SM faults (debug activation, temperature, watchdog) to reset reasons
  (a55 F4, tamper F2).
- Whether the PRO configuration resets only LM2 on A55 watchdog timeout and keeps the M7
  running (fault-recovery survey section 4, 5.3).
- Whether the non-secure A55 agent may read the reset reason on the PRO (fault-recovery
  survey section 8).
- A55 watchdog timeout value.
- dm-verity, lockdown, audit and IMA behaviour on the board (a55 F6, a55 F7).

## Questions for the owner

All provisional. Earlier questions are referred to by number: a55 questions 1 to 4 are
in the [A55 signals survey](a55-signals-survey.md); question 7 is in the
[tamper survey](tamper-survey.md).

1. **Who consumes the A55 reset-reason record?**
   - (a) The HSM service only, as a local file.
   - (b) (a), and the A55 also forwards it to the M7 or go-xkms (channel not decided).
   - (c) Nobody: do not keep it, the M7 reads the reset reason itself.

   Recommendation: (c) if the M7 can read it (fault-recovery survey section 8, grant
   unconfirmed), otherwise (a). The A55 copy is only a witness statement.

2. **May the A55 request an LM reset itself, or only report?**
   - (a) Report only; the M7 decides.
   - (b) The A55 may request an LM reset of itself.

   Recommendation: (a). A request from a compromised A55 can be a denial-of-service
   lever, and a missing request proves nothing (a55 F7).

3. **Is the A55 watchdog in the baseline?**
   - (a) Yes, enabled, timeout chosen on the board.
   - (b) No, rely on the SM and M7 only.

   Recommendation: (a); it needs the reaction in fault-recovery survey question 2 (LM
   reset of the A55) to be set explicitly.

4. **Which A55 inputs feed a ladder rung above "log only"?** (a55 question 1)
   - (a) SM reset reason and watchdog status only.
   - (b) (a) plus `ele_stats` counters and dm-verity events.
   - (c) All inputs in the table.

   Recommendation: (a); the others are A55-self-reported and a55 F6, a55 F7 are not
   confirmed.

5. **Which channel carries an A55 report to the M7 or go-xkms?**
   - (a) Decide with the trusted-firmware and go-xkms rows once their surveys exist.
   - (b) Use an existing SCMI notification path, if one is confirmed.

   Recommendation: (a). Channel not decided; no document on this branch names it. For
   the M7's tamper event under ruling 1234 the same question is question 1 of the
   [tamper-response note](a55-tamper-response-design.md), which names the candidates.

6. **Does the A55 HSM service quarantine its key-store sessions on the M7's tamper event?**
   (proposed, pending owner approval; ruling 1234)
   - (a) Yes, as the tamper-response note proposes: refuse new key operations, end the
     service's sessions, do not retry; no A55 observation of its own triggers deletion.
   - (b) No: the A55 stays a pure witness and the M7 alone stops it.

   Recommendation: (a). It costs one state machine on the side that holds the sessions
   and removes an open session from the window in which the M7 stops the A55 LM.

## Proposed SPEC changes (proposed, pending owner approval)

If the owner answers question 7 of the tamper survey with "here", a line in the
`hsm-self-defence` row could name this note and the A55 inputs of a55 F1 and a55 F4 as
witness inputs only.

Proposed, pending owner approval, under ruling 1234 (owner's answer to question 6 above):
in the `hsm-self-defence` row, replace the sentence that the Cortex-A55 tamper detector,
the NPU model and the IMA log are an open question by a sentence that the A55 Linux side,
as the caller of the enclave's HSM API (owner ruling 1234), quarantines its key-store
sessions on the M7's tamper event, as proposed in the
[tamper-response note](a55-tamper-response-design.md), pending owner approval, with the
A55 detector, the NPU model and the IMA log still an open question; and set the row's
docs cell to both notes. No other row changes.
