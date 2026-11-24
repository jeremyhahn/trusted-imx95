/* See ele_stub.h. A flag the caller did not send is never acknowledged. */
#include "ele_stub.h"

static void fill_ack(struct ele_stub *s, uint32_t flags, struct ele_ack *ack)
{
	s->last_flags = flags;
	*ack = s->reply;
	ack->strict_acked = s->reply.strict_acked && (flags & ELE_REQ_STRICT_OPERATION);
	ack->counter_acked = s->reply.counter_acked && (flags & ELE_REQ_MONOTONIC_COUNTER);
}

static int stub_generate(void *ctx, uint32_t flags, uint32_t *key_id, struct ele_ack *ack)
{
	struct ele_stub *s = ctx;

	if (s->fail)
		return -1;
	fill_ack(s, flags, ack);
	*key_id = ++s->next_id;
	s->live++;
	return 0;
}

static int stub_sign(void *ctx, uint32_t key_id, const uint8_t *msg, size_t msg_len,
		     uint8_t *sig, size_t *sig_len)
{
	struct ele_stub *s = ctx;

	if (s->fail || key_id == 0 || key_id > s->next_id || *sig_len < 1)
		return -1;
	/* Not a signature: one byte derived from the message, enough to see the call. */
	sig[0] = msg_len ? msg[0] : 0;
	*sig_len = 1;
	return 0;
}

static int stub_del(void *ctx, uint32_t flags, uint32_t key_id, struct ele_ack *ack)
{
	struct ele_stub *s = ctx;

	if (s->fail || key_id == 0 || key_id > s->next_id)
		return -1;
	fill_ack(s, flags, ack);
	s->live--;
	return 0;
}

static int stub_import(void *ctx, uint32_t flags, const uint8_t *blob, size_t blob_len, uint32_t *key_id,
		       struct ele_ack *ack)
{
	struct ele_stub *s = ctx;
	size_t i;

	s->imp_calls++;
	if (s->fail)
		return s->fail == 2 ? ELE_OP_UNKNOWN : -1;
	s->imp_len = blob_len;
	for (i = 0; i < blob_len && i < sizeof(s->imp_head); i++)
		s->imp_head[i] = blob[i];
	fill_ack(s, flags, ack);
	*key_id = ++s->next_id;
	s->live++;
	return 0;
}

const struct ele_ops ele_stub_ops = { stub_generate, stub_sign, stub_del, stub_import };
