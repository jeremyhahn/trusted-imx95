"""Independent check of the container signature of an AHAB signed message.

Usage: python -I msg-sig-check.py <message.bin> <signer public key PEM>

Does not use SPSDK: the offsets come from the container header and the signature
block header of the message itself, and the signature is checked with the
`cryptography` package (OpenSSL) against the given public key. Added because
`nxpimage signed-msg verify` of the pinned SPSDK did not reject a flipped
signature byte (docs/oem-key-provisioning/key-exchange-msg.md).

Layout read (little endian), as written by SPSDK 3.14.0 for a container v2:
  container header: byte 12..13 = signature block offset
  signature block (at that offset): +8..+9 = signature offset in the block
  signature (at block + signature offset): 8-byte header, then r || s
The signed data are the bytes from 0 up to the signature offset (block start
plus signature offset), the whole message before the signature.

Exit codes: 0 signature valid, 1 signature invalid, 2 message or key unusable.
"""

import struct
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

SIG_HEADER = 8


def main(argv):
    if len(argv) != 3:
        print("usage: msg-sig-check.py <message.bin> <signer public key PEM>", file=sys.stderr)
        return 2
    try:
        data = open(argv[1], "rb").read()
        pub = serialization.load_pem_public_key(open(argv[2], "rb").read())
        if not isinstance(pub, ec.EllipticCurvePublicKey):
            raise ValueError("not an EC key")
        size = (pub.curve.key_size + 7) // 8
        (block,) = struct.unpack_from("<H", data, 12)
        (sig_off,) = struct.unpack_from("<H", data, block + 8)
        signed_end = block + sig_off
        raw = data[signed_end + SIG_HEADER : signed_end + SIG_HEADER + 2 * size]
        if len(raw) != 2 * size:
            raise ValueError("signature outside the message")
    except (OSError, ValueError, struct.error) as e:
        print(f"msg-sig-check: {e}", file=sys.stderr)
        return 2
    r = int.from_bytes(raw[:size], "big")
    s = int.from_bytes(raw[size:], "big")
    algo = {256: hashes.SHA256(), 384: hashes.SHA384(), 521: hashes.SHA512()}[pub.curve.key_size]
    try:
        pub.verify(utils.encode_dss_signature(r, s), data[:signed_end], ec.ECDSA(algo))
    except InvalidSignature:
        print("msg-sig-check: invalid signature")
        return 1
    print(f"msg-sig-check: valid; signature at offset {signed_end + SIG_HEADER}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
