/* Compile-time check that the library's flag and return-code values are the
 * ones the client was written against (decision 241 path: the strict-operation
 * and monotonic-counter flags). Compiled by scripts/ele-lib-build.sh and by
 * test/ele_client_test.sh against the fetched library headers (-fsyntax-only);
 * a mismatch fails the compile. The values are from hsm_key_store.h,
 * hsm_key_generate.h, hsm_delete_key.h and hsm_utils.h at the pinned commit.
 */
#include "hsm_api.h"

#include "ele_client.h"

_Static_assert(HSM_SVC_KEY_STORE_FLAGS_LOAD == 0, "key store LOAD");
_Static_assert(HSM_SVC_KEY_STORE_FLAGS_CREATE == (1u << 0), "key store CREATE");
_Static_assert(HSM_SVC_KEY_STORE_FLAGS_SHARED == (1u << 2), "key store SHARED");
_Static_assert(HSM_SVC_KEY_STORE_FLAGS_SET_MAC_LEN == (1u << 3), "key store SET_MAC_LEN");
_Static_assert(HSM_SVC_KEY_STORE_FLAGS_MONOTONIC == (1u << 5), "key store MONOTONIC");
_Static_assert(HSM_SVC_KEY_STORE_FLAGS_STRICT_OPERATION == (1u << 7), "key store STRICT_OPERATION");

_Static_assert(HSM_OP_KEY_GENERATION_FLAGS_PLAINTEXT_KEY == (1u << 3), "generate PLAINTEXT_KEY");
_Static_assert(HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER == (1u << 5), "generate MONOTONIC_COUNTER");
_Static_assert(HSM_OP_KEY_GENERATION_FLAGS_STRICT_OPERATION == (1u << 7), "generate STRICT_OPERATION");

_Static_assert(HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION == (1u << 7), "delete STRICT_OPERATION");

/* hsm_importkey.h: the import's flags (ELE TLV input, automatic group, the
 * monotonic-counter and strict-operation bits). */
_Static_assert(HSM_OP_IMPORT_KEY_INPUT_ELE_TLV == 0, "import INPUT_ELE_TLV");
_Static_assert(HSM_OP_IMPORT_KEY_INPUT_E2GO_TLV == (1u << 0), "import INPUT_E2GO_TLV");
_Static_assert(HSM_OP_IMPORT_KEY_FLAGS_AUTOMATIC_GROUP == 0, "import AUTOMATIC_GROUP");
_Static_assert(HSM_OP_IMPORT_KEY_FLAGS_MONOTONIC_COUNTER_INCREMENT == (1u << 5), "import MONOTONIC_COUNTER_INCREMENT");
_Static_assert(HSM_OP_IMPORT_KEY_FLAGS_STRICT_OPERATION == (1u << 7), "import STRICT_OPERATION");

_Static_assert(HSM_NO_ERROR == 0x0, "HSM_NO_ERROR");
_Static_assert(HSM_NVM_ERROR == 0x5, "HSM_NVM_ERROR");
_Static_assert(HSM_KEY_STORE_ERROR == 0xA, "HSM_KEY_STORE_ERROR");
_Static_assert(HSM_KEY_STORE_COUNTER == 0x10, "HSM_KEY_STORE_COUNTER");
_Static_assert(HSM_FEATURE_NOT_SUPPORTED == 0x11, "HSM_FEATURE_NOT_SUPPORTED");
_Static_assert(HSM_GENERAL_ERROR == 0xFF, "HSM_GENERAL_ERROR");

/* The client's abstract request flags map onto the same bit positions, so the
 * mapping in ele_hsm_backend.c is a renaming, not a shift. */
_Static_assert(ELE_REQ_STRICT_OPERATION == 0x1u && ELE_REQ_MONOTONIC_COUNTER == 0x2u,
	       "client request flags");

int ele_hsm_consts_ok;
