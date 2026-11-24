/* Host test of the tamper-event parser. Every vector of the design note's
 * contract section is carried below, in the note's spelling (test/hsd_a55_test.sh
 * checks that each one of the note appears here). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tamper_event.h"

static int fails;

#define CHECK(cond, ...)                                                 \
	do {                                                             \
		if (!(cond)) {                                           \
			printf("FAIL %s:%d: ", __FILE__, __LINE__);      \
			printf(__VA_ARGS__);                             \
			printf("\n");                                    \
			fails++;                                         \
		}                                                        \
	} while (0)

struct vec {
	const char *id;
	const char *hex;
	enum tamper_status want;
	unsigned code;
	unsigned source;
	unsigned long long seq;
};

/* Accepted records V1 to V6. */
static const struct vec good[] = {
	{ "V1", "54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75", TAMPER_OK, 0x0001, 1, 1 },
	{ "V2", "54 41 4d 50 01 00 1c 00 02 00 01 00 02 00 00 00 00 00 00 00 00 00 00 00 d7 cb e1 2b", TAMPER_OK, 0x0002, 1, 2 },
	{ "V3", "54 41 4d 50 01 00 1c 00 03 00 01 00 03 00 00 00 00 00 00 00 00 00 00 00 29 16 2c 1e", TAMPER_OK, 0x0003, 1, 3 },
	{ "V4", "54 41 4d 50 01 00 1c 00 04 00 02 00 04 00 00 00 00 00 00 00 00 00 00 00 08 22 2c eb", TAMPER_OK, 0x0004, 2, 4 },
	{ "V5", "54 41 4d 50 01 00 1c 00 ff 00 01 00 05 00 00 00 00 00 00 00 00 00 00 00 ec 3e a8 d5", TAMPER_OK, 0x00ff, 1, 5 },
	{ "V6", "54 41 4d 50 01 00 1c 00 00 01 01 00 06 00 00 00 00 00 00 00 00 00 00 00 23 0e bc 16", TAMPER_OK, 0x0100, 1, 6 },
};

/* Rejected records R1 to R11 (R12, replay, is the state machine's). */
static const struct vec bad[] = {
	{ "R1", "54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7", TAMPER_SHORT, 0, 0, 0 },
	{ "R2", "54 41 4d 51 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 4b 2e 6d ea", TAMPER_BAD_MAGIC, 0, 0, 0 },
	{ "R3", "54 41 4d 50 02 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 1f e0 1e da", TAMPER_BAD_VERSION, 0, 0, 0 },
	{ "R4", "54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75 00", TAMPER_LONG, 0, 0, 0 },
	{ "R5", "54 41 4d 50 01 00 20 00 01 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 f7 30 ab 1a", TAMPER_BAD_LENGTH, 0, 0, 0 },
	{ "R6", "54 41 4d 50 01 00 1c 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 d5 ad b7 75", TAMPER_BAD_CRC, 0, 0, 0 },
	{ "R7", "54 41 4d 50 01 00 1c 00 01 00 7f 00 01 00 00 00 00 00 00 00 00 00 00 00 10 4b 43 54", TAMPER_BAD_SOURCE, 0, 0, 0 },
	{ "R8", "54 41 4d 50 01 00 1c 00 01 00 02 00 01 00 00 00 00 00 00 00 00 00 00 00 0e 88 d6 09", TAMPER_SOURCE_CODE_MISMATCH, 0, 0, 0 },
	{ "R9", "54 41 4d 50 01 00 1c 00 01 00 01 01 01 00 00 00 00 00 00 00 00 00 00 00 50 74 21 a8", TAMPER_BAD_RESERVED, 0, 0, 0 },
	{ "R10", "54 41 4d 50 01 00 1c 00 01 00 01 00 01 00 00 00 00 00 00 00 01 00 00 00 b0 ca 0b cd", TAMPER_BAD_RESERVED, 0, 0, 0 },
	{ "R11", "54 41 4d 50 01 00 1c 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 ba e1 12 ee", TAMPER_BAD_SEQUENCE, 0, 0, 0 },
};

/* Decode "aa bb cc" into buf; returns the byte count. */
static size_t unhex(const char *s, uint8_t *buf, size_t cap)
{
	size_t n = 0;

	while (*s != '\0') {
		char *end;
		unsigned long v = strtoul(s, &end, 16);

		if (end == s || n >= cap || v > 0xff) {
			printf("FAIL bad hex in test table: %s\n", s);
			exit(2);
		}
		buf[n++] = (uint8_t)v;
		s = end;
		while (*s == ' ')
			s++;
	}
	return n;
}

static void test_vectors(void)
{
	size_t i;
	uint8_t buf[64];

	for (i = 0; i < sizeof(good) / sizeof(good[0]); i++) {
		struct tamper_event ev;
		size_t n = unhex(good[i].hex, buf, sizeof(buf));
		enum tamper_status st;

		memset(&ev, 0xaa, sizeof(ev));
		st = tamper_event_parse(buf, n, &ev);
		CHECK(n == 28, "%s is %zu bytes", good[i].id, n);
		CHECK(st == TAMPER_OK, "%s: status %s", good[i].id, tamper_status_name(st));
		CHECK(ev.code == good[i].code, "%s: code %#x", good[i].id, ev.code);
		CHECK(ev.source == good[i].source, "%s: source %u", good[i].id, ev.source);
		CHECK(ev.sequence == good[i].seq, "%s: sequence %llu", good[i].id,
		      (unsigned long long)ev.sequence);
	}
	for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		struct tamper_event ev;
		struct tamper_event before;
		size_t n = unhex(bad[i].hex, buf, sizeof(buf));
		enum tamper_status st;

		memset(&ev, 0x5a, sizeof(ev));
		before = ev;
		st = tamper_event_parse(buf, n, &ev);
		CHECK(st == bad[i].want, "%s: status %s, want %s", bad[i].id,
		      tamper_status_name(st), tamper_status_name(bad[i].want));
		CHECK(memcmp(&ev, &before, sizeof(ev)) == 0, "%s: output written on reject", bad[i].id);
	}
}

static void test_names(void)
{
	int s;

	for (s = 0; s < TAMPER_STATUS_COUNT; s++)
		CHECK(strcmp(tamper_status_name((enum tamper_status)s), "unknown-status") != 0,
		      "status %d has no name", s);
	CHECK(strcmp(tamper_status_name(TAMPER_BAD_CRC), "bad-crc") == 0, "bad-crc name");
	CHECK(strcmp(tamper_status_name(TAMPER_SOURCE_CODE_MISMATCH), "source-code-mismatch") == 0,
	      "source-code-mismatch name");
}

static void test_crc(void)
{
	/* The standard check value of CRC-32/IEEE. */
	CHECK(tamper_crc32((const uint8_t *)"123456789", 9) == 0xcbf43926u, "crc32 check value");
}

/* Every length from 0 to the record size, for each valid vector: short below
 * 28, ok at 28; and for an unknown version, bad-version from 8 bytes up. */
static void test_truncation(void)
{
	uint8_t buf[64];
	size_t i, len, n;

	for (i = 0; i < sizeof(good) / sizeof(good[0]); i++) {
		n = unhex(good[i].hex, buf, sizeof(buf));
		for (len = 0; len <= n; len++) {
			enum tamper_status st = tamper_event_parse(buf, len, NULL);
			enum tamper_status want = len < n ? TAMPER_SHORT : TAMPER_OK;

			CHECK(st == want, "%s truncated to %zu: %s", good[i].id, len,
			      tamper_status_name(st));
		}
		buf[n] = 0;
		CHECK(tamper_event_parse(buf, n + 1, NULL) == TAMPER_LONG, "%s plus a byte", good[i].id);
	}
	n = unhex(bad[2].hex, buf, sizeof(buf)); /* R3, version 2 */
	for (len = 0; len <= n + 8; len++) {
		enum tamper_status st = tamper_event_parse(buf, len < 64 ? len : 64, NULL);
		enum tamper_status want = len < 8 ? TAMPER_SHORT : TAMPER_BAD_VERSION;

		CHECK(st == want, "R3 at %zu bytes: %s", len, tamper_status_name(st));
	}
	CHECK(tamper_event_parse(NULL, 0, NULL) == TAMPER_SHORT, "NULL buffer");
}

/* One byte changed at every offset of every valid vector (two patterns): the
 * CRC covers bytes 0 to 23 and is itself bytes 24 to 27, so no byte is free:
 * the status is defined and is never ok. */
static void test_flips(void)
{
	static const uint8_t pat[] = { 0xff, 0x01, 0x80 };
	uint8_t buf[64], orig[64];
	size_t i, off, p, n;

	for (i = 0; i < sizeof(good) / sizeof(good[0]); i++) {
		n = unhex(good[i].hex, orig, sizeof(orig));
		for (off = 0; off < n; off++) {
			for (p = 0; p < sizeof(pat); p++) {
				enum tamper_status st;
				struct tamper_event ev;

				memcpy(buf, orig, n);
				buf[off] ^= pat[p];
				st = tamper_event_parse(buf, n, &ev);
				CHECK(st != TAMPER_OK && st < TAMPER_STATUS_COUNT,
				      "%s flip %#x at %zu gave %s", good[i].id, pat[p], off,
				      tamper_status_name(st));
			}
		}
	}
}

int main(void)
{
	test_vectors();
	test_names();
	test_crc();
	test_truncation();
	test_flips();
	if (fails != 0) {
		printf("tamper_event_test: %d failed\n", fails);
		return 1;
	}
	printf("tamper_event_test: all passed\n");
	return 0;
}
