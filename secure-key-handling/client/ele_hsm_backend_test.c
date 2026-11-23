/* Behavioural tests of ele_hsm_backend.c against the HSM test double
 * (ele_hsm_fake.c). Each CLI operation runs as one unit in one forked child:
 * the double logs every library call with its pid in shared memory, so the
 * tests check that the whole operation ran in one pid that is not the
 * parent's, and that the parent made no library call. */
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
			fprintf(stderr, "FAIL: %s (line %d)\n", what, __LINE__); \
			fails++;                                              \
		}                                                             \
	} while (0)

#define OTHER_ERR 0xFEu /* neither HSM_NO_ERROR nor HSM_KEY_STORE_COUNTER */
#define NONCE 0xdeadbeefu

static void wipe_hook(const void *p, size_t n)
{
	const unsigned char *b = p;
	size_t i;

	ks_seen->hook_calls++;
	for (i = 0; i < n; i++)
		if (b[i])
			ks_seen->hook_nonzero++;
}

static void scrub_hook(size_t n)
{
	ks_seen->scrubs++;
	ks_seen->scrub_bytes = (uint32_t)n;
}

static int lock_ok(void)
{
	return 0;
}

static int lock_fails(void)
{
	return -1;
}

static void reset(void)
{
	memset(&fake, 0, sizeof(fake));
	memset(ks_seen, 0, sizeof(*ks_seen));
}

/* The call log is exactly this sequence of names, in one pid, not the parent's. */
static bool one_child(const char *const *names, size_t n)
{
	size_t i;

	if (fake.calls != n || n > 32)
		return false;
	for (i = 0; i < n; i++) {
		if (strncmp(fake.call_name[i], names[i], 15) != 0)
			return false;
		if (fake.call_pid[i] != fake.call_pid[0])
			return false;
	}
	return fake.call_pid[0] != 0 && fake.call_pid[0] != (uint32_t)getpid();
}

static const char *const seq_gen[] = { "open_session", "key_store", "open_key_management", "generate",
				       "close_key_management", "close_key_store", "close_session" };
static const char *const seq_del[] = { "open_session", "key_store", "open_key_management", "delete",
				       "close_key_management", "close_key_store", "close_session" };
static const char *const seq_sign[] = { "open_session", "key_store", "open_sign_gen", "sign",
					"close_sign_gen", "close_key_store", "close_session" };
#define NSEQ 7

static void begin(struct ele_hsm_ctx *x, struct ele_client *c, uint32_t *nonce, bool split)
{
	reset();
	*nonce = NONCE;
	CHECK(ele_hsm_open(x, 5, nonce) == 0, "open");
	x->counter_split_confirmed = split;
	ele_client_init(c, &ele_hsm_ops, x);
}

static int do_sign(uint32_t *nonce, uint8_t *sig, size_t *n)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	int rc;

	begin(&x, &c, nonce, true);
	rc = ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, n);
	ele_hsm_close(&x);
	return rc;
}

static void isolation(void)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	enum ele_commit st = ELE_NOT_COMMITTED;
	uint32_t id = 0, nonce;
	uint8_t sig[128];
	size_t n = sizeof(sig), i;
	int same = 1;

	/* Sign: the stub's 64 bytes reach the parent; every call in one child. */
	memset(sig, 0xaa, sizeof(sig));
	CHECK(do_sign(&nonce, sig, &n) == 0 && n == 64, "sign succeeds and reports 64");
	for (i = 0; i < 64; i++)
		if (sig[i] != (uint8_t)(3 * i + 1))
			same = 0;
	CHECK(same, "the stub's signature bytes reach the parent unchanged");
	CHECK(one_child(seq_sign, NSEQ), "sign: open session, open key store, sign, close, close in one child pid, none in the parent");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after sign");
	CHECK(ks_seen->id == 5 && ks_seen->nonce == NONCE, "store id and nonce reached the library, in the child");
	CHECK(ks_seen->flags == (HSM_SVC_KEY_STORE_FLAGS_LOAD | HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION |
				 HSM_SVC_KEY_STORE_FLAGS_MONOTONIC),
	      "key store opened LOAD|STRICT_OPERATION|MONOTONIC");
	CHECK((ks_seen->flags & HSM_SVC_KEY_STORE_FLAGS_CREATE) == 0, "key store never CREATE");
	CHECK(fake.sign_calls == 1, "one sign call");
	CHECK(ks_seen->scrubs >= 1 && ks_seen->scrub_bytes >= 4096, "the child scrubs its stack after the key store open");

	/* Generate: HSM_NO_ERROR cannot show the counter advanced: refused, id kept. */
	begin(&x, &c, &nonce, true);
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED && id == 7,
	      "generate: not rollback-protected, refused, key id kept");
	CHECK(one_child(seq_gen, NSEQ), "generate: all vendor calls in one child pid, none in the parent");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after generate");
	CHECK(fake.gen_flags == (HSM_OP_KEY_GENERATION_FLAGS_STRICT_OPERATION | HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER),
	      "generate sends STRICT_OPERATION and MONOTONIC_COUNTER only");
	CHECK(fake.gen_key_type == HSM_KEY_TYPE_ECC_NIST, "generate asks for an ECC NIST key");
	ele_hsm_close(&x);

	/* Generate on a counter warning and on another code. */
	begin(&x, &c, &nonce, true);
	fake.err = HSM_KEY_STORE_COUNTER;
	st = ELE_NOT_COMMITTED;
	id = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED && id == 7,
	      "HSM_KEY_STORE_COUNTER on generate: fails, state kept, key id returned");
	ele_hsm_close(&x);
	begin(&x, &c, &nonce, true);
	fake.err = OTHER_ERR;
	st = ELE_NOT_COMMITTED;
	id = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && st == ELE_NOT_COMMITTED && id == 0,
	      "other code on generate: fails, not committed");
	ele_hsm_close(&x);

	/* Split unconfirmed: refused before any fork, so before any library call. */
	begin(&x, &c, &nonce, false);
	id = 0;
	CHECK(ele_generate_key(&c, &id, &st) != 0 && id == 0 && fake.calls == 0,
	      "split unconfirmed: generate refused, zero library calls");
	ele_hsm_close(&x);
	CHECK(nonce == 0, "the nonce is erased by close when no operation ran");

	/* Delete: the strict flag only; never rollback-protected. */
	begin(&x, &c, &nonce, true);
	st = ELE_NOT_COMMITTED;
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED,
	      "delete: fails closed, never rollback-protected");
	CHECK(one_child(seq_del, NSEQ), "delete: all vendor calls in one child pid, none in the parent");
	CHECK(fake.del_flags == HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION && fake.del_key == 7, "delete sends STRICT_OPERATION only");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after delete");
	ele_hsm_close(&x);
	begin(&x, &c, &nonce, true);
	fake.err = HSM_KEY_STORE_COUNTER;
	st = ELE_NOT_COMMITTED;
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_COMMITTED_UNPROTECTED, "HSM_KEY_STORE_COUNTER on delete: fails, state kept");
	ele_hsm_close(&x);
	begin(&x, &c, &nonce, true);
	fake.err = OTHER_ERR;
	st = ELE_NOT_COMMITTED;
	CHECK(ele_delete_key(&c, 7, &st) != 0 && st == ELE_NOT_COMMITTED, "other code on delete: fails, not committed");
	ele_hsm_close(&x);

	/* One operation per open: the nonce is spent, a second operation fails. */
	begin(&x, &c, &nonce, true);
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) == 0, "first operation");
	fake.calls = 0;
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0 && fake.calls == 0,
	      "a second operation on the same open fails without any library call");
	ele_hsm_close(&x);

	/* A buffer under 64 bytes is refused before any fork. */
	begin(&x, &c, &nonce, true);
	n = 63;
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0 && fake.calls == 0, "short buffer refused before the call");
	ele_hsm_close(&x);
}

static void wrong_length(void)
{
	static const uint32_t bad[] = { 0, 32, 63, 65, 72 };
	uint8_t sig[128];
	uint32_t nonce;
	size_t k, i, n;

	for (k = 0; k < sizeof(bad) / sizeof(bad[0]); k++) {
		struct ele_hsm_ctx x;
		struct ele_client c;
		int clean = 1;

		begin(&x, &c, &nonce, true);
		fake.sign_exp_set = true;
		fake.sign_exp_size = bad[k];
		memset(sig, 0xaa, sizeof(sig));
		n = sizeof(sig);
		CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0, "a length other than 64 is refused");
		for (i = 0; i < sizeof(sig); i++)
			if (sig[i] != 0)
				clean = 0;
		CHECK(clean, "no signature bytes are left in the caller's buffer after a refused length");
		CHECK(nonce == 0, "the parent's nonce buffer is zero after a refused length");
		ele_hsm_close(&x);
	}
}

/* The child can die or lie: every such outcome fails the operation, and the
 * parent's nonce buffer is zero regardless. */
static void child_failures(void)
{
	static const struct {
		const char *what;
		uint32_t mode;
		size_t short_len;
	} cases[] = {
		{ "a child killed by a signal", 1, 0 },
		{ "a child that exits nonzero", 2, 0 },
		{ "a short result (1 byte)", 0, 1 },
		{ "a short result (7 bytes)", 0, 7 },
		{ "a short result (79 bytes)", 0, 79 },
	};
	size_t k, o;

	for (k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
		for (o = 0; o < 3; o++) {
			static const char *const opn[] = { "sign", "generate", "delete" };
			struct ele_hsm_ctx x;
			struct ele_client c;
			enum ele_commit st = ELE_NOT_COMMITTED;
			uint8_t sig[64];
			uint32_t nonce, id = 0;
			size_t n = sizeof(sig);
			int rc;
			char msg[96];

			begin(&x, &c, &nonce, true);
			fake.ks_mode = cases[k].mode;
			ele_hsm_result_len_override = cases[k].short_len;
			if (o == 0)
				rc = ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n);
			else if (o == 1)
				rc = ele_generate_key(&c, &id, &st);
			else
				rc = ele_delete_key(&c, 7, &st);
			ele_hsm_result_len_override = 0;
			snprintf(msg, sizeof(msg), "%s fails closed on %s", opn[o], cases[k].what);
			CHECK(rc != 0 && st == ELE_NOT_COMMITTED && id == 0, msg);
			snprintf(msg, sizeof(msg), "%s: the parent's nonce buffer is zero after %s", opn[o], cases[k].what);
			CHECK(nonce == 0, msg);
			ele_hsm_close(&x);
		}
	}
}

/* A refusal by the library at the session or the key store fails the
 * operation; the nonce copies are zero in the parent and in the child. */
static void nonce_erasure(void)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	uint8_t sig[64];
	uint32_t nonce;
	size_t n = sizeof(sig);

	ele_hsm_wipe_hook = wipe_hook;
	begin(&x, &c, &nonce, true);
	CHECK(nonce == NONCE, "the slot still holds the nonce until the operation forks");
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) == 0, "sign for the erasure test");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after a successful operation");
	CHECK(ks_seen->hook_calls == 1 && ks_seen->hook_nonzero == 0,
	      "the child's authentication_nonce copy is zero after a successful open");
	ele_hsm_close(&x);

	begin(&x, &c, &nonce, true);
	fake.ks_err = OTHER_ERR;
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0, "the operation fails when the key store refuses");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after a failed key store open");
	CHECK(ks_seen->hook_calls == 1 && ks_seen->hook_nonzero == 0,
	      "the child's authentication_nonce copy is zero after a failed key store open");
	CHECK(fake.calls == 3 && strncmp(fake.call_name[2], "close_session", 15) == 0,
	      "after a refused key store the child closes the session and nothing else");
	ele_hsm_close(&x);

	begin(&x, &c, &nonce, true);
	fake.session_err = OTHER_ERR;
	n = sizeof(sig);
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0, "the operation fails when the session does not open");
	CHECK(nonce == 0, "nonce zero after a failed session open");
	CHECK(ks_seen->calls == 0, "the key store is never reached without a session");
	CHECK(ks_seen->scrubs >= 1, "the stack is scrubbed after a failed session open");
	ele_hsm_close(&x);
	ele_hsm_wipe_hook = NULL;
}

/* mlockall fails: nothing is opened and the library never sees the nonce. */
static void lock_failures(void)
{
	struct ele_hsm_ctx x;
	struct ele_client c;
	uint8_t sig[64];
	uint32_t nonce;
	size_t n = sizeof(sig);

	ele_hsm_lockall_override = lock_fails;
	reset();
	nonce = NONCE;
	CHECK(ele_hsm_open(&x, 5, &nonce) == ELE_HSM_OPEN_NOLOCK, "open refused when the process cannot be locked");
	CHECK(nonce == 0 && ks_seen->nonce == 0 && fake.calls == 0, "the nonce is erased and never reached the library");

	/* The lock holds in the parent but fails in the child: the operation fails. */
	ele_hsm_lockall_override = lock_ok;
	begin(&x, &c, &nonce, true);
	ele_hsm_lockall_override = lock_fails;
	CHECK(ele_sign(&c, 7, (const uint8_t *)"m", 1, sig, &n) != 0 && fake.calls == 0,
	      "a child that cannot lock its memory fails closed before any library call");
	CHECK(nonce == 0, "the parent's nonce buffer is zero after a child lock failure");
	ele_hsm_lockall_override = lock_ok;
	ele_hsm_close(&x);

	/* The real mlockall with a zero limit, in a child so the limit stays there. */
	{
		pid_t pid;
		int status = 0;

		fflush(stdout);
		pid = fork();
		if (pid == 0) {
			struct rlimit rl = { 0, 0 };
			uint32_t nn = NONCE;

			ele_hsm_lockall_override = NULL;
			if (setrlimit(RLIMIT_MEMLOCK, &rl) != 0)
				_exit(77);
			reset();
			if (ele_hsm_open(&x, 5, &nn) == 0)
				_exit(77); /* lock is not limited here */
			_exit(nn == 0 && ks_seen->nonce == 0 ? 0 : 1);
		}
		CHECK(pid > 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status), "mlock child ran");
		if (WIFEXITED(status) && WEXITSTATUS(status) == 77)
			printf("skip: memory locking is not limited for this user\n");
		else
			CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "open fails closed when the memory cannot be locked");
	}
}

int main(void)
{
	/* A unit test cannot count on its host's memory-lock limit: the real
	 * mlockall is exercised in a child with the limit at 0 (lock_failures). */
	ele_hsm_lockall_override = lock_ok;
	ele_hsm_scrub_hook = scrub_hook;

	isolation();
	wrong_length();
	child_failures();
	nonce_erasure();
	lock_failures();
	if (fails)
		return 1;
	printf("ele_hsm_backend_test: all passed\n");
	return 0;
}
