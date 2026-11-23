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
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

#include "hsm_api.h"

#include "ele_hsm_fake.h"

struct ele_fake *ele_fake_p;
struct ele_ks_seen *ks_seen;

static void __attribute__((constructor)) seen_init(void)
{
	void *m = mmap(NULL, sizeof(*ks_seen), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	void *f = mmap(NULL, sizeof(*ele_fake_p), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);

	if (m == MAP_FAILED || f == MAP_FAILED)
		abort();
	ks_seen = m;
	ele_fake_p = f;
}

static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void note(const char *fmt, ...)
{
	const char *path = getenv("ELE_FAKE_LOG");
	FILE *f;
	va_list ap;

	if (fake.calls < 32) {
		fake.call_pid[fake.calls] = (uint32_t)getpid();
		snprintf(fake.call_name[fake.calls], sizeof(fake.call_name[0]), "%s", fmt);
	}
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
#ifdef __linux__
	note("open_session dumpable=%d", prctl(PR_GET_DUMPABLE));
#else
	note("open_session");
#endif
	if (fake.session_err)
		return (hsm_err_t)fake.session_err;
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
	ks_seen->flags = args->flags;
	ks_seen->id = args->key_store_identifier;
	ks_seen->nonce = args->authentication_nonce;
	ks_seen->pid = (uint32_t)getpid();
	ks_seen->calls++;
	note("key_store id=%u flags=0x%x pid=%d ppid=%d", (unsigned)args->key_store_identifier, (unsigned)args->flags,
	     (int)getpid(), (int)getppid());
	if (fake.ks_mode == 1)
		raise(SIGKILL);
	if (fake.ks_mode == 2)
		_exit(3);
	if (fake.ks_err)
		return (hsm_err_t)fake.ks_err;
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
	uint32_t i;

	(void)signature_gen_hdl;
	fake.sign_calls++;
	/* Known bytes: byte i is (3*i + 1) & 0xff. */
	for (i = 0; i < 64 && i < args->signature_size; i++)
		args->signature[i] = (uint8_t)(3 * i + 1);
	/* Like the pinned source (sab_sign_gen.c:178): signature_size is not
	 * updated by a successful sign; the response size is stored in
	 * exp_signature_size (PSA build). */
	args->exp_signature_size = fake.sign_exp_set ? fake.sign_exp_size : 64;
	note("sign key=%u", (unsigned)args->key_identifier);
	return HSM_NO_ERROR;
}
