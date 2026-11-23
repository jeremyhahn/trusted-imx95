/* Argument handling of the ele_client command line. PROVISIONAL.
 * No vendor header: it is tested on the host (test/ele_client_test.sh).
 * Every number is parsed strictly and the whole command line is validated
 * before any HSM service is opened. The key-store nonce is a credential: it
 * is read from a file descriptor, never from the argument list.
 */
#ifndef ELE_CLI_ARGS_H
#define ELE_CLI_ARGS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum ele_cli_op { ELE_CLI_GEN, ELE_CLI_SIGN, ELE_CLI_DEL };

struct ele_cli_cmd {
	bool split_confirmed;	/* --split-confirmed: the caller confirmed the counter split on the device */
	bool raw;		/* --raw (sign only): the signature as raw bytes, not lowercase hex */
	uint32_t store_id;
	int nonce_fd;
	enum ele_cli_op op;
	uint32_t key_id;
	const char *msg;
};

/* Decimal digits, or 0x and hex digits. No sign, no space, no trailing
 * character, no overflow, at most UINT32_MAX. Returns 0 or -1. */
int ele_parse_u32(const char *s, uint32_t *out);

/* ele_client [--split-confirmed] [--raw] <store-id> <nonce-fd> gen | sign <key-id> <msg> | del <key-id>.
 * --raw is for sign only. Returns 0 or -1; nothing is opened here. */
int ele_cli_parse(int argc, char **argv, struct ele_cli_cmd *cmd);

/* Read the nonce (one line, at most 16 characters) from fd and parse it
 * strictly. Refuses a terminal. Returns 0 or -1. */
int ele_read_nonce(int fd, uint32_t *nonce);

/* The text buffer is locked (mlock) while it holds the credential and erased
 * on every path. ele_lock_secret locks the caller's storage (0 or -1; a
 * failure, e.g. RLIMIT_MEMLOCK, is not fatal to the caller). */
int ele_lock_secret(void *p, size_t n);

/* Make the process non-dumpable (prctl PR_SET_DUMPABLE 0) and set
 * RLIMIT_CORE to 0, so no core file or ptrace carries the credential.
 * Returns 0 or -1. */
int ele_harden_process(void);

#endif
