/* See ele_cli_args.h. PROVISIONAL. */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

#include "ele_cli_args.h"
#include "ele_secure.h"

#define ELE_NONCE_BUF 18

int ele_parse_u32(const char *s, uint32_t *out)
{
	unsigned long long v = 0;
	unsigned int base = 10, d;
	const char *p = s;

	ele_parse_u32_calls++;
	if (!s || !out)
		return -1;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		base = 16;
		p += 2;
	}
	/* After one optional prefix every character must be a digit of the base:
	 * an empty rest, a second prefix, a sign, a space or junk is refused
	 * before any conversion. */
	if (*p == '\0')
		return -1;
	for (; *p; p++) {
		if (*p >= '0' && *p <= '9')
			d = (unsigned int)(*p - '0');
		else if (base == 16 && *p >= 'a' && *p <= 'f')
			d = (unsigned int)(*p - 'a') + 10;
		else if (base == 16 && *p >= 'A' && *p <= 'F')
			d = (unsigned int)(*p - 'A') + 10;
		else
			return -1;
		v = v * base + d;
		if (v > UINT32_MAX)
			return -1;
	}
	*out = (uint32_t)v;
	return 0;
}

int ele_cli_parse(int argc, char **argv, struct ele_cli_cmd *cmd)
{
	uint32_t fd;
	bool split = false, raw = false;

	if (argc < 4 || !argv || !cmd)
		return -1;
	while (argc > 1 && !strncmp(argv[1], "--", 2)) {
		if (!strcmp(argv[1], "--split-confirmed"))
			split = true;
		else if (!strcmp(argv[1], "--raw"))
			raw = true;
		else
			return -1;
		argc--;
		argv++;
	}
	if (argc < 4)
		return -1;
	memset(cmd, 0, sizeof(*cmd));
	cmd->split_confirmed = split;
	cmd->raw = raw;
	if (ele_parse_u32(argv[1], &cmd->store_id) != 0)
		return -1;
	if (ele_parse_u32(argv[2], &fd) != 0 || fd > 1023)
		return -1;
	cmd->nonce_fd = (int)fd;
	if (!strcmp(argv[3], "gen") && argc == 4) {
		cmd->op = ELE_CLI_GEN;
	} else if (!strcmp(argv[3], "sign") && argc == 6) {
		cmd->op = ELE_CLI_SIGN;
		if (ele_parse_u32(argv[4], &cmd->key_id) != 0)
			return -1;
		cmd->msg = argv[5];
	} else if (!strcmp(argv[3], "del") && argc == 5) {
		cmd->op = ELE_CLI_DEL;
		if (ele_parse_u32(argv[4], &cmd->key_id) != 0)
			return -1;
	} else if (!strcmp(argv[3], "import") && argc == 5) {
		cmd->op = ELE_CLI_IMPORT;
		if (argv[4][0] == '\0')
			return -1;
		cmd->blob_path = argv[4];
	} else {
		return -1;
	}
	if (raw && cmd->op != ELE_CLI_SIGN)
		return -1;
	return 0;
}

/* Calls to the generic ele_parse_u32, counted so a test can show the nonce
 * path never makes one (the generic parser keeps its value in an ordinary
 * automatic variable that is never erased). */
volatile unsigned long ele_parse_u32_calls;

/* The nonce parser: the same strict rules as ele_parse_u32 (one optional 0x/0X
 * prefix, then only digits of the base, no empty rest, no overflow), but the
 * running value is accumulated straight into *acc, which the caller points at
 * the locked slot, through a volatile pointer. The only other locals are the
 * text pointer and one digit, and the digit is erased on every path. *acc is
 * zeroed on every refusal. Stack residue in the optimised binary is minimised
 * by this, not proven absent. */
int ele_nonce_parse(const char *text, uint32_t *acc)
{
	volatile uint32_t *a = acc;
	volatile unsigned int d = 0;
	unsigned int base = 10;
	const char *p = text;
	int rc = -1;

	if (!text || !acc)
		return -1;
	*a = 0;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		base = 16;
		p += 2;
	}
	if (*p == '\0')
		goto out;
	for (; *p; p++) {
		if (*p >= '0' && *p <= '9')
			d = (unsigned int)(*p - '0');
		else if (base == 16 && *p >= 'a' && *p <= 'f')
			d = (unsigned int)(*p - 'a') + 10;
		else if (base == 16 && *p >= 'A' && *p <= 'F')
			d = (unsigned int)(*p - 'A') + 10;
		else
			goto out;
		/* value*base + d must fit in 32 bits, checked before the multiply */
		if (*a > (UINT32_MAX - d) / base)
			goto out;
		*a = *a * base + d;
	}
	rc = 0;
out:
	d = 0;
	if (rc != 0)
		*a = 0;
	return rc;
}

static int read_nonce_text(int fd, char *buf, uint32_t *nonce)
{
	size_t n = 0;
	ssize_t r;
	int bad = 0;

	if (isatty(fd))
		return -1;
	/* One byte at a time, straight into the locked slot (buf): no byte of the
	 * credential is ever held in a stack variable. A producer that writes the
	 * line and keeps its end open (no EOF) must not block the client. The
	 * buffer bounds the length; EOF ends the text as a newline does. */
	for (;;) {
		if (n >= ELE_NONCE_BUF - 1) {
			bad = 1;
			break;
		}
		r = read(fd, buf + n, 1);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			bad = 1;
			break;
		}
		if (r == 0 || buf[n] == '\n') {
			buf[n] = '\0';
			break;
		}
		n++;
	}
	/* Anything longer than the buffer holds is not a 32-bit number. */
	if (bad || n == 0 || n > 16 || memchr(buf, '\0', n))
		return -1;
	/* Not ele_parse_u32: that keeps the value in an unerased automatic. */
	return ele_nonce_parse(buf, nonce);
}

/* The slot owns whole pages of its own (an anonymous mapping), so locking and
 * unlocking it can never touch the lock state of any other object. */
struct ele_nonce_slot *ele_nonce_slot_new(void)
{
	void *p = mmap(NULL, (size_t)sysconf(_SC_PAGESIZE), PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (p == MAP_FAILED)
		return NULL;
	if (mlock(p, sizeof(struct ele_nonce_slot)) != 0) {
		munmap(p, (size_t)sysconf(_SC_PAGESIZE));
		return NULL;
	}
#ifdef MADV_DONTDUMP
	(void)madvise(p, (size_t)sysconf(_SC_PAGESIZE), MADV_DONTDUMP);
#endif
	return p;
}

int ele_nonce_slot_read(int fd, struct ele_nonce_slot *s)
{
	int rc;

	if (!s)
		return -1;
	rc = read_nonce_text(fd, s->text, &s->value);
	ele_secure_zero(s->text, sizeof(s->text));
	if (rc != 0)
		s->value = 0;
	return rc;
}

void ele_nonce_slot_free(struct ele_nonce_slot *s)
{
	if (!s)
		return;
	ele_secure_zero(s, sizeof(*s));
	munlock(s, sizeof(*s));
	munmap(s, (size_t)sysconf(_SC_PAGESIZE));
}

int ele_harden_process(void)
{
	struct rlimit rl = { 0, 0 };
	int rc = 0;

#ifdef __linux__
	if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0)
		rc = -1;
#endif
	if (setrlimit(RLIMIT_CORE, &rl) != 0)
		rc = -1;
	return rc;
}

int (*ele_cli_lockall_override)(void);
void (*ele_cli_read_hook)(void);

/* Order is the point: dumpable off and all memory locked first; only then is
 * the first credential byte read. On any failure nothing is read. */
int ele_cli_open_nonce(int fd, struct ele_nonce_slot **out)
{
	struct ele_nonce_slot *s;
	int rc;

	if (!out)
		return ELE_CLI_NONCE_NOLOCK;
	*out = NULL;
#ifdef __linux__
	if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0)
		return ELE_CLI_NONCE_NOLOCK;
#endif
	rc = ele_cli_lockall_override ? ele_cli_lockall_override() : mlockall(MCL_CURRENT | MCL_FUTURE);
	if (rc != 0)
		return ELE_CLI_NONCE_NOLOCK;
	s = ele_nonce_slot_new();
	if (!s)
		return ELE_CLI_NONCE_NOLOCK;
	if (ele_cli_read_hook)
		ele_cli_read_hook();
	if (ele_nonce_slot_read(fd, s) != 0) {
		ele_nonce_slot_free(s);
		return ELE_CLI_NONCE_BAD;
	}
	*out = s;
	return 0;
}
