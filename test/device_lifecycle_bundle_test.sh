#!/usr/bin/env bash
# device_lifecycle_bundle_test.sh: test/device_lifecycle/bundle_fixture.py
# build and check, with keys generated at test time in a temp dir. No board.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=test/lib.sh
source "$here/lib.sh"

before=$(cd "$ROOT" && git status --porcelain --ignored)
PY="$("$ROOT/scripts/ahab/spsdk-venv.sh")/bin/python"
TOOL="$ROOT/test/device_lifecycle/bundle_fixture.py"
W="$TMP_ROOT/w"
mkdir -p "$W"
NONCE=00112233445566778899aabbccddeeff
OTHER=ffeeddccbbaa99887766554433221100

py() { "$PY" -I "$@"; }
ev() { py "$TOOL" "$@"; }

# Fixtures. The signed region is SYNTHETIC: random bytes with the 16-byte nonce
# embedded once; the real response layout is not public.
py - "$W" "$NONCE" <<'EOF'
import os, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa, utils

w, nonce = sys.argv[1], bytes.fromhex(sys.argv[2])
P = serialization.Encoding.PEM
PUB = serialization.PublicFormat.SubjectPublicKeyInfo


def wr(name, data):
    with open(f"{w}/{name}", "wb") as f:
        f.write(data)


def sign(key, data):
    r, s = utils.decode_dss_signature(key.sign(data, ec.ECDSA(hashes.SHA384())))
    return r.to_bytes(48, "big") + s.to_bytes(48, "big")


key = ec.generate_private_key(ec.SECP384R1())
wr("ele.pem", key.public_key().public_bytes(P, PUB))
wr("other.pem", ec.generate_private_key(ec.SECP384R1()).public_key().public_bytes(P, PUB))
wr("p256.pem", ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(P, PUB))
wr("rsa.pem", rsa.generate_private_key(65537, 2048).public_key().public_bytes(P, PUB))
signed = os.urandom(40) + nonce + os.urandom(40)
wr("signed.bin", signed)
wr("sig.bin", sign(key, signed))
wr("sig95.bin", sign(key, signed)[:95])
absent = os.urandom(90)
wr("signed_absent.bin", absent)
wr("sig_absent.bin", sign(key, absent))
twice = os.urandom(10) + nonce + os.urandom(10) + nonce + os.urandom(10)
wr("signed_twice.bin", twice)
wr("sig_twice.bin", sign(key, twice))
# Synthetic TPM2B_PUBLIC: size, type 0x0023 (ECC), filler.
body = b"\x00\x23" + os.urandom(60)
wr("ek.bin", len(body).to_bytes(2, "big") + body)
wr("ek_other.bin", len(body).to_bytes(2, "big") + b"\x00\x23" + os.urandom(60))
wr("ek_badsize.bin", (len(body) + 1).to_bytes(2, "big") + body)
wr("ek_badtype.bin", len(body).to_bytes(2, "big") + b"\x00\x99" + body[2:])
EOF

build() { # out signed signature nonce version ek
	ev build --signed "$W/$2" --signature "$W/$3" --nonce "$4" --response-version "$5" \
		--ek-public "$W/$6" --ek-template "test-template" -o "$W/$1"
}
good() { build "$1" signed.bin sig.bin "$NONCE" "${2:-3}" ek.bin; }
chk() { ev check "$W/$1" --ele-pub "${2:-$W/ele.pem}" --nonce "${3:-$NONCE}" "${@:4}"; }

good bundle.json
run chk bundle.json
check "valid bundle" 0 "valid"
good bundle2.json
expect "builds are byte-identical" cmp -s "$W/bundle.json" "$W/bundle2.json"
build b_v2.json signed.bin sig.bin "$NONCE" 2 ek.bin
run chk b_v2.json
check "response_version 2" 0
run chk bundle.json "$W/ele.pem" "$NONCE" --ek-public "$W/ek.bin"
check "ek-public equal" 0

run chk bundle.json "$W/ele.pem" "$OTHER"
check "wrong --nonce" 1 "invalid"
run chk bundle.json "$W/other.pem"
check "different P-384 key" 1 "signature"
run chk bundle.json "$W/ele.pem" "$NONCE" --ek-public "$W/ek_other.bin"
check "ek-public mismatch" 1 "--ek-public"

# Flipped bytes: edit the decoded field and re-encode.
edit() { # name, python statement on dict b (b["ele_attestation"] is e)
	py - "$W/bundle.json" "$W/$1" "$2" <<'EOF'
import base64, json, sys
src, dst, stmt = sys.argv[1:4]
b = json.load(open(src))
e = b["ele_attestation"]


def dec(t):
    return bytearray(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))


def enc(x):
    return base64.urlsafe_b64encode(bytes(x)).rstrip(b"=").decode()


exec(stmt)
with open(dst, "w") as f:
    f.write(json.dumps(b, sort_keys=True, separators=(",", ":")) + "\n")
EOF
}
neg() { # name, python statement
	edit "m.json" "$2"
	run chk m.json
	check "$1" 1 "invalid"
}
neg "flipped signature byte" 's = dec(e["signature"]); s[5] ^= 1; e["signature"] = enc(s)'
neg "flipped signed byte" 's = dec(e["signed"]); s[0] ^= 1; e["signed"] = enc(s)'
neg "response_version 1" 'e["response_version"] = 1'
neg "response_version 4" 'e["response_version"] = 4'
neg "extra top-level key" 'b["extra"] = 1'
neg "extra nested key" 'e["extra"] = 1'
neg "missing key" 'del b["binding"]'
neg "missing nested key" 'del e["signature"]'
neg "padded base64" 'e["signature"] = e["signature"] + "=="'
neg "TPM2B size mismatch (shortened)" 'p = dec(b["ftpm_ek"]["public"]); b["ftpm_ek"]["public"] = enc(p[:-1])'
neg "wrong format" 'b["format"] = "x"'
neg "wrong version" 'b["version"] = 2'

build b_absent.json signed_absent.bin sig_absent.bin "$NONCE" 3 ek.bin
run chk b_absent.json
check "nonce absent from signed" 1 "nonce"
build b_twice.json signed_twice.bin sig_twice.bin "$NONCE" 3 ek.bin
run chk b_twice.json
check "nonce twice in signed" 1 "nonce"
build b_sig95.json signed.bin sig95.bin "$NONCE" 3 ek.bin
run chk b_sig95.json
check "signature 95 bytes" 1 "signature size"
build b_badsize.json signed.bin sig.bin "$NONCE" 3 ek_badsize.bin
run chk b_badsize.json
check "TPM2B size mismatch" 1 "TPM2B"
build b_badtype.json signed.bin sig.bin "$NONCE" 3 ek_badtype.bin
run chk b_badtype.json
check "unknown TPM type" 1 "TPM type"

printf 'not json' >"$W/junk.json"
run chk junk.json
check "non-JSON bundle" 2
run chk bundle.json "$W/rsa.pem"
check "non-EC --ele-pub" 2
run chk bundle.json "$W/p256.pem"
check "non-P-384 --ele-pub" 2
run ev
check "no arguments" 2 "usage"

after=$(cd "$ROOT" && git status --porcelain --ignored)
if [ "$before" = "$after" ]; then pass "the clone is unchanged"; else fail "the clone is unchanged" "$after"; fi
finish
