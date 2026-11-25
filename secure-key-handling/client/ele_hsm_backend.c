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
void (*ele_hsm_event_hook)(const char *event);

#ifndef MADV_WIPEONFORK
#define MADV_WIPEONFORK 18
#endif

static void ele_hsm_event(const char *event)
{
	if (ele_hsm_event_hook)
		ele_hsm_event_hook(event);
}

/* The library copies the nonce into its own stack buffer (process_sab_msg's
 * cmd[MAX_CMD_WORD_SZ = 256] words, plus the response buffer and frames) and
 * does not wipe it. Every vendor call of an operation runs in a child
 * process (run_op), which is what removes the copy. This many bytes of dead stack are also
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
	/* Called only after the started marker. Anything but HSM_NO_ERROR, the
	 * counter warning HSM_KEY_STORE_COUNTER included, is not a result the
	 * client can vouch for: the caller leaves status -1 and the parent
	 * reports an unknown outcome (the update may have been applied). */
	if (err != HSM_NO_ERROR)
		return false;
	ack->strict_acked = (sent & ELE_REQ_STRICT_OPERATION) != 0;
	ack->counter_warning = false;
	/* Fail closed. The pinned library maps a success-tagged response that
	 * carries a warning rating to HSM_NO_ERROR (client.md, contract table),
	 * so HSM_NO_ERROR does not show that the counter advanced. No per-flag
	 * acknowledgement is exposed, so the counter flag is never reported
	 * acknowledged and nothing is reported rollback-protected from here;
	 * a generate is refused and the client releases no key handle.
	 * PROVISIONAL: lifted only by evidence from the board or a library
	 * that exposes the acknowledgement (the owner's call). */
	ack->counter_acked = false;
	ack->split_configured = split;
	return true;
}

/* One CLI operation runs as one unit in one forked child (run_op): open the
 * session, open the key store with the nonce, do the operation, close
 * everything, write this fixed-size result to the parent, _exit. The parent
 * holds no session or key-store handle and calls the vendor library never. */
enum op_kind { OP_GEN = 1, OP_SIGN, OP_DEL };

struct op_req {
	enum op_kind kind;
	uint32_t store_id;
	uint32_t flags;
	uint32_t key_id;
	const uint8_t *msg;
	size_t msg_len;
	bool split;
};

struct op_res {
	int32_t status;		/* 0: the operation ran and its answer is valid */
	uint32_t key_id;	/* generate */
	uint32_t sig_len;	/* sign: the length the library reported */
	uint8_t strict_acked, counter_warning, counter_acked, split_configured;
	uint8_t sig[ELE_SIG_LEN];
};

static int run_op(struct ele_hsm_ctx *c, const struct op_req *rq, struct op_res *out);

static void res_ack(struct op_res *r, const struct ele_ack *a)
{
	r->strict_acked = a->strict_acked;
	r->counter_warning = a->counter_warning;
	r->counter_acked = a->counter_acked;
	r->split_configured = a->split_configured;
}

static void ack_from_res(const struct op_res *r, struct ele_ack *a)
{
	a->strict_acked = r->strict_acked != 0;
	a->counter_warning = r->counter_warning != 0;
	a->counter_acked = r->counter_acked != 0;
	a->split_configured = r->split_configured != 0;
}

static int hsm_generate(void *p, uint32_t flags, uint32_t *key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *c = p;
	struct op_req rq;
	struct op_res r;
	int rc;

	if (!c->open)
		return -1;
	/* The split cannot be read through the API. Generating while it is
	 * unconfirmed would update the store (and may spend a finite counter
	 * step) and then be refused, leaving an untracked key: refuse first. */
	if (!c->counter_split_confirmed)
		return -1;
	memset(&rq, 0, sizeof(rq));
	rq.kind = OP_GEN;
	rq.flags = flags;
	rq.split = c->counter_split_confirmed;
	rc = run_op(c, &rq, &r);
	if (rc != 0)
		return rc == ELE_OP_UNKNOWN ? ELE_OP_UNKNOWN : -1;
	ack_from_res(&r, ack);
	*key_id = r.key_id;
	return 0;
}

static int hsm_sign(void *p, uint32_t key_id, const uint8_t *msg, size_t msg_len,
		    uint8_t *sig, size_t *sig_len)
{
	struct ele_hsm_ctx *c = p;
	struct op_req rq;
	struct op_res r;
	int rc;

	/* A buffer under 64 bytes (P-256 r||s, provisional) is refused before
	 * the call: the library does not report the size back (see client.md). */
	if (!c->open || msg_len > UINT32_MAX || *sig_len > UINT16_MAX || *sig_len < ELE_SIG_LEN)
		return -1;
	memset(&rq, 0, sizeof(rq));
	rq.kind = OP_SIGN;
	rq.key_id = key_id;
	rq.msg = msg;
	rq.msg_len = msg_len;
	rc = run_op(c, &rq, &r);
	/* The child refuses a length other than 64 (this binding supports P-256
	 * only); the parent checks again and returns nothing on any mismatch. */
	if (rc != 0 || r.sig_len != ELE_SIG_LEN) {
		ele_secure_zero(&r, sizeof(r));
		ele_secure_zero(sig, *sig_len);
		return -1;
	}
	memcpy(sig, r.sig, ELE_SIG_LEN);
	ele_secure_zero(&r, sizeof(r));
	*sig_len = ELE_SIG_LEN;
	return 0;
}

/* The library's delete has HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION and no
 * monotonic-counter flag: only the strict flag is sent, and the counter flag
 * is never acknowledged for a delete (client.md). */
static int hsm_del(void *p, uint32_t flags, uint32_t key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *c = p;
	struct op_req rq;
	struct op_res r;
	int rc;

	if (!c->open)
		return -1;
	memset(&rq, 0, sizeof(rq));
	rq.kind = OP_DEL;
	rq.flags = flags;
	rq.key_id = key_id;
	rq.split = c->counter_split_confirmed;
	rc = run_op(c, &rq, &r);
	if (rc != 0)
		return rc == ELE_OP_UNKNOWN ? ELE_OP_UNKNOWN : -1;
	ack_from_res(&r, ack);
	return 0;
}

const struct ele_ops ele_hsm_ops = { hsm_generate, hsm_sign, hsm_del };

/* The service step of the child: open the service, run the one operation,
 * close the service. res->status stays -1 unless the answer is valid. */
/* The child's stream to the parent is one marker byte, then the result: 'S' is
 * written just before the update call (generate or delete) runs; 'N' goes in
 * front of the result when no update call was started. A parent that sees 'S'
 * and then no complete result cannot tell whether the update took effect. If
 * the marker cannot be written the update is not run. */
#define MARK_STARTED 'S'
#define MARK_NOT_STARTED 'N'
static bool child_started;

static void mark_started(int wfd)
{
	for (;;) {
		ssize_t w = write(wfd, "S", 1);

		if (w < 0 && errno == EINTR)
			continue;
		if (w != 1)
			_exit(4);
		break;
	}
	child_started = true;
}

static void op_service(const struct op_req *rq, hsm_hdl_t store, struct op_res *res, int wfd)
{
	hsm_hdl_t svc = 0;
	struct ele_ack ack;

	memset(&ack, 0, sizeof(ack));
	if (rq->kind == OP_SIGN) {
		open_svc_sign_gen_args_t sg;
		op_generate_sign_args_t a;

		memset(&sg, 0, sizeof(sg));
		if (hsm_open_signature_generation_service(store, &sg, &svc) != HSM_NO_ERROR)
			return;
		memset(&a, 0, sizeof(a));
		a.key_identifier = rq->key_id;
		a.message = (uint8_t *)rq->msg;
		a.message_size = (uint32_t)rq->msg_len;
		a.signature = res->sig;
		a.signature_size = ELE_SIG_LEN;
		a.scheme_id = (hsm_signature_scheme_id_t)ALGO_ECDSA_SHA256;
		a.flags = HSM_OP_GENERATE_SIGN_FLAGS_INPUT_MESSAGE;
		/* A successful sign does not update signature_size (sab_sign_gen.c:178);
		 * the response size is exp_signature_size. This binding supports P-256
		 * only: any length other than 64 is refused and nothing is returned. */
		if (hsm_generate_signature(svc, &a) == HSM_NO_ERROR && a.exp_signature_size == ELE_SIG_LEN) {
			res->sig_len = ELE_SIG_LEN;
			res->status = 0;
		} else {
			res->sig_len = a.exp_signature_size;
			ele_secure_zero(res->sig, sizeof(res->sig));
		}
		(void)hsm_close_signature_generation_service(svc);
		return;
	} else {
		open_svc_key_management_args_t km;

		memset(&km, 0, sizeof(km));
		if (hsm_open_key_management_service(store, &km, &svc) != HSM_NO_ERROR)
			return;
		if (rq->kind == OP_GEN) {
			op_generate_key_args_t a;
			uint32_t id = 0;
			hsm_err_t err;

			memset(&a, 0, sizeof(a));
			a.key_identifier = &id;	/* 0: the enclave picks the identifier */
			a.flags = gen_flags(rq->flags);
			/* No plaintext export: HSM_OP_KEY_GENERATION_FLAGS_PLAINTEXT_KEY is never set. */
			a.key_type = HSM_KEY_TYPE_ECC_NIST;
			a.key_group = 0;
			a.key_lifetime = HSM_SE_KEY_STORAGE_PERSISTENT;
			a.key_usage = HSM_KEY_USAGE_SIGN_HASH;
			a.permitted_algo = PERMITTED_ALGO_ECDSA_SHA256;
			a.bit_key_sz = HSM_KEY_SIZE_ECC_NIST_256;
			mark_started(wfd);
			err = hsm_generate_key(svc, &a);
			/* A success reply that leaves the identifier at the zero
			 * sentinel names no key: status stays -1 (unknown outcome). */
			if (err == HSM_NO_ERROR && id != 0 && fill_ack(err, rq->flags, rq->split, &ack)) {
				res_ack(res, &ack);
				res->key_id = id;
				res->status = 0;
			}
		} else {
			op_delete_key_args_t a;
			hsm_err_t err;

			memset(&a, 0, sizeof(a));
			a.key_identifier = rq->key_id;
			if (rq->flags & ELE_REQ_STRICT_OPERATION)
				a.flags = HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION;
			mark_started(wfd);
			err = hsm_delete_key(svc, &a);
			if (fill_ack(err, rq->flags & ELE_REQ_STRICT_OPERATION, rq->split, &ack)) {
				res_ack(res, &ack);
				res->status = 0;
			}
		}
		(void)hsm_close_key_management_service(svc);
	}
}

/* The whole operation, in the child: session, key store, service, operation,
 * close all, then the fixed-size result to the parent and _exit(). The child
 * owns the only live copy of the credential after the fork: it is
 * non-dumpable and locked, builds the library's arguments in its own memory,
 * erases what it can reach, and leaves with _exit() (no atexit handler, no
 * stdio flush); its pages, the vendor stack included, go when it exits. */
__attribute__((noreturn)) static void op_child(int wfd, int rfd, const struct op_req *rq)
{
	open_session_args_t sa;
	open_svc_key_store_args_t ks;
	struct op_res res;
	size_t n = sizeof(res);
	const unsigned char *p = (const unsigned char *)&res;
	hsm_hdl_t sess = 0, store = 0;
	hsm_err_t err;
	uint32_t nonce = 0;
	unsigned char *np = (unsigned char *)&nonce;
	size_t nleft = sizeof(nonce);

	/* The child holds no credential yet (the parent's copy sits in a page that
	 * is zero after the fork). It goes non-dumpable and locks first, says so,
	 * and only then does the parent send the nonce. */
	if (prctl(PR_SET_DUMPABLE, 0) != 0 || lock_process() != 0)
		_exit(3);
	ele_hsm_event("child_locked");
	for (;;) {
		ssize_t w = write(wfd, "L", 1);

		if (w < 0 && errno == EINTR)
			continue;
		if (w != 1)
			_exit(4);
		break;
	}
	while (nleft > 0) {
		ssize_t r = read(rfd, np, nleft);

		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0) {
			ele_secure_zero(&nonce, sizeof(nonce));
			_exit(5);
		}
		np += r;
		nleft -= (size_t)r;
	}
	close(rfd);
	ele_hsm_event("nonce_received");
	memset(&res, 0, sizeof(res));
	res.status = -1;
	memset(&sa, 0, sizeof(sa));
	if (hsm_open_session(&sa, &sess) != HSM_NO_ERROR) {
		ele_secure_zero(&nonce, sizeof(nonce));
		scrub_stack();
		goto out;
	}
	memset(&ks, 0, sizeof(ks));
	ks.key_store_identifier = rq->store_id;
	ks.authentication_nonce = nonce;
	/* The store is loaded, never created here; both update flags are set so
	 * the store's updates are strict and counted. */
	ks.flags = HSM_SVC_KEY_STORE_FLAGS_LOAD | HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION |
		   HSM_SVC_KEY_STORE_FLAGS_MONOTONIC;
	err = hsm_open_key_store_service(sess, &ks, &store);
	ele_secure_zero(&nonce, sizeof(nonce));
	ele_secure_zero(&ks, sizeof(ks));
	if (ele_hsm_wipe_hook)
		ele_hsm_wipe_hook(&ks, sizeof(ks));
	scrub_stack();
	if (err == HSM_NO_ERROR) {
		op_service(rq, store, &res, wfd);
		(void)hsm_close_key_store_service(store);
	}
	(void)hsm_close_session(sess);
out:
	if (ele_hsm_result_len_override && ele_hsm_result_len_override < n)
		n = ele_hsm_result_len_override;
	if (!child_started) {
		for (;;) {
			ssize_t w = write(wfd, "N", 1);

			if (w < 0 && errno == EINTR)
				continue;
			if (w != 1)
				_exit(4);
			break;
		}
	}
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

/* Run one whole operation in a forked child. Returns 0 with the result only
 * when the child exited 0 and sent exactly one fixed-size result with status
 * 0; a signal, a nonzero exit, a short or long result, or any failure to fork
 * or read is a failure. The caller's nonce is erased on every path. */
static int run_op(struct ele_hsm_ctx *c, const struct op_req *rq_in, struct op_res *out)
{
	struct op_req rq = *rq_in;
	struct op_res res;
	unsigned char buf[sizeof(res) + 2], ready = 0;
	bool started = false;
	int lost;
	size_t off = 0, got = 0, ps = (size_t)sysconf(_SC_PAGESIZE), left = sizeof(uint32_t);
	int up[2], down[2], status = 0, rd_ok = 1, sent_ok = 1, rc = -1;
	uint32_t *slot = c->nonce;
	volatile unsigned char *held;
	const unsigned char *hp;
	ssize_t r;
	pid_t pid;

	/* One operation per open: the nonce is spent by the one fork. */
	c->open = false;
	c->nonce = NULL;
	if (!slot)
		return -1;
	rq.store_id = c->store_id;
	/* The parent's copy lives in its own locked page (the process is under
	 * mlockall), marked to be zero in a forked child; the caller's slot is
	 * wiped now. The child therefore inherits no credential at all. */
	held = mmap(NULL, ps, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (held == MAP_FAILED) {
		ele_secure_zero(slot, sizeof(*slot));
		return -1;
	}
	if (madvise((void *)held, ps, MADV_WIPEONFORK) != 0) {
		ele_secure_zero(slot, sizeof(*slot));
		munmap((void *)held, ps);
		return -1;
	}
	memcpy((void *)held, slot, sizeof(*slot));
	ele_secure_zero(slot, sizeof(*slot));
	if (pipe(up) != 0) {
		ele_secure_zero((void *)held, ps);
		munmap((void *)held, ps);
		return -1;
	}
	if (pipe(down) != 0) {
		close(up[0]);
		close(up[1]);
		ele_secure_zero((void *)held, ps);
		munmap((void *)held, ps);
		return -1;
	}
	pid = fork();
	if (pid < 0) {
		close(up[0]);
		close(up[1]);
		close(down[0]);
		close(down[1]);
		ele_secure_zero((void *)held, ps);
		munmap((void *)held, ps);
		return -1;
	}
	if (pid == 0) {
		close(up[0]);
		close(down[1]);
		op_child(up[1], down[0], &rq);
	}
	close(up[1]);
	close(down[0]);
	/* Send the nonce only after the child says it is locked and non-dumpable;
	 * a child that cannot lock exits without a word and gets nothing. */
	do {
		r = read(up[0], &ready, 1);
	} while (r < 0 && errno == EINTR);
	if (r == 1 && ready == 'L') {
		hp = (const unsigned char *)held;
		ele_hsm_event("nonce_sending");
		while (left > 0) {
			ssize_t w = write(down[1], hp, left);

			if (w < 0 && errno == EINTR)
				continue;
			if (w <= 0) {
				sent_ok = 0;
				break;
			}
			hp += w;
			left -= (size_t)w;
		}
	} else {
		sent_ok = 0;
	}
	ele_secure_zero((void *)held, ps);
	munmap((void *)held, ps);
	close(down[1]);
	for (; sent_ok;) {
		r = read(up[0], buf + got, sizeof(buf) - got);
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
	close(up[0]);
	/* The first byte is the child's marker (see mark_started). 'S' means the
	 * update call was started: whatever goes wrong from here on is an unknown
	 * outcome for a generate or a delete, never a plain failure. */
	if (got >= 1 && (buf[0] == MARK_STARTED || buf[0] == MARK_NOT_STARTED)) {
		started = buf[0] == MARK_STARTED;
		off = 1;
	}
	lost = started && rq.kind != OP_SIGN ? ELE_OP_UNKNOWN : -1;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			ele_secure_zero(buf, sizeof(buf));
			return lost;
		}
	}
	if (!sent_ok || !rd_ok || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || got - off != sizeof(res)) {
		ele_secure_zero(buf, sizeof(buf));
		return lost;
	}
	memcpy(&res, buf + off, sizeof(res));
	ele_secure_zero(buf, sizeof(buf));
	if (res.status == 0) {
		*out = res;
		rc = 0;
	} else {
		/* Status -1 or any vendor error after the update call started:
		 * the vendor may report a lost device reply as an error after the
		 * update was applied, so it is unknown, whatever the code. */
		rc = lost;
	}
	ele_secure_zero(&res, sizeof(res));
	return rc;
}

int ele_hsm_open(struct ele_hsm_ctx *c, uint32_t key_store_id, uint32_t *nonce)
{
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
	/* No vendor call here: the session and the key store are opened, used and
	 * closed by the one forked child of each operation (run_op), so the
	 * library's command buffer holding the nonce lives and dies there. The
	 * context keeps the caller's nonce slot until that fork, which erases it. */
	c->store_id = key_store_id;
	c->nonce = nonce;
	c->open = true;
	return 0;
}

void ele_hsm_close(struct ele_hsm_ctx *c)
{
	/* Nothing to release: the parent holds no vendor handle. An operation
	 * never run leaves the nonce in the caller's slot: erase it. */
	if (c->nonce)
		ele_secure_zero(c->nonce, sizeof(*c->nonce));
	memset(c, 0, sizeof(*c));
}
