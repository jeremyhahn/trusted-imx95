#!/usr/bin/env bash
# The record checker's --pre-close mode (proposed, pending owner approval) is tied to the survey
# section 6 checklist. Reads text and JSON only: no device, no network, no fuse, no life-cycle step.
#
# Overrides: OKP_DOCS_DIR (key-ceremony-survey.md), OKP_SCRIPTS_DIR (record-check.py).
# Rerun: bash test/okp_pre_close_test.sh (scratch copies are built in a temp dir each run).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docs=${OKP_DOCS_DIR:-$here/docs/oem-key-provisioning}
scripts=${OKP_SCRIPTS_DIR:-$here/scripts/okp}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# shellcheck disable=SC2016  # the Python program is meant to be unexpanded
PY='
import re, sys

survey = sys.argv[1]
# Section 6 item (first words of the item) -> the record field it checks, or "not a record field: why".
ITEMS = {
    "Life cycle is OEM open": "life_cycle_before",
    "The SRK hash is fused and correct": "srk_hash",
    "A fully signed image boots with no enclave events": "ahab_events",
    "The image\x27s SRK table is the fused one": "not a record field: the image configuration names the SRK set; the record holds the hash and the lock states",
    "Imported keys work after the step": "public_keys",
    "One-time fuse decisions are made": "not a record field: section 6 itself marks whether these fuses can be written later not confirmed",
    "Versions are recorded": "enclave_fw_version",
    "The step itself": "not a record field: named for the record only; nothing here runs it",
}
errs, seen, inside = [], set(), False
for n, text in enumerate(open(survey, encoding="utf-8").read().split("\n"), 1):
    if text.startswith("## "):
        inside = text.startswith("## 6.")
        continue
    m = re.match(r"(\d+)\. \*\*(.+?)\.?\*\*", text)
    if inside and m:
        title = m.group(2).rstrip(".")
        seen.add(title)
        if title not in ITEMS:
            errs.append("%s:%d: %s: survey section 6 item has no entry in the pre-close table" % (survey, n, title))
if not seen:
    errs.append("%s:1: section 6: no numbered items found" % survey)
for title in ITEMS:
    if seen and title not in seen:
        errs.append("%s:1: %s: table entry names no survey section 6 item" % (survey, title))
for e in errs:
    print(e)
# the fields the table names are the ones the mode requires (printed for the shell to check)
if not errs:
    print("fields " + " ".join(sorted(v for v in ITEMS.values() if not v.startswith("not a record field"))))
sys.exit(1 if errs else 0)
'
items() { out=$(python3 -I -c "$PY" "$1" 2>&1); rc=$?; }

items "$docs/key-ceremony-survey.md"
if [ "$rc" = 0 ]; then ok "every survey section 6 item has a table entry"
else bad "section 6 table:"; echo "$out"; fi

# mkrec NAME 'python on rec': a record in the temp dir, built from the valid fixture
mkrec() {
  python3 -I -c '
import json, sys
rec = json.load(open(sys.argv[1]))
rec["life_cycle_before"] = "OEM  Open"
exec(sys.argv[3])
json.dump(rec, open(sys.argv[2], "w"))
' "$here/test/fixtures/okp-record/valid.json" "$work/$1.json" "$2"
}
chk() { # chk SCRIPTS_DIR ARGS...
  local d=$1
  shift
  out=$(python3 -I "$d/record-check.py" "$@" 2>&1)
  rc=$?
}
expect() { # expect NAME RC WANT...
  local name=$1 want=$2 w
  shift 2
  if [ "$rc" != "$want" ]; then bad "$name: rc=$rc want $want: $out"; return; fi
  for w in "$@"; do
    if [[ $out != *"$w"* ]]; then bad "$name: output lacks '$w': $out"; return; fi
  done
  ok "$name"
}

mkrec good 'del rec["life_cycle_after"], rec["outcome"], rec["step_times"]'
chk "$scripts" --pre-close "$work/good.json"
expect "a pre-close record without life_cycle_after passes" 0
chk "$scripts" "$work/good.json"
expect "the same record fails in default mode and names life_cycle_after" 1 "life_cycle_after"

mkrec full 'pass'
chk "$scripts" --pre-close "$work/full.json"
expect "a finished record also passes --pre-close" 0
chk "$scripts" "$here/test/fixtures/okp-record/valid.json"
expect "the valid fixture passes in default mode" 0

mkrec closed 'rec["life_cycle_before"] = "OEM " + "cl" + "osed"'
chk "$scripts" --pre-close "$work/closed.json"
expect "a record that is not in the open state is refused" 1 "life_cycle_before" "closed.json"
mkrec events 'rec["ahab_events"] = ["fake-event"]'
chk "$scripts" --pre-close "$work/events.json"
expect "a non-empty ahab_events is refused" 1 "ahab_events"
for f in srk_hash enclave_fw_version srk_lock_states spsdk_version public_keys soc_revision; do
  mkrec "no_$f" "del rec[\"$f\"]"
  chk "$scripts" --pre-close "$work/no_$f.json"
  expect "a record missing $f is refused" 1 "$f"
done
chk "$scripts" --pre-close "$work/good.json" extra
expect "an extra argument is a usage error" 2

# the table names the fields the mode requires: each is refused when missing (checked above)
items "$docs/key-ceremony-survey.md"
for f in $(echo "$out" | tail -n 1 | cut -d' ' -f2-); do
  [ -e "$work/no_$f.json" ] || [ "$f" = life_cycle_before ] || [ "$f" = ahab_events ] || bad "table field $f has no missing-field case"
done

# scratch copies, never in the tree
mkdir -p "$work/s/docs" "$work/s/scripts"
cp "$docs/key-ceremony-survey.md" "$work/s/docs/"
cp "$scripts/record-check.py" "$work/s/scripts/"
python3 -I -c '
import sys
p = sys.argv[1]
s = open(p).read()
t = s.replace("8. **The step itself.**", "8. **A fresh scratch item.** Text.\n9. **The step itself.**", 1)
assert t != s
open(p, "w").write(t)
' "$work/s/docs/key-ceremony-survey.md"
items "$work/s/docs/key-ceremony-survey.md"
if [ "$rc" = 1 ] && [[ $out == *"A fresh scratch item"* && $out == *"key-ceremony-survey.md:"* ]]; then
  ok "a new section 6 item without a table entry fails and is named"
else bad "new item: rc=$rc $out"; fi

python3 -I -c '
import sys
p = sys.argv[1]
s = open(p).read()
t = s.replace("!= PRE_CLOSE_STATE", "!= \"\" and False", 1)
assert t != s
open(p, "w").write(t)
' "$work/s/scripts/record-check.py"
chk "$work/s/scripts" --pre-close "$work/closed.json"
if [ "$rc" = 0 ]; then ok "without the OEM-open comparison the closed record passes (so the case bites)"
else bad "scratch checker still refuses the closed record: rc=$rc $out"; fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
