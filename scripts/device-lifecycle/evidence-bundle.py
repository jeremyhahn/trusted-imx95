"""Build and check the device-side endorse-01 evidence bundle (proposed).

Usage:
  python -I evidence-bundle.py build --signed F --signature F --nonce HEX \\
      --response-version N --ek-public F --ek-template S -o OUT
  python -I evidence-bundle.py check BUNDLE --ele-pub PEM --nonce HEX \\
      [--ek-public F]

The bundle is the evidence the Cortex-A55 hands to go-xkms under owner ruling
1234: the EdgeLock enclave attestation response (RM00284 section 3.12) with
the verifier's nonce, then the fTPM EK public area. The format is a proposal,
pending owner approval (docs/device-lifecycle/evidence-bundle.md); go-xkms
and go-trusted-platform own the real wire format.

A JSON object, UTF-8, sorted keys, compact separators, one trailing newline;
byte fields are unpadded base64url. `build` is deterministic and does not
verify anything but the nonce size. `check` verifies, offline:
  - the exact key set at every level, `format` and `version`;
  - response_version in {2, 3}, strict unpadded base64url fields;
  - the nonce is 16 bytes, equals --nonce, and occurs exactly once in the
    signed region (the field's position is not public, so none is assumed);
  - the signature is 96 bytes and valid as ECDSA P-384 r || s over the signed
    region with SHA-384 against --ele-pub. The algorithm is an inference
    (attestation-survey.md section 1.1), not confirmed;
  - ftpm_ek.public is a TPM2B_PUBLIC (2-byte big-endian size equal to the
    remaining length, type RSA 0x0001 or ECC 0x0023) and, when --ek-public
    is given, byte-equal to that file.
The signed region and the signature are opaque bytes. No key material is read
from or written into the repository.

Exit codes: 0 valid, 1 invalid (one line naming the failed check), 2 unusable
input.
"""

import argparse
import base64
import json
import re
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

FORMAT = "trusted-imx95/endorse-evidence"
VERSION = 1
NONCE_LEN = 16
SIG_LEN = 96
TPM_ALGS = (0x0001, 0x0023)
B64URL = re.compile(r"[A-Za-z0-9_-]*\Z")


class Invalid(Exception):
    pass


class Unusable(Exception):
    pass


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64(text, what):
    if not isinstance(text, str) or not B64URL.match(text) or len(text) % 4 == 1:
        raise Invalid(f"{what} is not unpadded base64url")
    raw = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    if b64(raw) != text:
        raise Invalid(f"{what} is not canonical base64url")
    return raw


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        raise Unusable(str(e))


def hex_nonce(text):
    try:
        raw = bytes.fromhex(text)
    except ValueError:
        raise Unusable("--nonce is not hex")
    if len(raw) != NONCE_LEN:
        raise Unusable(f"--nonce is not {NONCE_LEN} bytes")
    return raw


def build(args):
    nonce = hex_nonce(args.nonce)
    bundle = {
        "format": FORMAT,
        "version": VERSION,
        "ele_attestation": {
            "response_version": args.response_version,
            "signed": b64(read(args.signed)),
            "signature": b64(read(args.signature)),
            "verifier_nonce": b64(nonce),
        },
        "ftpm_ek": {"public": b64(read(args.ek_public)), "template": args.ek_template},
        "binding": "session",
    }
    text = json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n"
    try:
        with open(args.output, "wb") as f:
            f.write(text.encode("utf-8"))
    except OSError as e:
        raise Unusable(str(e))


def keys(obj, want, what):
    if not isinstance(obj, dict):
        raise Invalid(f"{what} is not an object")
    if set(obj) != set(want):
        raise Invalid(f"{what} key set differs (missing or unknown key)")


def check(args):
    nonce_want = hex_nonce(args.nonce)
    try:
        pub = serialization.load_pem_public_key(read(args.ele_pub))
    except ValueError as e:
        raise Unusable(f"--ele-pub: {e}")
    if not isinstance(pub, ec.EllipticCurvePublicKey) or pub.curve.name != "secp384r1":
        raise Unusable("--ele-pub is not an EC P-384 key")
    ek_want = read(args.ek_public) if args.ek_public else None
    try:
        bundle = json.loads(read(args.bundle).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise Unusable(f"bundle is not JSON: {e}")

    keys(bundle, ["format", "version", "ele_attestation", "ftpm_ek", "binding"], "bundle")
    if bundle["format"] != FORMAT:
        raise Invalid("format")
    if type(bundle["version"]) is not int or bundle["version"] != VERSION:
        raise Invalid("version")
    if bundle["binding"] != "session":
        raise Invalid("binding")
    ele = bundle["ele_attestation"]
    keys(ele, ["response_version", "signed", "signature", "verifier_nonce"], "ele_attestation")
    if type(ele["response_version"]) is not int or ele["response_version"] not in (2, 3):
        raise Invalid("response_version")
    ek = bundle["ftpm_ek"]
    keys(ek, ["public", "template"], "ftpm_ek")
    if not isinstance(ek["template"], str):
        raise Invalid("template is not a string")

    signed = unb64(ele["signed"], "signed")
    sig = unb64(ele["signature"], "signature")
    nonce = unb64(ele["verifier_nonce"], "verifier_nonce")
    tpm = unb64(ek["public"], "ftpm_ek.public")

    if len(nonce) != NONCE_LEN:
        raise Invalid("verifier_nonce size")
    if nonce != nonce_want:
        raise Invalid("verifier_nonce differs from --nonce")
    if signed.count(nonce) != 1:
        raise Invalid("nonce does not occur exactly once in signed")
    if len(sig) != SIG_LEN:
        raise Invalid("signature size")
    r = int.from_bytes(sig[: SIG_LEN // 2], "big")
    s = int.from_bytes(sig[SIG_LEN // 2 :], "big")
    try:
        pub.verify(utils.encode_dss_signature(r, s), signed, ec.ECDSA(hashes.SHA384()))
    except InvalidSignature:
        raise Invalid("signature does not verify")
    if len(tpm) < 4 or int.from_bytes(tpm[:2], "big") != len(tpm) - 2:
        raise Invalid("TPM2B size")
    if int.from_bytes(tpm[2:4], "big") not in TPM_ALGS:
        raise Invalid("TPM type")
    if ek_want is not None and tpm != ek_want:
        raise Invalid("ftpm_ek.public differs from --ek-public")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print(f"usage error: {message}", file=sys.stderr)
        raise SystemExit(2)


def main(argv):
    p = Parser(prog="evidence-bundle.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--signed", required=True)
    b.add_argument("--signature", required=True)
    b.add_argument("--nonce", required=True)
    b.add_argument("--response-version", required=True, type=int)
    b.add_argument("--ek-public", required=True)
    b.add_argument("--ek-template", required=True)
    b.add_argument("-o", "--output", required=True)
    c = sub.add_parser("check")
    c.add_argument("bundle")
    c.add_argument("--ele-pub", required=True)
    c.add_argument("--nonce", required=True)
    c.add_argument("--ek-public")
    args = p.parse_args(argv[1:])
    try:
        if args.cmd == "build":
            build(args)
            print("evidence-bundle: built")
        else:
            check(args)
            print("evidence-bundle: valid")
    except Invalid as e:
        print(f"evidence-bundle: invalid: {e}")
        return 1
    except Unusable as e:
        print(f"evidence-bundle: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
