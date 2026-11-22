# hsm-self-defence: what the Cortex-A55 Linux side can observe of tampering

Status: survey for the owner's decision (issue #26). Documentation only, and
**provisional**, pending the owner's answer on the A55 scope (question 7 of the
[tamper survey](tamper-survey.md)) and the blockers on #26. Nothing here was run on a
board. No key, fuse or zeroisation procedure is described.

Scope: what the A55 Linux kernel (the NXP fork and upstream) exposes about tampering,
ELE failure, resets and integrity violations, from public sources. It does not repeat
the System Manager fault path, the M7 grants, ELE key deletion or the fault and
side-channel defences; those are in the [tamper survey](tamper-survey.md) (F2 to F6) and
the [fault and SCA survey](fault-sca-survey.md). The firmware TPM is in
[docs/ftpm/](../ftpm/README.md).

All text is a summary in my own words. Vendor text is not quoted. Source ids are local
to this survey. What the A55 side should do with these signals is in the
[A55 self-defence design note](a55-self-defence-design.md).

## Sources

| Id | Source | Version surveyed | URL | Reached |
|----|--------|------------------|-----|---------|
| S1 | NXP Linux kernel fork: `drivers/firmware/imx/` (ELE driver `se_ctrl.c`, `ele_common.c`, `ele_bbsm.c`, `sm-misc.c`), `drivers/rtc/rtc-nxp-bbnsm.c`, `drivers/input/misc/nxp-bbnsm-pwrkey.c`, `drivers/watchdog/imx2_wdt.c`, `imx7ulp_wdt.c`, `drivers/firmware/arm_scmi/vendors/imx/` | tag `lf-6.18.37-2.1.0`, commit dated 2026-09-08 | https://github.com/nxp-imx/linux-imx/tree/lf-6.18.37-2.1.0 | yes (git clone) |
| S2 | Upstream Linux, same driver paths, existence check only | tag `v6.18` | https://github.com/torvalds/linux/tree/v6.18 | yes (tag by `git ls-remote`; paths by HTTP status only, content not read) |
| S3 | Upstream Linux IMA: `Documentation/ABI/testing/ima_policy`, `security/integrity/ima/` | tag `v6.18` | https://github.com/torvalds/linux/tree/v6.18/security/integrity/ima | yes (HTTP 200); content **not read** in this session |
| S4 | Upstream Linux lockdown: `security/lockdown/lockdown.c` | tag `v6.18` | https://github.com/torvalds/linux/blob/v6.18/security/lockdown/lockdown.c | yes (HTTP 200); content **not read** |
| S5 | Upstream Linux dm-verity: `drivers/md/dm-verity-target.c` | tag `v6.18` | https://github.com/torvalds/linux/blob/v6.18/drivers/md/dm-verity-target.c | yes (HTTP 200); content **not read** |
| S6 | Upstream Linux audit subsystem documentation | tag `v6.18` | https://github.com/torvalds/linux/tree/v6.18 | **no**: not fetched |
| S7 | `rtc-snvs.c` in S1 | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/linux-imx/blob/lf-6.18.37-2.1.0/drivers/rtc/rtc-snvs.c | **no**: file exists, not read |

Tags and sources came from `git clone --depth 1` and `git ls-remote`; the GitHub REST
API was not used.

## Findings

### F1. The NXP ELE driver gives userspace a command channel and counters, not a tamper or failure event

S1, `drivers/firmware/imx/se_ctrl.c`. The driver (platform name `fsl-se`, matching
`fsl,imx95-se` among others) registers one misc character device per ELE channel, named
from the interface and channel numbers. Userspace talks to it with ioctls: enable
command receive, get MU info, set up I/O buffers, get SoC info, send a command and
receive the response, configure shared buffers, send a signed message, get the timer and
get the V2X version. This is the path the user library in the
[tamper survey](tamper-survey.md) (F5) uses.

Beyond the ioctls, the driver has a sysfs group `ele_stats` with read-only
`timeout_count`, `recovery_count` and `circuit_breaker_state`, and a write-only
`circuit_breaker_reset`. These count message timeouts and driver recoveries on the A55
side. I found no debugfs file, event or netlink interface for ELE state in this
driver.

On failure reporting: `ele_common.c` checks a response for the ELE fatal-abort code and
writes a line to the driver's log dump when it sees one. That dump goes through a debug
buffer helper, so whether the line reaches the default kernel log is **not confirmed**.
There is no separate notification to userspace for an aborted ELE. A caller sees the
failed command's status or a timeout, and the counters above rise.

Status: confirmed from source (S1). What the board shows after a real abort: to be
validated on the board.

### F2. Linux has a BBSM tamper-status path in the ELE driver, but only wired for i.MX 93

S1, `drivers/firmware/imx/ele_bbsm.c` and `ele_common.c`. The earlier survey found the
word "tamper" absent from the System Manager and the ELE user library. It is present in
the NXP kernel: `ele_bbsm.c` reads a BBSM tamper status through a secure-monitor call
and registers two interrupt handlers (a secure and a non-secure one) that clear the
interrupt through the same call. The handlers only log and clear; they do not forward
the event to userspace.

In `ele_late_init` this code is called only when the SoC id is i.MX 93. For the i.MX 95
the branch is not taken, so on this board the kernel does not read or log BBSM tamper
status. Whether the secure-monitor call is implemented in the trusted firmware for the
i.MX 95 is **not confirmed**; it belongs to the trusted-firmware row.

Status: confirmed from source (S1). Whether any i.MX 95 tamper source reaches the A55:
not confirmed.

### F3. The BBNSM RTC and power-key drivers expose no tamper or violation status

S1, `rtc-nxp-bbnsm.c` and `nxp-bbnsm-pwrkey.c`. A search for "tamper" and "violation"
in both files found nothing. They provide time, alarm and the power-button input only.
An honest answer: Linux sees no security-violation status from the BBNSM through these
drivers. `rtc-snvs.c` (S7) was not read, so the same statement for the older SNVS RTC
driver is not confirmed. The i.MX 95 devicetree was not read either.

Status: confirmed from source for the two BBNSM drivers (S1); not confirmed for S7.

### F4. The kernel reads the System Manager reset reason and log, and the watchdog reports a card reset

S1, `drivers/firmware/imx/sm-misc.c` and `drivers/firmware/arm_scmi/vendors/imx/`.

- At probe the SM misc driver asks the SM, over SCMI, for the reset reason, for the
  system and for the logical machine, and prints the boot reason and the shutdown
  reason, with an origin and an error id when valid. It does this only on machines in a
  built-in allow list. So the A55 can learn why the last reset or shutdown happened, as
  far as the SM records it. It is printed once to the kernel log, not offered as a file.
- The same driver adds a debugfs file `scmi_imx/syslog` (mode 0444) that dumps the SM
  log. Debugfs is usually root-only and often disabled in production images.
- The i.MX 95 SCMI vendor documentation in the same directory lists a reset-reason
  command and LM boot and shutdown notifications. Linux can ask to be told when another
  LM boots or shuts down. Whether the kernel driver subscribes to those notifications
  was not confirmed.
- `imx2_wdt.c` sets the watchdog boot status to "card reset" when the reset-status
  register shows a watchdog timeout, which userspace reads through the standard
  watchdog interface. `imx7ulp_wdt.c` has a restart handler and I found no boot-status
  report in it. Which watchdog the i.MX 95 uses in this tree was **not confirmed**.

None of this is labelled tamper. A fault the SM raises (for example the debug-activation
faults in [tamper survey](tamper-survey.md) F2) may show up as a reset reason, but the
mapping from fault to reason code was not read.

Status: confirmed from source (S1) for the reading paths; the content of the reasons
after a tamper-like fault is not confirmed and is to be validated on the board.

### F5. What is mainline and what is NXP-only

S2 checked paths at `v6.18` by HTTP status. Present upstream: `sm-misc.c` under
`drivers/firmware/imx/`, `rtc-nxp-bbnsm.c`, `nxp-bbnsm-pwrkey.c`, `rtc-snvs.c`,
`imx2_wdt.c`, `imx7ulp_wdt.c` and the SCMI vendor files `imx-sm-misc.c` and
`imx-sm-bbm.c`. Absent upstream (HTTP 404): `se_ctrl.c`, `ele_base_msg.c`,
`ele_bbsm.c`, `se_ctrl.h` and the ELE ioctl header. So the ELE driver, its ioctl
surface, its sysfs counters and the BBSM tamper code are NXP-only; the reset-reason and
watchdog paths are in mainline at least in part. Whether the upstream copy of
`sm-misc.c` matches S1 in content (for example the syslog file or the reset-reason
print) was not read.

Status: confirmed for presence and absence of the files; not confirmed for content.

### F6. IMA and EVM, and what they need from a TPM

S3 was reached but its content was not read in this session. What follows is general
kernel knowledge, **not confirmed from the source here** and to be checked before
anyone relies on it.

- IMA keeps a measurement list in the kernel, appraises files against signatures or
  hashes (appraisal), and can audit. EVM protects file metadata. A policy chooses which
  files are measured or appraised.
- Without a TPM, IMA still keeps the in-kernel list and can appraise against
  signatures; what is lost is the anchor: with no PCR to extend, a remote verifier
  cannot tell if the list was altered by a compromised kernel. With a TPM, each
  measurement is extended into a PCR and the list is checkable against the quoted PCR.
- What IMA would need from the firmware TPM ([docs/ftpm/](../ftpm/README.md)): a TPM 2.0
  device the kernel can reach early, PCR extend and quote support, and a way to keep the
  PCR state through the points where the A55 side is stopped and restarted.

Status: not confirmed. Behaviour on the board: to be validated on the board.

### F7. dm-verity, lockdown and audit as A55-observable integrity signals

| Signal | What the A55 can observe | What it cannot |
|--------|--------------------------|----------------|
| dm-verity (S5) | A hash mismatch on a read of a verified block, as an I/O error to the reader, a kernel log line and a device-mapper event; the target can be set to restart or panic on corruption. | Tampering with data it never reads; a compromised kernel that disables the check; anything about the storage before the device is set up. |
| Kernel lockdown (S4) | The current mode (none, integrity or confidentiality) in a securityfs file, and denied operations in the log. | Whether the kernel that reports the mode is itself intact; a change made before the kernel started. |
| Audit (S6) | Events the kernel and user space raise: policy denials, IMA appraisal failures, configuration changes, in a log a daemon can ship. | Events from a compromised kernel or one that disables auditing; anything outside the A55 side. |

All three rows are general kernel knowledge: S4 and S5 were not read and S6 was not
fetched.

Status: not confirmed. Board behaviour: to be validated on the board.

## Sources not reached or not read

- S6 (audit documentation): not fetched.
- S7 (`rtc-snvs.c`): not read.
- S3, S4 and S5: reached by HTTP status only; F6 and F7 are from general knowledge.
- The i.MX 95 devicetree and the secure-monitor call implementation (trusted firmware).
- Upstream file content for F5.
- The IMX95RM and Security Reference Manual, as in the tamper survey.

## What is still missing

- Reading S3 to S6 so that F6 and F7 can be marked confirmed.
- Which watchdog and which reset reasons the i.MX 95 board really produces, and the
  mapping from System Manager faults to reason codes.
- Whether the BBSM secure-monitor call exists for the i.MX 95 in the trusted firmware.
- Board validation of every "to be validated" line above.

## Questions for the owner

All provisional, pending question 7 of the tamper survey and the blockers on #26.

1. **Which A55 signals should the tamper detector consume?**
   - (a) Kernel log and SM reset reason only (F4).
   - (b) (a) plus ELE `ele_stats` counters (F1) and dm-verity events (F7).
   - (c) Also IMA and audit events.

   Recommendation: (b); (c) only once F6 is confirmed and the firmware TPM exists.

2. **Is a kernel change acceptable to reach BBSM tamper status on the i.MX 95?** (F2)
   - (a) No: the A55 stays blind to it and the M7 or SM carries tamper detection.
   - (b) Yes: carry a patch to the NXP kernel enabling it, if the trusted firmware
     supports it.

   Recommendation: (a); the A55 is the side under attack, so it is the wrong place to
   depend on for detection (F2, F3).

3. **Is IMA in scope without a TPM?** (F6)
   - (a) Yes, appraisal only, no remote attestation.
   - (b) No, wait for the firmware TPM.

   Recommendation: (b), because the anchor is what makes the list trustworthy.

4. **Should the production image disable debugfs?** (F4: the SM log is there)
   - (a) Yes.
   - (b) No, keep it for field diagnosis.

   Recommendation: (a), and read the reset reason at boot instead.

## Proposed SPEC changes (proposed, pending owner approval)

None. If the owner answers question 7 of the tamper survey with "here", a line in the
`hsm-self-defence` row naming the A55 signals of F1, F4 and F7 as inputs could be added.
