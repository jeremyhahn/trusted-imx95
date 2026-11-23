/* Command-line front end of the client over the HSM library backend.
 * PROVISIONAL. Built for aarch64 by scripts/ele-lib-build.sh; this repository
 * never runs it on a board. It prints the commit state of every update, and
 * never a key: a key is an id.
 *
 *   ele_client <store-id> <nonce-fd> gen
 *   ele_client [--raw] <store-id> <nonce-fd> sign <key-id> <message>
 *       the signature on stdout: one line of lowercase hex, or --raw bytes
 *   ele_client <store-id> <nonce-fd> del <key-id>
 * The nonce is a credential: read from the descriptor, never from argv.
 */
#include <stdio.h>
#include <string.h>

#include "ele_cli_args.h"
#include "ele_hsm_backend.h"
#include "ele_secure.h"

static int usage(void)
{
	fprintf(stderr, "usage: ele_client [--split-confirmed] [--raw] <store-id> <nonce-fd> gen | sign <key-id> <msg> | del <key-id>\n"
			"       the nonce is read from that file descriptor (e.g. 3<nonce-file), never from arguments\n");
	return 2;
}

int main(int argc, char **argv)
{
	struct ele_cli_cmd cmd;
	struct ele_hsm_ctx ctx;
	struct ele_client cl;
	enum ele_commit st = ELE_NOT_COMMITTED;
	uint32_t nonce = 0, id = 0;
	uint8_t sig[128];
	size_t n = sizeof(sig), i;
	int rc = 1;

	/* No core file and no ptrace may carry the credential; the one copy of
	 * the nonce is locked in memory and erased as soon as the store is open
	 * (ele_hsm_open) or on any failure. */
	if (ele_harden_process() != 0) {
		fprintf(stderr, "ele_client: cannot make the process non-dumpable\n");
		return 2;
	}
	/* Everything is validated before any HSM service is opened. */
	if (ele_cli_parse(argc, argv, &cmd) != 0)
		return usage();
	(void)ele_lock_secret(&nonce, sizeof(nonce));
	if (ele_read_nonce(cmd.nonce_fd, &nonce) != 0) {
		ele_secure_zero(&nonce, sizeof(nonce));
		fprintf(stderr, "ele_client: cannot read the nonce from fd %d\n", cmd.nonce_fd);
		return 2;
	}
	if (ele_hsm_open(&ctx, cmd.store_id, &nonce) != 0) {
		ele_secure_zero(&nonce, sizeof(nonce));
		fprintf(stderr, "ele_client: cannot open the key store\n");
		return 1;
	}
	ele_secure_zero(&nonce, sizeof(nonce));
	ctx.counter_split_confirmed = cmd.split_confirmed;
	ele_client_init(&cl, &ele_hsm_ops, &ctx);
	switch (cmd.op) {
	case ELE_CLI_GEN:
		rc = ele_generate_key(&cl, &id, &st) == 0 ? 0 : 1;
		if (rc == 0)
			printf("key %u %s\n", id, ele_commit_name(st));
		break;
	case ELE_CLI_SIGN:
		rc = ele_sign(&cl, cmd.key_id, (const uint8_t *)cmd.msg, strlen(cmd.msg), sig, &n) == 0 ? 0 : 1;
		if (rc == 0 && cmd.raw) {
			/* The signature bytes, exactly, on stdout. */
			if (fwrite(sig, 1, n, stdout) != n)
				rc = 1;
		} else if (rc == 0) {
			/* One line of lowercase hex, two digits per byte. */
			for (i = 0; i < n; i++)
				printf("%02x", sig[i]);
			putchar('\n');
		}
		if (rc == 0 && fflush(stdout) != 0)
			rc = 1;
		break;
	case ELE_CLI_DEL:
		rc = ele_delete_key(&cl, cmd.key_id, &st) == 0 ? 0 : 1;
		if (rc == 0)
			printf("deleted %s\n", ele_commit_name(st));
		break;
	}
	/* A failed update keeps its diagnostic state: print it, exit nonzero. */
	if (rc != 0 && cmd.op != ELE_CLI_SIGN && st != ELE_NOT_COMMITTED)
		fprintf(stderr, "ele_client: update refused (%s)\n", ele_commit_name(st));
	else if (rc != 0)
		fprintf(stderr, "ele_client: failed\n");
	ele_hsm_close(&ctx);
	return rc;
}
