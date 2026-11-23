/* Host tests of the ele_client argument handling (no vendor header). */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "ele_cli_args.h"

static int fails;

#define CHECK(cond, what)                                                     \
	do {                                                                  \
		if (!(cond)) {                                                \
			printf("FAIL %s (line %d)\n", what, __LINE__);        \
			fails++;                                              \
		}                                                             \
	} while (0)

static int parse(const char *a, const char *b, const char *c, const char *d, const char *e)
{
	char *argv[7] = { (char *)"ele_client", (char *)a, (char *)b, (char *)c, (char *)d, (char *)e, NULL };
	struct ele_cli_cmd cmd;
	int argc = e ? 6 : d ? 5 : 4;

	return ele_cli_parse(argc, argv, &cmd);
}

static int nonce_from(const char *text, uint32_t *v)
{
	int p[2];
	int rc;

	if (pipe(p) != 0)
		return -2;
	if (write(p[1], text, strlen(text)) < 0) {
		close(p[0]);
		close(p[1]);
		return -2;
	}
	close(p[1]);
	rc = ele_read_nonce(p[0], v);
	close(p[0]);
	return rc;
}

int main(void)
{
	uint32_t v = 0;

	CHECK(ele_parse_u32("4294967295", &v) == 0 && v == 4294967295u, "UINT32_MAX accepted");
	CHECK(ele_parse_u32("0x10", &v) == 0 && v == 16, "hex accepted");
	CHECK(ele_parse_u32("4294967297", &v) != 0, "2^32+1 refused");
	CHECK(ele_parse_u32("4294967296", &v) != 0, "2^32 refused");
	CHECK(ele_parse_u32("99999999999999999999999", &v) != 0, "overflow refused");
	CHECK(ele_parse_u32("1junk", &v) != 0, "trailing characters refused");
	CHECK(ele_parse_u32("-1", &v) != 0, "minus sign refused");
	CHECK(ele_parse_u32("+1", &v) != 0, "plus sign refused");
	CHECK(ele_parse_u32(" 1", &v) != 0, "leading space refused");
	CHECK(ele_parse_u32("1 ", &v) != 0, "trailing space refused");
	CHECK(ele_parse_u32("", &v) != 0, "empty refused");
	CHECK(ele_parse_u32("0x", &v) != 0, "bare 0x refused");
	CHECK(ele_parse_u32("0x-1", &v) != 0, "signed hex refused");
	CHECK(ele_parse_u32(NULL, &v) != 0, "null refused");

	CHECK(parse("1", "3", "gen", NULL, NULL) == 0, "gen accepted");
	CHECK(parse("1", "3", "del", "4", NULL) == 0, "del accepted");
	CHECK(parse("1", "3", "sign", "4", "m") == 0, "sign accepted");
	CHECK(parse("1", "3", "del", "4294967297", NULL) != 0, "del 4294967297 refused");
	CHECK(parse("1", "3", "del", "1junk", NULL) != 0, "del 1junk refused");
	CHECK(parse("1", "3", "del", "-1", NULL) != 0, "del -1 refused");
	CHECK(parse("1", "3", "del", "", NULL) != 0, "del '' refused");
	CHECK(parse("1", "3", "sign", "-1", "m") != 0, "sign -1 refused");
	CHECK(parse("1x", "3", "gen", NULL, NULL) != 0, "bad store id refused");
	CHECK(parse("1", "99999", "gen", NULL, NULL) != 0, "bad nonce fd refused");
	CHECK(parse("1", "3", "gen", "4", NULL) != 0, "gen with a key id refused");
	CHECK(parse("1", "3", "frob", NULL, NULL) != 0, "unknown command refused");
	/* The nonce is never an argument: a number where the fd goes is a descriptor, and
	 * a nonce-sized value there is refused as one. */
	CHECK(parse("1", "305419896", "gen", NULL, NULL) != 0, "a nonce in argv is not accepted");

	CHECK(nonce_from("1234\n", &v) == 0 && v == 1234, "nonce from a descriptor");
	CHECK(nonce_from("0xdeadbeef", &v) == 0 && v == 0xdeadbeefu, "hex nonce, no newline");
	CHECK(nonce_from("12x\n", &v) != 0, "nonce with trailing characters refused");
	CHECK(nonce_from("-5\n", &v) != 0, "negative nonce refused");
	CHECK(nonce_from("4294967297\n", &v) != 0, "oversized nonce refused");
	CHECK(nonce_from("", &v) != 0, "empty nonce refused");
	CHECK(nonce_from("\n", &v) != 0, "blank nonce refused");
	CHECK(nonce_from("123456789012345678901234567890\n", &v) != 0, "long nonce refused");
	CHECK(ele_read_nonce(-1, &v) != 0, "bad descriptor refused");

	if (fails)
		return 1;
	printf("ele_cli_args_test: all passed\n");
	return 0;
}
