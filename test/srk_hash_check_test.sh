#!/usr/bin/env bash
# srk_hash_check_test.sh: scripts/ahab/srk-hash-check.sh on a throwaway test PKI
# generated per run in a mktemp -d outside the clone and deleted on exit.
# The expected hash comes from nxpimage ahab export of a container signed with
# the test PKI, not from the script under test. No board, no fuse.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
check=$root/scripts/ahab/srk-hash-check.sh

venv=$("$root/scripts/ahab/spsdk-venv.sh")
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) echo "FAIL: work directory $work is inside the clone; set TMPDIR outside it" >&2; exit 1 ;; esac

fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# Five test SRKs; srk4 is the odd one out.
for i in 0 1 2 3 4; do
	"$venv/bin/nxpcrypto" key generate -k secp384r1 -o "$work/srk$i.pem" >/dev/null 2>&1
done
# The private keys stay in $work/srk*.pem; the checker only ever sees the .pub files.

# Reference hash from the signing pipeline itself.
mkdir "$work/ref"
cp "$root/scripts/ahab/container.yaml" "$work/ref/"
for i in 0 1 2 3; do cp "$work/srk$i.pem" "$work/srk$i.pub" "$work/ref/"; done
head -c 4096 /dev/urandom >"$work/ref/payload.bin"
(cd "$work/ref" && "$venv/bin/nxpimage" ahab export -c container.yaml) >"$work/ref.log" 2>&1 ||
	{ tail -n 5 "$work/ref.log" >&2; echo "FAIL: reference export" >&2; exit 1; }
tr -d '[:space:]' <"$work/ref/ahab_oem0_srk0_hash.txt" >"$work/expected.txt"
exp=$(tr -d '[:space:]' <"$work/expected.txt")
case "${exp:0:1}" in 0) first=1 ;; *) first=0 ;; esac
printf '%s\n' "$first${exp:1}" >"$work/wrong.txt"
tr 'A-F' 'a-f' <"$work/expected.txt" >"$work/expected-lower.txt"
pub=("$work/srk0.pub" "$work/srk1.pub" "$work/srk2.pub" "$work/srk3.pub")

run() { # run <name> <expected rc> <expected output substring> -- args...
	local name=$1 rc=$2 want=$3 got=0
	shift 4
	"$check" "$@" >"$work/out.log" 2>&1 || got=$?
	if [ "$got" -ne "$rc" ]; then
		bad "$name: exit $got, want $rc"
		tail -n 3 "$work/out.log" >&2
	elif ! grep -q -- "$want" "$work/out.log"; then
		bad "$name: output lacks '$want'"
	else
		ok "$name"
	fi
}

run match 0 "srk-hash-check: match" -- "$work/expected.txt" "${pub[@]}"
run match-lowercase-expected 0 "srk-hash-check: match" -- "$work/expected-lower.txt" "${pub[@]}"
run mismatch-expected 1 "srk-hash-check: mismatch" -- "$work/wrong.txt" "${pub[@]}"
run mismatch-other-key 1 "srk-hash-check: mismatch" -- "$work/expected.txt" "${pub[@]:0:3}" "$work/srk4.pub"
run wrong-count-three 2 "exactly 4" -- "$work/expected.txt" "${pub[@]:0:3}"
run wrong-count-five 2 "exactly 4" -- "$work/expected.txt" "${pub[@]}" "$work/srk4.pub"
run private-key-refused 2 "private key" -- "$work/expected.txt" "$work/srk0.pem" "${pub[@]:1}"
head -c 120 /dev/urandom >"$work/not-pem.der"
run non-pem-refused 2 "neither a PEM" -- "$work/expected.txt" "$work/not-pem.der" "${pub[@]:1}"
printf 'zz\n' >"$work/bad-hex.txt"
run bad-expected-file 2 "not a hex string" -- "$work/bad-hex.txt" "${pub[@]}"

# PEM certificate input: disposable self-signed certificates over the same test
# keys; the reference hash is an AHAB export that names those certificates.
cat >"$work/mkcert.py" <<'PYEOF'
import datetime
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import NameOID

key = serialization.load_pem_private_key(open(sys.argv[1], "rb").read(), password=None)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, sys.argv[3])])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=2))
    .sign(key, hashes.SHA384())
)
open(sys.argv[2], "wb").write(cert.public_bytes(serialization.Encoding.PEM))
PYEOF
for i in 0 1 2 3 4; do
	"$venv/bin/python" -I "$work/mkcert.py" "$work/srk$i.pem" "$work/srk$i.crt" "srk-hash-check-test-$i" >/dev/null 2>"$work/mkcert.log" ||
		{ tail -n 3 "$work/mkcert.log" >&2; echo "FAIL: could not make test certificate $i" >&2; exit 1; }
done
mkdir "$work/refc"
cfg=$(<"$root/scripts/ahab/container.yaml")
for i in 0 1 2 3; do
	cfg=${cfg//srk$i.pub/srk$i.crt}
	cp "$work/srk$i.pem" "$work/srk$i.crt" "$work/refc/"
done
printf '%s\n' "$cfg" >"$work/refc/container.yaml"
cp "$work/ref/payload.bin" "$work/refc/"
(cd "$work/refc" && "$venv/bin/nxpimage" ahab export -c container.yaml) >"$work/refc.log" 2>&1 ||
	{ tail -n 5 "$work/refc.log" >&2; echo "FAIL: reference export with certificates" >&2; exit 1; }
tr -d '[:space:]' <"$work/refc/ahab_oem0_srk0_hash.txt" >"$work/expected-crt.txt"
crt=("$work/srk0.crt" "$work/srk1.crt" "$work/srk2.crt" "$work/srk3.crt")
{ head -n 3 "$work/srk0.crt"; } >"$work/bad.crt"

run cert-match 0 "srk-hash-check: match" -- "$work/expected-crt.txt" "${crt[@]}"
run cert-substituted-mismatch 1 "srk-hash-check: mismatch" -- "$work/expected-crt.txt" "${crt[@]:0:3}" "$work/srk4.crt"
run cert-malformed-refused 2 "SPSDK could not load" -- "$work/expected-crt.txt" "$work/bad.crt" "${crt[@]:1}"

# The output states the hash and names no fuse step.
"$check" "$work/expected.txt" "${pub[@]}" >"$work/out.log" 2>&1 || true
if grep -q "SRK table hash: $(cat "$work/expected.txt")" "$work/out.log"; then ok "hash printed"; else bad "hash not printed"; fi
if grep -qiE "fuse (prog|write)|efuse|blhost|\.bcf" "$work/out.log"; then bad "output names a fuse step"; else ok "no fuse step in output"; fi

[ "$fails" -eq 0 ] || { echo "srk_hash_check_test: $fails FAILED" >&2; exit 1; }
echo "srk_hash_check_test: OK"
