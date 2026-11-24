/* Quarantine state machine of the A55 HSM service, per the design note
 * docs/hsm-self-defence/a55-tamper-response-design.md (proposed, pending
 * owner approval). Takes parsed events, returns actions; it calls no enclave
 * function and no device: the caller performs the actions. The note wins over
 * this code if they disagree. */
#ifndef QUARANTINE_H
#define QUARANTINE_H

#include <stdint.h>

#include "tamper_event.h"

enum quarantine_state {
	QUARANTINE_NORMAL = 0,
	QUARANTINE_QUARANTINED,
	QUARANTINE_TERMINAL
};

/* Why the service left normal (the first cause is kept). */
enum quarantine_reason {
	QUARANTINE_REASON_NONE = 0,
	QUARANTINE_REASON_TAMPER_ASSERTED,
	QUARANTINE_REASON_ZEROISATION_STARTED,
	QUARANTINE_REASON_ZEROISATION_DONE,
	QUARANTINE_REASON_SHUTDOWN_IMMINENT,
	QUARANTINE_REASON_UNKNOWN_CODE
};

/* Action bits the caller performs. */
#define QUARANTINE_ACT_LOG 0x01u            /* log the event (every call logs) */
#define QUARANTINE_ACT_REFUSE_KEY_OPS 0x02u /* refuse new key operations with KEYSTORE_QUARANTINED */
#define QUARANTINE_ACT_CLOSE_SESSIONS 0x04u /* end the service's key-store sessions; no retry */
#define QUARANTINE_ACT_AWAIT_RESET 0x08u    /* stop talking to the enclave; wait for the LM reset */
#define QUARANTINE_ACT_REJECTED 0x10u       /* the event was not acted on (replay): log only */

#define QUARANTINE_NSRC 2 /* M7 and adapter: one sequence counter each */

struct quarantine {
	enum quarantine_state state;
	enum quarantine_reason reason;
	/* last accepted sequence per sender (index quarantine_src_index), 0
	 * before any: the note's sequences are strictly increasing per sender */
	uint64_t last_seq[QUARANTINE_NSRC];
	uint32_t replays;      /* rejected non-increasing sequences */
	uint32_t gaps;         /* accepted events with a sequence gap */
};

/* Start in normal (a service restart after an LM reset). */
void quarantine_init(struct quarantine *q);

/* Last accepted sequence of a sender (enum tamper_source); 0 before any and
 * for an unknown sender. */
uint64_t quarantine_last_seq(const struct quarantine *q, uint8_t source);

/* Apply one parsed event. A sequence not above the last accepted one of the
 * same sender, or an unknown sender, is rejected: QUARANTINE_ACT_REJECTED |
 * QUARANTINE_ACT_LOG, no change of state or last sequence. Otherwise the
 * transitions of the note's table. CLOSE_SESSIONS (and REFUSE_KEY_OPS) is
 * asked once, on leaving normal; reaching terminal asks AWAIT_RESET (with
 * the close too only when it comes straight from normal). Returns the
 * actions to perform now; a NULL argument returns LOG only. */
unsigned quarantine_step(struct quarantine *q, const struct tamper_event *ev);

/* True only in normal. After quarantine it is false for good. */
int quarantine_allow_key_op(const struct quarantine *q);

/* False in terminal: the service no longer talks to the enclave. */
int quarantine_allow_enclave_call(const struct quarantine *q);

const char *quarantine_state_name(enum quarantine_state s);
const char *quarantine_reason_name(enum quarantine_reason r);

#endif
