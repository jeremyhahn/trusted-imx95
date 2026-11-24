"""TEST-ONLY fixture helper for the endorse-01 evidence bundle tests.

This is not a verifier and not a command for users or for the provisioning
station. It defines no wire format and no acceptance rule of this repository:
verification and the wire format belong to go-xkms (endorse-01) and
go-trusted-platform (docs/SPEC.md rows). It only builds and checks the
synthetic fixture bundles that test/device_lifecycle_*_test.sh use, so the
collector's output and the proposal in docs/device-lifecycle/evidence-bundle.md
can be exercised.

Usage (tests only):
  python -I bundle_fixture.py build --signed F --signature F --nonce HEX \\
      --response-version N --ek-public F --ek-template S -o OUT
  python -I bundle_fixture.py check BUNDLE --ele-pub PEM --nonce HEX \\
      [--ek-public F]

The bundle shape is a proposal, pending owner approval, for go-xkms and
go-trusted-platform, not an interface of this repository.

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
import os
import re
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa, utils

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


def pem_pub(key):
    return key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def sign96(key, data):
    r, s = utils.decode_dss_signature(key.sign(data, ec.ECDSA(hashes.SHA384())))
    return r.to_bytes(48, "big") + s.to_bytes(48, "big")


def vectors(args):
    """Write a labelled vector set for a verifier: every file in OUTDIR is a
    bundle or a public key, manifest.json says how to `check` each and what
    must come out. The enclave key is generated here and only its public half
    is written. The vectors are SYNTHETIC: the response layout is not public."""
    nonce = os.urandom(NONCE_LEN)
    other_nonce = bytes(b ^ 0xFF for b in nonce)
    key = ec.generate_private_key(ec.SECP384R1())
    keys_out = {
        "ele-pub.pem": pem_pub(key),
        "ele-pub-other.pem": pem_pub(ec.generate_private_key(ec.SECP384R1())),
        "ele-pub-p256.pem": pem_pub(ec.generate_private_key(ec.SECP256R1())),
        "ele-pub-rsa.pem": pem_pub(rsa.generate_private_key(65537, 2048)),
    }

    def region(*parts):
        return b"".join(parts)

    signed = region(os.urandom(40), nonce, os.urandom(40))
    absent = os.urandom(90)
    twice = region(os.urandom(10), nonce, os.urandom(10), nonce, os.urandom(10))
    body = b"\x00\x23" + os.urandom(60)
    ek = len(body).to_bytes(2, "big") + body
    ek_other = len(body).to_bytes(2, "big") + b"\x00\x23" + os.urandom(60)

    def bundle(signed=signed, sig=None, version=3, tpm=ek, nonce_in=nonce):
        sig = sign96(key, signed) if sig is None else sig
        return {
            "format": FORMAT,
            "version": VERSION,
            "ele_attestation": {
                "response_version": version,
                "signed": b64(signed),
                "signature": b64(sig),
                "verifier_nonce": b64(nonce_in),
            },
            "ftpm_ek": {"public": b64(tpm), "template": "vector-template"},
            "binding": "session",
        }

    def flip(text, index):
        raw = bytearray(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))
        raw[index] ^= 1
        return b64(bytes(raw))

    def mut(fn):
        b = bundle()
        fn(b, b["ele_attestation"])
        return b

    def set_(d, k, v):
        d[k] = v

    def delete(d, k):
        del d[k]

    nonce_hex = nonce.hex()
    cases = []  # name, bundle dict (or raw bytes), ele-pub file, nonce hex, ek file, rc, check

    def case(name, content, rc, want, pub="ele-pub.pem", nonce_arg=nonce_hex, ek_file=None):
        cases.append((name, content, pub, nonce_arg, ek_file, rc, want))

    case("valid", bundle(), 0, "valid")
    case("valid-response-version-2", bundle(version=2), 0, "valid")
    case("valid-ek-public-equal", bundle(), 0, "valid", ek_file="ek-public.bin")
    case("wrong-nonce-argument", bundle(), 1, "verifier_nonce differs", nonce_arg=other_nonce.hex())
    case("different-p384-key", bundle(), 1, "signature does not verify", pub="ele-pub-other.pem")
    case("ek-public-mismatch", bundle(), 1, "differs from --ek-public", ek_file="ek-public-other.bin")
    sig = sign96(key, signed)
    case("flipped-signature-byte", mut(lambda b, e: set_(e, "signature", flip(e["signature"], 5))),
         1, "signature does not verify")
    case("flipped-signed-byte", mut(lambda b, e: set_(e, "signed", flip(e["signed"], 0))),
         1, "signature does not verify")
    case("response-version-1", mut(lambda b, e: set_(e, "response_version", 1)), 1, "response_version")
    case("response-version-4", mut(lambda b, e: set_(e, "response_version", 4)), 1, "response_version")
    case("extra-top-level-key", mut(lambda b, e: set_(b, "extra", 1)), 1, "key set differs")
    case("extra-nested-key", mut(lambda b, e: set_(e, "extra", 1)), 1, "key set differs")
    case("missing-key", mut(lambda b, e: delete(b, "binding")), 1, "key set differs")
    case("missing-nested-key", mut(lambda b, e: delete(e, "signature")), 1, "key set differs")
    case("padded-base64", mut(lambda b, e: set_(e, "signature", e["signature"] + "==")),
         1, "not unpadded base64url")
    case("tpm2b-size-shortened",
         mut(lambda b, e: set_(b["ftpm_ek"], "public", b64(ek[:-1]))), 1, "TPM2B size")
    case("wrong-format", mut(lambda b, e: set_(b, "format", "x")), 1, "format")
    case("wrong-version", mut(lambda b, e: set_(b, "version", 2)), 1, "version")
    case("nonce-absent-from-signed", bundle(signed=absent), 1, "nonce does not occur exactly once")
    case("nonce-twice-in-signed", bundle(signed=twice), 1, "nonce does not occur exactly once")
    case("signature-95-bytes", bundle(sig=sig[:95]), 1, "signature size")
    case("tpm2b-size-mismatch", bundle(tpm=(len(body) + 1).to_bytes(2, "big") + body), 1, "TPM2B size")
    case("unknown-tpm-type", bundle(tpm=len(body).to_bytes(2, "big") + b"\x00\x99" + body[2:]),
         1, "TPM type")
    case("not-json", b"not json", 2, "not JSON")
    case("ele-pub-rsa", bundle(), 2, "not an EC P-384 key", pub="ele-pub-rsa.pem")
    case("ele-pub-p256", bundle(), 2, "not an EC P-384 key", pub="ele-pub-p256.pem")

    try:
        os.makedirs(args.outdir, exist_ok=True)

        def put(name, data):
            with open(os.path.join(args.outdir, name), "wb") as f:
                f.write(data)

        for name, data in keys_out.items():
            put(name, data)
        put("ek-public.bin", ek)
        put("ek-public-other.bin", ek_other)
        entries = []
        for name, content, pub, nonce_arg, ek_file, rc, want in cases:
            fname = f"{name}.json"
            if isinstance(content, bytes):
                put(fname, content)
            else:
                text = json.dumps(content, sort_keys=True, separators=(",", ":")) + "\n"
                put(fname, text.encode("utf-8"))
            check_args = [fname, "--ele-pub", pub, "--nonce", nonce_arg]
            if ek_file:
                check_args += ["--ek-public", ek_file]
            entries.append(
                {"name": name, "check_args": check_args, "expect_exit": rc, "expect_check": want}
            )
        manifest = {
            "format": "trusted-imx95/endorse-evidence-vectors",
            "synthetic": "the enclave response layout is not public: signed regions are "
            "random bytes holding the nonce, signed with a key generated for this "
            "run; not a statement about the real enclave output",
            "proposed": "pending owner approval",
            "check_args_relative_to": "the manifest directory",
            "vectors": entries,
        }
        put("manifest.json", (json.dumps(manifest, indent=2) + "\n").encode("utf-8"))
    except OSError as e:
        raise Unusable(str(e))


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print(f"usage error: {message}", file=sys.stderr)
        raise SystemExit(2)


def main(argv):
    p = Parser(prog="bundle_fixture.py")
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
    v = sub.add_parser("vectors")
    v.add_argument("outdir")
    args = p.parse_args(argv[1:])
    try:
        if args.cmd == "build":
            build(args)
            print("bundle_fixture: built")
        elif args.cmd == "vectors":
            vectors(args)
            print("bundle_fixture: vectors written")
        else:
            check(args)
            print("bundle_fixture: valid")
    except Invalid as e:
        print(f"bundle_fixture: invalid: {e}")
        return 1
    except Unusable as e:
        print(f"bundle_fixture: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
