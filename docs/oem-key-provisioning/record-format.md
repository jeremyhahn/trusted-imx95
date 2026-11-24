# Station record format

> **Status: proposed, pending owner approval** · Scope: trusted-imx95 `oem-key-provisioning` · Last verified: 2026-11-24
> A station-side proposal. The record schema and the registry belong to go-trusted-platform
> ([SPEC.md](../SPEC.md), Boundaries). Nothing here is a device fact.

The provisioning station (owner ruling 1234) leaves one record per device. This page proposes the
fields of that record; [provisioning-records-survey.md](provisioning-records-survey.md) §3 says what it
holds and §4 what it must never hold. Until the owner answers §8, the checker uses the survey's own
recommendations: Q1 (a) the enclave UID is the key, with the board serial alongside; Q3 (a) only a hash
of each wrapped blob, never the blob; Q4 (a) the SRK lock state and the life-cycle state before and
after are mandatory. They sit in one table at the top of `scripts/okp/record-check.py`
(`OWNER_ANSWERS`), so another answer is a one-line edit.

The envelope (survey §8 Q6) is not chosen. The checker reads the plain JSON payload; the signature
envelope is go-trusted-platform's.

## Fields

JSON object; every field cites the survey §3 row. "Optional" marks a field the survey §7 lists as unconfirmed.

| JSON name | Type | Required | Survey |
| --- | --- | --- | --- |
| `device_uid` | string | yes | §3 device identifier |
| `board_serial` | string | yes (Q1 a) | §3 board identifier |
| `soc_revision` | string (`A0`, `A1`, `B0`) | yes | §3 SRK hash row |
| `srk_hash_algorithm` | string | yes | §3 SRK hash row |
| `srk_hash` | hex string, 64 characters on A0/A1, 128 on B0 | yes | §3 SRK hash row |
| `pqc_srk_hash` | hex string, same width | optional (B0 only) | §3 SRK hash row |
| `srk_lock_states` | object, lock name to boolean | yes (Q4 a) | §3 SRK fuse lock state |
| `life_cycle_before`, `life_cycle_after` | string | yes (Q4 a) | §3 life-cycle state |
| `ahab_events` | list, expected empty | yes | §3 AHAB event status |
| `enclave_fw_version` | string | yes | §3 enclave firmware version |
| `spsdk_version` | string | yes | §3 station software |
| `enclave_lib_version` | string | optional (§7) | §3 library version |
| `public_keys` | list of `{key_id, public_key_hash}` | yes | §3 public keys |
| `key_policy` | list of `{key_id, algorithm, usage}` | optional (§7) | §3 key policy |
| `monotonic_counter` | integer | yes | §3 monotonic counter |
| `step_times` | object, step name to time string | yes | §3 time |
| `station_id`, `operator_role` | string | yes | §3 station and operator |
| `outcome` | string | yes | §3 outcome |
| `payload_hashes` | list of hex strings | optional (Q3 a) | §4 wrapped blobs |
| `secure_object_ids` | list of strings | optional | §4 EdgeLock 2GO objects |

Public keys are carried as a key ID and a hash, not as key material. A device ID that looks like
hex or base64 of 32 bytes or more is refused, so write the UID in its reported text form.

## What the checker refuses

`scripts/okp/record-check.py RECORD.json` reads one file and touches no device. Exit 0 valid; 1 each
problem named by file and JSON path (never the value); 2 not JSON. It refuses (survey §4):

- a PEM or OpenSSH private-key header in any string or key name;
- a key name on the deny list: private key, secret, session key, wrapped key, blob, token, password,
  API key, secure-object contents, and names for a station credential;
- a string of plain hex or base64 of 32 bytes or more outside the declared hash fields;
- a hash field whose width is wrong (256-bit on A0/A1, 512-bit on B0).

`make okp-record-check` runs it on the test fixture. Owner question (proposed, pending owner approval):
whether the SPEC row should name this record; this lane does not edit SPEC.md.
