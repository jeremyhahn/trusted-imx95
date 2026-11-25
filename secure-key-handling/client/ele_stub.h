/* A host stub of the library's key-store calls: it holds no key, only ids and
 * a configurable acknowledgement, for the policy tests. PROVISIONAL. */
#ifndef ELE_STUB_H
#define ELE_STUB_H

#include "ele_client.h"

struct ele_stub {
	struct ele_ack reply;	/* what each update acknowledges; flags it received are ANDed in */
	uint32_t last_flags;	/* flags the last update carried */
	uint32_t next_id;
	int live;		/* keys present */
	int fail;		/* nonzero: every call fails */
};

extern const struct ele_ops ele_stub_ops;

#endif
