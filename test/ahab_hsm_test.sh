#!/usr/bin/env bash
# make ahab-hsm-test (row boot-container, #202): the Cortex-M7 AHAB container
# signed through SPSDK's proxy signature provider by a test HSM that holds the
# private key, after AN14471's custody model (AN14471 §3.1, §3.6).
#   (a) the run signs through the HSM, holds no private key in the build
#       directory, and the container it hands back verifies;
#   (b) that container with one payload byte flipped is rejected;
#   (c) an HSM holding a key other than the used SRK fails the run;
#   (d) no HSM fails the run: there is no fallback to a key file;
#   (e) the test HSM signs only a pre-hashed SHA-384 digest, never raw data;
#   (f) the run leaves no new or changed file in the clone.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HSMSIGN="$ROOT/scripts/ahab/hsm-sign-test.sh"
SIGN="$ROOT/scripts/ahab/sign-test.sh"
out="$TMP_ROOT/out"
mkdir -p "$out"
stamp="$TMP_ROOT/stamp"
touch "$stamp"

# (a)
run env AHAB_OUT_DIR="$out" make -C "$ROOT" --no-print-directory ahab-hsm-test
check "(a) make ahab-hsm-test signs the Cortex-M7 container through the test HSM" 0 \
	"nxpimage, version 3.14.0" "holds srk0 (the build holds public keys only)" \
	"custody: no private key in the build directory (before export)" \
	"custody: no private key in the build directory (after export)" \
	"test HSM: signed a SHA-384 digest" "verify: OK (HSM-signed Cortex-M7 container)" "ahab-hsm-test: OK"
bin="$out/m7-container.bin"
if [ -s "$bin" ]; then
	run "$SIGN" verify "$bin"
	check "(a) the handed-back HSM-signed container passes nxpimage ahab verify" 0 "verify: OK"
	# (b) The payload is the image's last bytes; its hash is in the signed image array.
	cp "$bin" "$TMP_ROOT/flip.bin"
	last=$(($(stat -c %s "$bin") - 1))
	v=$(od -An -tu1 -j"$last" -N1 "$bin" | tr -d ' ')
	# shellcheck disable=SC2059 # the format is the byte itself, as an octal escape
	printf "$(printf '\\%03o' $((v ^ 0xff)))" | dd of="$TMP_ROOT/flip.bin" bs=1 seek="$last" conv=notrunc status=none
	run "$SIGN" verify "$TMP_ROOT/flip.bin"
	check "(b) the HSM-signed container with one payload byte flipped is rejected" nonzero "verify: FAILED"
else
	fail "(a) the run handed back no container in AHAB_OUT_DIR"
fi

# (c)
run "$HSMSIGN" --hsm-key 1
check "(c) an HSM holding srk1 cannot sign a container whose used SRK is srk0" nonzero \
	"holds srk1" "nxpimage ahab export failed"
if [[ "$OUT" == *"ahab-hsm-test: OK"* ]]; then fail "(c) the wrong-key run reported OK"; fi

# (d)
run "$HSMSIGN" --no-hsm
check "(d) with no HSM the export fails; nothing falls back to a key file" nonzero \
	"none started" "custody: no private key in the build directory (before export)" "nxpimage ahab export failed"

# (e) Start the test HSM directly and send it raw data, then a digest.
venv=$("$ROOT/scripts/ahab/spsdk-venv.sh")
hsm="$TMP_ROOT/hsm"
mkdir -p "$hsm"
"$venv/bin/nxpcrypto" key generate -k secp384r1 -o "$hsm/k.pem" >/dev/null 2>&1
"$venv/bin/python" -I "$ROOT/scripts/ahab/test-hsm.py" "$hsm/k.pem" "$hsm/port" "$hsm/log" 2>/dev/null &
pid=$!
for _ in $(seq 1 100); do [ -s "$hsm/port" ] && break; sleep 0.1; done
if [ -s "$hsm/port" ]; then
	port=$(tr -d '[:space:]' <"$hsm/port")
	req() {
		"$venv/bin/python" -I -c '
import json, sys, requests
r = requests.get("http://127.0.0.1:%s/api/sign" % sys.argv[1], json=json.loads(sys.argv[2]), timeout=10)
print(r.status_code, r.text)' "$port" "$1"
	}
	run req '{"data": "00112233", "prehashed": null}'
	check "(e) the test HSM refuses to sign raw data" 0 "400" "only pre-hashed sha384 digests are signed"
	run req '{"data": "0011", "prehashed": "sha384"}'
	check "(e) the test HSM refuses a digest that is not 48 bytes" 0 "400" "the digest must be 48 bytes"
	run req "{\"data\": \"$(printf '%096d' 0)\", \"prehashed\": \"sha384\"}"
	check "(e) the test HSM signs a 48-byte SHA-384 digest" 0 "200" '"data"'
else
	fail "(e) the test HSM did not listen within 10 s"
fi
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

# (f)
changed=$(find "$ROOT" -path "$ROOT/.git" -prune -o -newer "$stamp" -print)
if [ -z "$changed" ]; then pass "(f) the runs wrote nothing inside the clone"; else
	fail "(f) the runs wrote inside the clone" "$changed"; fi

finish
