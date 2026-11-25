#!/usr/bin/env python3
"""okp-policy-check.py <trace.jsonl>

The oem-key-provisioning row of docs/SPEC.md as a fail-closed check of the
trace of one provisioning run, one JSON object per line, in the order the
steps ran. It does not talk to an enclave and closes nothing; it decides
whether a recorded run kept the row
(docs/oem-key-provisioning/architecture.md).

Each record has a "step":

- key_exchange (AN14861 sections 2, 5.2; RM00284 section 3.20): the enclave
  and the provisioning side agree the key that wraps the OEM key. It counts
  only with "status": "ok".
- key_import (AN14861 section 5.3; RM00284 section 3.2.6.3): the OEM key,
  "wrapped": true, imported into the enclave's key store. It must follow a
  key_exchange that succeeded earlier in the same run (the vendor's order).
  It is committed only when the request sent, and the enclave acknowledged,
  both the strict-operation flag and the monotonic-counter flag, the enclave
  returned no warning and the counter split is configured (RM00284 section
  2.4.2; owner decision 241). The "warnings" field must be present and a
  list of strings (empty means none); absent, null or any other type is not
  committed.
- counter_fuse_config (RM00284 section 3.24): the monotonic counter fuses are
  configured once. A fuse write is irreversible: it needs the owner's
  explicit approval ("owner_approval", a non-empty reference) and runs at
  most once, and the prior state must be proven: "already_configured" must
  be present and the JSON boolean false (true means the fuses are already
  configured and are not written again; anything else fails).
- counter_fuse_evidence (RM00284 section 3.24): a read-only record that the
  fuses were configured before this run, {"configured": true, "evidence":
  "<non-empty reference>"}. It stands in for counter_fuse_config at the end
  of the trace; it is refused after a fuse write in the same run, and a
  fuse write after it is refused.
- lifecycle_close (RM00284 section 3.23): the life cycle moves from OEM open
  to OEM closed through the enclave ("from": "oem_open", "to": "oem_closed",
  "via": "enclave"). Irreversible: it needs "owner_approval" and runs at most
  once.

The run must be complete: at the end of the trace the check requires a
committed key_import, the counter fuses configured (counter_fuse_config or
counter_fuse_evidence) and the lifecycle_close; a trace that stops short, a
key_exchange alone included, fails.

No record carries a key in the clear ("plaintext_key"). Any other step fails:
the check knows no other step, so it fails closed. The relative order of the
fuse write, the import and the close is not given by the row's citations, so
it is not checked; when the close runs and where provisioning runs are the
owner's open questions.

Prints one line per record and a summary. Exit status: 0 when every record
holds, 1 when one does not, 2 when the trace cannot be read.
"""

import json
import sys

STEPS = {
    "key_exchange": "AN14861 §2, §5.2; RM00284 §3.20",
    "key_import": "AN14861 §5.3; RM00284 §3.2.6.3",
    "counter_fuse_config": "RM00284 §3.24",
    "lifecycle_close": "RM00284 §3.23",
    "counter_fuse_evidence": "RM00284 §3.24",
}
IRREVERSIBLE = ("counter_fuse_config", "lifecycle_close")
ROLLBACK_FLAGS = ("strict", "monotonic")


def flag_list(rec, field):
    """The named flag list of a record; a missing field is no flags."""
    value = rec.get(field, [])
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ValueError(f"{field} must be a list of strings")
    return value


def commit_faults(rec):
    """Why a key_import is not committed; empty if it is."""
    faults = []
    sent = flag_list(rec, "request_flags")
    acked = flag_list(rec, "ack_flags")
    for flag in ROLLBACK_FLAGS:
        if flag not in sent:
            faults.append(f"{flag} flag not sent")
        elif flag not in acked:
            faults.append(f"{flag} flag not acknowledged")
    warnings = rec.get("warnings")
    if not isinstance(warnings, list) or not all(isinstance(w, str) for w in warnings):
        faults.append("warnings absent or not a list of strings: no proof the enclave returned none")
    else:
        for warning in warnings:
            faults.append(f"enclave warning {warning}")
    if rec.get("counter_split") is not True:
        faults.append("counter split not configured")
    return faults


def approved(rec):
    value = rec.get("owner_approval")
    return isinstance(value, str) and value.strip() != ""


class Run:
    """The state of one provisioning run, record by record."""

    def __init__(self):
        self.exchanged = False
        self.done = set()
        # Outcomes that completed without a fault; finish() needs them.
        self.committed = False
        self.fuses_configured = False
        self.fuses_evidenced = False
        self.closed = False

    def finish(self):
        """The faults of a trace that ends here: the run must have completed."""
        faults = []
        if not self.committed:
            faults.append("no key import committed (RM00284 §2.4.2, owner decision 241)")
        if not (self.fuses_configured or self.fuses_evidenced):
            faults.append("the counter fuses are not shown configured: no counter_fuse_config, "
                          "no counter_fuse_evidence (RM00284 §3.24)")
        if not self.closed:
            faults.append("no life-cycle close from OEM open to OEM closed (RM00284 §3.23)")
        return faults

    def check(self, rec):
        """The faults of one record, and the verdict line for it."""
        if not isinstance(rec, dict):
            raise ValueError("a record must be a JSON object")
        step = rec.get("step")
        faults = []
        if step not in STEPS:
            return [f"step {step!r} is not a step of the vendor's flow"], f"{step}: refused"
        if "plaintext_key" in rec:
            faults.append("key material in the clear (RM00284 §2.4, §3.2)")
        verdict = "ok"
        if step == "key_exchange":
            if rec.get("status") != "ok":
                faults.append(f"key exchange status {rec.get('status')!r}, not ok")
            else:
                self.exchanged = True
        elif step == "key_import":
            if not self.exchanged:
                faults.append("no successful key exchange before the import (AN14861 §2, §5.2, §5.3)")
            if rec.get("wrapped") is not True:
                faults.append("the imported key is not wrapped (AN14861 §5.3)")
            cf = commit_faults(rec)
            if cf:
                faults.append("not committed: " + "; ".join(cf) + " (RM00284 §2.4.2, owner decision 241)")
                verdict = "not committed"
            else:
                verdict = "committed"
        elif step == "counter_fuse_evidence":
            # A read-only record that the fuses were configured before this run.
            evidence = rec.get("evidence")
            if rec.get("configured") is not True:
                faults.append("counter_fuse_evidence needs \"configured\": true")
            if not isinstance(evidence, str) or evidence.strip() == "":
                faults.append("counter_fuse_evidence needs a non-empty \"evidence\" reference")
            if "counter_fuse_config" in self.done:
                faults.append("the counter fuses were written in this run; there is no prior state to evidence")
        else:
            if not approved(rec):
                faults.append(f"irreversible ({STEPS[step]}): no owner_approval recorded")
            if step in self.done:
                faults.append(f"runs at most once ({STEPS[step]}); this is a second run")
            if step == "counter_fuse_config":
                prior = rec.get("already_configured")
                if prior is True:
                    faults.append("the monotonic counter fuses are already configured; configured once (RM00284 §3.24)")
                elif prior is not False:
                    faults.append("already_configured must be present and the JSON boolean false "
                                  f"(got {prior!r}): the prior fuse state is not proven (RM00284 §3.24)")
                if self.fuses_evidenced:
                    faults.append("counter_fuse_evidence says the fuses are already configured; configured once")
            if step == "lifecycle_close":
                for field, want in (("from", "oem_open"), ("to", "oem_closed"), ("via", "enclave")):
                    if rec.get(field) != want:
                        faults.append(f"{field} {rec.get(field)!r}, want {want!r} (RM00284 §3.23)")
            self.done.add(step)
        if faults and verdict == "ok":
            verdict = "refused"
        if not faults:
            if step == "key_import":
                self.committed = True
            elif step == "counter_fuse_config":
                self.fuses_configured = True
            elif step == "counter_fuse_evidence":
                self.fuses_evidenced = True
            elif step == "lifecycle_close":
                self.closed = True
        return faults, f"{step}: {verdict}"


def main(argv):
    if len(argv) != 2:
        print("usage: okp-policy-check.py <trace.jsonl>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as err:
        print(f"okp-policy-check: {err}", file=sys.stderr)
        return 2
    run = Run()
    records = 0
    failed = 0
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            faults, verdict = run.check(json.loads(line))
        except (ValueError, TypeError) as err:
            print(f"okp-policy-check: {argv[1]}:{n}: {err}", file=sys.stderr)
            return 2
        records += 1
        if faults:
            failed += 1
            print(f"FAIL {n} {verdict}: " + "; ".join(faults))
        else:
            print(f"ok {n} {verdict}")
    if records == 0:
        print(f"okp-policy-check: {argv[1]}: no record", file=sys.stderr)
        return 2
    incomplete = run.finish()
    for fault in incomplete:
        print(f"FAIL end of trace: {fault}")
    if failed or incomplete:
        print(f"okp-policy-check: {failed} of {records} records break the oem-key-provisioning row"
              + (f"; the run is incomplete ({len(incomplete)} outcomes missing)" if incomplete else ""))
        return 1
    print(f"okp-policy-check: OK ({records} records keep the oem-key-provisioning row)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
