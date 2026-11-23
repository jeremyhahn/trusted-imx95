/* See ele_cli_args.h. PROVISIONAL. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ele_cli_args.h"

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
	bool split = false;

	if (argc < 4 || !argv || !cmd)
		return -1;
	if (!strcmp(argv[1], "--split-confirmed")) {
		split = true;
		argc--;
		argv++;
		if (argc < 4)
			return -1;
	}
	memset(cmd, 0, sizeof(*cmd));
	cmd->split_confirmed = split;
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
	return 0;
}

int ele_read_nonce(int fd, uint32_t *nonce)
{
	char buf[18];
	size_t n = 0;
	ssize_t r;

	if (isatty(fd))
		return -1;
	while (n < sizeof(buf) - 1 && (r = read(fd, buf + n, sizeof(buf) - 1 - n)) != 0) {
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		n += (size_t)r;
	}
	if (n > 0 && buf[n - 1] == '\n')
		n--;
	buf[n] = '\0';
	/* Anything longer than the buffer holds is not a 32-bit number. */
	if (n == 0 || n > 16 || memchr(buf, '\0', n))
		return -1;
	return ele_parse_u32(buf, nonce);
}
