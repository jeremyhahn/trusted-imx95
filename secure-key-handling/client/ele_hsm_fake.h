/* State the HSM test double records (ele_hsm_fake.c). It deliberately holds
 * plain integers, so the backend test needs no vendor header. */
#ifndef ELE_HSM_FAKE_H
#define ELE_HSM_FAKE_H

#include <stdbool.h>
#include <stdint.h>

struct ele_fake {
	uint32_t err;	/* return code of generate and delete; 0 = HSM_NO_ERROR */
	uint32_t ks_mode;	/* key store open: 1 = the process dies of SIGKILL, 2 = exits 3 */
	uint32_t gen_flags, gen_key_type, gen_calls;
	uint32_t del_flags, del_key, del_calls;
	uint32_t sign_calls;
	uint32_t sign_exp_size;	/* exp_signature_size the double reports ... */
	bool sign_exp_set;	/* ... when set; otherwise 64 */
	uint32_t calls;
	uint32_t session_err, ks_err;	/* nonzero: open_session / open_key_store fail with it */
};

extern struct ele_fake fake;

/* What the key store open saw. The backend runs that call in a forked child,
 * so the record is in a MAP_SHARED mapping the parent can read. */
struct ele_ks_seen {
	uint32_t flags, id, nonce;
	uint32_t pid;			/* the pid the library call ran in */
	uint32_t calls;
	uint32_t hook_calls, hook_nonzero;	/* the test's wipe hook, run in the child */
};

extern struct ele_ks_seen *ks_seen;

#endif
