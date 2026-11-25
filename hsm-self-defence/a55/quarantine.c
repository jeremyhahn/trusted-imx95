#include "quarantine.h"

void quarantine_init(struct quarantine *q)
{
	int i;

	q->state = QUARANTINE_NORMAL;
	q->reason = QUARANTINE_REASON_NONE;
	for (i = 0; i < QUARANTINE_NSRC; i++)
		q->last_seq[i] = 0;
	q->replays = 0;
	q->gaps = 0;
}

/* Index of a sender's counter, or -1 for an unknown sender. */
static int src_index(uint8_t source)
{
	switch (source) {
	case TAMPER_SRC_M7:
		return 0;
	case TAMPER_SRC_ADAPTER:
		return 1;
	default:
		return -1;
	}
}

uint64_t quarantine_last_seq(const struct quarantine *q, uint8_t source)
{
	int i = src_index(source);

	return (q == NULL || i < 0) ? 0 : q->last_seq[i];
}

/* The note's table: state after an accepted event. */
static enum quarantine_state next_state(enum quarantine_state from, uint16_t code,
					enum quarantine_reason *reason)
{
	enum quarantine_state to;

	switch (code) {
	case TAMPER_ASSERTED:
		*reason = QUARANTINE_REASON_TAMPER_ASSERTED;
		to = QUARANTINE_QUARANTINED;
		break;
	case TAMPER_ZEROISATION_STARTED:
		*reason = QUARANTINE_REASON_ZEROISATION_STARTED;
		to = QUARANTINE_QUARANTINED;
		break;
	case TAMPER_ZEROISATION_DONE:
		*reason = QUARANTINE_REASON_ZEROISATION_DONE;
		to = QUARANTINE_TERMINAL;
		break;
	case TAMPER_SHUTDOWN_IMMINENT:
		*reason = QUARANTINE_REASON_SHUTDOWN_IMMINENT;
		to = QUARANTINE_TERMINAL;
		break;
	case TAMPER_TEST_EVENT:
		*reason = QUARANTINE_REASON_NONE;
		to = QUARANTINE_NORMAL;
		break;
	default: /* unknown code: fail closed */
		*reason = QUARANTINE_REASON_UNKNOWN_CODE;
		to = QUARANTINE_QUARANTINED;
		break;
	}
	/* No event moves a state back: take the stronger of the two. */
	return to > from ? to : from;
}

unsigned quarantine_step(struct quarantine *q, const struct tamper_event *ev)
{
	enum quarantine_state from, to;
	enum quarantine_reason reason;
	unsigned act = QUARANTINE_ACT_LOG;
	int si;

	if (q == NULL || ev == NULL)
		return act;
	si = src_index(ev->source);
	if (si < 0 || ev->sequence == 0 || ev->sequence <= q->last_seq[si]) {
		q->replays++;
		return act | QUARANTINE_ACT_REJECTED;
	}
	if (ev->sequence > q->last_seq[si] + 1)
		q->gaps++;
	q->last_seq[si] = ev->sequence;

	from = q->state;
	to = next_state(from, ev->code, &reason);
	if (from == QUARANTINE_NORMAL && to != QUARANTINE_NORMAL)
		q->reason = reason;
	q->state = to;

	/* Refuse and close once, on leaving normal; escalating from quarantined
	 * to terminal asks AWAIT_RESET only: no second close, no retry. */
	if (to != QUARANTINE_NORMAL && from == QUARANTINE_NORMAL)
		act |= QUARANTINE_ACT_REFUSE_KEY_OPS | QUARANTINE_ACT_CLOSE_SESSIONS;
	if (to == QUARANTINE_TERMINAL && from != QUARANTINE_TERMINAL)
		act |= QUARANTINE_ACT_AWAIT_RESET;
	return act;
}

int quarantine_allow_key_op(const struct quarantine *q)
{
	return q != NULL && q->state == QUARANTINE_NORMAL;
}

int quarantine_allow_enclave_call(const struct quarantine *q)
{
	return q != NULL && q->state != QUARANTINE_TERMINAL;
}

const char *quarantine_state_name(enum quarantine_state s)
{
	switch (s) {
	case QUARANTINE_NORMAL:
		return "normal";
	case QUARANTINE_QUARANTINED:
		return "quarantined";
	case QUARANTINE_TERMINAL:
		return "terminal";
	}
	return "unknown-state";
}

const char *quarantine_reason_name(enum quarantine_reason r)
{
	switch (r) {
	case QUARANTINE_REASON_NONE:
		return "none";
	case QUARANTINE_REASON_TAMPER_ASSERTED:
		return "tamper-asserted";
	case QUARANTINE_REASON_ZEROISATION_STARTED:
		return "zeroisation-started";
	case QUARANTINE_REASON_ZEROISATION_DONE:
		return "zeroisation-done";
	case QUARANTINE_REASON_SHUTDOWN_IMMINENT:
		return "shutdown-imminent";
	case QUARANTINE_REASON_UNKNOWN_CODE:
		return "unknown-code";
	}
	return "unknown-reason";
}
