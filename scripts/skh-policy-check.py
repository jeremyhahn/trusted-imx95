#!/usr/bin/env python3
"""skh-policy-check.py <trace.jsonl>

The secure-key-handling row of docs/SPEC.md as a fail-closed check of a trace
of enclave operations, one JSON object per line. The trace is what a caller of
the EdgeLock secure enclave's HSM API records: the operation, the API it went
through, the flags it sent, the flags the enclave acknowledged, the warnings
the enclave returned and whether the key store's counter split is configured.
It does not talk to an enclave; it decides whether a recorded run kept the row.

Each record is checked against the row (docs/secure-key-handling/architecture.md):

- api must be "hsm": the Generic Crypto APIs are not available on the
  i.MX 95 (RM00284 section 3.45).
- op must be one of the HSM API services the row uses: key_generate,
  key_update, key_delete (key store and key management, RM00284 section 3.2),
  sign (section 3.4), data_storage (section 3.8), attest (section 3.12). Any
  other op fails: the check knows no other service, so it fails closed.
- No record carries a key in the clear ("plaintext_key"), and key_generate
  has "generated_in": "enclave": keys are generated and held in the enclave's
  key store and never leave it in the clear (RM00284 sections 2.4, 3.2).
- key_update and key_delete are rollback-protected only when the request sent
  both the strict-operation flag ("strict") and the monotonic-counter flag
  ("monotonic"), the enclave acknowledged both for that operation, it returned
  no warning, and the counter split is configured (RM00284 section 2.4.2;
  owner decision 241). One flag alone is not rollback-protected.

Prints one line per record and a summary. Exit status: 0 when every record
holds, 1 when one does not, 2 when the trace cannot be read.
"""

import json
import sys

SERVICES = {
    "key_generate": "RM00284 §3.2",
    "key_update": "RM00284 §3.2",
    "key_delete": "RM00284 §3.2",
    "sign": "RM00284 §3.4",
    "data_storage": "RM00284 §3.8",
    "attest": "RM00284 §3.12",
}
ROLLBACK_OPS = ("key_update", "key_delete")
ROLLBACK_FLAGS = ("strict", "monotonic")


def flag_list(rec, field):
    """The named flag list of a record; a missing field is no flags."""
    value = rec.get(field, [])
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ValueError(f"{field} must be a list of strings")
    return value


def rollback_faults(rec):
    """Why a key_update or key_delete is not rollback-protected; empty if it is."""
    faults = []
    sent = flag_list(rec, "request_flags")
    acked = flag_list(rec, "ack_flags")
    for flag in ROLLBACK_FLAGS:
        if flag not in sent:
            faults.append(f"{flag} flag not sent")
        elif flag not in acked:
            faults.append(f"{flag} flag not acknowledged")
    for warning in flag_list(rec, "warnings"):
        faults.append(f"enclave warning {warning}")
    if rec.get("counter_split") is not True:
        faults.append("counter split not configured")
    return faults


def check(rec):
    """The faults of one record, and the verdict line for it."""
    if not isinstance(rec, dict):
        raise ValueError("a record must be a JSON object")
    op = rec.get("op")
    faults = []
    if rec.get("api") != "hsm":
        faults.append(f"api {rec.get('api')!r} is not the HSM API (Generic Crypto is unavailable, RM00284 §3.45)")
    if op not in SERVICES:
        faults.append(f"op {op!r} is not an HSM API service the row uses")
    if "plaintext_key" in rec:
        faults.append("key material in the clear (RM00284 §2.4, §3.2)")
    if op == "key_generate" and rec.get("generated_in") != "enclave":
        faults.append("key not generated in the enclave (RM00284 §2.4, §3.2)")
    if op in ROLLBACK_OPS:
        rb = rollback_faults(rec)
        if rb:
            faults.append("not rollback-protected: " + "; ".join(rb) + " (RM00284 §2.4.2, owner decision 241)")
            return faults, f"{op}: not rollback-protected"
        return faults, f"{op}: rollback-protected"
    return faults, f"{op}: ok" if not faults else f"{op}: refused"


def main(argv):
    if len(argv) != 2:
        print("usage: skh-policy-check.py <trace.jsonl>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as err:
        print(f"skh-policy-check: {err}", file=sys.stderr)
        return 2
    records = 0
    failed = 0
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            faults, verdict = check(json.loads(line))
        except (ValueError, TypeError) as err:
            print(f"skh-policy-check: {argv[1]}:{n}: {err}", file=sys.stderr)
            return 2
        records += 1
        if faults:
            failed += 1
            print(f"FAIL {n} {verdict}: " + "; ".join(faults))
        else:
            print(f"ok {n} {verdict}")
    if records == 0:
        print(f"skh-policy-check: {argv[1]}: no record", file=sys.stderr)
        return 2
    if failed:
        print(f"skh-policy-check: {failed} of {records} records break the secure-key-handling row")
        return 1
    print(f"skh-policy-check: OK ({records} records keep the secure-key-handling row)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
