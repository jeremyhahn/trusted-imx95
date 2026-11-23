#define _DEFAULT_SOURCE
/* See ele_hsm_backend.h. PROVISIONAL.
 *
 * The flag and return-code names are the library's own, from hsm_api.h and
 * internal/hsm_key_store.h, hsm_key_generate.h, hsm_delete_key.h, hsm_utils.h
 * at the pinned commit; ele_hsm_consts_check.c asserts their values.
 */
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "hsm_api.h"

#include "ele_hsm_backend.h"
#include "ele_secure.h"

void (*ele_hsm_wipe_hook)(const void *copy, size_t len);

int (*ele_hsm_lockall_override)(void);
void (*ele_hsm_scrub_hook)(size_t len);
size_t ele_hsm_result_len_override;

/* The library copies the nonce into its own stack buffer (process_sab_msg's
 * cmd[MAX_CMD_WORD_SZ = 256] words, plus the response buffer and frames) and
 * does not wipe it. That call runs in a child process (ks_open_isolated),
 * which is what removes the copy. This many bytes of dead stack are also
 * zeroed after the call, in both processes: defence in depth, best effort,
 * and not evidence that the vendor's copy is erased (client.md). */
#define ELE_SCRUB_BYTES 16384u

static int lock_process(void)
{
	if (ele_hsm_lockall_override)
		return ele_hsm_lockall_override();
	return mlockall(MCL_CURRENT | MCL_FUTURE);
}

__attribute__((noinline)) static void scrub_stack(void)
{
	volatile unsigned char buf[ELE_SCRUB_BYTES];

	ele_secure_zero((void *)buf, sizeof(buf));
	if (ele_hsm_scrub_hook)
		ele_hsm_scrub_hook(sizeof(buf));
}

/* P-256 r||s; provisional, the library does not report the length. */
#define ELE_SIG_LEN 64u

/* The request flags of the client, mapped to the library's. */
static uint8_t gen_flags(uint32_t f)
{
	uint8_t o = 0;

	if (f & ELE_REQ_STRICT_OPERATION)
		o |= HSM_OP_KEY_GENERATION_FLAGS_STRICT_OPERATION;
	if (f & ELE_REQ_MONOTONIC_COUNTER)
		o |= HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER;
	return o;
}

/* Fill the acknowledgement from the library's return code. A counter warning
 * (HSM_KEY_STORE_COUNTER) means the update was accepted without the counter
 * advancing: the strict operation is acknowledged, the counter flag is not. */
static bool fill_ack(hsm_err_t err, uint32_t sent, bool split, struct ele_ack *ack)
{
	if (err != HSM_NO_ERROR && err != HSM_KEY_STORE_COUNTER)
		return false;
	ack->strict_acked = (sent & ELE_REQ_STRICT_OPERATION) != 0;
	ack->counter_warning = err == HSM_KEY_STORE_COUNTER;
	/* Fail closed. The pinned library maps a success-tagged response that
	 * carries a warning rating to HSM_NO_ERROR (client.md, contract table),
	 * so HSM_NO_ERROR does not show that the counter advanced. No per-flag
	 * acknowledgement is exposed, so the counter flag is never reported
	 * acknowledged and nothing is reported rollback-protected from here;
	 * a generate is refused with the key id kept for reconciliation.
	 * PROVISIONAL: lifted only by evidence from the board or a library
	 * that exposes the acknowledgement (the owner's call). */
	ack->counter_acked = false;
	ack->split_configured = split;
	return true;
}

static int hsm_generate(void *p, uint32_t flags, uint32_t *key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *c = p;
	op_generate_key_args_t a;
	uint32_t id = 0;
	hsm_err_t err;

	if (!c->open)
		return -1;
	/* The split cannot be read through the API. Generating while it is
	 * unconfirmed would update the store (and may spend a finite counter
	 * step) and then be refused, leaving an untracked key: refuse first. */
	if (!c->counter_split_confirmed)
		return -1;
	memset(&a, 0, sizeof(a));
	a.key_identifier = &id;	/* 0: the enclave picks the identifier */
	a.flags = gen_flags(flags);
	/* No plaintext export: HSM_OP_KEY_GENERATION_FLAGS_PLAINTEXT_KEY is never set. */
	a.key_type = HSM_KEY_TYPE_ECC_NIST;
	a.key_group = 0;
	a.key_lifetime = HSM_SE_KEY_STORAGE_PERSISTENT;
	a.key_usage = HSM_KEY_USAGE_SIGN_HASH;
	a.permitted_algo = PERMITTED_ALGO_ECDSA_SHA256;
	a.bit_key_sz = HSM_KEY_SIZE_ECC_NIST_256;
	err = hsm_generate_key(c->key_mgmt, &a);
	if (!fill_ack(err, flags, c->counter_split_confirmed, ack))
		return -1;
	*key_id = id;
	return 0;
}

static int hsm_sign(void *p, uint32_t key_id, const uint8_t *msg, size_t msg_len,
		    uint8_t *sig, size_t *sig_len)
{
	struct ele_hsm_ctx *c = p;
	op_generate_sign_args_t a;

	/* A buffer under 64 bytes (P-256 r||s, provisional) is refused before
	 * the call: the library does not report the size back (see client.md). */
	if (!c->open || msg_len > UINT32_MAX || *sig_len > UINT16_MAX || *sig_len < ELE_SIG_LEN)
		return -1;
	memset(&a, 0, sizeof(a));
	a.key_identifier = key_id;
	a.message = (uint8_t *)msg;
	a.message_size = (uint32_t)msg_len;
	a.signature = sig;
	a.signature_size = (uint16_t)*sig_len;
	a.scheme_id = (hsm_signature_scheme_id_t)ALGO_ECDSA_SHA256;
	a.flags = HSM_OP_GENERATE_SIGN_FLAGS_INPUT_MESSAGE;
	if (hsm_generate_signature(c->sign_gen, &a) != HSM_NO_ERROR) {
		ele_secure_zero(sig, *sig_len);
		return -1;
	}
	/* A successful sign does not update signature_size (sab_sign_gen.c:178);
	 * the response size is exp_signature_size. This binding supports P-256
	 * only: any length other than 64 is refused and nothing is returned. */
	if (a.exp_signature_size != ELE_SIG_LEN) {
		ele_secure_zero(sig, *sig_len);
		return -1;
	}
	*sig_len = ELE_SIG_LEN;
	return 0;
}

/* The library's delete has HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION and no
 * monotonic-counter flag: only the strict flag is sent, and the counter flag
 * is never acknowledged for a delete (client.md). */
static int hsm_del(void *p, uint32_t flags, uint32_t key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *c = p;
	op_delete_key_args_t a;
	hsm_err_t err;

	if (!c->open)
		return -1;
	memset(&a, 0, sizeof(a));
	a.key_identifier = key_id;
	if (flags & ELE_REQ_STRICT_OPERATION)
		a.flags = HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION;
	err = hsm_delete_key(c->key_mgmt, &a);
	return fill_ack(err, flags & ELE_REQ_STRICT_OPERATION, c->counter_split_confirmed, ack) ? 0 : -1;
}

const struct ele_ops ele_hsm_ops = { hsm_generate, hsm_sign, hsm_del };

/* What the child reports: the library's status and the new service handle,
 * nothing else. The parent accepts exactly this many bytes. */
struct ks_result {
	int32_t err;
	uint32_t handle;
};

/* The child. It owns the only live copy of the credential after the fork: it
 * is non-dumpable and locked, builds the library's arguments in its own
 * memory, makes the one vendor call, erases what it can reach, writes the
 * result and leaves with _exit() (no atexit handler, no stdio flush). Its
 * pages, the vendor stack frame included, are released when it exits. */
__attribute__((noreturn)) static void ks_child(int wfd, hsm_hdl_t session, uint32_t key_store_id,
					       uint32_t *nonce)
{
	open_svc_key_store_args_t ks;
	struct ks_result res;
	size_t n = sizeof(res);
	const unsigned char *p = (const unsigned char *)&res;
	hsm_hdl_t h = 0;

	if (prctl(PR_SET_DUMPABLE, 0) != 0 || lock_process() != 0)
		_exit(3);
	memset(&ks, 0, sizeof(ks));
	ks.key_store_identifier = key_store_id;
	ks.authentication_nonce = *nonce;
	/* The store is loaded, never created here; both update flags are set so
	 * the store's updates are strict and counted. */
	ks.flags = HSM_SVC_KEY_STORE_FLAGS_LOAD | HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION |
		   HSM_SVC_KEY_STORE_FLAGS_MONOTONIC;
	memset(&res, 0, sizeof(res));
	res.err = (int32_t)hsm_open_key_store_service(session, &ks, &h);
	res.handle = h;
	ele_secure_zero(nonce, sizeof(*nonce));
	ele_secure_zero(&ks, sizeof(ks));
	if (ele_hsm_wipe_hook)
		ele_hsm_wipe_hook(&ks, sizeof(ks));
	scrub_stack();
	if (ele_hsm_result_len_override && ele_hsm_result_len_override < n)
		n = ele_hsm_result_len_override;
	while (n > 0) {
		ssize_t w = write(wfd, p, n);

		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			_exit(4);
		p += w;
		n -= (size_t)w;
	}
	_exit(0);
}

/* Run hsm_open_key_store_service in a forked child. Returns 0 with the handle
 * only when the child exited 0 and sent exactly one result; a signal, a
 * nonzero status, a short or long result, or any failure to fork or read is a
 * failure. *nonce is erased on every path. */
static int ks_open_isolated(hsm_hdl_t session, uint32_t key_store_id, uint32_t *nonce, hsm_hdl_t *h)
{
	struct ks_result res;
	unsigned char buf[sizeof(res) + 1];
	size_t got = 0;
	int fd[2], status = 0, rd_ok = 1;
	pid_t pid;

	if (pipe(fd) != 0) {
		ele_secure_zero(nonce, sizeof(*nonce));
		return -1;
	}
	pid = fork();
	if (pid < 0) {
		close(fd[0]);
		close(fd[1]);
		ele_secure_zero(nonce, sizeof(*nonce));
		return -1;
	}
	if (pid == 0) {
		close(fd[0]);
		ks_child(fd[1], session, key_store_id, nonce);
	}
	/* Right after the fork: the parent's copy goes before anything else. */
	ele_secure_zero(nonce, sizeof(*nonce));
	close(fd[1]);
	for (;;) {
		ssize_t r = read(fd[0], buf + got, sizeof(buf) - got);

		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0)
			rd_ok = 0;
		if (r <= 0)
			break;
		got += (size_t)r;
		if (got == sizeof(buf))
			break;
	}
	close(fd[0]);
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			ele_secure_zero(buf, sizeof(buf));
			return -1;
		}
	}
	if (!rd_ok || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || got != sizeof(res)) {
		ele_secure_zero(buf, sizeof(buf));
		return -1;
	}
	memcpy(&res, buf, sizeof(res));
	ele_secure_zero(buf, sizeof(buf));
	if (res.err != (int32_t)HSM_NO_ERROR)
		return -1;
	*h = res.handle;
	return 0;
}

int ele_hsm_open(struct ele_hsm_ctx *c, uint32_t key_store_id, uint32_t *nonce)
{
	open_session_args_t sa;
	open_svc_key_management_args_t km;
	open_svc_sign_gen_args_t sg;
	hsm_hdl_t h;
	bool ks_ok;

	memset(c, 0, sizeof(*c));
	if (!nonce)
		return -1;
	/* The library keeps an unwiped stack copy of the nonce; with all memory
	 * locked it can never reach swap. When the lock fails the credential is
	 * never handed over (fail closed). */
	if (lock_process() != 0) {
		ele_secure_zero(nonce, sizeof(*nonce));
		return ELE_HSM_OPEN_NOLOCK;
	}
	memset(&sa, 0, sizeof(sa));
	if (hsm_open_session(&sa, &h) != HSM_NO_ERROR) {
		ele_secure_zero(nonce, sizeof(*nonce));
		scrub_stack();
		return -1;
	}
	c->session = h;
	/* The one vendor call that marshals the credential runs in a forked
	 * child (ks_open_isolated): the library's command buffer holds the
	 * nonce and this code cannot reach it, so the buffer lives and dies in
	 * the child. *nonce is erased in the parent right after the fork. */
	ks_ok = ks_open_isolated(c->session, key_store_id, nonce, &h) == 0;
	/* Defence in depth only; it proves nothing about the vendor's copy. */
	scrub_stack();
	if (!ks_ok)
		goto fail;
	c->key_store = h;
	memset(&km, 0, sizeof(km));
	if (hsm_open_key_management_service(c->key_store, &km, &h) != HSM_NO_ERROR)
		goto fail;
	c->key_mgmt = h;
	memset(&sg, 0, sizeof(sg));
	if (hsm_open_signature_generation_service(c->key_store, &sg, &h) != HSM_NO_ERROR)
		goto fail;
	c->sign_gen = h;
	c->open = true;
	return 0;
fail:
	c->open = true;	/* so close releases what was opened */
	ele_hsm_close(c);
	return -1;
}

void ele_hsm_close(struct ele_hsm_ctx *c)
{
	if (c->open) {
		if (c->sign_gen)
			(void)hsm_close_signature_generation_service(c->sign_gen);
		if (c->key_mgmt)
			(void)hsm_close_key_management_service(c->key_mgmt);
		if (c->key_store)
			(void)hsm_close_key_store_service(c->key_store);
		if (c->session)
			(void)hsm_close_session(c->session);
	}
	memset(c, 0, sizeof(*c));
}
