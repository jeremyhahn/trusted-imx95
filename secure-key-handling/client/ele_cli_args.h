/* Argument handling of the ele_client command line. PROVISIONAL.
 * No vendor header: it is tested on the host (test/ele_client_test.sh).
 * Every number is parsed strictly and the whole command line is validated
 * before any HSM service is opened. The key-store nonce is a credential: it
 * is read from a file descriptor, never from the argument list.
 */
#ifndef ELE_CLI_ARGS_H
#define ELE_CLI_ARGS_H

#include <stdbool.h>
#include <stdint.h>

enum ele_cli_op { ELE_CLI_GEN, ELE_CLI_SIGN, ELE_CLI_DEL };

struct ele_cli_cmd {
	bool split_confirmed;	/* --split-confirmed: the caller confirmed the counter split on the device */
	uint32_t store_id;
	int nonce_fd;
	enum ele_cli_op op;
	uint32_t key_id;
	const char *msg;
};

/* Decimal digits, or 0x and hex digits. No sign, no space, no trailing
 * character, no overflow, at most UINT32_MAX. Returns 0 or -1. */
int ele_parse_u32(const char *s, uint32_t *out);

/* ele_client [--split-confirmed] <store-id> <nonce-fd> gen | sign <key-id> <msg> | del <key-id>.
 * Returns 0 or -1; nothing is opened here. */
int ele_cli_parse(int argc, char **argv, struct ele_cli_cmd *cmd);

/* Read the nonce (one line, at most 16 characters) from fd and parse it
 * strictly. Refuses a terminal. Returns 0 or -1. */
int ele_read_nonce(int fd, uint32_t *nonce);

#endif
