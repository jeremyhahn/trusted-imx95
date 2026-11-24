/* A test-only stand-in for ele_hsm_backend.c, linked with ele_client_cli.c by
 * test/ele_client_test.sh and never by the shipped build. The shipped backend
 * cannot report a counter acknowledgement (client.md, Q2), so a generate or a
 * delete never succeeds through it; this double answers every update as
 * committed with both flags acknowledged, so the command line's success path,
 * and the checks of its stdout writes, can be run. No library, no nonce kept. */
#include <string.h>

#include "ele_client.h"
#include "ele_hsm_backend.h"
#include "ele_secure.h"

static void ack_all(uint32_t flags, bool split, struct ele_ack *ack)
{
	ack->strict_acked = (flags & ELE_REQ_STRICT_OPERATION) != 0;
	ack->counter_warning = false;
	ack->counter_acked = (flags & ELE_REQ_MONOTONIC_COUNTER) != 0;
	ack->split_configured = split;
}

static int dbl_generate(void *ctx, uint32_t flags, uint32_t *key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *x = ctx;

	ack_all(flags, x->counter_split_confirmed, ack);
	*key_id = 7;
	return 0;
}

static int dbl_sign(void *ctx, uint32_t key_id, const uint8_t *msg, size_t msg_len, uint8_t *sig, size_t *sig_len)
{
	(void)ctx;
	(void)key_id;
	(void)msg;
	(void)msg_len;
	(void)sig;
	(void)sig_len;
	return -1;
}

static int dbl_del(void *ctx, uint32_t flags, uint32_t key_id, struct ele_ack *ack)
{
	struct ele_hsm_ctx *x = ctx;

	(void)key_id;
	ack_all(flags, x->counter_split_confirmed, ack);
	/* A delete sends the strict flag only; ele_delete_key still needs the
	 * counter acknowledgement, which only a library exposing it could give. */
	ack->counter_acked = true;
	return 0;
}

static int dbl_import(void *ctx, uint32_t flags, const uint8_t *blob, size_t blob_len, uint32_t *key_id,
		      struct ele_ack *ack)
{
	struct ele_hsm_ctx *x = ctx;

	(void)blob;
	(void)blob_len;
	ack_all(flags, x->counter_split_confirmed, ack);
	*key_id = 9;
	return 0;
}

const struct ele_ops ele_hsm_ops = { dbl_generate, dbl_sign, dbl_del, dbl_import };

int ele_hsm_open(struct ele_hsm_ctx *c, uint32_t key_store_id, uint32_t *nonce)
{
	memset(c, 0, sizeof(*c));
	if (!nonce)
		return -1;
	ele_secure_zero(nonce, sizeof(*nonce));
	c->store_id = key_store_id;
	c->open = true;
	return 0;
}

void ele_hsm_close(struct ele_hsm_ctx *ctx)
{
	memset(ctx, 0, sizeof(*ctx));
}
