/* Command-line front end of the client over the HSM library backend.
 * PROVISIONAL. Built for aarch64 by scripts/ele-lib-build.sh; this repository
 * never runs it on a board. It prints the commit state of every update, and
 * never a key: a key is an id.
 *
 *   ele_client <store-id> <nonce> gen
 *   ele_client <store-id> <nonce> sign <key-id> <message>
 *   ele_client <store-id> <nonce> del <key-id>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ele_hsm_backend.h"

static int usage(void)
{
	fprintf(stderr, "usage: ele_client <store-id> <nonce> gen | sign <key-id> <msg> | del <key-id>\n");
	return 2;
}

int main(int argc, char **argv)
{
	struct ele_hsm_ctx ctx;
	struct ele_client cl;
	enum ele_commit st;
	uint32_t id;
	int rc = 1;

	if (argc < 4)
		return usage();
	if (ele_hsm_open(&ctx, (uint32_t)strtoul(argv[1], NULL, 0), (uint32_t)strtoul(argv[2], NULL, 0)) != 0) {
		fprintf(stderr, "ele_client: cannot open the key store\n");
		return 1;
	}
	ele_client_init(&cl, &ele_hsm_ops, &ctx);
	if (!strcmp(argv[3], "gen") && argc == 4) {
		if (ele_generate_key(&cl, &id, &st) == 0) {
			printf("key %u %s\n", id, ele_commit_name(st));
			rc = 0;
		}
	} else if (!strcmp(argv[3], "sign") && argc == 6) {
		uint8_t sig[128];
		size_t n = sizeof(sig);

		if (ele_sign(&cl, (uint32_t)strtoul(argv[4], NULL, 0), (const uint8_t *)argv[5],
			     strlen(argv[5]), sig, &n) == 0) {
			printf("signature %zu bytes\n", n);
			rc = 0;
		}
	} else if (!strcmp(argv[3], "del") && argc == 5) {
		if (ele_delete_key(&cl, (uint32_t)strtoul(argv[4], NULL, 0), &st) == 0) {
			printf("deleted %s\n", ele_commit_name(st));
			rc = 0;
		}
	} else {
		ele_hsm_close(&ctx);
		return usage();
	}
	ele_hsm_close(&ctx);
	return rc;
}
