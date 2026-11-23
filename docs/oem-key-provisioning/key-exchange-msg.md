# Key-exchange signed message on a test SRK set

> **Status: PROVISIONAL** · Row: `oem-key-provisioning` ([SPEC.md](../SPEC.md)) · Issue #163

A host-side exercise of the message format. `make okp-keyexchange-test` builds a `key_exchange_req` signed message for
`mimx9596` (revision `b0`) with the pinned SPSDK, signed by a throwaway test SRK set, and verifies it with
`nxpimage signed-msg verify`.

**This exercises the message format only. It sends nothing to a device, proves nothing about a real enclave, and this
file documents no command to send a message to a board.** Whether and when a key exchange is run on a device is the
owner's decision ([architecture.md](architecture.md#provisioning-flow)). The message holds no ECDH key: the template's
optional `oem_private_key` and `nxp_prod_ka_pub` fields are left out, and the digests and key IDs are zero test values.

## What the test does

`scripts/ahab/key-exchange-test.sh` (run through `test/key_exchange_test.sh`, which also checks the clone is unchanged):

1. Generates five ECDSA P-384 keys in a `mktemp -d` directory outside the clone: four form the SRK set, the fifth is
   foreign. The directory, keys included, is removed on exit.
2. Builds the message from a configuration written from the template that the pinned
   `nxpimage signed-msg get-template -m key_exchange_req` produces, with test values only.
3. Verifies the message: it builds and `nxpimage signed-msg verify` reports no error.
4. Reads the offsets from the message itself (container header byte 12 gives the signature block; its header gives the
   SRK table and signature offsets), flips one byte in the SRK table (rejected by `verify`), then checks the signature
   with `scripts/ahab/msg-sig-check.py`, which does not use SPSDK (the `cryptography` package, ECDSA over the signed
   region against SRK 0's public key). The signature is valid; a flipped signature byte, a flipped body byte and the
   check under another SRK's public key are each rejected.
5. Parses the message and compares the SRK table hash SPSDK reports with the one
   [srk-hash-check.md](srk-hash-check.md) computes from the set's public keys: they agree.
6. Builds a second message under a set whose SRK 0 is the foreign key, signed by that key: it verifies on its own, its
   SRK table hash differs, and `srk-hash-check` against the first set's hash reports a mismatch.

## Findings with the pinned SPSDK 3.13.0

- **SPSDK `verify` does not check the signature at the pinned version.** `nxpimage signed-msg verify` took a flipped
  byte at every probed offset (every eighth byte) of the trailing signature without complaint, and a flipped byte in
  the message body (the command fields). It rejected flips in the header and the SRK table. A message whose signature
  was altered therefore passes `verify`. The test asserts the signature with the independent check of step 4, and
  records that SPSDK `verify` accepts a flipped body byte. A caller must not rely on `verify` for authenticity.
- `nxpimage signed-msg export` accepted a signer key that is not in the SRK table. The test therefore stands in for
  "signed by a different SRK" with a message built under another SRK set (step 6) and the SRK table hash comparison.

## Provisional defaults

Each is the owner's to change.

- Algorithm and key sizes: ECDSA P-384 SRKs, `key_exchange_algorithm` ECDH HKDF SHA256 KEY IMPORT, an AES derived key
  of 256 bits, persistent lifetime, usage Cache and Derive. These are the template's defaults, not a choice for a device.
- Container version 2, SRK set `oem`, used SRK 0, `fuse_version` 0, zero UUID (no restriction to a chip).
- The offsets are read from the message header, but the layout read (header byte 12, block bytes 6 and 8, an 8-byte
  signature header, r and s) is that SPSDK 3.13.0 writes for container version 2; a bump of the pin needs it checked.
  The signature algorithm is taken from the curve of the key (P-384: ECDSA with SHA-384).

## Open

- Which fields a real key-exchange message carries, and the UUID restriction: the owner's, with the vendor documents
  cited in [key-ceremony-survey.md](key-ceremony-survey.md) and [public-flow-survey.md](public-flow-survey.md).
- Whether the enclave rejects a message signed by a key outside its SRK table: not tested, needs a device.
