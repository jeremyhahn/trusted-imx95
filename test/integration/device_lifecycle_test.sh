#!/usr/bin/env bash
# The device-lifecycle row end to end (make integration-test-device-lifecycle,
# make integration-test): the board's side of go-trusted-platform's
# hsm-device-lifecycle under owner rulings 927 and 1234. The Cortex-A55's
# collector (scripts/device-lifecycle/collect-evidence.sh) runs against doubles
# of the enclave's HSM API attestation call and of tpm2_readpublic, and a
# stand-in control plane (a test double here, not an interface of this
# repository) takes the device through endorse-01, enroll-01 and
# device-attest-01 in the `tpm` format, in that order and only in that order.
# The double checks structure only (python3 stdlib; no signature check, which
# test/device_lifecycle_bundle_test.sh covers with real keys): the root, the
# EK binding and the wire format stay open items for go-xkms and
# go-trusted-platform. No board, no TPM, no network; writes only under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

COLLECT="$ROOT/scripts/device-lifecycle/collect-evidence.sh"
W="$TMP_ROOT/w"
BIN="$W/bin"
LOG="$W/device.log"
CP="$W/control-plane.py"
mkdir -p "$BIN"

# --- The stand-in control plane -------------------------------------------
# State in $W/cp.json. Verbs: nonce, endorse BUNDLE, enroll, device-attest FMT.
# Every verb refuses (exit 1, "refused: ...") out of order.
cat >"$CP" <<'EOF'
import base64, json, os, re, sys

state_path = os.environ["CP_STATE"]
st = json.load(open(state_path)) if os.path.exists(state_path) else {"steps": []}

def save():
    json.dump(st, open(state_path, "w"))

def refuse(msg):
    print(f"refused: {msg}")
    sys.exit(1)

def b64(s):
    if not isinstance(s, str) or not re.fullmatch(r"[A-Za-z0-9_-]*", s):
        refuse("not unpadded base64url")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

verb = sys.argv[1]
if verb == "nonce":
    st = {"steps": [], "nonce": os.urandom(16).hex()}
    save()
    print(st["nonce"])
elif verb == "endorse":
    if "nonce" not in st:
        refuse("endorse-01 without a challenge")
    try:
        b = json.load(open(sys.argv[2]))
    except (OSError, ValueError):
        refuse("endorse-01 without an enclave attestation")
    if set(b) != {"format", "version", "ele_attestation", "ftpm_ek", "binding"}:
        refuse("endorse-01: unexpected keys")
    if b["format"] != "trusted-imx95/endorse-evidence" or b["version"] != 1:
        refuse("endorse-01: unknown format")
    ele = b["ele_attestation"]
    if set(ele) != {"response_version", "signed", "signature", "verifier_nonce"}:
        refuse("endorse-01: no enclave attestation")
    if ele["response_version"] not in (2, 3):
        refuse("endorse-01: enclave response version")
    n = b64(ele["verifier_nonce"])
    if n.hex() != st["nonce"]:
        refuse("endorse-01: the enclave attestation is not for this challenge")
    if b64(ele["signed"]).count(n) != 1:
        refuse("endorse-01: the nonce is not in the signed region once")
    if len(b64(ele["signature"])) != 96:
        refuse("endorse-01: signature length")
    ek = b64(b["ftpm_ek"]["public"])
    if len(ek) < 4 or int.from_bytes(ek[:2], "big") != len(ek) - 2 or ek[2:4] not in (b"\x00\x01", b"\x00\x23"):
        refuse("endorse-01: not a TPM2B_PUBLIC EK")
    st["steps"].append("endorse-01")
    st["ek"] = ek.hex()
    save()
    print("endorse-01: EK certified")
elif verb == "enroll":
    if st["steps"] != ["endorse-01"]:
        refuse("enroll-01 before endorse-01")
    st["steps"].append("enroll-01")
    save()
    print("enroll-01: enrolled")
elif verb == "device-attest":
    if sys.argv[2] != "tpm":
        refuse(f"device-attest-01 format {sys.argv[2]}: only tpm (ruling 927)")
    if st["steps"] != ["endorse-01", "enroll-01"]:
        refuse("device-attest-01 before enroll-01")
    st["steps"].append("device-attest-01")
    save()
    print("device-attest-01: tpm attested")
else:
    refuse(f"unknown verb {verb}")
EOF
cp_() { CP_STATE="$W/cp.json" python3 -I "$CP" "$@"; }

# --- Device doubles --------------------------------------------------------
# The enclave double stands in for the A55's HSM API attestation call (RM00284
# section 3.12): it puts the verifier's nonce in a synthetic signed region.
cat >"$BIN/ele-attest" <<EOF
#!/usr/bin/env bash
echo "ele-attest \$*" >>"$LOG"
[ -z "\${FAIL_ELE:-}" ] || exit 1
python3 -I -c 'import os,sys; n=bytes.fromhex(sys.argv[1]); open(sys.argv[2],"wb").write(os.urandom(24)+n+os.urandom(24)); open(sys.argv[3],"wb").write(os.urandom(96))' "\${NONCE_OVERRIDE:-\$1}" "\$2" "\$3"
EOF
cat >"$BIN/tpm2_readpublic" <<EOF
#!/usr/bin/env bash
echo "tpm2_readpublic \$*" >>"$LOG"
out=
while [ \$# -gt 0 ]; do
	[ "\$1" != -o ] || out=\$2
	shift
done
python3 -I -c 'import os,sys; body=b"\x00\x23"+os.urandom(60); open(sys.argv[1],"wb").write(len(body).to_bytes(2,"big")+body)' "\$out"
EOF
for n in tpm2_createek tpm2_clear tpm2_evictcontrol tpm2_nvwrite tpm2_nvdefine tpm2_nvundefine tpm2_changeauth; do
	printf '#!/usr/bin/env bash\necho "FORBIDDEN %s $*" >>"%s"\nexit 1\n' "$n" "$LOG" >"$BIN/$n"
done
chmod +x "$BIN"/*

collect() { # collect <nonce> <out> [env...]
	local nonce=$1 out=$2
	shift 2
	cat "$LOG" >>"$W/all.log" 2>/dev/null || true
	: >"$LOG"
	run env PATH="$BIN:$PATH" ELE_ATTEST_CMD="$BIN/ele-attest" "$@" "$COLLECT" --nonce "$nonce" \
		--response-version 3 --ek-handle 0x81010001 --ek-template test-template -o "$out"
}

# --- 1. The whole lifecycle in the order ruling 1234 sets ------------------
nonce=$(cp_ nonce)
collect "$nonce" "$W/bundle.json"
check "device: the A55 collects the enclave attestation and the EK" 0 "collect-evidence: wrote"
mapfile -t calls <"$LOG"
if [ "${#calls[@]}" -eq 2 ] && [[ "${calls[0]}" == "ele-attest $nonce "* ]] &&
	[[ "${calls[1]}" == "tpm2_readpublic -c 0x81010001 "* ]]; then
	pass "device: the enclave attestation, with the verifier's nonce, comes before the EK read"
else
	fail "device: call order" "${calls[*]}"
fi
run cp_ enroll
check "control plane: enroll-01 before endorse-01 is refused" nonzero "refused: enroll-01 before endorse-01"
run cp_ device-attest tpm
check "control plane: device-attest-01 before enroll-01 is refused" nonzero "refused: device-attest-01 before enroll-01"
run cp_ endorse "$W/bundle.json"
check "endorse-01 certifies the fTPM's EK after the enclave attestation" 0 "endorse-01: EK certified"
run cp_ device-attest tpm
check "control plane: device-attest-01 before enroll-01 is still refused" nonzero "before enroll-01"
run cp_ enroll
check "enroll-01 follows endorse-01" 0 "enroll-01: enrolled"
run cp_ device-attest packed
check "device-attest-01 in a format other than tpm is refused (ruling 927)" nonzero "only tpm"
run cp_ device-attest tpm
check "device-attest-01 in the tpm format completes the lifecycle" 0 "device-attest-01: tpm attested"
run python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["steps"])' "$W/cp.json"
check "the control plane saw endorse-01, enroll-01, device-attest-01, in order" 0 \
	"['endorse-01', 'enroll-01', 'device-attest-01']"

# --- 2. No enclave attestation, no endorse-01 -----------------------------
nonce=$(cp_ nonce)
rm -f "$W/b2.json"
collect "$nonce" "$W/b2.json" FAIL_ELE=1
check "device: a failed enclave attestation fails the collector" nonzero
if [[ "$(<"$LOG")" != *tpm2_readpublic* ]] && [ ! -e "$W/b2.json" ]; then
	pass "device: no enclave attestation, no EK read and no bundle"
else
	fail "device: the EK was read or a bundle written without an enclave attestation" "$(<"$LOG")"
fi
run cp_ endorse "$W/b2.json"
check "endorse-01 without an enclave attestation is refused" nonzero "refused: endorse-01 without an enclave attestation"
run cp_ enroll
check "enroll-01 stays refused" nonzero "before endorse-01"

# --- 3. A replayed attestation (another challenge's nonce) ----------------
nonce=$(cp_ nonce)
collect "$nonce" "$W/b3.json" NONCE_OVERRIDE=ffeeddccbbaa99887766554433221100
check "device: the collector composes, it does not verify" 0 "collect-evidence: wrote"
run cp_ endorse "$W/b3.json"
check "endorse-01 refuses an enclave attestation that is not for its challenge" nonzero "not in the signed region once"
cp_ nonce >/dev/null # a fresh challenge; the first bundle answers an earlier one
run cp_ endorse "$W/bundle.json"
check "endorse-01 refuses a bundle from an earlier challenge" nonzero "not for this challenge"

# --- 4. The device never writes the TPM -----------------------------------
cat "$LOG" >>"$W/all.log"
if [[ "$(<"$W/all.log")" != *FORBIDDEN* ]]; then
	pass "device: no EK creation, clear, evict or NV write"
else
	fail "device: a TPM-writing command ran" "$(<"$W/all.log")"
fi

# --- 5. The row as written -------------------------------------------------
row=$(python3 -I - "$ROOT/docs/SPEC.md" <<'EOF'
import sys
for line in open(sys.argv[1]):
    if line.startswith("| device-lifecycle |"):
        print(line.strip())
EOF
)
for want in "go-trusted-platform's \`hsm-device-lifecycle\`" "which builds no firmware for it" \
	"RM00284 §3.12" "Owner ruling 927" "Owner ruling 1234" "endorse-01 certify the fTPM's EK" \
	"followed by enroll-01 and device-attest-01 in the \`tpm\` format" \
	"(device-lifecycle/architecture.md)"; do
	if [[ "$row" == *"$want"* ]]; then pass "SPEC row: $want"; else fail "SPEC row lacks: $want" "$row"; fi
done
arch="$ROOT/docs/device-lifecycle/architecture.md"
run python3 -I - "$arch" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
order = text.split("## Device-side order", 1)[1].split("\n## ", 1)[0]
steps = re.findall(r"^\d\. (.*)$", order, re.M)
assert len(steps) == 4, steps
assert "enclave" in steps[0] and "HSM API" in steps[0] and "RM00284" in steps[0], steps[0]
assert "EK" in steps[1] and "/dev/tpmrm0" in steps[1], steps[1]
assert "endorse-01 checks the attestation, then certifies the EK" in steps[2], steps[2]
assert "enroll-01, then device-attest-01 in the `tpm` format" in steps[3], steps[3]
items = text.split("## Open items for go-xkms", 1)[1]
for label in ("(A2)", "(B1, B3)", "(C2, F2)"):
    assert label in items, label
print("architecture: order and open items")
EOF
check "feature folder: the device-side order and the three open items (root, EK binding, wire format)" 0 \
	"architecture: order and open items"
# The control plane builds no firmware: no lock file of this repository's
# firmware and image builds takes a go-trusted-platform source.
locks=("$ROOT/secure-world/bsp.lock" "$ROOT/platform-image/manifest.lock" "$ROOT/system-manager/sm.lock")
bad=
for l in "${locks[@]}"; do
	[ -f "$l" ] || { bad="$bad missing:$l"; continue; }
	[[ "$(<"$l")" != *go-trusted-platform* ]] || bad="$bad $l"
done
if [ -z "$bad" ]; then pass "the firmware and the image are built here, from no go-trusted-platform source"; else fail "firmware source from the control plane" "$bad"; fi

finish
