"""test-hsm.py: a TEST stand-in for the HSM that holds the AHAB signing key.

AN14471's model for the custody of the signing keys (AN14471 §3.1, §3.6): the
private key stays in the HSM; the build sends what is to be signed and gets a
signature back. go-xkms is that custody on the real path. This script is a
throwaway stand-in, for scripts/ahab/hsm-sign-test.sh only: it serves SPSDK's
`proxy` signature provider protocol (API 2.0: GET <prefix>/sign,
/signature_length, /verify_public_key) on 127.0.0.1 for ONE private key it
reads from its own directory, which the build never sees.

    python -I test-hsm.py <key.pem> <port-file> <log-file>

It binds an ephemeral port on 127.0.0.1, writes the port to <port-file> once
it listens, and appends one line per request to <log-file>. It accepts only
pre-hashed SHA-384 digests ("prehashed": "sha384", 48 bytes): it never sees
the container. Run it with the pinned SPSDK venv's python (it uses the
`cryptography` package that venv pins). Not a production signer.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

DIGEST_LEN = 48  # SHA-384
PREFIX = "/api"


def load_key(path):
    with open(path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp384r1":
        raise SystemExit("test-hsm: the key must be an ECDSA P-384 private key")
    return key


def make_handler(key, log_path):
    pub_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    # Raw r||s of P-384: two 48-byte integers.
    sig_len = 2 * ((key.curve.key_size + 7) // 8)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # quiet: the log file is the record
            pass

        def record(self, line):
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")

        def reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                return json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return None

        def do_GET(self):  # noqa: N802 (http.server's name)
            req = self.body()
            path = self.path.split("?", 1)[0]
            if req is None:
                self.record("bad-request %s: body is not JSON" % path)
                return self.reply(400, {"error": "body is not JSON"})
            if path == PREFIX + "/signature_length":
                self.record("signature_length %d" % sig_len)
                return self.reply(200, {"data": sig_len})
            if path == PREFIX + "/verify_public_key":
                given = str(req.get("data", "")).encode()
                try:
                    match = serialization.load_pem_public_key(given).public_bytes(
                        serialization.Encoding.PEM,
                        serialization.PublicFormat.SubjectPublicKeyInfo,
                    ) == pub_pem
                except ValueError:
                    match = False
                self.record("verify_public_key %s" % ("match" if match else "mismatch"))
                return self.reply(200, {"data": match})
            if path == PREFIX + "/sign":
                if req.get("prehashed") != "sha384":
                    self.record("refused sign: not a pre-hashed sha384 digest")
                    return self.reply(400, {"error": "only pre-hashed sha384 digests are signed"})
                try:
                    digest = bytes.fromhex(str(req.get("data", "")))
                except ValueError:
                    digest = b""
                if len(digest) != DIGEST_LEN:
                    self.record("refused sign: digest of %d bytes" % len(digest))
                    return self.reply(400, {"error": "the digest must be 48 bytes"})
                sig = key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA384())))
                self.record("sign sha384 %s" % digest.hex())
                return self.reply(200, {"data": sig.hex()})
            self.record("unknown %s" % path)
            return self.reply(404, {"error": "unknown endpoint"})

    return Handler


def main(argv):
    if len(argv) != 4:
        raise SystemExit("usage: test-hsm.py <key.pem> <port-file> <log-file>")
    key = load_key(argv[1])
    server = HTTPServer(("127.0.0.1", 0), make_handler(key, argv[3]))
    tmp = argv[2] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("%d\n" % server.server_address[1])
    os.replace(tmp, argv[2])
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
