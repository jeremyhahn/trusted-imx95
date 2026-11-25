/* Host test of the quarantine state machine against the design note's
 * transition table (proposed, pending owner approval). */
#include <stdio.h>
#include <string.h>

#include "quarantine.h"

static int fails;

#define CHECK(cond, ...)                                                 \
	do {                                                             \
		if (!(cond)) {                                           \
			printf("FAIL %s:%d: ", __FILE__, __LINE__);      \
			printf(__VA_ARGS__);                             \
			printf("\n");                                    \
			fails++;                                         \
		}                                                        \
	} while (0)

/* The six event kinds of the table; the last is an unknown code. */
static const uint16_t codes[] = { TAMPER_ASSERTED, TAMPER_ZEROISATION_STARTED,
				  TAMPER_ZEROISATION_DONE, TAMPER_SHUTDOWN_IMMINENT,
				  TAMPER_TEST_EVENT, 0x0100 };
static const char *const code_names[] = { "TAMPER_ASSERTED", "ZEROISATION_STARTED",
					  "ZEROISATION_DONE", "SHUTDOWN_IMMINENT",
					  "TEST_EVENT", "unknown code" };
#define NCODES (sizeof(codes) / sizeof(codes[0]))

/* The note's table, rows in the order of codes[], columns normal,
 * quarantined, terminal. */
static const enum quarantine_state table[NCODES][3] = {
	{ QUARANTINE_QUARANTINED, QUARANTINE_QUARANTINED, QUARANTINE_TERMINAL },
	{ QUARANTINE_QUARANTINED, QUARANTINE_QUARANTINED, QUARANTINE_TERMINAL },
	{ QUARANTINE_TERMINAL, QUARANTINE_TERMINAL, QUARANTINE_TERMINAL },
	{ QUARANTINE_TERMINAL, QUARANTINE_TERMINAL, QUARANTINE_TERMINAL },
	{ QUARANTINE_NORMAL, QUARANTINE_QUARANTINED, QUARANTINE_TERMINAL },
	{ QUARANTINE_QUARANTINED, QUARANTINE_QUARANTINED, QUARANTINE_TERMINAL },
};

#define LAST(q, src) quarantine_last_seq(&(q), (uint8_t)(src))

static struct tamper_event mk(uint16_t code, uint64_t seq)
{
	struct tamper_event e;

	e.code = code;
	e.source = code == TAMPER_SHUTDOWN_IMMINENT ? TAMPER_SRC_ADAPTER : TAMPER_SRC_M7;
	e.sequence = seq;
	return e;
}

/* Put q in state s with last sequence 1. */
static void enter(struct quarantine *q, enum quarantine_state s)
{
	struct tamper_event e;

	quarantine_init(q);
	if (s == QUARANTINE_QUARANTINED)
		e = mk(TAMPER_ASSERTED, 1);
	else if (s == QUARANTINE_TERMINAL)
		e = mk(TAMPER_SHUTDOWN_IMMINENT, 1);
	else
		e = mk(TAMPER_TEST_EVENT, 1);
	quarantine_step(q, &e);
	CHECK(q->state == s, "setup of %s gave %s", quarantine_state_name(s),
	      quarantine_state_name(q->state));
}

static void test_init(void)
{
	struct quarantine q;

	memset(&q, 0xff, sizeof(q));
	quarantine_init(&q);
	CHECK(q.state == QUARANTINE_NORMAL && LAST(q, TAMPER_SRC_M7) == 0 &&
		      LAST(q, TAMPER_SRC_ADAPTER) == 0, "init state");
	CHECK(quarantine_allow_key_op(&q) && quarantine_allow_enclave_call(&q), "normal serves");
	CHECK(!quarantine_allow_key_op(NULL) && !quarantine_allow_enclave_call(NULL), "NULL denies");
	CHECK(quarantine_step(&q, NULL) == QUARANTINE_ACT_LOG && q.state == QUARANTINE_NORMAL,
	      "NULL event");
	CHECK(quarantine_step(NULL, NULL) == QUARANTINE_ACT_LOG, "NULL machine");
}

/* Every cell of the table: every code in every state. */
static void test_table(void)
{
	size_t c;
	int s;

	for (c = 0; c < NCODES; c++) {
		for (s = 0; s < 3; s++) {
			struct quarantine q;
			struct tamper_event e = mk(codes[c], 2);
			unsigned act;

			enter(&q, (enum quarantine_state)s);
			act = quarantine_step(&q, &e);
			CHECK(q.state == table[c][s], "%s from %s: %s, want %s", code_names[c],
			      quarantine_state_name((enum quarantine_state)s),
			      quarantine_state_name(q.state),
			      quarantine_state_name(table[c][s]));
			CHECK(LAST(q, e.source) == 2, "%s from %d: last sequence %llu", code_names[c], s,
			      (unsigned long long)LAST(q, e.source));
			CHECK((act & QUARANTINE_ACT_LOG) && !(act & QUARANTINE_ACT_REJECTED),
			      "%s from %d: accepted event must log, not reject", code_names[c], s);
			CHECK(quarantine_allow_key_op(&q) == (q.state == QUARANTINE_NORMAL),
			      "%s from %d: key-op gate", code_names[c], s);
			CHECK(quarantine_allow_enclave_call(&q) == (q.state != QUARANTINE_TERMINAL),
			      "%s from %d: enclave gate", code_names[c], s);
			/* Actions: entering a stronger state asks for its actions once. */
			if (s == QUARANTINE_NORMAL && table[c][s] != QUARANTINE_NORMAL)
				CHECK((act & (QUARANTINE_ACT_REFUSE_KEY_OPS | QUARANTINE_ACT_CLOSE_SESSIONS)) ==
					      (QUARANTINE_ACT_REFUSE_KEY_OPS | QUARANTINE_ACT_CLOSE_SESSIONS),
				      "%s from normal: refuse and close", code_names[c]);
			if (table[c][s] == QUARANTINE_TERMINAL && s != QUARANTINE_TERMINAL)
				CHECK(act & QUARANTINE_ACT_AWAIT_RESET, "%s from %d: await reset",
				      code_names[c], s);
			if (table[c][s] != QUARANTINE_TERMINAL)
				CHECK(!(act & QUARANTINE_ACT_AWAIT_RESET), "%s from %d: no await reset",
				      code_names[c], s);
			if (table[c][s] == (enum quarantine_state)s)
				CHECK(act == QUARANTINE_ACT_LOG, "%s from %d: no new action, got %#x",
				      code_names[c], s, act);
		}
	}
}

static void test_reasons(void)
{
	struct quarantine q;
	struct tamper_event e;

	quarantine_init(&q);
	e = mk(TAMPER_TEST_EVENT, 1);
	quarantine_step(&q, &e);
	CHECK(q.reason == QUARANTINE_REASON_NONE, "test event leaves no reason");
	e = mk(0x0100, 2);
	quarantine_step(&q, &e);
	CHECK(q.reason == QUARANTINE_REASON_UNKNOWN_CODE, "unknown code reason");
	CHECK(strcmp(quarantine_reason_name(q.reason), "unknown-code") == 0, "reason name");
	e = mk(TAMPER_SHUTDOWN_IMMINENT, 3);
	quarantine_step(&q, &e);
	CHECK(q.reason == QUARANTINE_REASON_UNKNOWN_CODE, "first reason is kept");
	CHECK(strcmp(quarantine_state_name(q.state), "terminal") == 0, "state name");
}

/* Replayed, repeated and decreasing sequence numbers are rejected and logged,
 * never acted on, in every state. */
static void test_sequence(void)
{
	static const uint64_t bad_seq[] = { 0, 1, 2, 4 }; /* last accepted is 5 */
	size_t i, c;
	int s;

	for (s = 0; s < 3; s++) {
		for (c = 0; c < NCODES; c++) {
			for (i = 0; i < sizeof(bad_seq) / sizeof(bad_seq[0]); i++) {
				struct quarantine q, before;
				struct tamper_event e = mk(codes[c], 5), r;
				unsigned act;

				enter(&q, (enum quarantine_state)s);
				quarantine_step(&q, &e); /* last sequence 5 */
				before = q;
				r = mk(codes[c], bad_seq[i]);
				act = quarantine_step(&q, &r);
				CHECK(act == (QUARANTINE_ACT_LOG | QUARANTINE_ACT_REJECTED),
				      "state %d %s seq %llu: actions %#x", s, code_names[c],
				      (unsigned long long)bad_seq[i], act);
				CHECK(q.state == before.state && LAST(q, e.source) == 5 &&
					      q.reason == before.reason && q.gaps == before.gaps &&
					      q.replays == before.replays + 1,
				      "state %d %s seq %llu: changed state", s, code_names[c],
				      (unsigned long long)bad_seq[i]);
			}
		}
	}
	/* Note's example: V1, V2, V3 accepted; then V1 again is a replay. */
	{
		struct quarantine q;
		struct tamper_event a = mk(TAMPER_ASSERTED, 1), b = mk(TAMPER_ZEROISATION_STARTED, 2),
				    d = mk(TAMPER_ZEROISATION_DONE, 3);

		quarantine_init(&q);
		CHECK(!(quarantine_step(&q, &a) & QUARANTINE_ACT_REJECTED), "1 accepted");
		CHECK(!(quarantine_step(&q, &b) & QUARANTINE_ACT_REJECTED), "2 accepted");
		CHECK(!(quarantine_step(&q, &d) & QUARANTINE_ACT_REJECTED), "3 accepted");
		CHECK(q.state == QUARANTINE_TERMINAL && LAST(q, TAMPER_SRC_M7) == 3, "terminal at 3");
		CHECK(quarantine_step(&q, &a) & QUARANTINE_ACT_REJECTED, "V1 again is a replay");
		CHECK(q.replays == 1 && q.gaps == 0, "counters");
	}
	/* A gap is accepted and counted. */
	{
		struct quarantine q;
		struct tamper_event a = mk(TAMPER_TEST_EVENT, 1), b = mk(TAMPER_TEST_EVENT, 9);

		quarantine_init(&q);
		quarantine_step(&q, &a);
		CHECK(!(quarantine_step(&q, &b) & QUARANTINE_ACT_REJECTED), "gap accepted");
		CHECK(q.gaps == 1 && LAST(q, TAMPER_SRC_M7) == 9, "gap counted");
		/* a first event with a high sequence is also a gap from 0 */
		quarantine_init(&q);
		CHECK(!(quarantine_step(&q, &b) & QUARANTINE_ACT_REJECTED), "first at 9 accepted");
		CHECK(q.gaps == 1, "first gap counted");
	}
}

/* No sequence of up to five events (with increasing sequence numbers, and
 * with every pattern of replays between) returns to normal once left. */
static void walk(struct quarantine q, int depth, unsigned long *runs)
{
	size_t c;

	if (depth == 0)
		return;
	for (c = 0; c < NCODES; c++) {
		struct quarantine n = q;
		struct tamper_event e = mk(codes[c], 0), old = e;
		uint64_t last = LAST(q, e.source);
		enum quarantine_state was = q.state;

		e.sequence = last + 1;
		old.sequence = last; /* replay (0 before any: also rejected) */
		quarantine_step(&n, &old);
		CHECK(n.state == was, "replay changed state");
		quarantine_step(&n, &e);
		(*runs)++;
		CHECK(n.state >= was, "state went back from %s to %s", quarantine_state_name(was),
		      quarantine_state_name(n.state));
		if (was != QUARANTINE_NORMAL) {
			CHECK(!quarantine_allow_key_op(&n), "key op allowed after quarantine");
			CHECK(n.state != QUARANTINE_NORMAL, "returned to normal");
		}
		walk(n, depth - 1, runs);
	}
}

static void test_no_return(void)
{
	struct quarantine q;
	unsigned long runs = 0;

	quarantine_init(&q);
	walk(q, 5, &runs);
	CHECK(runs > 1000, "walk covered %lu steps", runs);
	/* A long run of test events after quarantine stays quarantined. */
	enter(&q, QUARANTINE_QUARANTINED);
	{
		uint64_t i;

		for (i = 2; i < 1000; i++) {
			struct tamper_event e = mk(TAMPER_TEST_EVENT, i);

			quarantine_step(&q, &e);
			if (q.state != QUARANTINE_QUARANTINED || quarantine_allow_key_op(&q)) {
				CHECK(0, "test events changed quarantined at %llu", (unsigned long long)i);
				break;
			}
		}
	}
}

/* Sequences are per sender (note: strictly increasing per sender and boot):
 * the M7 at 5 does not make the adapter's first event (1) a replay. */
static void test_per_sender(void)
{
	struct quarantine q;
	struct tamper_event m7 = mk(TAMPER_TEST_EVENT, 5), ad = mk(TAMPER_SHUTDOWN_IMMINENT, 1);
	unsigned act;

	quarantine_init(&q);
	quarantine_step(&q, &m7);
	CHECK(q.state == QUARANTINE_NORMAL, "M7 test event keeps normal");
	act = quarantine_step(&q, &ad);
	CHECK(!(act & QUARANTINE_ACT_REJECTED), "adapter seq 1 after M7 seq 5 accepted, got %#x", act);
	CHECK(q.state == QUARANTINE_TERMINAL, "adapter shutdown moved the state: %s",
	      quarantine_state_name(q.state));
	CHECK(LAST(q, TAMPER_SRC_M7) == 5 && LAST(q, TAMPER_SRC_ADAPTER) == 1, "per-sender counters");
	CHECK(q.replays == 0 && q.gaps == 1, "no replay; the M7's 0 to 5 is the only gap");
	/* each sender's own replay is still rejected */
	act = quarantine_step(&q, &ad);
	CHECK(act & QUARANTINE_ACT_REJECTED, "adapter seq 1 again is a replay");
	m7.sequence = 5;
	act = quarantine_step(&q, &m7);
	CHECK(act & QUARANTINE_ACT_REJECTED, "M7 seq 5 again is a replay");
	/* an unknown sender is rejected, state untouched */
	{
		struct quarantine u;
		struct tamper_event bad = mk(TAMPER_ASSERTED, 1);

		quarantine_init(&u);
		bad.source = 0x7f;
		act = quarantine_step(&u, &bad);
		CHECK((act & QUARANTINE_ACT_REJECTED) && u.state == QUARANTINE_NORMAL,
		      "unknown sender rejected");
	}
}

/* Close the sessions once: leaving normal asks refuse + close; escalating to
 * terminal asks AWAIT_RESET with no second close (note: no retry). */
static void test_escalation_actions(void)
{
	static const uint16_t second[] = { TAMPER_ZEROISATION_DONE, TAMPER_SHUTDOWN_IMMINENT };
	const unsigned first_want = QUARANTINE_ACT_LOG | QUARANTINE_ACT_REFUSE_KEY_OPS |
				    QUARANTINE_ACT_CLOSE_SESSIONS;
	const unsigned second_want = QUARANTINE_ACT_LOG | QUARANTINE_ACT_AWAIT_RESET;
	size_t i;

	for (i = 0; i < sizeof(second) / sizeof(second[0]); i++) {
		struct quarantine q;
		struct tamper_event a = mk(TAMPER_ASSERTED, 1), b = mk(second[i], 2);
		unsigned act1, act2;

		quarantine_init(&q);
		act1 = quarantine_step(&q, &a);
		act2 = quarantine_step(&q, &b);
		CHECK(act1 == first_want, "asserted then code %u: first actions %#x, want %#x",
		      (unsigned)second[i], act1, first_want);
		CHECK(act2 == second_want, "asserted then code %u: second actions %#x, want %#x",
		      (unsigned)second[i], act2, second_want);
		CHECK(q.state == QUARANTINE_TERMINAL, "asserted then code %u: terminal", (unsigned)second[i]);
	}
}

int main(void)
{
	test_init();
	test_table();
	test_reasons();
	test_sequence();
	test_no_return();
	test_per_sender();
	test_escalation_actions();
	if (fails != 0) {
		printf("quarantine_test: %d failed\n", fails);
		return 1;
	}
	printf("quarantine_test: all passed\n");
	return 0;
}
