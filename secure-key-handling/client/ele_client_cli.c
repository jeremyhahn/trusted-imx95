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
#include <signal.h>
#include <stdio.h>
#include <string.h>

#include "ele_cli_args.h"
#include "ele_hsm_backend.h"
#include "ele_secure.h"

/* The fixed reason for a refused generate or delete (TENANT ASK 5, owner
 * question open): see docs/secure-key-handling/client.md. */
#define CTR_REASON "the pinned library cannot prove the monotonic-counter acknowledgement (fail closed)"

/* Read the whole wrapped blob: 1 to ELE_IMPORT_MAX_BLOB bytes, read in full.
 * Returns the length, or -1 for an unreadable, empty or over-long file. The
 * blob is opaque and already wrapped; nothing here parses or prints it. */
static long read_blob(const char *path, uint8_t *buf)
{
	FILE *f = fopen(path, "rb");
	size_t n;
	long ret = -1;

	if (!f)
		return -1;
	n = fread(buf, 1, ELE_IMPORT_MAX_BLOB + 1, f);
	if (!ferror(f) && n >= 1 && n <= ELE_IMPORT_MAX_BLOB)
		ret = (long)n;
	fclose(f);
	return ret;
}

static int usage(void)
{
	fprintf(stderr, "usage: ele_client [--split-confirmed] [--raw] <store-id> <nonce-fd> gen | sign <key-id> <msg> | del <key-id> | import <blob-file>\n"
			"       the nonce is read from that file descriptor (e.g. 3<nonce-file), never from arguments\n");
	return 2;
}

int main(int argc, char **argv)
{
	struct ele_cli_cmd cmd;
	struct ele_hsm_ctx ctx;
	struct ele_client cl;
	enum ele_commit st = ELE_NOT_COMMITTED;
	struct ele_nonce_slot *slot;
	uint32_t id = 0;
	uint8_t sig[128] = { 0 };
	uint8_t blob[ELE_IMPORT_MAX_BLOB];
	size_t blob_len = 0;
	size_t n = sizeof(sig), i;
	int rc = 1;

	/* No core file and no ptrace may carry the credential; the one copy of
	 * the nonce is locked in memory and erased as soon as the store is open
	 * (ele_hsm_open) or on any failure. */
	if (ele_harden_process() != 0) {
		fprintf(stderr, "ele_client: cannot make the process non-dumpable\n");
		return 2;
	}
	/* A closed reader must surface as EPIPE on the checked write, not kill the
	 * process after the HSM operation with the key id unreported. */
	{
		struct sigaction ign;

		memset(&ign, 0, sizeof(ign));
		ign.sa_handler = SIG_IGN;
		sigemptyset(&ign.sa_mask);
		if (sigaction(SIGPIPE, &ign, NULL) != 0) {
			fprintf(stderr, "ele_client: cannot ignore SIGPIPE\n");
			return 2;
		}
	}
	/* Everything is validated before any HSM service is opened. */
	if (ele_cli_parse(argc, argv, &cmd) != 0)
		return usage();
	/* A generate on an unconfirmed counter split is refused here, before the
	 * credential is read and before any HSM call. */
	if (cmd.op == ELE_CLI_GEN && !cmd.split_confirmed) {
		fprintf(stderr, "ele_client: generate refused: the counter split is not confirmed (--split-confirmed); failed\n");
		return 1;
	}
	/* An import on an unconfirmed split, or with a blob that is empty, over
	 * the cap or not readable in full, is refused here: no credential read,
	 * no HSM call. */
	if (cmd.op == ELE_CLI_IMPORT) {
		long bl;

		if (!cmd.split_confirmed) {
			fprintf(stderr, "ele_client: import refused: the counter split is not confirmed (--split-confirmed); failed\n");
			return 1;
		}
		bl = read_blob(cmd.blob_path, blob);
		if (bl < 0) {
			fprintf(stderr, "ele_client: import refused: the blob file is unreadable, empty or over %u bytes; failed\n",
				(unsigned)ELE_IMPORT_MAX_BLOB);
			return 1;
		}
		blob_len = (size_t)bl;
	}
	/* Locked storage first: when it cannot be locked the credential is never read. */
	rc = ele_cli_open_nonce(cmd.nonce_fd, &slot);
	if (rc == ELE_CLI_NONCE_NOLOCK) {
		fprintf(stderr, "ele_client: cannot lock memory for the nonce; nothing was read\n");
		return 2;
	}
	if (rc != 0) {
		fprintf(stderr, "ele_client: cannot read the nonce from fd %d\n", cmd.nonce_fd);
		return 2;
	}
	rc = ele_hsm_open(&ctx, cmd.store_id, &slot->value);
	if (rc != 0) {
		ele_nonce_slot_free(slot);
		if (rc == ELE_HSM_OPEN_NOLOCK) {
			fprintf(stderr, "ele_client: cannot lock the process memory (mlockall; check RLIMIT_MEMLOCK); the nonce was not used\n");
			return 2;
		}
		fprintf(stderr, "ele_client: cannot open the key store\n");
		return 1;
	}
	rc = 1;
	/* The slot stays until the operation's fork erases the nonce; it is
	 * freed (and wiped) at done. */
	ctx.counter_split_confirmed = cmd.split_confirmed;
	ele_client_init(&cl, &ele_hsm_ops, &ctx);
	switch (cmd.op) {
	case ELE_CLI_GEN:
		rc = ele_generate_key(&cl, &id, &st) == 0 ? 0 : 1;
		if (rc == 0 && (printf("key %u %s\n", id, ele_commit_name(st)) < 0 || fflush(stdout) != 0)) {
			/* The key exists whatever stdout did: name it on stderr. */
			fprintf(stderr, "ele_client: cannot write the result; key %u was generated, commit state %s\n",
				id, ele_commit_name(st));
			rc = 1;
			goto done;
		}
		break;
	case ELE_CLI_IMPORT:
		rc = ele_import_key(&cl, blob, blob_len, &id, &st) == 0 ? 0 : 1;
		if (rc == 0 && (printf("key %u %s\n", id, ele_commit_name(st)) < 0 || fflush(stdout) != 0)) {
			fprintf(stderr, "ele_client: cannot write the result; key %u was imported, commit state %s\n",
				id, ele_commit_name(st));
			rc = 1;
			goto done;
		}
		break;
	case ELE_CLI_SIGN:
		rc = ele_sign(&cl, cmd.key_id, (const uint8_t *)cmd.msg, strlen(cmd.msg), sig, &n) == 0 ? 0 : 1;
		if (rc == 0 && cmd.raw) {
			/* The signature bytes, exactly, on stdout. */
			if (fwrite(sig, 1, n, stdout) != n || ferror(stdout))
				rc = 1;
		} else if (rc == 0) {
			/* One line of lowercase hex, two digits per byte. */
			for (i = 0; i < n && rc == 0; i++)
				if (printf("%02x", sig[i]) < 0)
					rc = 1;
			if (rc == 0 && putchar('\n') == EOF)
				rc = 1;
		}
		/* Every write above is checked; the flush and the stream error
		 * flag catch what a buffer held back (/dev/full, a closed pipe). */
		if (rc == 0 && (fflush(stdout) != 0 || ferror(stdout)))
			rc = 1;
		if (rc == 1 && st == ELE_NOT_COMMITTED && ferror(stdout))
			fprintf(stderr, "ele_client: cannot write the signature to stdout\n");
		break;
	case ELE_CLI_DEL:
		rc = ele_delete_key(&cl, cmd.key_id, &st) == 0 ? 0 : 1;
		if (rc == 0 && (printf("deleted %s\n", ele_commit_name(st)) < 0 || fflush(stdout) != 0)) {
			fprintf(stderr, "ele_client: cannot write the result; key %u was deleted, commit state %s\n",
				cmd.key_id, ele_commit_name(st));
			rc = 1;
			goto done;
		}
		break;
	}
	/* A lost result after the update call started: the key store may have
	 * changed. Never success, never retried here; exit 3, distinct from a
	 * plain failure (1) and a setup failure (2). */
	if (rc != 0 && st == ELE_OUTCOME_UNKNOWN) {
		fprintf(stderr, "ele_client: outcome unknown (%s): the result of the %s was lost after it started; the key store may have changed. Check the key store before any retry; nothing was retried\n",
			ele_commit_name(st),
			cmd.op == ELE_CLI_GEN ? "generate" : cmd.op == ELE_CLI_IMPORT ? "import" : "delete");
		rc = 3;
		goto done;
	}
	/* A failed update keeps its diagnostic state: print it, exit nonzero. */
	if (rc != 0 && cmd.op == ELE_CLI_GEN && st != ELE_NOT_COMMITTED && id != 0)
		/* The key exists but the update was refused: name it so it can be
		 * reconciled or deleted. Not a protected key. */
		fprintf(stderr, "ele_client: update refused (%s); key %u was generated and is NOT rollback-protected: reconcile or delete it; %s\n",
			ele_commit_name(st), id, CTR_REASON);
	else if (rc != 0 && cmd.op == ELE_CLI_IMPORT && st != ELE_NOT_COMMITTED && id != 0)
		fprintf(stderr, "ele_client: update refused (%s); key %u was imported and is NOT rollback-protected: reconcile or delete it; %s\n",
			ele_commit_name(st), id, CTR_REASON);
	else if (rc != 0 && cmd.op == ELE_CLI_DEL && st != ELE_NOT_COMMITTED)
		/* Every key-store update fails closed: the counter acknowledgement
		 * cannot be established for a delete (client.md, "Fail-closed rule"). The delete may
		 * have taken effect, but its old store blob may stay replayable. */
		fprintf(stderr, "ele_client: update refused (%s); key %u delete is NOT rollback-protected: the old key-store state may be replayable; %s\\n",
			ele_commit_name(st), cmd.key_id, CTR_REASON);
	else if (rc != 0 && cmd.op != ELE_CLI_SIGN && st != ELE_NOT_COMMITTED)
		fprintf(stderr, "ele_client: update refused (%s)\n", ele_commit_name(st));
	else if (rc != 0)
		fprintf(stderr, "ele_client: failed\n");
done:
	ele_hsm_close(&ctx);
	ele_nonce_slot_free(slot);
	return rc;
}
