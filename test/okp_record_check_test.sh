#!/usr/bin/env bash
# Tests the test-only helper test/okp/record-check.py on fixture records (proposed format, pending owner approval).
# Reads files only: no device, no network. Fake values are built here from fragments, so the
# repository holds no key-shaped string.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chk="$here/test/okp/record-check.py"
valid="$here/test/fixtures/okp-record/valid.json"
doc="$here/docs/oem-key-provisioning/record-format.md"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# mut FILE-OUT 'python statements on rec' : copy valid.json, apply, write
mut() {
  python3 -I -c '
import json, sys
rec = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(rec, open(sys.argv[2], "w"))
' "$valid" "$1" "$2"
}

# expect NAME FILE RC WANT [NOWANT]: run the checker; rc, output has WANT and the file, not NOWANT
expect() {
  local name=$1 f=$2 rc=$3 want=$4 nowant=${5:-} out got
  out=$(python3 -I "${CHK:-$chk}" ${FLAG:+"$FLAG"} "$f" 2>&1); got=$?
  if [ "$got" != "$rc" ]; then bad "$name: rc=$got want $rc"; return; fi
  if [ -n "$want" ] && [[ $out != *"$want"* ]]; then bad "$name: output lacks '$want'"; return; fi
  if [ -n "$want" ] && [[ $out != *"$f"* ]]; then bad "$name: output lacks the file name"; return; fi
  if [ -n "$nowant" ] && [[ $out == *"$nowant"* ]]; then bad "$name: output prints the value"; return; fi
  ok "$name"
}

fields=(device_uid board_serial soc_revision srk_hash_algorithm srk_hash srk_lock_states
  life_cycle_before life_cycle_after ahab_events enclave_fw_version spsdk_version public_keys
  monotonic_counter step_times station_id operator_role outcome)

# usage and the valid record
h=$(python3 -I "$chk" -h)
if [[ $h == *usage* ]]; then ok "-h prints usage"; else bad "-h prints usage"; fi
expect "valid fixture passes" "$valid" 0 "ok"

# slice 1: one failing fixture per required field, and type errors
for f in "${fields[@]}"; do
  mut "$work/missing-$f.json" "del rec['$f']"
  expect "missing $f fails" "$work/missing-$f.json" 1 "\$.$f"
done
mut "$work/type-events.json" "rec['ahab_events'] = 'none'"
expect "mistyped ahab_events fails" "$work/type-events.json" 1 "\$.ahab_events"
mut "$work/type-counter.json" "rec['monotonic_counter'] = '0'"
expect "mistyped monotonic_counter fails" "$work/type-counter.json" 1 "\$.monotonic_counter"
mut "$work/item-key.json" "del rec['public_keys'][0]['key_id']"
expect "public key without key_id fails" "$work/item-key.json" 1 "\$.public_keys[0].key_id"
printf 'not json' >"$work/notjson.json"
expect "non-JSON file exits 2" "$work/notjson.json" 2 "not readable JSON"

# slice 2: secrets, blobs, credentials
pre='-----BEGIN '
pem="${pre}RSA PRIV""ATE KEY-----"
ossh="${pre}OPENSSH PRIV""ATE KEY-----"
hex64=$(python3 -I -c 'print("ab" * 40)')
b64=$(python3 -I -c 'print("QUJD" * 12)')
v_pem="fake-pem-$$"

mut "$work/pem.json" "rec['station_id'] = '$pem fakebody'"
expect "PEM header refused" "$work/pem.json" 1 "\$.station_id" "fakebody"
mut "$work/ossh.json" "rec['operator_role'] = '$ossh fakebody'"
expect "OpenSSH header refused" "$work/ossh.json" 1 "\$.operator_role" "fakebody"
for k in private_key secret session_key wrapped_key blob token password api_key secure_object_contents station_credential; do
  mut "$work/key-$k.json" "rec['$k'] = '$v_pem'"
  expect "key name $k refused" "$work/key-$k.json" 1 "\$.$k" "$v_pem"
done
mut "$work/key-nested.json" "rec['step_times']['session_key'] = '$v_pem'"
expect "nested key name refused" "$work/key-nested.json" 1 "\$.step_times.session_key" "$v_pem"
mut "$work/hex.json" "rec['outcome'] = '$hex64'"
expect "long hex refused" "$work/hex.json" 1 "\$.outcome" "$hex64"
mut "$work/b64.json" "rec['outcome'] = '$b64'"
expect "long base64 refused" "$work/b64.json" 1 "\$.outcome" "$b64"
mut "$work/hash-short.json" "rec['srk_hash'] = '00' * 31"
expect "short SRK hash refused" "$work/hash-short.json" 1 "\$.srk_hash"
mut "$work/hash-b0.json" "rec['soc_revision'] = 'B0'"
expect "256-bit hash on B0 refused" "$work/hash-b0.json" 1 "\$.srk_hash"
mut "$work/hash-b0-ok.json" "rec['soc_revision'] = 'B0'; rec['srk_hash'] = '00' * 64"
expect "512-bit hash on B0 passes" "$work/hash-b0-ok.json" 0 "ok"
# unknown silicon revisions fail in both modes; the width follows the known revision only
for flag in "" --pre-close; do
  m=${flag:-default}
  pc="rec['life_cycle_before'] = 'oem open'; "
  mut "$work/rev-c0.json" "${pc}rec['soc_revision'] = 'C0'"
  FLAG=$flag expect "revision C0 refused ($m)" "$work/rev-c0.json" 1 "\$.soc_revision" 
  mut "$work/rev-empty.json" "${pc}rec['soc_revision'] = ''"
  FLAG=$flag expect "empty revision refused ($m)" "$work/rev-empty.json" 1 "\$.soc_revision"
  mut "$work/rev-b0-256.json" "${pc}rec['soc_revision'] = 'b0'"
  FLAG=$flag expect "revision b0 with a 256-bit hash refused on width ($m)" "$work/rev-b0-256.json" 1 "\$.srk_hash"
  mut "$work/rev-b0-512.json" "${pc}rec['soc_revision'] = ' b0 '; rec['srk_hash'] = '00' * 64"
  FLAG=$flag expect "revision b0 with a 512-bit hash passes ($m)" "$work/rev-b0-512.json" 0 "ok"
done
out=$(python3 -I "$chk" "$work/rev-c0.json" 2>&1)
if [[ $out == *"\$.soc_revision"* && $out == *"A0, A1, B0"* ]]; then ok "unknown revision message names the field and the allowed set"
else bad "unknown revision message lacks the field or the allowed set: $out"; fi
# Non-disclosure: a rejected value is never echoed, in either mode.
# The planted value is built at run time from repeated characters: low entropy, no key shape.
q6=$(printf 'Q%.0s' 1 2 3 4 5 6)
planted="${q6}-planted-${q6}"
for flag in "" --pre-close; do
  m=${flag:-default}
  mut "$work/rev-planted.json" "rec['life_cycle_before'] = 'oem open'; rec['soc_revision'] = '$planted'"
  out=$(python3 -I "$chk" $flag "$work/rev-planted.json" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 && $out == *"\$.soc_revision"* && $out != *"$planted"* && $out != *"$q6"* ]]; then
    ok "rejected revision is not echoed ($m)"
  else bad "rejected revision handling disclosed the value or did not fail ($m, rc=$rc)"; fi
done
# Nested evidence fails closed: every member is checked, and no value is printed.
nested() { # name file-stem python-edit want
  mut "$work/$2.json" "$3"
  expect "$1" "$work/$2.json" 1 "$4"
}
nested "unknown lock state refused" lock-word "rec['srk_lock_states']['ELE_OEM_SRKH1_LOCK'] = 'maybe'" "\$.srk_lock_states.<lock#1>: must be a lock state"
nested "null lock state refused" lock-null "rec['srk_lock_states']['ELE_OEM_SRKH0_LOCK'] = None" "\$.srk_lock_states.<lock#0>"
nested "integer lock state refused" lock-int "rec['srk_lock_states']['ELE_OEM_SRKH0_LOCK'] = 1" "\$.srk_lock_states.<lock#0>"
nested "nested-object lock state refused" lock-obj "rec['srk_lock_states']['ELE_OEM_SRKH0_LOCK'] = {'locked': True}" "\$.srk_lock_states.<lock#0>"
nested "empty lock state object refused" lock-empty "rec['srk_lock_states'] = {}" "\$.srk_lock_states: must name at least one lock"
nested "non-timestamp step time refused" time-word "rec['step_times']['key_import'] = 'yesterday'" "\$.step_times.<step#1>: must be an RFC 3339 timestamp"
nested "null step time refused" time-null "rec['step_times']['key_exchange'] = None" "\$.step_times.<step#0>"
nested "numeric step time refused" time-num "rec['step_times']['key_exchange'] = 1767225600" "\$.step_times.<step#0>"
nested "step time without a zone refused" time-nozone "rec['step_times']['key_exchange'] = '2026-01-01T00:00:00'" "\$.step_times.<step#0>"
nested "impossible step time refused" time-month "rec['step_times']['key_exchange'] = '2026-13-01T00:00:00Z'" "\$.step_times.<step#0>"
nested "null payload hash refused" ph-null "rec['payload_hashes'] = [None]" "\$.payload_hashes[0]: must be a lowercase hex string"
nested "non-hex payload hash refused" ph-nonhex "rec['payload_hashes'] = ['zz' * 32]" "\$.payload_hashes[0]"
nested "integer payload hash refused" ph-int "rec['payload_hashes'] = [12345]" "\$.payload_hashes[0]"
nested "uppercase payload hash refused" ph-upper "rec['payload_hashes'] = ['AB' * 32]" "\$.payload_hashes[0]"
nested "short payload hash refused" ph-short "rec['payload_hashes'] = ['ab' * 8]" "\$.payload_hashes[0]"
nested "payload hash object refused" ph-obj "rec['payload_hashes'] = ['ab' * 32, {'h': 'ab'}]" "\$.payload_hashes[1]"
mut "$work/nested-ok.json" "rec['payload_hashes'] = ['ab' * 32, 'cd' * 64]; rec['step_times']['key_import'] = '2026-01-01T00:01:00.5+01:00'; rec['srk_lock_states']['ELE_OEM_SRKH1_LOCK'] = False"
expect "well-formed nested evidence passes" "$work/nested-ok.json" 0 "ok"
FLAG=--pre-close nested "null payload hash refused (pre-close)" ph-null-pc "rec['life_cycle_before'] = 'oem open'; rec['payload_hashes'] = [None]" "\$.payload_hashes[0]"
FLAG=--pre-close nested "unknown lock state refused (pre-close)" lock-word-pc "rec['life_cycle_before'] = 'oem open'; rec['srk_lock_states']['ELE_OEM_SRKH0_LOCK'] = 'maybe'" "\$.srk_lock_states.<lock#0>"
mut "$work/pk-hash.json" "rec['public_keys'][0]['public_key_hash'] = '11' * 20"
expect "wrong public key hash width refused" "$work/pk-hash.json" 1 "\$.public_keys[0].public_key_hash"
mut "$work/ids.json" "rec['secure_object_ids'] = ['fake-object-1']"
expect "object identifiers pass" "$work/ids.json" 0 "ok"

# scratch copies: the checks must bite
scratch="$work/scratch"
mkdir "$scratch"
python3 -I -c '
import re, sys
src = open(sys.argv[1]).read()
a = re.sub(r"# --- required fields: begin.*?# --- required fields: end", "FIELDS = ()\nITEM_FIELDS = {}", src, flags=re.S)
assert a != src
open(sys.argv[2], "w").write(a)
b = src.replace("    errors += secret_errors(rec)\n", "    pass\n")
assert b != src
open(sys.argv[3], "w").write(b)
' "$chk" "$scratch/no-fields.py" "$scratch/no-secrets.py"
out=$(CHK="$scratch/no-fields.py" expect "scratch" "$work/missing-device_uid.json" 1 "\$.device_uid")
if [[ $out == FAIL* ]]; then ok "scratch with an empty field table lets a missing field through"
else bad "empty field table still fails the missing-field fixture"; fi
out=$(CHK="$scratch/no-secrets.py" expect "scratch" "$work/key-token.json" 1 "\$.token")
if [[ $out == FAIL* ]]; then ok "scratch without the deny-list pass lets a secret through"
else bad "no deny-list pass still fails the secret fixture"; fi

# the doc says what it is
d=$(<"$doc")
if [[ $d == *"proposed, pending owner approval"* ]]; then ok "record-format.md says proposed, pending owner approval"
else bad "record-format.md lacks 'proposed, pending owner approval'"; fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
