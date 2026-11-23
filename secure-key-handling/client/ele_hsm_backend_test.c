/* Behavioural tests of ele_hsm_backend.c against the HSM test double
 * (ele_hsm_fake.c): the request flags it sends and how it translates the
 * library's return codes into the client's policy. Built against the pinned
 * library's headers (ELE_SRC); never touches an enclave. Exit 0 when all pass.
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

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
	memset(ks_seen, 0, sizeof(*ks_seen));
	CHECK(ele_hsm_open(x, 5, &nonce) == 0, "open");
	CHECK(nonce == 0, "the caller's nonce is erased after open");
	x->counter_split_confirmed = split;
	ele_client_init(c, &ele_hsm_ops, x);
}

/* The library argument structure that held the nonce, as the hook sees it
 * after the backend erased it. The hook runs in the key-store child, so it
 * records into the shared mapping. */
static void wipe_hook(const void *p, size_t n)
{
	const unsigned char *b = p;
	size_t i;

	ks_seen->hook_calls++;
	for (i = 0; i < n; i++)
		if (b[i])
			ks_seen->hook_nonzero++;
}

static int lock_ok(void)
{
	return 0;
}

static int lock_fails(void)
{
	return -1;
}

static int scrubs, scrub_bytes;

static void scrub_hook(size_t n)
{
	scrubs++;
	scrub_bytes = (int)n;
}

/* The library's stack copy of the nonce: the process is locked before the
 * call (fail closed) and the stack is scrubbed after it, on every exit. */
static void lock_and_scrub(void)
{
	struct ele_hsm_ctx x;
	uint32_t nonce;

	ele_hsm_scrub_hook = scrub_hook;

	scrubs = 0;
	memset(&fake, 0, sizeof(fake));
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) == 0 && scrubs == 1, "the stack is scrubbed after a successful open");
	CHECK(scrub_bytes >= 4096, "the scrub covers at least the SAB command and response buffers");
	ele_hsm_close(&x);

	scrubs = 0;
	memset(&fake, 0, sizeof(fake));
	fake.ks_err = OTHER_ERR;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0 && scrubs == 1, "the stack is scrubbed after a failed key store open");

	scrubs = 0;
	memset(&fake, 0, sizeof(fake));
	fake.session_err = OTHER_ERR;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0 && scrubs == 1, "the stack is scrubbed after a failed session open");

	/* mlockall fails: nothing is opened, the library never sees the nonce. */
	ele_hsm_lockall_override = lock_fails;
	scrubs = 0;
	memset(&fake, 0, sizeof(fake));
	memset(ks_seen, 0, sizeof(*ks_seen));
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) == ELE_HSM_OPEN_NOLOCK, "open refused when the process cannot be locked");
	CHECK(nonce == 0 && ks_seen->nonce == 0 && ks_seen->calls == 0, "the nonce is erased and never reached the library");
	ele_hsm_lockall_override = lock_ok;
	ele_hsm_scrub_hook = NULL;
}

static void nonce_erasure(void)
{
	struct ele_hsm_ctx x;
	uint32_t nonce;

	ele_hsm_wipe_hook = wipe_hook;

	/* Success. */
	memset(&fake, 0, sizeof(fake));
	memset(ks_seen, 0, sizeof(*ks_seen));
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) == 0, "open for the erasure test");
	CHECK(ks_seen->nonce == 0xdeadbeef, "the library saw the nonce");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after a successful open");
	CHECK(ks_seen->hook_calls == 1 && ks_seen->hook_nonzero == 0,
	      "the child's authentication_nonce copy is zero after a successful open");
	ele_hsm_close(&x);

	/* The key store refuses the nonce. */
	memset(&fake, 0, sizeof(fake));
	memset(ks_seen, 0, sizeof(*ks_seen));
	fake.ks_err = OTHER_ERR;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0, "open fails when the key store refuses");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after a failed key store open");
	CHECK(ks_seen->hook_calls == 1 && ks_seen->hook_nonzero == 0,
	      "the child's authentication_nonce copy is zero after a failed key store open");

	/* The session does not open: the key store service is never reached. */
	memset(&fake, 0, sizeof(fake));
	fake.session_err = OTHER_ERR;
	nonce = 0xdeadbeef;
	CHECK(ele_hsm_open(&x, 5, &nonce) != 0, "open fails when the session does not open");
	CHECK(nonce == 0, "nonce zero after a failed session open");

	ele_hsm_wipe_hook = NULL;

	/* The args page cannot be locked: open fails closed, the library never
	 * sees the nonce, and the nonce is erased. Run in a child so the limit
	 * does not reach the other tests. */
	{
		pid_t pid;
		int status = 0;

		fflush(stdout);
		pid = fork();
		if (pid == 0) {
			struct rlimit rl = { 0, 0 };
			uint32_t nn = 0xdeadbeef;

			ele_hsm_lockall_override = NULL; /* the real mlockall */
			if (setrlimit(RLIMIT_MEMLOCK, &rl) != 0)
				_exit(77);
			memset(&fake, 0, sizeof(fake));
			memset(ks_seen, 0, sizeof(*ks_seen));
			if (ele_hsm_open(&x, 5, &nn) == 0)
				_exit(77); /* lock is not limited here */
			_exit(nn == 0 && ks_seen->nonce == 0 ? 0 : 1);
		}
		CHECK(pid > 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status), "mlock child ran");
		if (WIFEXITED(status) && WEXITSTATUS(status) == 77)
			printf("skip: memory locking is not limited for this user\n");
		else
			CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "open fails closed when the nonce page cannot be locked");
	}
}

/* The child that makes the vendor call can die or lie: every such outcome is
 * a failed open, and the parent's nonce buffer is zero regardless. */
static void child_failures(void)
{
	static const struct {
		const char *what;
		uint32_t mode;
		size_t short_len;
	} cases[] = {
		{ "a child killed by a signal", 1, 0 },
		{ "a child that exits nonzero", 2, 0 },
		{ "a short result (0 bytes)", 0, 1 },
		{ "a short result (7 of 8 bytes)", 0, 7 },
	};
	size_t k;

	for (k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
		struct ele_hsm_ctx x;
		uint32_t nonce = 0xdeadbeef;
		char msg[96];

		memset(&fake, 0, sizeof(fake));
		memset(ks_seen, 0, sizeof(*ks_seen));
		fake.ks_mode = cases[k].mode;
		ele_hsm_result_len_override = cases[k].short_len;
		snprintf(msg, sizeof(msg), "open fails closed on %s", cases[k].what);
		CHECK(ele_hsm_open(&x, 5, &nonce) != 0 && !x.open && x.key_store == 0, msg);
		snprintf(msg, sizeof(msg), "the parent's nonce buffer is zero after %s", cases[k].what);
		CHECK(nonce == 0, msg);
		ele_hsm_result_len_override = 0;
	}
	/* A refusal by the library, sent intact, also fails. */
	{
		struct ele_hsm_ctx x;
		uint32_t nonce = 0xdeadbeef;

		memset(&fake, 0, sizeof(fake));
		fake.ks_err = OTHER_ERR;
		CHECK(ele_hsm_open(&x, 5, &nonce) != 0 && nonce == 0, "a library refusal fails the open");
	}
}

int main(void)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	enum ele_commit st;
	uint32_t id;
	uint8_t sig[128];
	size_t n;

	/* A unit test cannot count on its host's memory-lock limit: the real
	 * mlockall is exercised in a child with the limit at 0 (nonce_erasure). */
	ele_hsm_lockall_override = lock_ok;

	/* The store is loaded with strict and counted updates, never created. */
	open_client(&x, &c, true);
	CHECK(ks_seen->id == 5 && ks_seen->nonce == 1234, "store id and nonce passed");
	CHECK(ks_seen->flags == (HSM_SVC_KEY_STORE_FLAGS_LOAD | HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION |
				 HSM_SVC_KEY_STORE_FLAGS_MONOTONIC),
	      "key store opened LOAD|STRICT_OPERATION|MONOTONIC");
	CHECK((ks_seen->flags & HSM_SVC_KEY_STORE_FLAGS_CREATE) == 0, "key store never CREATE");
	CHECK(ks_seen->pid != 0 && ks_seen->pid != (uint32_t)getpid(),
	      "the vendor call that marshals the credential runs in a different pid");

	/* Generate: strict and counter flags, no plaintext key. */
	st = ELE_NOT_COMMITTED;
	/* HSM_NO_ERROR is also what a success-tagged warning response maps to:
	 * the counter acknowledgement cannot be established, so it fails closed. */
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED && id == 7,
	      "HSM_NO_ERROR (also a success-tagged warning): not rollback-protected, generate refused, key id kept");
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
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED,
	      "HSM_NO_ERROR on delete (also a success-tagged warning): fails closed, never rollback-protected");
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
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) == 0 && n == 64 && fake.sign_calls == 1, "sign reports 64, not the buffer size");
	/* A buffer under 64 bytes is refused before the library is called. */
	n = 63;
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0 && fake.sign_calls == 1, "short buffer refused before the call");
	/* The library's reported length is read (exp_signature_size): only 64 is accepted. */
	{
		static const uint32_t bad[] = { 0, 32, 63, 65, 72 };
		size_t k, i;
		int clean;

		for (k = 0; k < sizeof(bad) / sizeof(bad[0]); k++) {
			memset(sig, 0xaa, sizeof(sig));
			fake.sign_exp_set = true;
			fake.sign_exp_size = bad[k];
			n = sizeof(sig);
			clean = 1;
			CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0, "a length other than 64 is refused");
			for (i = 0; i < sizeof(sig); i++)
				if (sig[i] != 0)
					clean = 0;
			CHECK(clean, "no signature bytes are left in the caller's buffer after a refused length");
		}
		fake.sign_exp_set = false;
	}
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) == 0 && n == 64, "exp_signature_size 64: accepted");
	n = sizeof(sig);
	{
		size_t i;
		int same = 1;

		for (i = 0; i < 64; i++)
			if (sig[i] != (uint8_t)(3 * i + 1))
				same = 0;
		CHECK(same, "the signature bytes reach the caller unchanged");
	}

	ele_hsm_close(&x);
	lock_and_scrub();
	ele_hsm_wipe_hook = wipe_hook;
	nonce_erasure();
	child_failures();
	ele_hsm_wipe_hook = NULL;
	if (fails)
		return 1;
	printf("ele_hsm_backend_test: all passed\n");
	return 0;
}
