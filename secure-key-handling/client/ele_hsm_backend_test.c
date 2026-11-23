/* Behavioural tests of ele_hsm_backend.c against the HSM test double
 * (ele_hsm_fake.c): the request flags it sends and how it translates the
 * library's return codes into the client's policy. Built against the pinned
 * library's headers (ELE_SRC); never touches an enclave. Exit 0 when all pass.
 */
#include <stdio.h>
#include <string.h>

#include "hsm_api.h"

#include "ele_client.h"
#include "ele_hsm_backend.h"
#include "ele_hsm_fake.h"

static int fails;

#define CHECK(cond, what)                                                     \
	do {                                                                  \
		if (!(cond)) {                                                \
			printf("FAIL %s (line %d)\n", what, __LINE__);        \
			fails++;                                              \
		}                                                             \
	} while (0)

#define OTHER_ERR 0xFEu /* neither HSM_NO_ERROR nor HSM_KEY_STORE_COUNTER */

static void open_client(struct ele_hsm_ctx *x, struct ele_client *c, bool split)
{
	uint32_t nonce = 1234;

	memset(&fake, 0, sizeof(fake));
	CHECK(ele_hsm_open(x, 5, &nonce) == 0, "open");
	CHECK(nonce == 0, "the caller's nonce is erased after open");
	x->counter_split_confirmed = split;
	ele_client_init(c, &ele_hsm_ops, x);
}

/* The library argument structure that held the nonce, as the hook sees it
 * after the backend erased it. */
static int wiped_calls, wiped_nonzero;

static void wipe_hook(const void *p, size_t n)
{
	const unsigned char *b = p;
	size_t i;

	wiped_calls++;
	for (i = 0; i < n; i++)
		if (b[i])
			wiped_nonzero++;
}

static void nonce_erasure(void)
{
	struct ele_hsm_ctx x;
	uint32_t nonce;

	ele_hsm_wipe_hook = wipe_hook;

	/* Success. */
	memset(&fake, 0, sizeof(fake));
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) == 0, "open for the erasure test");
	CHECK(fake.ks_nonce == 0xdeadbeef, "the library saw the nonce");
	CHECK(nonce == 0, "nonce zero after a successful open");
	CHECK(wiped_calls == 1 && wiped_nonzero == 0, "authentication_nonce copy zero after a successful open");
	ele_hsm_close(&x);

	/* The key store refuses the nonce. */
	memset(&fake, 0, sizeof(fake));
	fake.ks_err = OTHER_ERR;
	wiped_calls = wiped_nonzero = 0;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0, "open fails when the key store refuses");
	CHECK(nonce == 0, "nonce zero after a failed key store open");
	CHECK(wiped_calls == 1 && wiped_nonzero == 0, "authentication_nonce copy zero after a failed key store open");

	/* The session does not open: the key store service is never reached. */
	memset(&fake, 0, sizeof(fake));
	fake.session_err = OTHER_ERR;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0, "open fails when the session does not open");
	CHECK(nonce == 0, "nonce zero after a failed session open");

	ele_hsm_wipe_hook = NULL;
}

int main(void)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	enum ele_commit st;
	uint32_t id;
	uint8_t sig[128];
	size_t n;

	/* The store is loaded with strict and counted updates, never created. */
	open_client(&x, &c, true);
	CHECK(fake.ks_id == 5 && fake.ks_nonce == 1234, "store id and nonce passed");
	CHECK(fake.ks_flags == (HSM_SVC_KEY_STORE_FLAGS_LOAD | HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION |
				HSM_SVC_KEY_STORE_FLAGS_MONOTONIC),
	      "key store opened LOAD|STRICT_OPERATION|MONOTONIC");
	CHECK((fake.ks_flags & HSM_SVC_KEY_STORE_FLAGS_CREATE) == 0, "key store never CREATE");

	/* Generate: strict and counter flags, no plaintext key. */
	st = ELE_NOT_COMMITTED;
	CHECK(ele_generate_key(&c, &id, &st) == 0 && st == ELE_ROLLBACK_PROTECTED && id == 7,
	      "HSM_NO_ERROR with the split confirmed: rollback-protected");
	CHECK(fake.gen_flags == (HSM_OP_KEY_GENERATION_FLAGS_STRICT_OPERATION |
				 HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER),
	      "generate sends STRICT_OPERATION and MONOTONIC_COUNTER only");
	CHECK((fake.gen_flags & HSM_OP_KEY_GENERATION_FLAGS_PLAINTEXT_KEY) == 0, "generate never PLAINTEXT_KEY");
	CHECK(fake.gen_key_type == HSM_KEY_TYPE_ECC_NIST, "generate asks for an ECC NIST key");

	/* The split cannot be read through the API: unconfirmed, the generate is
	 * refused before any library call (it would update the store and spend
	 * a counter step for a key nobody tracks). */
	x.counter_split_confirmed = false;
	st = ELE_NOT_COMMITTED;
	id = 0;
	fake.gen_calls = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && id == 0 && fake.gen_calls == 0,
	      "split unconfirmed: generate refused, zero generate calls");
	x.counter_split_confirmed = true;

	/* HSM_KEY_STORE_COUNTER: accepted without the counter advancing. */
	fake.err = HSM_KEY_STORE_COUNTER;
	st = ELE_NOT_COMMITTED;
	id = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED && id == 7,
	      "HSM_KEY_STORE_COUNTER on generate: fails, state kept, accepted key id returned");

	/* Any other code fails and commits nothing. */
	fake.err = OTHER_ERR;
	st = ELE_NOT_COMMITTED;
	id = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_NOT_COMMITTED && id == 0,
	      "other code on generate: fails, not committed");

	/* Delete: the strict flag only; never rollback-protected. */
	fake.err = 0;
	CHECK(ele_delete_key(&c, 7, &st) == 0 && st == ELE_COMMITTED_UNPROTECTED,
	      "HSM_NO_ERROR on delete: committed, never rollback-protected");
	CHECK(fake.del_flags == HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION && fake.del_key == 7,
	      "delete sends STRICT_OPERATION only");
	fake.err = HSM_KEY_STORE_COUNTER;
	st = ELE_NOT_COMMITTED;
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED,
	      "HSM_KEY_STORE_COUNTER on delete: fails, state kept");
	fake.err = OTHER_ERR;
	st = ELE_NOT_COMMITTED;
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_NOT_COMMITTED, "other code on delete: fails, not committed");

	/* Sign goes through. */
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) == 0 && n == 64 && fake.sign_calls == 1, "sign");
	{
		size_t i;
		int same = 1;

		for (i = 0; i < 64; i++)
			if (sig[i] != (uint8_t)(3 * i + 1))
				same = 0;
		CHECK(same, "the signature bytes reach the caller unchanged");
	}

	ele_hsm_close(&x);
	nonce_erasure();
	if (fails)
		return 1;
	printf("ele_hsm_backend_test: all passed\n");
	return 0;
}
