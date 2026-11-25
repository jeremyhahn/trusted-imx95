#include "tamper_event.h"

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | ((unsigned)p[1] << 8));
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

static uint64_t le64(const uint8_t *p)
{
	return (uint64_t)le32(p) | ((uint64_t)le32(p + 4) << 32);
}

const char *tamper_status_name(enum tamper_status s)
{
	switch (s) {
	case TAMPER_OK:
		return "ok";
	case TAMPER_SHORT:
		return "short";
	case TAMPER_BAD_MAGIC:
		return "bad-magic";
	case TAMPER_BAD_VERSION:
		return "bad-version";
	case TAMPER_LONG:
		return "long";
	case TAMPER_BAD_LENGTH:
		return "bad-length";
	case TAMPER_BAD_CRC:
		return "bad-crc";
	case TAMPER_BAD_SOURCE:
		return "bad-source";
	case TAMPER_SOURCE_CODE_MISMATCH:
		return "source-code-mismatch";
	case TAMPER_BAD_RESERVED:
		return "bad-reserved";
	case TAMPER_BAD_SEQUENCE:
		return "bad-sequence";
	case TAMPER_STATUS_COUNT:
		break;
	}
	return "unknown-status";
}

uint32_t tamper_crc32(const uint8_t *buf, size_t len)
{
	uint32_t crc = 0xffffffffu;
	size_t i;
	int b;

	for (i = 0; i < len; i++) {
		crc ^= buf[i];
		for (b = 0; b < 8; b++)
			crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
	}
	return ~crc;
}

enum tamper_status tamper_event_parse(const uint8_t *buf, size_t len,
				      struct tamper_event *out)
{
	static const uint8_t magic[4] = { 0x54, 0x41, 0x4d, 0x50 };
	uint16_t code;
	uint8_t source;
	uint64_t seq;
	size_t i;

	if (buf == NULL || len < 8)
		return TAMPER_SHORT;
	for (i = 0; i < 4; i++)
		if (buf[i] != magic[i])
			return TAMPER_BAD_MAGIC;
	if (le16(buf + 4) != TAMPER_EVENT_VERSION)
		return TAMPER_BAD_VERSION;
	if (len < TAMPER_EVENT_SIZE)
		return TAMPER_SHORT;
	if (len > TAMPER_EVENT_SIZE)
		return TAMPER_LONG;
	if (le16(buf + 6) != TAMPER_EVENT_SIZE)
		return TAMPER_BAD_LENGTH;
	if (le32(buf + 24) != tamper_crc32(buf, 24))
		return TAMPER_BAD_CRC;
	code = le16(buf + 8);
	source = buf[10];
	if (source != TAMPER_SRC_M7 && source != TAMPER_SRC_ADAPTER)
		return TAMPER_BAD_SOURCE;
	if (source == TAMPER_SRC_ADAPTER && code != TAMPER_SHUTDOWN_IMMINENT)
		return TAMPER_SOURCE_CODE_MISMATCH;
	if (buf[11] != 0 || le32(buf + 20) != 0)
		return TAMPER_BAD_RESERVED;
	seq = le64(buf + 12);
	if (seq == 0)
		return TAMPER_BAD_SEQUENCE;
	if (out != NULL) {
		out->code = code;
		out->source = source;
		out->sequence = seq;
	}
	return TAMPER_OK;
}
