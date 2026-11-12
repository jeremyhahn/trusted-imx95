# hsm-self-defence: public survey of tamper detection and zeroisation on the i.MX 95

Status: survey for the owner's decision (issue #44). Documentation only: nothing here
was run on a board, and no fuse, life-cycle or provisioning step is described as a
procedure.

Scope: what public NXP sources say about how the FRDM-IMX95-PRO can detect tampering
and respond to it. The response covers powering down domains, stopping the other
logical machines, zeroising keys in the EdgeLock secure enclave (ELE) and shutting
down. This is the device side of the `hsm-self-defence` row in [SPEC.md](../SPEC.md).

All text below is a summary in my own words. Vendor text is not quoted.

## Sources

| Id | Source | Version surveyed | URL | Reached |
|----|--------|------------------|-----|---------|
| S1 | NXP System Manager (`imx-sm`): source, configs and Doxygen docs (`sm/doc/arch.md`, `sm/doc/imp.md`, `sm/doc/config.md`) | tag `rel_imx_sm_2026q3`, commit dated 2026-09-03 | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3 | yes (git clone) |
| S2 | NXP System Manager board config for the FRDM-IMX95-PRO, `configs/other/mx95frdm-pro.cfg` | same tag as S1 | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg | yes |
| S3 | NXP System Manager i.MX 95 fault list, `devices/MIMX95/sm/dev_sm_fault.h`, and ELE driver, `drivers/ele/fsl_ele.h` | same tag as S1 | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3/devices/MIMX95/sm | yes |
| S4 | NXP EdgeLock secure enclave user library (`imx-secure-enclave`), HSM API headers (`include/hsm/internal/hsm_delete_key.h`, `hsm_key_store.h`) | tag `lf-6.18.37-2.1.0`, commit dated 2026-09-08; library version 1.1 (`se_version.txt`) | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 | yes (git clone) |
| S5 | NXP i.MX 95 Applications Processor Reference Manual (IMX95RM) | n/a | https://www.nxp.com/docs/en/reference-manual/IMX95RM.pdf | **no**: HTTP 404 at this URL; NXP seems to give it out only after sign-in |
| S6 | NXP i.MX 95 Security Reference Manual | n/a | no public URL found | **no**: does not seem to be public |
| S7 | NXP i.MX Linux User's Guide | n/a | https://www.nxp.com/docs/en/user-manual/IMX_LINUX_USERS_GUIDE.pdf | **no**: HTTP 404 at this URL |
| S8 | NXP Linux kernel fork (`linux-imx`) | tag `lf-6.18.37-2.1.0` exists | https://github.com/nxp-imx/linux-imx/tree/lf-6.18.37-2.1.0 | tag seen, source **not surveyed** |
| S9 | Issue #44 text on the forge | n/a | (forge issue #44) | **no**: the lane has no forge credentials; I worked from the brief and SPEC.md |

I could not reach the GitHub REST API (HTTP 403, rate limit), so I got tags and
sources with `git ls-remote` and `git clone --depth 1`.

## Findings

### F1. No public NXP source documents an ELE tamper input on the i.MX 95

The word "tamper" does not appear anywhere in S1–S4: not in the System Manager source,
its docs or its i.MX 95 configs, and not in the ELE user library. In those sources I
found no API for configuring tamper pins, enabling tamper detection or reading tamper
status. The only zeroisation-related match is a fuse-shadow status bit in a header
for a different i.MX 9 device (`devices/MIMX937`), and it is not about tampering.

**Unconfirmed**: whether the i.MX 95 has external tamper pins at all, whether the ELE or
a battery-backed security block watches them, and what the ELE does on a tamper event.
These questions are for S5/S6, which I could not reach. This matches what SPEC.md
already says: the document with the EdgeLock tamper pins is missing.

### F2. The System Manager has a configurable fault-reaction path

The System Manager (on the Cortex-M33) takes hardware faults from the fault collection
unit (FCCU) and maps each one to a configured reaction (S1, `sm/doc/imp.md`
"Example Fault Flow"; `sm/doc/config.md` FCCU section):

- Each fault has an immediate reaction and a delayed one. If software does not
  acknowledge the immediate reaction within a timeout (about 300 ms on the i.MX 95,
  per S1), the delayed reaction fires, and that can reset the whole system.
- The reactions in the config files include resetting a logical machine (LM), resetting a
  group, resetting the system, and handing the fault to the FuSa (functional
  safety) path, which can notify an agent (S1, S2).
- The board hook that looks up the reaction can also record the fault in persistent
  storage (S1, `imp.md`).

On the i.MX 95 the fault list (S3, `dev_sm_fault.h`) includes over-temperature,
debug-mode activation, unintended Cortex-M33 and Cortex-M7 debug activation, watchdogs,
and a set of software faults (`FAULT_SW0`…). Some of these are signs of tampering
(debug activation, temperature); none of them is labelled as tamper.

The FCCU itself is set up in a C file for the eMcem safety component, not with the
configtool (S1, `config.md`).

### F3. On the FRDM-IMX95-PRO config, the M7 has the controls a tamper responder needs

In S2 (the public SM config for this board):

- LM1 is the Cortex-M7 ("M7"), with secure-world access. LM2 is the Cortex-A55 side,
  which has a secure part (the "AP-S" agent) and a non-secure part (the "AP-NS" agent).
- The M7's SCMI agent is granted full access to the System protocol (system
  shutdown and reset), the FuSa protocol, and LM management of the A55 LM
  (`LMM_2`, so it can stop or reset the A55 side). It also owns its own ELE mailbox
  (`MU_ELE5`) and four GPIO pins (`GPIO_IO14`, `IO15`, `IO36`, `IO37`).
- The M7 owns `FAULT_SW0` (reaction: FuSa) and `FAULT_SW1` (reaction: reset the
  LM), and its own lockup, reset and watchdog faults.
- The M7 is **not** granted power-domain or PHY controls for other domains (for
  example NETC, HSIO, or the NPU). The A55 non-secure LM owns those.

So with the stock config, the M7 can stop the A55 world and shut down the system, but
it cannot power down a single domain or PHY. That would need a change to the config,
which belongs to the `system-manager-config` row.

The SCMI protocols are listed in S1 (`sm/doc/arch.md`): the standard Arm SCMI
protocols (power, system, reset, and so on) plus NXP extensions (LMM, BBM, CPU, Misc,
FuSa).

**Unconfirmed**: whether an agent can raise a software fault (`FAULT_SW*`) itself through
a FuSa SCMI message. I did not trace that path in the source.

### F4. The System Manager can force the ELE into an aborted state

The SM's ELE driver (S3, `fsl_ele.h`) has a call that forces the ELE into an
aborted state, a call that queries the abort state, and a call that reads ELE event
records.

**Unconfirmed**: whether any SCMI message gives an agent such as the M7 access to the
abort call (I found none in the protocol list). I also could not confirm whether an
aborted ELE wipes its key material or just refuses service until reset. That is in S6.

### F5. The public ELE HSM API supports deleting keys and the key store, not a single "zeroise" command

From S4 (headers for the ELE user library on the Linux side):

- Deleting a key takes a strict flag. With that flag, the deletion counts only after the
  updated key store has been written to non-volatile storage under a newer monotonic
  counter value. So an older key store blob cannot be restored afterwards. This
  matches the strict-operation rule SPEC.md cites from RM00284 §2.4.2.
- Closing a key-store service removes the key store from the ELE's internal memory.
  Any change not yet saved to non-volatile storage is lost.
- I found no command that erases every key or the whole enclave in one step.

**Unconfirmed**:
- Whether the M7 (bare metal or RTOS, over `MU_ELE5`) can use the same HSM services.
  S4 is the Linux user-space library.
- Where the key store blob lives in non-volatile storage on this board.
- Whether destroying that blob is enough to make the keys unrecoverable without also
  advancing the monotonic counter.

### F6. Life-cycle and fuse actions are out of scope

The irreversible responses are a forward life-cycle move or blowing fuses. SPEC.md
puts them in the `oem-key-provisioning` row (RM00284 §3.23–3.24), and this brief
excludes them. The SM has fuse read and write calls (S3), but this survey describes
no procedure that uses them.

## What is still missing

- S5 (IMX95RM) and S6 (Security Reference Manual). These are needed for tamper pins,
  security violation sources and how the ELE behaves when aborted or tampered with.
- S8 (the Linux ELE driver and NVM manager). This would show where the key store blob
  is kept and how the A55 side sees an aborted ELE.
- S9 (the text of issue #44). This survey follows the lane brief and may not
  cover every point the issue lists.

## Questions for the owner

1. **Where does the tamper signal come from?**
   - (a) An on-chip EdgeLock or SoC tamper input. Its existence is unconfirmed (F1) and
     needs S6.
   - (b) A board-level tamper loop (case switch or mesh) wired to a GPIO the M7 already
     owns in the stock config (F3).
   - (c) Only the SM's existing FCCU faults: debug activation and over-temperature (F2).

   *Recommendation*: (b) together with (c) now. Add (a) if S6 shows the input exists.
   The public sources support (b) and (c); nothing public supports (a).

2. **Which core runs the tamper response?**
   - (a) The Cortex-M7, through SCMI to the SM and `MU_ELE5` to the ELE.
   - (b) The A55 secure world.
   - (c) The SM alone, using its fault reactions.

   *Recommendation*: (a), with (c) as the backstop. In the stock config the M7 can
   already stop the A55 LM and shut down the system (F3). The M7 also stays
   trustworthy when the A55 side is the part under attack. The delayed FCCU reaction
   resets the system even if the M7 does not respond (F2).

3. **What does the response do, and in what order?**
   - (a) Reset only, using an SM fault reaction.
   - (b) Stop the A55 LM, zeroise keys in the ELE, then shut down the system.
   - (c) Option (b), but with an ELE abort instead of zeroisation.

   *Recommendation*: (b). It is the only option the public APIs fully cover (F3, F5).
   (c) depends on unconfirmed abort semantics (F4).

4. **How should keys be zeroised?**
   - (a) Delete each key with the strict flag.
   - (b) Close the key store and destroy its blob in non-volatile storage.
   - (c) An irreversible life-cycle or fuse action.

   *Recommendation*: (a), then (b). The strict delete gives rollback protection through
   the monotonic counter (F5). (c) belongs to `oem-key-provisioning` and is out of
   scope here (F6).

5. **Should the M7 get per-domain power and PHY control?** (This is a change to the
   `system-manager-config` row.)
   - (a) Yes: grant the M7 the power domains and PHYs to cut (for example NETC and
     HSIO).
   - (b) No: the M7 only stops the A55 LM and shuts down the system.

   *Recommendation*: (b) to start with, because the stock config already supports it
   (F3). Choose (a) only if the threat model needs the board to stay up and partly
   working after a tamper event.

6. **Which SM config is the starting point?**
   - (a) `configs/other/mx95frdm-pro.cfg` at `rel_imx_sm_2026q3`, pinned.
   - (b) A config written from scratch.

   *Recommendation*: (a), pinned to that tag (S2).

7. **Are the A55 tamper detector, the NPU model and the IMA log built in this
   repository?** (This is the open question in SPEC.md.)
   - (a) Here.
   - (b) In another repository.
   - (c) Deferred.

   No public source bears on this, so I make no recommendation.

8. **Should the non-public documents be obtained?**
   - (a) Request IMX95RM and the i.MX 95 Security Reference Manual from NXP (NDA if
     needed) and add them to the private reference set.
   - (b) Go ahead on public sources only.

   *Recommendation*: (a). F1 and F4 cannot be settled without them.
