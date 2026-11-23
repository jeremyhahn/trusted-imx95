/* The ops-table backend that calls the pinned imx-secure-enclave library's
 * HSM API (include/hsm/hsm_api.h and the headers under include/hsm/internal at the commit in
 * secure-key-handling/ele-lib.lock). PROVISIONAL (docs/secure-key-handling/
 * client.md). Built only against the fetched library (scripts/ele-lib-build.sh);
 * the host tests use the stub. Never run on a board by this repository.
 */
#ifndef ELE_HSM_BACKEND_H
#define ELE_HSM_BACKEND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ele_client.h"

struct ele_hsm_ctx {
	uint32_t session;
	uint32_t key_store;
	uint32_t key_mgmt;
	uint32_t sign_gen;
	bool open;
	/* The caller sets this only after confirming the counter split is
	 * configured on the device (architecture.md). It stays false until then,
	 * so no operation is reported rollback-protected on an unconfirmed split. */
	bool counter_split_confirmed;
};

extern const struct ele_ops ele_hsm_ops;

/* Open a session, the key store (identifier and nonce as the caller's
 * provisioning gave them) and the key management and signature services.
 * Returns 0 or -1. flags_load: open an existing store, never CREATE here. */
int ele_hsm_open(struct ele_hsm_ctx *ctx, uint32_t key_store_id, uint32_t *nonce);
/* The nonce is a credential: *nonce is erased on every path, and so is the
 * library argument structure holding its copy. */

/* Test hook: called after the library's argument structure (which held the
 * nonce) has been erased, with its address and size, so a test can check the
 * erasure. NULL in production. */
extern void (*ele_hsm_wipe_hook)(const void *copy, size_t len);
void ele_hsm_close(struct ele_hsm_ctx *ctx);

#endif
