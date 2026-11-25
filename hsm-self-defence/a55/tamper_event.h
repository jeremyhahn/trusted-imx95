/* Tamper-event record, version 1: parser for the contract in
 * docs/hsm-self-defence/a55-tamper-response-design.md (proposed, pending
 * owner approval). Portable C99, no I/O, no allocation. The note wins over
 * this code if they disagree. */
#ifndef TAMPER_EVENT_H
#define TAMPER_EVENT_H

#include <stddef.h>
#include <stdint.h>

#define TAMPER_EVENT_SIZE 28u
#define TAMPER_EVENT_VERSION 1u

enum tamper_code {
	TAMPER_ASSERTED = 0x0001,
	TAMPER_ZEROISATION_STARTED = 0x0002,
	TAMPER_ZEROISATION_DONE = 0x0003,
	TAMPER_SHUTDOWN_IMMINENT = 0x0004,
	TAMPER_TEST_EVENT = 0x00ff
};

enum tamper_source {
	TAMPER_SRC_M7 = 0x01,
	TAMPER_SRC_ADAPTER = 0x02
};

/* One status per reject of the note's validation order (1 to 10), in that
 * order. The replay check (11) needs the last accepted sequence, so it is the
 * state machine's (quarantine.h). An unknown event code passes the parser:
 * the note makes it fail closed in the state machine. */
enum tamper_status {
	TAMPER_OK = 0,
	TAMPER_SHORT,
	TAMPER_BAD_MAGIC,
	TAMPER_BAD_VERSION,
	TAMPER_LONG,
	TAMPER_BAD_LENGTH,
	TAMPER_BAD_CRC,
	TAMPER_BAD_SOURCE,
	TAMPER_SOURCE_CODE_MISMATCH,
	TAMPER_BAD_RESERVED,
	TAMPER_BAD_SEQUENCE,
	TAMPER_STATUS_COUNT
};

struct tamper_event {
	uint16_t code;     /* raw wire value; may be unassigned */
	uint8_t source;    /* enum tamper_source */
	uint64_t sequence; /* never 0 in a parsed event */
};

/* Stable reject name (the note's spelling), "ok" for TAMPER_OK. */
const char *tamper_status_name(enum tamper_status s);

/* CRC-32 (IEEE 802.3, reflected, init and final xor 0xffffffff). */
uint32_t tamper_crc32(const uint8_t *buf, size_t len);

/* Parse one record. *out is written only on TAMPER_OK. */
enum tamper_status tamper_event_parse(const uint8_t *buf, size_t len,
				      struct tamper_event *out);

#endif
