/* Host unit tests of the client policy against the stub. Exit 0 when all pass. */
#include <stdio.h>
#include <string.h>

#include "ele_client.h"
#include "ele_stub.h"

static int fails;

#define CHECK(cond, what)                                                     \
	do {                                                                  \
		if (!(cond)) {                                                \
			printf("FAIL %s (line %d)\n", what, __LINE__);        \
			fails++;                                              \
		}                                                             \
	} while (0)

static struct ele_stub make(bool strict, bool counter, bool warn, bool split)
{
	struct ele_stub s;

	memset(&s, 0, sizeof(s));
	s.reply.strict_acked = strict;
	s.reply.counter_acked = counter;
	s.reply.counter_warning = warn;
	s.reply.split_configured = split;
	return s;
}

/* Both operations that update the key store: generate, then delete. */
static void case_flags(const char *name, uint32_t sent, bool strict_ack, bool counter_ack,
		       bool warn, bool split, enum ele_commit want, bool want_ok)
{
	struct ele_stub s = make(strict_ack, counter_ack, warn, split);
	struct ele_client c;
	enum ele_commit st = ELE_NOT_COMMITTED;
	uint32_t id = 0;
	int rc;

	ele_client_init(&c, &ele_stub_ops, &s);
	c.flags = sent;
	rc = ele_generate_key(&c, &id, &st);
	CHECK((rc == 0) == want_ok, name);
	if (want_ok)
		CHECK(st == want, name);
	if (want_ok) {
		/* A delete is never rollback-protected: strict flag only. */
		rc = ele_delete_key(&c, id, &st);
		CHECK(rc == 0 && st == ELE_COMMITTED_UNPROTECTED, name);
		CHECK((s.last_flags & ELE_REQ_MONOTONIC_COUNTER) == 0, "delete sends no counter flag");
	}
}

/* A success followed by a failure on the same variables must not carry the
 * earlier operation's evidence: the state is not pre-initialised by hand, the
 * first (successful) call is what leaves it protected. */
static void case_success_then_failure(void)
{
	struct ele_stub s = make(true, true, false, true);
	struct ele_client c;
	enum ele_commit st;
	uint32_t id;

	ele_client_init(&c, &ele_stub_ops, &s);
	CHECK(ele_generate_key(&c, &id, &st) == 0 && st == ELE_ROLLBACK_PROTECTED && id != 0,
	      "first generate succeeds and is protected");
	s.fail = 1;
	CHECK(ele_generate_key(&c, &id, &st) != 0, "second generate fails");
	CHECK(st == ELE_NOT_COMMITTED, "a failed generate reports not committed, not the previous state");
	CHECK(id == 0, "a failed generate returns no key id");

	s.fail = 0;
	CHECK(ele_generate_key(&c, &id, &st) == 0 && st == ELE_ROLLBACK_PROTECTED, "generate again");
	CHECK(ele_delete_key(&c, id, &st) == 0 && st == ELE_COMMITTED_UNPROTECTED, "delete succeeds");
	s.fail = 1;
	CHECK(ele_delete_key(&c, id, &st) != 0, "failed delete");
	CHECK(st == ELE_NOT_COMMITTED, "a failed delete reports not committed, not the previous state");
}

int main(void)
{
	const uint32_t both = ELE_REQ_STRICT_OPERATION | ELE_REQ_MONOTONIC_COUNTER;

	/* The four flag combinations of decision 241. */
	case_flags("both flags", both, true, true, false, true, ELE_ROLLBACK_PROTECTED, true);
	case_flags("strict only", ELE_REQ_STRICT_OPERATION, true, true, false, true,
		   ELE_COMMITTED_UNPROTECTED, true);
	case_flags("counter only", ELE_REQ_MONOTONIC_COUNTER, true, true, false, true,
		   ELE_NOT_COMMITTED, false);
	case_flags("neither", 0, true, true, false, true, ELE_NOT_COMMITTED, false);

	/* Both sent, but the enclave acknowledges one, or warns. */
	/* The diagnostic state is kept, but the call fails (case_state). */
	case_flags("strict acked, counter not", both, true, false, false, true,
		   ELE_COMMITTED_UNPROTECTED, false);
	case_flags("counter acked, strict not", both, false, true, false, true,
		   ELE_NOT_COMMITTED, false);
	case_flags("counter warning", both, true, true, true, true, ELE_COMMITTED_UNPROTECTED, false);
	case_flags("no counter split", both, true, true, false, false, ELE_COMMITTED_UNPROTECTED, false);
	case_flags("counter warning, strict only", ELE_REQ_STRICT_OPERATION, true, false, true, true,
		   ELE_COMMITTED_UNPROTECTED, false);

	/* A failed update still reports why (the state is not cleared). */
	{
		struct ele_stub s = make(true, true, true, true);
		struct ele_client c;
		enum ele_commit st = ELE_NOT_COMMITTED;
		uint32_t id = 0;

		ele_client_init(&c, &ele_stub_ops, &s);
		CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED && id == 1,
		      "counter warning fails, state kept, the accepted key id is returned");
		st = ELE_NOT_COMMITTED;
		CHECK(ele_delete_key(&c, 1, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED,
		      "counter warning on delete fails, state kept");
	}

	/* The default client sends both flags. */
	{
		struct ele_stub s = make(true, true, false, true);
		struct ele_client c;
		enum ele_commit st;
		uint32_t id;
		uint8_t sig[8];
		size_t n = sizeof(sig);

		ele_client_init(&c, &ele_stub_ops, &s);
		CHECK(c.flags == both, "default sends both flags");
		CHECK(ele_generate_key(&c, &id, &st) == 0 && st == ELE_ROLLBACK_PROTECTED, "default generate");
		CHECK(s.last_flags == both, "stub saw both flags");
		CHECK(ele_sign(&c, id, (const uint8_t *)"m", 1, sig, &n) == 0 && n == 1, "sign");
		CHECK(ele_delete_key(&c, id, &st) == 0 && st == ELE_COMMITTED_UNPROTECTED,
		      "default delete is committed, never rollback-protected");
		CHECK(ele_sign(&c, 99, (const uint8_t *)"m", 1, sig, &n) != 0, "sign unknown key fails");
	}

	/* A failing library fails the call; a missing ack pointer is not protected. */
	{
		struct ele_stub s = make(true, true, false, true);
		struct ele_client c;
		enum ele_commit st = ELE_ROLLBACK_PROTECTED;
		uint32_t id = 0;

		s.fail = 1;
		ele_client_init(&c, &ele_stub_ops, &s);
		CHECK(ele_generate_key(&c, &id, &st) != 0 && id == 0, "library failure");
		CHECK(ele_classify(both, NULL) == ELE_NOT_COMMITTED, "null ack");
	}

	case_success_then_failure();
	CHECK(strcmp(ele_commit_name(ELE_ROLLBACK_PROTECTED), "rollback-protected") == 0, "name");

	if (fails)
		return 1;
	printf("ele_client_test: all passed\n");
	return 0;
}
