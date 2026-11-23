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
	unsigned long long v;
	char *end = NULL;
	int base = 10;
	const char *p = s;

	if (!s || !out)
		return -1;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		base = 16;
		p += 2;
	}
	/* strtoull accepts a sign and leading space: only digits may start it. */
	if (base == 10 ? !(*p >= '0' && *p <= '9') :
			 !((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')))
		return -1;
	errno = 0;
	v = strtoull(p, &end, base);
	if (errno != 0 || end == p || *end != '\0' || v > UINT32_MAX)
		return -1;
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
	} else {
		return -1;
	}
	if (raw && cmd->op != ELE_CLI_SIGN)
		return -1;
	return 0;
}

static int read_nonce_text(int fd, char *buf, uint32_t *nonce)
{
	size_t n = 0;
	ssize_t r;
	char ch;

	if (isatty(fd))
		return -1;
	/* One byte at a time, up to the newline: a producer that writes the line
	 * and keeps its end open (no EOF) must not block the client. The buffer
	 * still bounds the length; EOF ends the text as a newline does. */
	while (n < ELE_NONCE_BUF - 1) {
		r = read(fd, &ch, 1);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			ele_secure_zero(&ch, sizeof(ch));
			return -1;
		}
		if (r == 0 || ch == '\n')
			break;
		buf[n++] = ch;
	}
	ele_secure_zero(&ch, sizeof(ch));
	buf[n] = '\0';
	/* Anything longer than the buffer holds is not a 32-bit number. */
	if (n == 0 || n > 16 || memchr(buf, '\0', n))
		return -1;
	return ele_parse_u32(buf, nonce);
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
