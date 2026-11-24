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

/* An update succeeds only when every flag sent was acknowledged: a counter
 * warning (accepted, counter not advanced, so the prior blob can be replayed)
 * fails it, as does a missing strict acknowledgement, and a call that sent the
 * counter flag needs rollback-protected (counter acknowledged, split
 * configured). A strict-only send (a delete) needs the strict acknowledgement. */
static bool ele_update_ok(uint32_t flags_sent, const struct ele_ack *ack, enum ele_commit st)
{
	if (st == ELE_NOT_COMMITTED || !ack || ack->counter_warning)
		return false;
	/* Fail closed (owner, Q2 (c)): a generate sent without the counter flag
	 * (strict only) skips the acknowledgement, so it never succeeds. */
	if (!(flags_sent & ELE_REQ_MONOTONIC_COUNTER) || st != ELE_ROLLBACK_PROTECTED)
		return false;
	return true;
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
	case ELE_OUTCOME_UNKNOWN:
		return "outcome-unknown";
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
	int rc;

	if (!c || !c->ops || !c->ops->generate || !key_id || !state)
		return -1;
	/* A failure must never carry the previous operation's evidence: the
	 * state and the identifier are reset before the backend is called. */
	*state = ELE_NOT_COMMITTED;
	*key_id = 0;
	rc = c->ops->generate(c->ctx, c->flags, &id, &ack);
	if (rc == ELE_OP_UNKNOWN) {
		*state = ELE_OUTCOME_UNKNOWN;
		return -1;
	}
	if (rc != 0)
		return -1;
	*state = ele_classify(c->flags, &ack);
	/* The state is kept for the caller's diagnostics even when the call fails. */
	/* No key handle is released unless the counter flag was sent and
	 * acknowledged (fail closed, owner Q2 (c)). With the acknowledgement, a
	 * refused update (a counter warning, no split) still returns the
	 * identifier with the failure so the caller can reconcile or delete it.
	 * 0 is never a returned key. */
	if (*state != ELE_NOT_COMMITTED && (c->flags & ELE_REQ_MONOTONIC_COUNTER) &&
	    ack.counter_acked)
		*key_id = id;
	if (!ele_update_ok(c->flags, &ack, *state))
		return -1;
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
	/* The library's delete offers the strict-operation flag only: there is no
	 * monotonic-counter flag on a delete, so the enclave can never acknowledge
	 * both flags for it. Send the strict flag alone and never report a delete
	 * as rollback-protected (client.md, "Fail-closed rule"). */
	uint32_t flags = c ? (c->flags & ELE_REQ_STRICT_OPERATION) : 0;
	int rc;

	if (!c || !c->ops || !c->ops->del || !state)
		return -1;
	*state = ELE_NOT_COMMITTED;	/* never the previous operation's evidence */
	rc = c->ops->del(c->ctx, flags, key_id, &ack);
	if (rc == ELE_OP_UNKNOWN) {
		*state = ELE_OUTCOME_UNKNOWN;
		return -1;
	}
	if (rc != 0)
		return -1;
	*state = ele_classify(flags, &ack);
	/* Fail closed like generate. A delete updates the key store, and the
	 * library can return HSM_NO_ERROR for a success-tagged counter warning,
	 * so a clean return does not show the counter advanced: success needs
	 * the counter acknowledgement itself, with no warning and the split
	 * configured. The library's delete cannot supply it (no counter flag),
	 * so until the owner answers Q2 (the ELE rollback gap) every delete is
	 * refused here, the diagnostic state kept. The strict flag is not what
	 * decides this. */
	if (*state == ELE_NOT_COMMITTED || !ack.counter_acked || ack.counter_warning || !ack.split_configured)
		return -1;
	return 0;
}
