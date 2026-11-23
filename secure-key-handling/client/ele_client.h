/* Minimal key-store client over the enclave HSM API: key generate, sign,
 * delete. PROVISIONAL (docs/secure-key-handling/client.md): the Linux A55 side
 * as the caller is a default pending the owner.
 *
 * The client reaches the library through an ops table, so the policy below runs
 * on the host against a stub. Binding the table to the library's real calls is
 * left open (client.md, "What is left open"). No key material crosses this
 * interface: a key is a numeric id, and sign returns a signature only.
 */
#ifndef ELE_CLIENT_H
#define ELE_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The two request flags of owner decision 241. */
#define ELE_REQ_STRICT_OPERATION 0x1u
#define ELE_REQ_MONOTONIC_COUNTER 0x2u

/* What the enclave reported for one operation. */
struct ele_ack {
	bool strict_acked;	  /* the strict-operation flag was acknowledged */
	bool counter_acked;	  /* the monotonic-counter flag was acknowledged */
	bool counter_warning;	  /* any counter warning (e.g. HSM_KEY_STORE_COUNTER) */
	bool split_configured;	  /* the counter split is configured */
};

/* The outcome of an update or delete, as the policy classifies it. */
enum ele_commit {
	ELE_NOT_COMMITTED = 0,	      /* strict-operation flag missing or not acknowledged */
	ELE_COMMITTED_UNPROTECTED,    /* committed, but not rollback-protected */
	ELE_ROLLBACK_PROTECTED	      /* both flags sent and acknowledged, no warning, split set */
};

/* The decision, a pure function: rollback-protected only with both flags sent
 * and acknowledged for this operation, no counter warning and the counter
 * split configured (architecture.md, "Key store rollback protection"). */
enum ele_commit ele_classify(uint32_t flags_sent, const struct ele_ack *ack);
const char *ele_commit_name(enum ele_commit c);

/* The library side. Each call returns 0 or a negative error and fills ack
 * for the update calls. */
struct ele_ops {
	int (*generate)(void *ctx, uint32_t flags, uint32_t *key_id, struct ele_ack *ack);
	int (*sign)(void *ctx, uint32_t key_id, const uint8_t *msg, size_t msg_len,
		    uint8_t *sig, size_t *sig_len);
	int (*del)(void *ctx, uint32_t flags, uint32_t key_id, struct ele_ack *ack);
};

struct ele_client {
	const struct ele_ops *ops;
	void *ctx;
	uint32_t flags;	/* sent with every update: both flags by default */
};

void ele_client_init(struct ele_client *c, const struct ele_ops *ops, void *ctx);

/* Generate a key in the key store. A failed call or a not-committed update
 * returns -1 and no key id counts. *state is set whenever the call reached
 * the library. */
int ele_generate_key(struct ele_client *c, uint32_t *key_id, enum ele_commit *state);
int ele_sign(struct ele_client *c, uint32_t key_id, const uint8_t *msg, size_t msg_len,
	     uint8_t *sig, size_t *sig_len);
/* Delete a key. Returns 0 only for a committed delete. The library's delete has
 * the strict-operation flag and no monotonic-counter flag, so *state is never
 * ELE_ROLLBACK_PROTECTED for a delete: at best ELE_COMMITTED_UNPROTECTED. */
int ele_delete_key(struct ele_client *c, uint32_t key_id, enum ele_commit *state);

#endif
