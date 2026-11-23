/* State the HSM test double records (ele_hsm_fake.c). It deliberately holds
 * plain integers, so the backend test needs no vendor header. */
#ifndef ELE_HSM_FAKE_H
#define ELE_HSM_FAKE_H

#include <stdbool.h>
#include <stdint.h>

struct ele_fake {
	uint32_t err;	/* return code of generate and delete; 0 = HSM_NO_ERROR */
	uint32_t ks_flags, ks_id, ks_nonce;
	uint32_t gen_flags, gen_key_type, gen_calls;
	uint32_t del_flags, del_key, del_calls;
	uint32_t sign_calls;
	uint32_t sign_exp_size;	/* exp_signature_size the double reports ... */
	bool sign_exp_set;	/* ... when set; otherwise 64 */
	uint32_t calls;
	uint32_t session_err, ks_err;	/* nonzero: open_session / open_key_store fail with it */
};

extern struct ele_fake fake;

#endif
