#!/usr/bin/env bash
# Tests scripts/okp/record-check.py on fixture records (proposed format, pending owner approval).
# Reads files only: no device, no network. Fake values are built here from fragments, so the
# repository holds no key-shaped string.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chk="$here/scripts/okp/record-check.py"
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
  out=$(python3 -I "${CHK:-$chk}" "$f" 2>&1); got=$?
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
