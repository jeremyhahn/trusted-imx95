#!/usr/bin/env python3
"""Check one proposed station record (JSON) for required fields and for secrets.

Proposed, pending owner approval: see docs/oem-key-provisioning/record-format.md.
Reads the one file named on the command line and nothing else: no network, no
device, no subprocess. The signature envelope around the payload is
go-trusted-platform's and is not read here.

Exit 0: the record is valid. Exit 1: each problem is printed with the file and
the JSON path (never a value). Exit 2: usage error, or the file is not JSON.
"""
import base64
import binascii
import json
import re
import sys

# --- owner answers: begin (survey section 8; the survey's own recommendations, pending the owner)
OWNER_ANSWERS = {
    "Q1_board_serial_required": True,  # Q1 (a): enclave UID is the key, board serial alongside
    "Q3_blob_hash_only": True,  # Q3 (a): only a hash of each wrapped blob, never the blob
    "Q4_lock_and_lifecycle_required": True,  # Q4 (a): lock state and life-cycle before/after mandatory
}
# --- owner answers: end

Q1 = OWNER_ANSWERS["Q1_board_serial_required"]
Q4 = OWNER_ANSWERS["Q4_lock_and_lifecycle_required"]

# --- required fields: begin
# (JSON name, type, required, survey section 3 row)
FIELDS = (
    ("device_uid", str, True, "device identifier"),
    ("board_serial", str, Q1, "board identifier"),
    ("soc_revision", str, True, "SRK hash row: silicon revision"),
    ("srk_hash_algorithm", str, True, "SRK hash row"),
    ("srk_hash", str, True, "SRK hash row"),
    ("pqc_srk_hash", str, False, "SRK hash row: B0 only"),
    ("srk_lock_states", dict, Q4, "SRK fuse lock state"),
    ("life_cycle_before", str, Q4, "life-cycle state before"),
    ("life_cycle_after", str, Q4, "life-cycle state after"),
    ("ahab_events", list, True, "AHAB event status (expected empty)"),
    ("enclave_fw_version", str, True, "enclave firmware version"),
    ("spsdk_version", str, True, "station software versions"),
    ("enclave_lib_version", str, False, "library version (get-info set unconfirmed, section 7)"),
    ("public_keys", list, True, "public keys and their hashes"),
    ("key_policy", list, False, "key identifiers and policy (section 7: not re-read)"),
    ("monotonic_counter", int, True, "monotonic counter configuration"),
    ("step_times", dict, True, "time of each step"),
    ("station_id", str, True, "station"),
    ("operator_role", str, True, "operator role"),
    ("outcome", str, True, "outcome"),
    ("payload_hashes", list, False, "hash of each wrapped payload (Q3 a)"),
    ("secure_object_ids", list, False, "EdgeLock 2GO object identifiers, never contents"),
)
ITEM_FIELDS = {
    "public_keys": (("key_id", str, True), ("public_key_hash", str, True)),
    "key_policy": (("key_id", str, True), ("algorithm", str, True), ("usage", str, True)),
}
# --- required fields: end

# Hash width in hex characters. SRK hash by silicon revision (survey section 3: 256-bit on
# A0/A1, 512-bit on B0); the other hashes take either width. An unknown revision fails.
# --pre-close (proposed): the state a record must show before the step, and the fields it cannot yet hold.
PRE_CLOSE_STATE = "oem open"
PRE_CLOSE_LATER = ("life_cycle_after", "outcome", "step_times")
SRK_WIDTH = {"A0": 64, "A1": 64, "B0": 128}
OTHER_HASH_WIDTHS = (64, 128)

# --- deny list: begin
DENY_KEY_TERMS = (
    "privatekey", "secret", "sessionkey", "wrappedkey", "token", "password", "apikey",
    "secureobjectcontent", "securedobjectcontent",
    # a field named for a station credential
    "credential", "stationkey", "signingkey", "hsmpin", "bearer", "authkey",
    # a field named for an operator's personal data (survey section 4); a value cannot be judged
    "operatorname", "fullname", "email", "phone",
)
if OWNER_ANSWERS["Q3_blob_hash_only"]:
    DENY_KEY_TERMS += ("blob",)
# --- deny list: end

PEM_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----")
HEX_RE = re.compile(r"(?:0x)?[0-9A-Fa-f]{64,}")
B64_RE = re.compile(r"[A-Za-z0-9+/]{43,}={0,2}")
SAFE_KEY_RE = re.compile(r"[A-Za-z0-9_.-]{1,48}")


def usage():
    return "usage: record-check.py [-h] [--pre-close] RECORD.json   (reads one file, touches no device)"


def type_ok(value, typ):
    if typ is int:
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, typ)


def norm_revision(value):
    """The silicon revision with case and surrounding whitespace removed, or None."""
    return value.strip().upper() if isinstance(value, str) else None


def revision_errors(rec):
    """soc_revision must be a documented revision (A0, A1, B0), in every mode."""
    value = rec.get("soc_revision")
    if not isinstance(value, str) or norm_revision(value) in SRK_WIDTH:
        return []  # a missing or non-string value is reported by fields_errors
    return [
        "$.soc_revision: %r is not a known silicon revision (allowed: %s)"
        % (value, ", ".join(sorted(SRK_WIDTH)))
    ]


def fields_errors(rec, fields=None):
    fields = FIELDS if fields is None else fields
    errs = []
    if not isinstance(rec, dict):
        return ["$: the record is not a JSON object"]
    errs += revision_errors(rec)
    for name, typ, required, _src in fields:
        if name not in rec:
            if required:
                errs.append("$.%s: required field is missing" % name)
        elif not type_ok(rec[name], typ):
            errs.append("$.%s: must be %s" % (name, typ.__name__))
    for name, items in ITEM_FIELDS.items():
        if not isinstance(rec.get(name), list):
            continue
        for i, item in enumerate(rec[name]):
            if not isinstance(item, dict):
                errs.append("$.%s[%d]: must be an object" % (name, i))
                continue
            for sub, typ, required in items:
                if sub not in item:
                    if required:
                        errs.append("$.%s[%d].%s: required field is missing" % (name, i, sub))
                elif not type_ok(item[sub], typ):
                    errs.append("$.%s[%d].%s: must be %s" % (name, i, sub, typ.__name__))
    return errs


def hash_slots(rec):
    """Yield (path, value, allowed widths) for every declared hash field that holds a string."""
    if not isinstance(rec, dict):
        return
    # The SRK hash width follows the known revision only; an unknown revision is an
    # error of its own (revision_errors), so its hashes are not checked against a guess.
    width = SRK_WIDTH.get(norm_revision(rec.get("soc_revision")))
    if width:
        for name in ("srk_hash", "pqc_srk_hash"):
            if isinstance(rec.get(name), str):
                yield "$." + name, rec[name], (width,)
    for name, sub in (("public_keys", "public_key_hash"),):
        if isinstance(rec.get(name), list):
            for i, item in enumerate(rec[name]):
                if isinstance(item, dict) and isinstance(item.get(sub), str):
                    yield "$.%s[%d].%s" % (name, i, sub), item[sub], OTHER_HASH_WIDTHS
    if isinstance(rec.get("payload_hashes"), list):
        for i, v in enumerate(rec["payload_hashes"]):
            if isinstance(v, str):
                yield "$.payload_hashes[%d]" % i, v, OTHER_HASH_WIDTHS


def looks_encoded(s):
    """True for plain hex or base64 of 32 bytes or more."""
    if HEX_RE.fullmatch(s):
        return True
    if B64_RE.fullmatch(s):
        try:
            return len(base64.b64decode(s + "=" * (-len(s) % 4), validate=True)) >= 32
        except (binascii.Error, ValueError):
            return False
    return False


def norm(key):
    return re.sub(r"[^a-z0-9]", "", key.lower())


def secret_errors(rec):
    """Second pass over every string and key name. Never prints a value."""
    errs = []
    declared = {}
    for path, value, widths in hash_slots(rec):
        declared[path] = None
        if not (re.fullmatch(r"[0-9A-Fa-f]+", value) and len(value) in widths):
            errs.append("%s: hash must be hex of exactly %s characters" % (
                path, " or ".join(str(w) for w in widths)))

    def walk(node, path):
        if isinstance(node, dict):
            for n, (k, v) in enumerate(node.items()):
                label = k if SAFE_KEY_RE.fullmatch(k) and not looks_encoded(k) else "<key#%d>" % n
                sub = "%s.%s" % (path, label)
                if PEM_RE.search(k) or looks_encoded(k):
                    errs.append("%s: key name holds a private-key header or an encoded blob" % sub)
                nk = norm(k)
                for term in DENY_KEY_TERMS:
                    if term in nk:
                        errs.append("%s: field name is on the deny list (%s)" % (sub, term))
                        break
                walk(v, sub)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, "%s[%d]" % (path, i))
        elif isinstance(node, str):
            if PEM_RE.search(node) or "OPENSSH PRIVATE KEY" in node:
                errs.append("%s: string holds a private-key header" % path)
            elif path not in declared and looks_encoded(node):
                errs.append("%s: string is hex or base64 of 32 bytes or more outside a hash field" % path)

    walk(rec, "$")
    return errs


def pre_close_errors(rec):
    """Survey section 6 items a record can hold, before the irreversible step (proposed)."""
    if not isinstance(rec, dict):
        return []
    errs = []
    state = rec.get("life_cycle_before")
    if isinstance(state, str) and " ".join(state.split()).lower() != PRE_CLOSE_STATE:
        errs.append("$.life_cycle_before: must be the OEM open state before the step")
    if "ahab_events" in rec and rec["ahab_events"] != []:
        errs.append("$.ahab_events: must be an empty list before the step")
    return errs


def main(argv):
    if len(argv) == 2 and argv[1] in ("-h", "--help"):
        print(usage())
        return 0
    pre_close = len(argv) == 3 and argv[1] == "--pre-close"
    if len(argv) != 2 and not pre_close:
        print(usage(), file=sys.stderr)
        return 2
    path = argv[-1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError) as exc:
        print("%s: not readable JSON (%s)" % (path, type(exc).__name__), file=sys.stderr)
        return 2
    if pre_close:
        # a record written before the step cannot hold these three
        fields = tuple(
            (n, t, r and n not in PRE_CLOSE_LATER, s) for n, t, r, s in FIELDS
        )
        errors = fields_errors(rec, fields)
        errors += pre_close_errors(rec)
    else:
        errors = fields_errors(rec)
    errors += secret_errors(rec)
    if errors:
        for e in errors:
            print("%s: %s" % (path, e))
        return 1
    print("%s: ok (proposed record format; the signature envelope is go-trusted-platform's)" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
