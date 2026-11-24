#!/usr/bin/env bash
# device_lifecycle_collect_test.sh: scripts/device-lifecycle/collect-evidence.sh
# against doubles for the enclave command and tpm2_readpublic. No board, no
# TPM, no enclave device. Keys are generated at test time.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=test/lib.sh
source "$here/lib.sh"

before=$(cd "$ROOT" && git status --porcelain --ignored)
PY="$("$ROOT/scripts/ahab/spsdk-venv.sh")/bin/python"
TOOL="$ROOT/test/device_lifecycle/bundle_fixture.py"
COLLECT="$ROOT/scripts/device-lifecycle/collect-evidence.sh"
W="$TMP_ROOT/w"
BIN="$W/bin"
LOG="$W/calls.log"
mkdir -p "$BIN"
NONCE=00112233445566778899aabbccddeeff

# Fixtures: a synthetic signed region holding the nonce once, its signature,
# and a synthetic TPM2B_PUBLIC.
"$PY" -I - "$W" "$NONCE" <<'EOF'
import os, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

w, nonce = sys.argv[1], bytes.fromhex(sys.argv[2])
key = ec.generate_private_key(ec.SECP384R1())
signed = os.urandom(40) + nonce + os.urandom(40)
r, s = utils.decode_dss_signature(key.sign(signed, ec.ECDSA(hashes.SHA384())))
body = b"\x00\x23" + os.urandom(60)
for name, data in (
    ("fx_signed.bin", signed),
    ("fx_sig.bin", r.to_bytes(48, "big") + s.to_bytes(48, "big")),
    ("fx_ek.bin", len(body).to_bytes(2, "big") + body),
    (
        "ele.pem",
        key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        ),
    ),
):
    with open(f"{w}/{name}", "wb") as f:
        f.write(data)
EOF

# Doubles. Each logs its argv; the enclave double honours FAIL_ELE, the TPM
# double FAIL_TPM.
cat >"$BIN/ele-attest" <<EOF
#!/usr/bin/env bash
echo "ele-attest \$*" >>"$LOG"
[ -z "\${FAIL_ELE:-}" ] || exit 1
cp "$W/fx_signed.bin" "\$2"
cp "\${SIG_FX:-$W/fx_sig.bin}" "\$3"
EOF
cat >"$BIN/tpm2_readpublic" <<EOF
#!/usr/bin/env bash
echo "tpm2_readpublic \$*" >>"$LOG"
[ -z "\${FAIL_TPM:-}" ] || exit 1
out=
while [ \$# -gt 0 ]; do
	[ "\$1" != -o ] || out=\$2
	shift
done
cp "\${EK_FX:-$W/fx_ek.bin}" "\$out"
EOF
for n in tpm2_createek tpm2_clear tpm2_evictcontrol tpm2_nvwrite tpm2_nvdefine; do
	printf '#!/usr/bin/env bash\necho "FORBIDDEN %s $*" >>"%s"\nexit 1\n' "$n" "$LOG" >"$BIN/$n"
done
chmod +x "$BIN"/*

col() { # env and args pass through; the doubles come first on PATH
	cat "$LOG" >>"$W/all.log" 2>/dev/null || true
	: >"$LOG"
	PATH="$BIN:$PATH" EVIDENCE_PYTHON="$PY" "$@"
}
HANDLE=0x81010001
args=(--nonce "$NONCE" --response-version 3 --ek-handle "$HANDLE" --ek-template test-template)

rm -f "$W/out.json"
run col env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
check "good run" 0 "wrote"
run "$PY" -I "$TOOL" check "$W/out.json" --ele-pub "$W/ele.pem" --nonce "$NONCE" --ek-public "$W/fx_ek.bin"
check "the bundle passes the test fixture check" 0 "valid"
mapfile -t calls <"$LOG"
if [ "${#calls[@]}" -eq 2 ] && [[ "${calls[0]}" == "ele-attest $NONCE "* ]] &&
	[[ "${calls[1]}" == "tpm2_readpublic -c $HANDLE "* ]]; then
	pass "the enclave command runs before tpm2_readpublic"
else
	fail "call order" "${calls[*]}"
fi

if [[ "$(<"$COLLECT")" != *bundle_fixture* && "$(<"$COLLECT")" != *evidence-bundle* ]]; then
	pass "the collector does not call the checker"
else
	fail "the collector calls the checker"
fi
rm -f "$W/out.json"
run col env FAIL_ELE=1 ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
check "enclave failure" nonzero
expect "enclave failure: no OUT" test ! -e "$W/out.json"
if [[ "$(<"$LOG")" != *tpm2_readpublic* ]]; then
	pass "enclave failure: tpm2_readpublic never called"
else
	fail "enclave failure: tpm2_readpublic was called"
fi

rm -f "$W/out.json"
run col env FAIL_TPM=1 ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
check "readpublic failure" nonzero
expect "readpublic failure: no OUT" test ! -e "$W/out.json"

# A failed output copy fails the collector: OUT's parent is missing.
rm -rf "$W/nodir"
run col env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/nodir/out.json"
check "missing OUT parent" nonzero
if [[ "$OUT" != *"collect-evidence: wrote"* ]]; then
	pass "missing OUT parent: no success line"
else
	fail "missing OUT parent: success line printed" "$OUT"
fi
expect "missing OUT parent: nothing written" test ! -e "$W/nodir"

# The publication temp file is exclusive: planted symlinks are never written through.
printf 'victim\n' >"$W/victim"
cp "$W/victim" "$W/victim.ref"
mkdir -p "$W/pub"
ln -s "$W/victim" "$W/pub/.out.json.XXXXXX"
# The wrapper plants a link at the exact path the old publish wrote (OUT.tmp.<PID>), then
# execs the collector: exec keeps the PID, so $$ here is the collector's own PID.
# shellcheck disable=SC2016 # the inner shell expands $1, $2 and $$
run col bash -c 'ln -s "$1" "$2.tmp.$$"; shift 2; exec "$@"' _ "$W/victim" "$W/pub/out.json" \
	env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/pub/out.json"
check "planted symlinks" 0 "wrote"
expect "planted symlinks: victim unchanged" cmp -s "$W/victim" "$W/victim.ref"
expect "planted symlinks: OUT is a regular file" test -f "$W/pub/out.json" -a ! -L "$W/pub/out.json"
rm -rf "$W/pub"
# a failed run leaves no temp file in OUT's parent
mkdir -p "$W/pub"
run col env ELE_ATTEST_CMD="$BIN/ele-attest" EVIDENCE_PYTHON=/bin/false "$COLLECT" "${args[@]}" -o "$W/pub/out.json"
check "failed run" nonzero
expect "failed run: parent empty" test -z "$(ls -A "$W/pub")"
rm -rf "$W/pub"

# OUT must be a file path: a directory, or a link to one, is refused.
mkdir -p "$W/adir"
ln -sfn "$W/adir" "$W/alink"
for d in adir alink; do
	run col env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/$d"
	check "OUT is $d" nonzero
	if [[ "$OUT" != *"collect-evidence: wrote"* ]]; then pass "OUT is $d: no success line"; else fail "OUT is $d: success line printed" "$OUT"; fi
	expect "OUT is $d: nothing inside" test -z "$(ls -A "$W/adir")"
done
rm -rf "$W/adir" "$W/alink"

# Refusals happen before any double runs.
refuse() { # name, then env assignments and collector arguments
	local name=$1
	shift
	run col "$@"
	check "$name" nonzero
	if [ ! -s "$LOG" ]; then pass "$name: no double ran"; else fail "$name: a double ran" "$(<"$LOG")"; fi
}
refuse "missing ELE_ATTEST_CMD" env -u ELE_ATTEST_CMD "$COLLECT" "${args[@]}" -o "$W/out.json"
refuse "bad nonce (short)" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" --nonce 0011 \
	--response-version 3 --ek-handle "$HANDLE" --ek-template t -o "$W/out.json"
refuse "bad nonce (not hex)" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" \
	--nonce zz112233445566778899aabbccddeeff --response-version 3 --ek-handle "$HANDLE" \
	--ek-template t -o "$W/out.json"
refuse "non-persistent handle" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" --nonce "$NONCE" \
	--response-version 3 --ek-handle 0x80000001 --ek-template t -o "$W/out.json"
refuse "handle past the persistent range" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" \
	--nonce "$NONCE" --response-version 3 --ek-handle 0x82000000 --ek-template t -o "$W/out.json"
refuse "missing handle" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" --nonce "$NONCE" \
	--response-version 3 --ek-template t -o "$W/out.json"
for v in 1 4 0x3 0 03; do
	refuse "response version $v" env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" --nonce "$NONCE" \
		--response-version "$v" --ek-handle "$HANDLE" --ek-template t -o "$W/out.json"
done
expect "refusals left no OUT" test ! -e "$W/out.json"

# Shape checks on the collected bytes: exit 2, no OUT. Variant files feed the doubles.
head -c 95 "$W/fx_sig.bin" >"$W/sig95.bin"
{ cat "$W/fx_sig.bin"; printf '\0'; } >"$W/sig97.bin"
printf '\x00\x40%s' "$(head -c 10 /dev/zero | tr '\0' x)" >"$W/ek_badsize.bin"
printf '\x00\x01\x00' >"$W/ek_3bytes.bin"
for s in sig95 sig97; do
	rm -f "$W/out.json"
	run col env SIG_FX="$W/$s.bin" ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
	check "$s signature" 2
	expect "$s signature: no OUT" test ! -e "$W/out.json"
	if [[ "$(<"$LOG")" != *tpm2_readpublic* && "$(<"$LOG")" == ele-attest* ]]; then
		pass "$s signature: tpm2_readpublic not called"
	else
		fail "$s signature: tpm2_readpublic was called" "$(<"$LOG")"
	fi
done
for e in ek_badsize ek_3bytes; do
	rm -f "$W/out.json"
	run col env EK_FX="$W/$e.bin" ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
	check "$e" 2
	expect "$e: no OUT" test ! -e "$W/out.json"
done
rm -f "$W/out.json"
run col env ELE_ATTEST_CMD="$BIN/ele-attest" "$COLLECT" "${args[@]}" -o "$W/out.json"
check "positive case after the shape negatives" 0 "wrote"
rm -f "$W/out.json"

cat "$LOG" >>"$W/all.log"
if [[ "$(<"$W/all.log")" != *FORBIDDEN* ]]; then
	pass "no createek, clear, evictcontrol or nvwrite ever called"
else
	fail "a forbidden TPM command was called"
fi

after=$(cd "$ROOT" && git status --porcelain --ignored)
if [ "$before" = "$after" ]; then pass "the clone is unchanged"; else fail "the clone is unchanged" "$after"; fi
finish
