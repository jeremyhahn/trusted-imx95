/* State the HSM test double records (ele_hsm_fake.c). It deliberately holds
 * plain integers, so the backend test needs no vendor header. */
#ifndef ELE_HSM_FAKE_H
#define ELE_HSM_FAKE_H

#include <stdbool.h>
#include <stdint.h>

struct ele_fake {
	uint32_t err;	/* return code of generate and delete; 0 = HSM_NO_ERROR */
	uint32_t ks_mode;	/* key store open: 1 = the process dies of SIGKILL, 2 = exits 3; 3 and 4 the same inside the generate/delete update call */
	uint32_t gen_flags, gen_key_type, gen_calls;
	uint32_t del_flags, del_key, del_calls;
	uint32_t imp_flags, imp_calls, imp_len;	/* the import record: flags, call count, blob length seen */
	uint32_t imp_sum;		/* FNV-1a of the blob bytes the import call saw */
	uint8_t imp_head[8];		/* its first bytes */
	uint32_t sign_calls;
	uint32_t sign_exp_size;	/* exp_signature_size the double reports ... */
	bool sign_exp_set;	/* ... when set; otherwise 64 */
	uint32_t calls;
	uint32_t session_err, ks_err;	/* nonzero: open_session / open_key_store fail with it */
	/* One entry per library call, in order: the pid it ran in and the first
	 * 15 characters of its format string (open_session, key_store, ...). */
	uint32_t call_pid[32];
	char call_name[32][16];
};

/* The double's state lives in a MAP_SHARED mapping: the backend runs every
 * library call of an operation in a forked child, and the parent reads the
 * counters and the call log the child wrote. */
extern struct ele_fake *ele_fake_p;
#define fake (*ele_fake_p)

/* What the key store open saw. The backend runs that call in a forked child,
 * so the record is in a MAP_SHARED mapping the parent can read. */
struct ele_ks_seen {
	uint32_t flags, id, nonce;
	uint32_t pid;			/* the pid the library call ran in */
	uint32_t calls;
	uint32_t hook_calls, hook_nonzero;	/* the test's wipe hook, run in the child */
	uint32_t scrubs, scrub_bytes;		/* the test's scrub hook, run in the child */
	uint32_t ev_n;				/* the test's event hook: the ordered event log */
	char ev[8][16];
};

extern struct ele_ks_seen *ks_seen;

#endif
