/* A test double for the HSM library calls the backend makes. PROVISIONAL.
 * It is compiled against the pinned library's headers (so a prototype or a
 * structure member that drifts fails the build) and replaces libele_hsm in
 * the host tests: it records the request the backend sent and answers with a
 * configured return code. No enclave, no key, no board.
 *
 * ELE_FAKE_ERR (a number) sets the return code of generate and delete;
 * ELE_FAKE_LOG (a path) gets one line per call, for the command-line tests.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hsm_api.h"

#include "ele_hsm_fake.h"

struct ele_fake fake;

static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void note(const char *fmt, ...)
{
	const char *path = getenv("ELE_FAKE_LOG");
	FILE *f;
	va_list ap;

	fake.calls++;
	if (!path || !(f = fopen(path, "a")))
		return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static hsm_err_t env_err(void)
{
	const char *e = getenv("ELE_FAKE_ERR");

	return fake.err ? fake.err : (hsm_err_t)(e ? strtoul(e, NULL, 0) : 0);
}

hsm_err_t hsm_open_session(open_session_args_t *args, hsm_hdl_t *session_hdl)
{
	(void)args;
	note("open_session");
	*session_hdl = 1;
	return HSM_NO_ERROR;
}

hsm_err_t hsm_close_session(hsm_hdl_t session_hdl)
{
	(void)session_hdl;
	note("close_session");
	return HSM_NO_ERROR;
}

hsm_err_t hsm_open_key_store_service(hsm_hdl_t session_hdl, open_svc_key_store_args_t *args,
				     hsm_hdl_t *key_store_hdl)
{
	(void)session_hdl;
	fake.ks_flags = args->flags;
	fake.ks_id = args->key_store_identifier;
	fake.ks_nonce = args->authentication_nonce;
	note("key_store id=%u flags=0x%x", (unsigned)args->key_store_identifier, (unsigned)args->flags);
	*key_store_hdl = 2;
	return HSM_NO_ERROR;
}

hsm_err_t hsm_close_key_store_service(hsm_hdl_t key_store_hdl)
{
	(void)key_store_hdl;
	note("close_key_store");
	return HSM_NO_ERROR;
}

hsm_err_t hsm_open_key_management_service(hsm_hdl_t key_store_hdl, open_svc_key_management_args_t *args,
					  hsm_hdl_t *key_management_hdl)
{
	(void)key_store_hdl;
	(void)args;
	note("open_key_management");
	*key_management_hdl = 3;
	return HSM_NO_ERROR;
}

hsm_err_t hsm_close_key_management_service(hsm_hdl_t key_management_hdl)
{
	(void)key_management_hdl;
	note("close_key_management");
	return HSM_NO_ERROR;
}

hsm_err_t hsm_open_signature_generation_service(hsm_hdl_t key_store_hdl, open_svc_sign_gen_args_t *args,
						hsm_hdl_t *signature_gen_hdl)
{
	(void)key_store_hdl;
	(void)args;
	note("open_sign_gen");
	*signature_gen_hdl = 4;
	return HSM_NO_ERROR;
}

hsm_err_t hsm_close_signature_generation_service(hsm_hdl_t signature_gen_hdl)
{
	(void)signature_gen_hdl;
	note("close_sign_gen");
	return HSM_NO_ERROR;
}

hsm_err_t hsm_generate_key(hsm_hdl_t key_management_hdl, op_generate_key_args_t *args)
{
	(void)key_management_hdl;
	fake.gen_flags = args->flags;
	fake.gen_key_type = args->key_type;
	fake.gen_calls++;
	*args->key_identifier = 7;
	note("generate flags=0x%x", (unsigned)args->flags);
	return env_err();
}

hsm_err_t hsm_delete_key(hsm_hdl_t key_management_hdl, op_delete_key_args_t *args)
{
	(void)key_management_hdl;
	fake.del_flags = args->flags;
	fake.del_key = args->key_identifier;
	fake.del_calls++;
	note("delete key=%u flags=0x%x", (unsigned)args->key_identifier, (unsigned)args->flags);
	return env_err();
}

hsm_err_t hsm_generate_signature(hsm_hdl_t signature_gen_hdl, op_generate_sign_args_t *args)
{
	(void)signature_gen_hdl;
	fake.sign_calls++;
	args->signature_size = 64;
	note("sign key=%u", (unsigned)args->key_identifier);
	return HSM_NO_ERROR;
}
