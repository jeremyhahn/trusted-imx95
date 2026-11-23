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

/* The one home of the credential: the text read from the descriptor and the
 * parsed value, in an anonymous mapping of its own that is locked (mlock)
 * for its whole life. ele_nonce_slot_new returns NULL when the lock fails
 * (e.g. RLIMIT_MEMLOCK), and the caller must then refuse before reading any
 * credential. ele_nonce_slot_free erases the slot and only then unlocks it. */
struct ele_nonce_slot {
	char text[18];
	uint32_t value;
};
struct ele_nonce_slot *ele_nonce_slot_new(void);
void ele_nonce_slot_free(struct ele_nonce_slot *s);

/* Read the nonce (one line, at most 16 characters) from fd into s->value,
 * parsed strictly; the text is erased on every path. Refuses a terminal.
 * Returns 0 or -1. */
int ele_nonce_slot_read(int fd, struct ele_nonce_slot *s);

/* The nonce's own strict parser: the rules of ele_parse_u32, but it
 * accumulates straight into *acc (the locked slot's value) and never calls
 * ele_parse_u32. ele_parse_u32_calls counts calls to the generic parser, for
 * a test of that. */
int ele_nonce_parse(const char *text, uint32_t *acc);
extern volatile unsigned long ele_parse_u32_calls;

/* The one entry the CLI uses to obtain the nonce. Order: PR_SET_DUMPABLE 0,
 * mlockall(MCL_CURRENT|MCL_FUTURE), the locked slot, and only then the first
 * read of the descriptor. A failed lock returns ELE_CLI_NONCE_NOLOCK and reads
 * nothing; an unreadable or malformed nonce returns ELE_CLI_NONCE_BAD. On 0,
 * *out is the slot. Test hooks, NULL in production: ele_cli_lockall_override
 * replaces mlockall; ele_cli_read_hook runs just before the first read. */
#define ELE_CLI_NONCE_NOLOCK (-2)
#define ELE_CLI_NONCE_BAD (-1)
int ele_cli_open_nonce(int fd, struct ele_nonce_slot **out);
extern int (*ele_cli_lockall_override)(void);
extern void (*ele_cli_read_hook)(void);

/* Make the process non-dumpable (prctl PR_SET_DUMPABLE 0) and set
 * RLIMIT_CORE to 0, so no core file or ptrace carries the credential.
 * Returns 0 or -1. */
int ele_harden_process(void);

#endif
