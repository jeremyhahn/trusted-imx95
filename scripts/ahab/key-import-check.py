"""Test helper for scripts/ahab/key-import-test.sh: two independent steps that do
not use SPSDK (the `cryptography` package only). Test keys only; nothing here
is a production derivation.

  key-import-check.py derive <own private key PEM> <peer public key PEM>
      Print a 32-byte test value as 64 hex digits: HKDF-SHA256 over the ECDH
      shared secret of the two P-256 keys. A throwaway stand-in for an
      OEM_IMPORT_MK_SK agreed with a device key; it is NOT the derivation of any
      real device.

  key-import-check.py check <blob> <MK_SK hex file> <raw key file>
      Check a key_import TLV blob built by SPSDK 3.14.0 (RFC 3394 wrapping,
      CMAC): derive OEM_IMPORT_WRAP_SK and OEM_IMPORT_CMAC_SK from the MK_SK
      (HKDF-SHA256, zero salt, the info strings the SPSDK source uses), check the
      trailing 16-byte CMAC over everything before it, and unwrap the wrapped key
      and compare it with the raw key. The blob's last 16 bytes are the CMAC
      value, the 16 bytes before them are not part of it but the tag and length
      bytes of the signature TLV are; the wrapped key is the TLV before that.

Exit codes of `check`: 0 valid, 1 CMAC or key mismatch, 2 blob or input unusable.
"""

import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import cmac, hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import algorithms
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.keywrap import InvalidUnwrap, aes_key_unwrap

SIG_LEN = 16


def hkdf(ikm, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=bytes(32), info=info).derive(ikm)


def derive(own_path, peer_path):
    own = serialization.load_pem_private_key(open(own_path, "rb").read(), password=None)
    peer = serialization.load_pem_public_key(open(peer_path, "rb").read())
    if not isinstance(own.curve, ec.SECP256R1) or not isinstance(peer.curve, ec.SECP256R1):
        raise ValueError("P-256 keys expected")
    secret = own.exchange(ec.ECDH(), peer)
    print(hkdf(secret, b"okp-test-mk-sk").hex())


def find_wrapped(blob):
    """The wrapped key: the value of the TLV just before the signature TLV.

    Walk the (tag, length, value) items from the start; short and long (0x81)
    length forms as SPSDK writes them.
    """
    items = []
    i = 0
    while i < len(blob):
        start = i
        i += 1
        n = blob[i]
        i += 1
        if n == 0x81:
            n = blob[i]
            i += 1
        elif n > 0x81:
            raise ValueError("unsupported length form")
        items.append((start, i, blob[i : i + n]))
        i += n
    if i != len(blob) or len(items) < 2:
        raise ValueError("blob is not a sequence of TLVs")
    return items


def check(blob_path, mksk_path, raw_path):
    blob = open(blob_path, "rb").read()
    mksk = bytes.fromhex(open(mksk_path).read().strip().removeprefix("0x"))
    raw = open(raw_path, "rb").read()
    items = find_wrapped(blob)
    sig_start, sig_value_start, sig = items[-1]
    wrapped = items[-2][2]
    if len(sig) != SIG_LEN:
        raise ValueError("signature TLV is not 16 bytes")
    wrap_sk = hkdf(mksk, b"oemelefwkeyimportwrap256")
    cmac_sk = hkdf(mksk, b"oemelefwkeyimportcmac256")
    c = cmac.CMAC(algorithms.AES(cmac_sk))
    c.update(blob[:-SIG_LEN])
    try:
        c.verify(sig)
    except InvalidSignature:
        print("key-import-check: CMAC mismatch")
        return 1
    try:
        plain = aes_key_unwrap(wrap_sk, wrapped)
    except InvalidUnwrap:
        print("key-import-check: unwrap failed")
        return 1
    if plain != raw:
        print("key-import-check: unwrapped key differs from the raw key")
        return 1
    print("key-import-check: CMAC valid, wrapped key unwraps to the raw key")
    return 0


def main(argv):
    try:
        if len(argv) == 4 and argv[1] == "derive":
            derive(argv[2], argv[3])
            return 0
        if len(argv) == 5 and argv[1] == "check":
            return check(argv[2], argv[3], argv[4])
    except (OSError, ValueError, IndexError) as e:
        print(f"key-import-check: {e}", file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
