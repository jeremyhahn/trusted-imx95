# Decommission runbook for an i.MX 95 board

> **Status: PROPOSED, pending owner approval, documentation only; nothing here is scripted, and no step is run on a development board** · Row: device-lifecycle · Issue: #177 · Ruling 1234 and ruling 1244 bind it

This runbook turns the step table of [decommission-survey.md](decommission-survey.md#6-return-and-decommission-steps-and-which-are-irreversible) into an ordered list of who does what. The survey says its table is "not a procedure"; this page is the procedure the survey's question 7 recommends (option (c): a runbook here plus a go-trusted-platform verb). Neither is scripted until the owner approves. Vendor facts are cited from the survey's own sources (S1 to S6 there), not copied.

## Scope and defaults

The four answers below are the survey's recommendations, used as defaults. Each stays **pending the owner**.

| Owner question | Default used here | Survey |
|---|---|---|
| E1: what end of life means | (a) scrap only; no part goes back to NXP | [question 1](decommission-survey.md#8-questions-for-the-owner) |
| E2: is the key-store wipe mandatory | (a) yes, always, before the board leaves custody | [question 2](decommission-survey.md#8-questions-for-the-owner) |
| E3: may a key outlive its device | (a) no key outlives its device; step 2 therefore has nothing to export | [question 3](decommission-survey.md#8-questions-for-the-owner) |
| E4: the revocation of record | (c) both, the certificate revocation list first, then the device record | [question 4](decommission-survey.md#8-questions-for-the-owner) |

Ruling 1234 binds this page: no move of the chip's life cycle is described as a step to run on a development board. Ruling 1244 binds it too: the RPMB key is not programmed on development boards.

## Order of steps

Steps follow the survey's numbering. The survey's order rule: steps 3 and 4 come before the board leaves the owner's hands.

| # | Step | Who acts | Where | Section |
|---|---|---|---|---|
| 1 | Suspend the device (block its port, refuse boot credentials) | control plane operator, through go-trusted-platform | control plane | [Control-plane steps](#control-plane-steps) |
| 2 | Export or re-wrap a key that must outlive the device | nobody: under E3 (a) there is none | board | [Scope and defaults](#scope-and-defaults) |
| 3 | Wipe the enclave key store | technician with the board | board | [Board-side wipe](#board-side-wipe) |
| 4 | Revoke the device's certificates; publish the CRL | control plane operator | control plane | [Control-plane steps](#control-plane-steps) |
| 5 | Move the device record to revoked | control plane operator | control plane | [Control-plane steps](#control-plane-steps) |
| 6a | Wipe the rest of the board's storage | technician with the board | board | [Board-side wipe](#board-side-wipe) |
| 6b | Field return | not described here | board | [Not in this runbook](#not-in-this-runbook) |
| 6c | Retire for good by a chip state move | not described here | board | [Not in this runbook](#not-in-this-runbook) |
| 7 | Remove the serial from the fleet allow-list or EAB record | control plane operator | control plane | [Control-plane steps](#control-plane-steps) |

Steps 4 and 5 cannot be undone: a revoked serial stays revoked and the revoked record is terminal (survey section 6). Do them only once the board is certain to be retired.

## Board-side wipe

Step 3 (survey [section 4.1](decommission-survey.md#41-where-the-enclave-key-store-lives)):

- Delete every key in the enclave key store with a deletion the enclave acknowledges for both the strict (sync) flag and the monotonic flag, as SPEC row `secure-key-handling` (owner decision 241) requires; close the store; remove the `nvm_daemon` storage directory.
- **Unresolved validation.** No source read shows the enclave rejecting a restored pre-deletion blob after a reset (survey section 4.1 and [section 7](decommission-survey.md#7-what-could-not-be-confirmed), item 6). Until that is validated on hardware, the wipe is treated as recoverable, and a board is not called sanitised, and is not released as sanitised, after step 3 alone.
- The firmware TPM's NV and the PKCS#11 state live in the root file system and go with it, as [docs/SPEC.md](../SPEC.md) and [docs/ftpm/README.md](../ftpm/README.md#nv-storage) state; they are not restated here. A cleared or erased root file system also ends the board's TPM identity (ftpm re-provisioning, B6).

Step 6a (the rest of the storage):

- The eMMC wipe method and its effect on the media were not surveyed and are **to be validated**; this page names no method.
- RPMB: nothing to wipe while RPMB is unused. RPMB stays with the owner (ruling 1244); this runbook programs, wipes and enables nothing there.

## Control-plane steps

Steps 1, 4, 5 and 7 are requests to go-trusted-platform (issue #884). Verb: none yet. The survey's question 7 recommends such a verb; which go-trusted-platform operation moves a record to revoked is open (survey section 7, item 7). Until it exists, each step is a request to the control-plane operator, who acts in the order 1, then 4 (CRL first, E4 (c)), then 5, then 7.

| # | Request | Verb |
|---|---|---|
| 1 | Suspend the device | none yet |
| 4 | Revoke the device's certificates at the platform CA; publish the CRL | none yet |
| 5 | Move the device record to revoked | none yet |
| 7 | Remove the serial from any fleet allow-list or EAB record | none yet |

## Not in this runbook

- 6b (field return) and 6c (retire for good by a chip state move): moves of the chip's state, one-way as far as the survey could tell. They stay **not recommended pending owner decision** (survey questions 1, 5 and 6), and this page gives no instruction for them.
- Any fuse or chip-state change on any board.
- RPMB: no key, no wipe, no enablement (ruling 1244).
- A script, or a go-trusted-platform verb. Both wait for the owner.

## Evidence of completion

The technician records, per board: the board serial; the date; the result of each step in the order table (done, not applicable, or refused, with the reason); and, for step 3, whether the enclave acknowledged both flags and whether the hardware validation above is done. A record holds no key, no secret and no key-store contents.
