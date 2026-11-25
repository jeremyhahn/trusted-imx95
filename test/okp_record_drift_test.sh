#!/usr/bin/env bash
# The station record checker, its format page and the survey cannot drift apart (proposed format,
# pending owner approval). Reads text only: no device, no network, no fuse, no life-cycle step.
#
# Slice 1: every row of survey section 3 maps to JSON fields, and the map, the FIELDS table of
# test/okp/record-check.py (read as text) and the Fields table of record-format.md agree.
#
# Overrides: OKP_DOCS_DIR (survey and format page), OKP_SCRIPTS_DIR (record-check.py).
# Rerun the scratch fixtures: bash test/okp_record_drift_test.sh (they are built in a temp dir
# each run and never written to the tree).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docs=${OKP_DOCS_DIR:-$here/docs/oem-key-provisioning}
scripts=${OKP_SCRIPTS_DIR:-$here/test/okp}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# shellcheck disable=SC2016  # the Python program is meant to be unexpanded
PY='
import os, re, sys

docs, scripts, mode = sys.argv[1], sys.argv[2], sys.argv[3]
SURVEY = os.path.join(docs, "provisioning-records-survey.md")
FORMAT = os.path.join(docs, "record-format.md")
CHECKER = os.path.join(scripts, "record-check.py")
errs = []


def err(path, line, token, msg):
    errs.append("%s:%s: %s: %s" % (path, line, token, msg))


def lines(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().split("\n")


def table(path, heading_re):
    """Data rows (line number, cells) of the first table under the matching "## " heading."""
    rows, inside = [], False
    for n, text in enumerate(lines(path), 1):
        if text.startswith("## "):
            if inside:
                break
            inside = re.match(heading_re, text) is not None
            continue
        if inside and text.startswith("|"):
            cells = [c.strip() for c in text.strip().strip("|").split("|")]
            if all(re.fullmatch(r"-+", c) for c in cells) or cells[0] in ("Field", "JSON name", "Never in the record"):
                continue
            rows.append((n, cells))
    return rows


# Survey section 3 row (first cell up to its first colon) -> the JSON fields that carry it.
ROW_FIELDS = {
    "Device identifier": ["device_uid"],
    "Board identifier": ["board_serial"],
    # one row, four fields: the revision decides the hash width, the algorithm names the hash,
    # the PQC hash is the B0-only second hash the row lists
    "SRK hash written to the fuses": ["soc_revision", "srk_hash_algorithm", "srk_hash", "pqc_srk_hash"],
    "SRK fuse lock state": ["srk_lock_states"],
    # one row, two fields: the state read back before and after
    "Life-cycle state before and after": ["life_cycle_before", "life_cycle_after"],
    "AHAB event status at provisioning": ["ahab_events"],
    "Enclave firmware version": ["enclave_fw_version"],
    # one row, two fields: the library version (optional, section 7) and the station software
    "Enclave library and station software versions": ["enclave_lib_version", "spsdk_version"],
    "Public keys and their certificates": ["public_keys"],
    "Key identifiers and policy": ["key_policy"],
    "Monotonic counter configuration": ["monotonic_counter"],
    "Time": ["step_times"],
    # one row, two fields: the station and the operator role
    "Station and operator": ["station_id", "operator_role"],
    "Outcome": ["outcome"],
}
# FIELDS names that come from survey section 4 and carry no section 3 row.
OTHER_FIELDS = {
    "payload_hashes": "section 4 wrapped blobs: the record holds a hash of each blob, never the blob (Q3 a)",
    "secure_object_ids": "section 4 EdgeLock 2GO objects: identifiers only, never contents",
}

# (a) survey section 3
survey = {}
for n, cells in table(SURVEY, r"## 3\."):
    survey[cells[0].split(":")[0].strip()] = n
if not survey:
    err(SURVEY, 1, "section 3", "no data rows found")
for row, n in survey.items():
    if row not in ROW_FIELDS:
        err(SURVEY, n, row, "survey section 3 row has no entry in the drift test row map")
for row in ROW_FIELDS:
    if survey and row not in survey:
        err(SURVEY, 1, row, "row map entry names no survey section 3 row")

# (b) FIELDS of the checker, read as text
checker = {}
inside = False
for n, text in enumerate(lines(CHECKER), 1):
    if text.startswith("FIELDS = ("):
        inside = True
        continue
    if inside and text.startswith(")"):
        break
    m = re.match(r"\s*\(\"([a-z0-9_]+)\",", text)
    if inside and m:
        checker[m.group(1)] = n
if not checker:
    err(CHECKER, 1, "FIELDS", "no field rows found")

# (c) Fields table of the format page
page = {}
for n, cells in table(FORMAT, r"## Fields"):
    for name in re.findall(r"`([a-z0-9_]+)`", cells[0]):
        page[name] = n
if not page:
    err(FORMAT, 1, "Fields", "no field rows found")

mapped = {f: row for row, fs in ROW_FIELDS.items() for f in fs}
for field, row in mapped.items():
    if checker and field not in checker:
        err(CHECKER, 1, field, "carries survey row \"%s\" but is not in FIELDS" % row)
    if page and field not in page:
        err(FORMAT, 1, field, "carries survey row \"%s\" but is not in the format page Fields table" % row)
for field, n in checker.items():
    if field not in mapped and field not in OTHER_FIELDS:
        err(CHECKER, n, field, "FIELDS name is in no survey row map entry and not in the other-fields table")
    if page and field not in page:
        err(FORMAT, 1, field, "FIELDS name is not in the format page Fields table")
for field, n in page.items():
    if checker and field not in checker:
        err(FORMAT, n, field, "format page field is not in FIELDS")
for field in OTHER_FIELDS:
    if checker and field not in checker:
        err(CHECKER, 1, field, "other-fields table entry is not in FIELDS")

# Slice 2: every survey section 4 "never in the record" row (first cell) -> the name of one
# record field that holds that kind of content and a value for it. Values are built from
# fragments here, so no key-shaped literal sits in this file.
pre = "-----BEGIN "
tail = "-----"
short = "fake-value-%d" % os.getpid()
ROW4 = {
    "Private keys, symmetric keys, OEM master keys": ("private_key", pre + "RSA PRIV" + "ATE KEY" + tail + " body"),
    "Key-exchange secrets and session keys": ("kex_shared_secret", short),
    "Wrapped key blobs, where custody would weaken": ("wrapped_key_blob", short),
    "EdgeLock 2GO secure objects": ("secure_object_contents", short),
    "Credentials of the station itself": ("station_credential", short),
    "Unredacted personal data of operators": ("operator_email", short),
}
# Rows the checker cannot refuse: row -> reason, "proposed, pending owner approval". Empty: every
# row has a refused record today.
ROW4_IGNORE = {}

if mode == "refuse":
    import json, subprocess, tempfile
    rows4 = {}
    for n, cells in table(SURVEY, r"## 4\."):
        rows4[cells[0]] = n
    if not rows4:
        err(SURVEY, 1, "section 4", "no data rows found")
    for row, n in rows4.items():
        if row not in ROW4 and row not in ROW4_IGNORE:
            err(SURVEY, n, row, "survey section 4 row has no record in the drift test table")
    for row in list(ROW4) + list(ROW4_IGNORE):
        if rows4 and row not in rows4:
            err(SURVEY, 1, row, "table entry names no survey section 4 row")
    with open(sys.argv[4], encoding="utf-8") as fh:
        valid = json.load(fh)
    with tempfile.TemporaryDirectory() as tmp:
        for row, n in rows4.items():
            if row not in ROW4:
                continue
            field, value = ROW4[row]
            rec = dict(valid)
            rec[field] = value
            path = os.path.join(tmp, "rec.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(rec, fh)
            run = subprocess.run([sys.executable, "-I", CHECKER, path], capture_output=True, text=True)
            text = run.stdout + run.stderr
            if run.returncode != 1:
                err(SURVEY, n, row, "a record with field %s exits %d, want 1" % (field, run.returncode))
            elif "$." + field not in text:
                err(SURVEY, n, row, "the checker refuses the record but does not name $.%s" % field)
            elif value in text:
                err(SURVEY, n, row, "the checker prints the value of $.%s" % field)

for e in errs:
    print(e)
sys.exit(1 if errs else 0)
'
fixture="$here/test/fixtures/okp-record/valid.json"

# drift DOCS SCRIPTS [MODE]: run the check, output in $out, status in $rc
drift() { out=$(python3 -I -c "$PY" "$1" "$2" "${3:-drift}" "$fixture" 2>&1); rc=$?; }

# expect_fail NAME WANT...: the last drift run failed and its output names every WANT
expect_fail() {
  local name=$1 w
  shift
  if [ "$rc" != 1 ]; then bad "$name: rc=$rc want 1: $out"; return; fi
  for w in "$@"; do
    if [[ $out != *"$w"* ]]; then bad "$name: output lacks '$w': $out"; return; fi
  done
  ok "$name"
}

drift "$docs" "$scripts"
if [ "$rc" = 0 ]; then ok "survey section 3, FIELDS and the format page match one to one"
else bad "the tree has drifted:"; echo "$out"; fi

# scratch copies, in a temp dir, never in the tree
mk() { # mk NAME: scratch docs and scripts dirs
  mkdir -p "$work/$1/docs" "$work/$1/scripts"
  cp "$docs/provisioning-records-survey.md" "$docs/record-format.md" "$work/$1/docs/"
  cp "$scripts/record-check.py" "$work/$1/scripts/"
}
# edit NAME FILE 'python statements on s': change one scratch file in place
edit() {
  python3 -I -c '
import sys
s = open(sys.argv[1]).read()
orig = s
exec(sys.argv[2])
assert s != orig, "scratch edit changed nothing"
open(sys.argv[1], "w").write(s)
' "$work/$1/$2" "$3"
}

mk newrow
edit newrow docs/provisioning-records-survey.md 's = s.replace("| Outcome |", "| Fresh scratch row | why | src |\n| Outcome |", 1)'
drift "$work/newrow/docs" "$work/newrow/scripts"
expect_fail "a new survey section 3 row fails and is named" "Fresh scratch row" "provisioning-records-survey.md"

mk renamed
edit renamed scripts/record-check.py 's = s.replace("(\"srk_hash_algorithm\",", "(\"srk_hash_alg\",", 1)'
drift "$work/renamed/docs" "$work/renamed/scripts"
expect_fail "a renamed FIELDS name fails and is named" "srk_hash_algorithm" "srk_hash_alg" "record-check.py"

mk nopage
# shellcheck disable=SC2016  # backticks in the Python text are literal
edit nopage docs/record-format.md 's = s.replace("| `outcome` |", "| `outcome_gone` |", 1).replace("| `outcome_gone` | string | yes | §3 outcome |\n", "", 1)'
drift "$work/nopage/docs" "$work/nopage/scripts"
expect_fail "a deleted format page field row fails and is named" "outcome" "record-format.md"

# slice 2
drift "$docs" "$scripts" refuse
if [ "$rc" = 0 ]; then ok "every survey section 4 row has a record the checker refuses, naming the field"
else bad "a section 4 row is not refused:"; echo "$out"; fi

mk nodeny
edit nodeny scripts/record-check.py 'import re
s = re.sub(r"# --- deny list: begin.*?# --- deny list: end", "DENY_KEY_TERMS = ()", s, flags=re.S)'
drift "$work/nodeny/docs" "$work/nodeny/scripts" refuse
expect_fail "an emptied deny list fails the credential and key-exchange rows" \
  "Credentials of the station itself" "Key-exchange secrets and session keys"

mk newrow4
edit newrow4 docs/provisioning-records-survey.md 's = s.replace("| Credentials of the station itself |", "| Fresh scratch never-row | why | src |\n| Credentials of the station itself |", 1)'
drift "$work/newrow4/docs" "$work/newrow4/scripts" refuse
expect_fail "a new section 4 row without a table entry fails and is named" "Fresh scratch never-row"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
