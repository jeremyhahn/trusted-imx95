# hsm-self-defence: the A55 HSM service's tamper response (design note)

Status: **proposed, pending owner approval** (issue #26). Documentation only, and
**provisional**. Nothing here was run on a board. No key, fuse or zeroisation procedure is
described. The message contract is a proposal for the owner to approve, and
for `26-hsd-a55-2` to implement a parser against; nothing in it is built.

Scope: what the Cortex-A55 Linux side does when the Cortex-M7 runs its tamper response.
Findings are cited by survey and id (`a55 F1`, `tamper F3`, `fault-sca F1`; see the
[A55 signals survey](a55-signals-survey.md), the [tamper survey](tamper-survey.md) and the
[fault and SCA survey](fault-sca-survey.md)) or by section of the
[fault-recovery survey](../system-manager-config/fault-recovery-survey.md) and the
[SCMI permissions survey](../system-manager-config/scmi-permissions-survey.md). A fact that
no survey confirms is marked **unconfirmed**. All text is a summary in my own words; vendor
text is not quoted.

## Scope and ruling 1234

Owner ruling 1234 makes the Cortex-A55 Linux side the caller of the enclave's key (HSM)
API, and the Cortex-M7 not a caller (the `secure-key-handling` row, as worded on PR #169,
proposed, pending owner approval there). So the A55 HSM service holds the key-store
sessions with the EdgeLock secure enclave. The earlier
[design note](a55-self-defence-design.md) treats the A55 as a witness only. This note adds
one duty and keeps the principle:

- Duty: when the M7 runs its tamper response, the A55 HSM service stops using keys,
  ends its key-store sessions and does not retry.
- Principle kept: no A55 observation alone triggers key deletion. The A55 never decides
  deletion and never issues a delete on its own account.

Out of scope: the M7's detection and response (trusted-firmware's `hsm-self-defence` row),
the SM configuration (`system-manager-config`), fuses and life-cycle steps, and how the
service is built.

## Who does what on a tamper event

| Party | Does | Does not |
|-------|------|----------|
| Cortex-M7 | Detects tamper, decides, acts through the SM (stop the A55 LM, shut down or reset the system) and the enclave (tamper F3, tamper F4, tamper F5; fault-recovery §8) | Call the HSM API in the normal path (ruling 1234) |
| System Manager | Applies the configured reaction; relays notifications (fault-recovery §5.1, §5.2) | Decide that a tamper happened |
| Enclave | Deletes keys or aborts on request (tamper F4, tamper F5) | Tell the A55 about tamper (a55 F1) |
| A55 HSM service | Reacts to the M7's event: refuses new key operations, ends its key-store sessions, logs, waits for the LM reset | Decide deletion, retry after quarantine, ask the M7 to stand down |

Tension to settle (question 6): tamper F5 leaves **unconfirmed** whether the M7 can use the
HSM services over its own enclave messaging unit, and ruling 1234 says it is not a caller.
How the M7's zeroisation request reaches the enclave is therefore open, and so is who
persists a strict delete (tamper survey question 3: the writer named in the sources is a
daemon on the A55 side).

## Candidate channels from the M7, through the SM, to the A55

No document confirms any channel that carries an M7 tamper event to Linux
(fault-recovery §6 and §8). The candidates:

| Channel | What the surveys confirm | What is unconfirmed | Carries a record? |
|---------|--------------------------|---------------------|-------------------|
| A. SCMI notification of the M7 LM's state or of the system power state, to the non-secure A55 agent | A reference file grants that agent notify rights on the M7 LM and on the system protocol (fault-recovery §8; scmi-permissions §2.4, §3.4); the LMM protocol has an LM event notification (fault-recovery §6) | The PRO file's grants; which message fires when the M7 LM is stopped; the delay before the A55 LM is stopped | No: it carries a state change, so the adapter of the contract below makes the record (source `0x02`) |
| B. FuSa notification relayed by the SM | The SM sends FuSa notifications on every fault set or cleared, to the safety environment, which is the M7 (fault-recovery §5.2, §7) | Any route from there to Linux | No |
| C. SCMI Misc protocol event or reset-reason read | The Misc protocol has a system reset reason query (fault-recovery §6) | Any event; the reset reason is read after the fact | No |
| D. A direct M7-to-A55 message path (a messaging unit with shared memory, for example RPMsg) | Only that the non-secure A55 agent has read and write access to a DDR window inside the M7's range, likely the RPMsg area (scmi-permissions §4, not confirmed) | That it exists, who owns it, and that trusted-firmware's M7 image uses it | Yes: the record of the contract below, in full |

Provisional default, pending owner (question 1): **A as the always-on trigger, D for the
full record if it exists**. A is the only channel whose permission is partly sourced and
that needs no new M7 code beyond the LM stop it already does; its weakness is that it
can say only "the M7 side is going down", which maps to the single event
`SHUTDOWN_IMMINENT`. D carries every event code, but nothing confirms it. B and C cannot reach the A55 on the evidence read, so
they are not defaults. The contract below is channel-independent: a transport adapter
hands the service one byte buffer; the service does not know which channel produced it.

## The tamper-event message contract

A fixed-size, little-endian, versioned record. **Proposed.** Version 1 is 28 bytes.

### Fields

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 4 | magic | bytes `54 41 4d 50` (ASCII `TAMP`) |
| 4 | 2 | version | `0x0001` |
| 6 | 2 | length | total record length in bytes, `0x001c` (28) |
| 8 | 2 | event code | see the event-code table |
| 10 | 1 | source | `0x01` M7 firmware; `0x02` adapter built from an SM notification |
| 11 | 1 | flags | reserved, must be zero in version 1 |
| 12 | 8 | sequence | unsigned, starts at 1, strictly increasing per sender and boot |
| 20 | 4 | reserved | must be zero in version 1 |
| 24 | 4 | crc32 | CRC-32 (IEEE 802.3: reflected, polynomial `0xedb88320`, initial value and final xor `0xffffffff`) of bytes 0 to 23 |

Integrity: the CRC-32 detects accidental corruption only. It is not authentication: there
is no key on this path, and none should be put on the A55, which is the witness. Who sent a
record rests on the channel (the SM's SCMI channel for A; the owner of the shared region
for D). Delivery to the service must be through a node that only the kernel and root can
write, so that an unprivileged A55 process cannot inject a record. For an adapter record
(source `0x02`) the adapter in the service computes the CRC itself, so it protects nothing
on that path. Whether the AP channels check integrity at all is **unconfirmed**; the
reference M7 channel does and the AP channels do not (scmi-permissions §2.4).

### Event codes

| Code | Name | Meaning | Sent by |
|------|------|---------|---------|
| `0x0001` | TAMPER_ASSERTED | The M7 judged that tamper happened and starts its response | M7 (source `0x01`) |
| `0x0002` | ZEROISATION_STARTED | The M7 asked the enclave to delete keys | M7 |
| `0x0003` | ZEROISATION_DONE | The enclave acknowledged the deletion (as far as the M7 can tell) | M7 |
| `0x0004` | SHUTDOWN_IMMINENT | The M7 or the SM is about to stop the A55 LM or the system | M7 or the adapter (source `0x02`) |
| `0x00ff` | TEST_EVENT | Exercise the path; no effect on the state | M7 |

Codes `0x0005` to `0x00fe` and every code of `0x0100` and above are unassigned.

### Validation order and rejections

The service applies these checks in this order and stops at the first that fails. A
rejected record changes nothing except a log line and a counter; it never moves the state
machine and never updates the last sequence number. The reject names are stable (the
parser of `26-hsd-a55-2` returns them).

| Order | Reject | Condition |
|-------|--------|-----------|
| 1 | short | fewer than 8 bytes, or, for version 1, fewer than 28 |
| 2 | bad-magic | bytes 0 to 3 differ from `54 41 4d 50` |
| 3 | bad-version | version is not 1; the rest of the buffer is not interpreted |
| 4 | long | version 1 and more than 28 bytes |
| 5 | bad-length | the length field is not 28 |
| 6 | bad-crc | the CRC-32 does not match |
| 7 | bad-source | source is neither `0x01` nor `0x02` |
| 8 | source-code-mismatch | source `0x02` with a code other than `0x0004` |
| 9 | bad-reserved | flags or reserved field not zero |
| 10 | bad-sequence | sequence is 0 |
| 11 | replay | sequence is not greater than the last accepted one |

Check 1 needs only the first 8 bytes. The size test for version 1 (fewer than 28 bytes is
also `short`, more is `long`) runs right after check 3, so an unknown version of any size
is `bad-version`, never `short` or `long`. A gap in the sequence (a value above last plus one) is accepted and logged,
since the channel may lose events.

Unknown event code on a record that passes every check above: **fail closed**, treat it as
TAMPER_ASSERTED (state `quarantined`, reason `unknown-code`), and log it. Question 4.
Unknown version: reject, no state change; this is fail-open for that record, and is the
reason the M7 firmware and the service must be released together.

### Test vectors

Bytes in hex, in wire order. "State before" is the service state and the last accepted
sequence. Each vector below was produced by the same layout and checked against the
CRC-32 rule above.

Accepted records, each delivered in state normal with last sequence 0:

| Id | Name | Bytes | State after |
|----|------|-------|-------------|
| V1 | TAMPER_ASSERTED | `54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75` | quarantined, last 1 |
| V2 | ZEROISATION_STARTED | `54 41 4d 50 01 00 1c 00 02 00 01 00 02 00 00 00 00 00 00 00 00 00 00 00 d7 cb e1 2b` | quarantined, last 2 |
| V3 | ZEROISATION_DONE | `54 41 4d 50 01 00 1c 00 03 00 01 00 03 00 00 00 00 00 00 00 00 00 00 00 29 16 2c 1e` | terminal, last 3 |
| V4 | SHUTDOWN_IMMINENT | `54 41 4d 50 01 00 1c 00 04 00 02 00 04 00 00 00 00 00 00 00 00 00 00 00 08 22 2c eb` | terminal, last 4 (source 2) |
| V5 | TEST_EVENT | `54 41 4d 50 01 00 1c 00 ff 00 01 00 05 00 00 00 00 00 00 00 00 00 00 00 ec 3e a8 d5` | normal, last 5 |
| V6 | UNKNOWN_CODE | `54 41 4d 50 01 00 1c 00 00 01 01 00 06 00 00 00 00 00 00 00 00 00 00 00 23 0e bc 16` | quarantined, last 6 |

Rejected records, each delivered in state normal with last sequence 0 unless the last
column says otherwise; every one leaves the state and the last sequence unchanged:

| Id | Reject | Bytes | Note |
|----|--------|-------|------|
| R1 | short | `54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7` | V1 without its last byte (27 bytes) |
| R2 | bad-magic | `54 41 4d 51 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 4b 2e 6d ea` | CRC valid for these bytes |
| R3 | bad-version | `54 41 4d 50 02 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 1f e0 1e da` | version 2, CRC valid |
| R4 | long | `54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75 00` | V1 plus one byte (29 bytes) |
| R5 | bad-length | `54 41 4d 50 01 00 20 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 f7 30 ab 1a` | length field 32, CRC valid |
| R6 | bad-crc | `54 41 4d 50 01 00 1c 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75` | V1 with the sequence changed to 0, CRC not updated |
| R7 | bad-source | `54 41 4d 50 01 00 1c 00 01 00 7f 00 01 00 00 00 00 00 00 00 00 00 00 00 10 4b 43 54` | source `0x7f`, CRC valid |
| R8 | source-code-mismatch | `54 41 4d 50 01 00 1c 00 01 00 02 00 01 00 00 00 00 00 00 00 00 00 00 00 0e 88 d6 09` | source 2 with TAMPER_ASSERTED, CRC valid |
| R9 | bad-reserved | `54 41 4d 50 01 00 1c 00 01 00 01 01 01 00 00 00 00 00 00 00 00 00 00 00 50 74 21 a8` | flags `0x01`, CRC valid |
| R10 | bad-reserved | `54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 01 00 00 00 b0 ca 0b cd` | reserved field 1, CRC valid |
| R11 | bad-sequence | `54 41 4d 50 01 00 1c 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 ba e1 12 ee` | sequence 0, CRC valid |
| R12 | replay | `54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75` | V1 delivered a second time, so last sequence is 1 (state quarantined after the first V1) |

Sequence tests for a parser: V1 then V2 then V3 are all accepted (1, 2, 3). V2 then V1:
V1 is `replay` (1 is not above 2) and the state stays as V2 left it. V5 then V1 is also
`replay`, so a test that wants both must send V1 first.

## The service's state machine

States: **normal**, **quarantined**, **terminal**.

- normal: key operations are served.
- quarantined: refuse every new key operation with one stable error, `KEYSTORE_QUARANTINED`
  (its numeric form is the implementer's choice, once, and does not change); end the
  service's key-store sessions; log the event and its reason once. In-flight operations
  are not retried.
- terminal: quarantined, and the service stops talking to the enclave altogether and waits
  for the A55 LM reset. A reset restarts the service in normal.

| Event, accepted | From normal | From quarantined | From terminal |
|-----------------|-------------|------------------|---------------|
| TAMPER_ASSERTED | quarantined | quarantined | terminal |
| ZEROISATION_STARTED | quarantined | quarantined | terminal |
| ZEROISATION_DONE | terminal | terminal | terminal |
| SHUTDOWN_IMMINENT | terminal | terminal | terminal |
| TEST_EVENT | normal | quarantined | terminal |
| unknown code | quarantined | quarantined | terminal |

Rules:

- No event moves a state back. Only an LM reset (a service restart) leaves quarantined or
  terminal. A later "all clear" is not defined and a record claiming one is an unknown code.
- After quarantine, an error from the enclave (a failed session end, a timeout, a
  circuit-breaker state, a55 F1) is logged once and is **not retried**. Retrying keeps an
  attacker's process talking to the enclave in the window the M7 is closing.
- The service never issues a key delete or any state-changing enclave command because of
  an event. Ending a session is not a deletion. One consequence is **unconfirmed** and is
  question 5: ending a key-store service drops any change not yet written to
  non-volatile storage (tamper F5), so the session end must not stop a persistence
  writer the M7's zeroisation relies on (tamper survey question 3).
- Test events do not change the state in normal; in quarantined and terminal the state is
  already stronger and stays.
- If the service starts after the event (the record was sent while it was not
  listening), it starts in normal and learns nothing; the M7's own response does not depend
  on it. Whether the M7 resends its latest state when a listener appears is question 2.

## What a compromised A55 can and cannot do to this path

- It **can** ignore the event: keep sessions open, kill the service, never subscribe. The
  M7's response does not depend on the A55 (tamper F3): the M7 stops the A55 LM through
  the SM and asks the enclave to delete. This note adds no path where the A55 helps the M7
  and no path where the M7 waits for the A55. (The unresolved SM-never-acknowledges case
  stays open in fault-recovery §10, question 3.)
- It **can** forge a record to itself. The effect is its own quarantine, the safe
  direction: it harms only the service it controls. It cannot forge a record into the M7.
- It **cannot** make the M7 stand down by any message defined here: there is no
  acknowledgement and no all-clear in the contract (question 2).
- It **can** use keys until the M7 stops the A55 LM. That window is the M7's to close, not
  this note's; the A55 side quarantine is a tidy shutdown, not a defence against a
  compromised A55 (a55 F7).
- It **cannot**, on the evidence read, observe an ELE tamper event as such (a55 F1), so the
  event is the only sign it gets.

## Code

Status: **proposed, pending owner approval**. Portable C99, host-tested, no enclave call
and no device (issue #26):

- `hsm-self-defence/a55/tamper_event.c` and `.h`: the parser. It returns the reject names
  of checks 1 to 10; an unknown event code passes it; the replay check (11) needs the last
  sequence, so the state machine makes it.
- `hsm-self-defence/a55/quarantine.c` and `.h`: the state machine of the table above. It
  returns actions (log, refuse key operations, close sessions, await reset) and the caller
  performs them.
- `hsm-self-defence/a55/tamper_event_test.c`, `quarantine_test.c`, run by
  `test/hsd_a55_test.sh`, which also checks that every vector of this note is in the
  parser test.

## Board validation list

Every item is to be validated on the board.

- Which channel of the table above reaches Linux when the M7 LM is stopped, and its
  latency against the A55 LM stop.
- The PRO file's notify grants on the M7 LM and the system protocol for the non-secure A55
  agent (fault-recovery §8).
- Whether a D-style shared region exists, who owns it, and that Linux cannot write to the
  M7's side of it.
- That an unprivileged process cannot write to the service's delivery node.
- That ending a key-store session after an event leaves a strict delete issued by the M7
  (or by its writer) durable, and what a restored pre-deletion blob does (tamper F5).
- That the enclave's errors after session end are all logged once and none is retried.
- The CRC-32 vectors above against the first parser implementation.

## Questions for the owner

All proposed, pending owner approval. Earlier questions are in the
[earlier design note](a55-self-defence-design.md).

1. **Which channel carries the event?**
   - (a) A (SCMI notification, adapter record) as the trigger, D for the full record if it exists.
   - (b) A only.
   - (c) D only, once trusted-firmware names it.

   Recommendation: (a). A is the only candidate with a sourced, if reference, permission;
   D is the only one that can carry every event code.

2. **Does the A55 acknowledge, and does the M7 resend its state?**
   - (a) No acknowledgement, no resend.
   - (b) No acknowledgement; the M7 resends its latest state to a service that starts late.
   - (c) The service acknowledges each record.

   Recommendation: (b). An acknowledgement from a witness proves nothing and gives the M7
   a reason to wait; a resend covers a late-starting service.

3. **Is TEST_EVENT accepted in production images?**
   - (a) Yes, always.
   - (b) Only in images built for validation.
   - (c) Never.

   Recommendation: (b). The test event is useful on the board and a needless input after.

4. **An unknown event code on an otherwise valid record.**
   - (a) Fail closed: quarantine (the contract above).
   - (b) Ignore and log.

   Recommendation: (a). Quarantine is the safe direction for a witness, and a version
   change is a release matter between the M7 firmware and the service.

5. **Must ending the key-store sessions leave the persistence writer running?**
   - (a) Yes: end the service's sessions only, keep the writer until the A55 LM stops.
   - (b) End everything the service owns.

   Recommendation: (a), until the zeroisation path that makes a strict delete durable
   is named (tamper survey question 3).

6. **How does the M7's zeroisation request reach the enclave under ruling 1234?**
   - (a) The M7 uses the enclave through its own messaging unit (tamper F5 unconfirmed).
   - (b) The M7 asks the A55 HSM service to delete, which breaks the witness principle and
     is rejected here.
   - (c) The M7 uses an abort or a system reaction and no delete.

   Recommendation: none from the sources; (b) is rejected, and (a) against (c) needs the
   missing reference manuals.

## Proposed SPEC changes (proposed, pending owner approval)

The `hsm-self-defence` row of `docs/SPEC.md` names this note and says that the A55 Linux
side, as the caller of the enclave's HSM API (ruling 1234), quarantines its key-store
sessions on the M7's tamper event; the A55 detector, the NPU model and the IMA log stay an
open question. The wording is in the row; it changes no other row.
