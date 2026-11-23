# Key-import TLV blob on test keys

> **Status: PROVISIONAL** · Row: `oem-key-provisioning` ([SPEC.md](../SPEC.md)) · Issue #163

A host-side exercise of the wrapped-key blob format. `make okp-import-tlv-test` builds a `key_import` TLV blob for
`mimx9596` (revision `b0`) with the pinned SPSDK 3.13.0 (`nxpimage signed-msg tlv export`) around a fresh throwaway
test key, then parses and verifies it.

**This proves nothing about a real device and documents no production import path.** A throwaway P-256 key stands in
for the device key-agreement key; the wrapping key is derived from it only for this test. Nothing is sent to a board,
no fuse or life-cycle step is involved, and this file gives no command to import a blob into a device. Keys that
protect a fleet stay blocked behind the owner's ceremony decisions
([key-ceremony-survey.md](key-ceremony-survey.md): wrapping or import keys held in memory or in files are acceptable
only as disposable development keys, discarded after use).

## What the test does

`scripts/ahab/key-import-test.sh` (run through `test/key_import_test.sh`, which also checks the clone is unchanged):

1. In a `mktemp -d` directory outside the clone, generates two ECDSA P-256 keys (`device` stands in for the device
   key-agreement key, `oem` is the host side), a third foreign one, and a fresh 32-byte random test key. The directory,
   keys included, is removed on exit.
2. Derives a 32-byte test MK_SK from the ECDH of the two P-256 keys (HKDF-SHA256 over the shared secret). Either side
   gets the same value. This derivation is a stand-in made up for the test, not the derivation of any real device.
3. Builds the blob from a configuration written from the template of
   `nxpimage signed-msg tlv get-template -t key_import` (AES key, 256 bits, RFC 3394 wrapping, CMAC), giving
   `import_key` and `oem_import_mk_sk_key`, so SPSDK wraps and signs it.
4. Parses and verifies the blob with SPSDK.
5. Checks the blob independently of SPSDK (`scripts/ahab/key-import-check.py`, the `cryptography` package): derives the
   wrapping and CMAC keys from the MK_SK with HKDF-SHA256 and the info strings the SPSDK source uses, checks the
   trailing 16-byte CMAC over everything before it, unwraps the wrapped key and compares it with the test key.
6. Flips one CMAC byte, one ciphertext byte (offsets from the blob layout, counted back from its end), and checks the
   blob under a different MK_SK: each is rejected by the independent check.

## Findings with the pinned SPSDK 3.13.0

- `nxpimage signed-msg tlv verify` holds no key, so it checks structure and field values only. It accepts a blob with a
  flipped CMAC byte or a flipped ciphertext byte. The test therefore asserts those rejections with the independent
  check, and prints the SPSDK result as information only.
- The CMAC and the RFC 3394 unwrap of the checker follow the SPSDK source (salt: 32 zero bytes when no SRK hash is
  given; info strings `oemelefwkeyimportwrap256` and `oemelefwkeyimportcmac256`). That matches SPSDK with itself, not
  the vendor's specification of the enclave side. The section of the vendor reference that defines the key-import
  blob is to be cited here by the owner before this is relied on for anything else.

## Provisional defaults

Each is the owner's to change.

- Key: AES 256, usage Cache and Sign message, persistent lifetime, life cycle CURRENT, key ID 0, MK_SK key ID 0.
- Wrapping RFC 3394, signing CMAC, no SRK hash (zero salt).
- The blob offsets the tamper step uses are those of this blob under SPSDK 3.13.0 (32-byte key, 40-byte wrapped value);
  a bump of the pin or another key size needs new ones.

## Open

- Which key a real import carries, how the MK_SK is agreed with the device (see
  [key-exchange-msg.md](key-exchange-msg.md)), and whether the SRK hash is used as salt: the owner's.
- Whether the enclave accepts this blob: not tested, needs a device.
