/* See ele_client.h. PROVISIONAL. */
#include "ele_client.h"

enum ele_commit ele_classify(uint32_t flags_sent, const struct ele_ack *ack)
{
	bool strict = (flags_sent & ELE_REQ_STRICT_OPERATION) && ack && ack->strict_acked;
	bool counter = (flags_sent & ELE_REQ_MONOTONIC_COUNTER) && ack && ack->counter_acked;

	/* An update counts only after the strict operation is acknowledged. */
	if (!strict)
		return ELE_NOT_COMMITTED;
	if (counter && !ack->counter_warning && ack->split_configured)
		return ELE_ROLLBACK_PROTECTED;
	return ELE_COMMITTED_UNPROTECTED;
}

const char *ele_commit_name(enum ele_commit c)
{
	switch (c) {
	case ELE_NOT_COMMITTED:
		return "not-committed";
	case ELE_COMMITTED_UNPROTECTED:
		return "committed-not-rollback-protected";
	case ELE_ROLLBACK_PROTECTED:
		return "rollback-protected";
	}
	return "unknown";
}

void ele_client_init(struct ele_client *c, const struct ele_ops *ops, void *ctx)
{
	c->ops = ops;
	c->ctx = ctx;
	c->flags = ELE_REQ_STRICT_OPERATION | ELE_REQ_MONOTONIC_COUNTER;
}

int ele_generate_key(struct ele_client *c, uint32_t *key_id, enum ele_commit *state)
{
	struct ele_ack ack = { 0 };
	uint32_t id = 0;

	if (!c || !c->ops || !c->ops->generate || !key_id || !state)
		return -1;
	if (c->ops->generate(c->ctx, c->flags, &id, &ack) != 0)
		return -1;
	*state = ele_classify(c->flags, &ack);
	if (*state == ELE_NOT_COMMITTED)
		return -1;
	*key_id = id;
	return 0;
}

int ele_sign(struct ele_client *c, uint32_t key_id, const uint8_t *msg, size_t msg_len,
	     uint8_t *sig, size_t *sig_len)
{
	if (!c || !c->ops || !c->ops->sign || !msg || !sig || !sig_len)
		return -1;
	return c->ops->sign(c->ctx, key_id, msg, msg_len, sig, sig_len) == 0 ? 0 : -1;
}

int ele_delete_key(struct ele_client *c, uint32_t key_id, enum ele_commit *state)
{
	struct ele_ack ack = { 0 };

	if (!c || !c->ops || !c->ops->del || !state)
		return -1;
	if (c->ops->del(c->ctx, c->flags, key_id, &ack) != 0)
		return -1;
	*state = ele_classify(c->flags, &ack);
	return *state == ELE_NOT_COMMITTED ? -1 : 0;
}
