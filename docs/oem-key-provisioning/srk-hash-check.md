# SRK hash check of a public SRK set

> **Status: PROVISIONAL** · Row: `oem-key-provisioning` ([SPEC.md](../SPEC.md)) · Issue #163

A host-side check. It computes the SRK table hash of four public SRK keys or certificates and compares it with an
expected value kept in a file. It touches no board, no fuse and no life-cycle state; `test/okp_host_only_test.sh` reads its scripts and fails on any device-transport tool or path in them.

**Programming the SRK hash into a device is the owner's decision alone. It is not scripted here and this file gives
no command for it.** The same holds for the life-cycle close
([architecture.md](architecture.md#life-cycle-close)). The check prints no fuse word layout; where the hash goes on
the i.MX 95 is the fuse map's question ([fuse-map-survey.md](fuse-map-survey.md)).

## Use

```text
make srk-hash-check SRK_EXPECTED=<expected-hash-file> SRK_FILES="<srk0> <srk1> <srk2> <srk3>"
```

- `<expected-hash-file>` holds the expected hash as one hex string of 128 digits, any case.
- The four SRK files are PEM certificates (`BEGIN CERTIFICATE`) or PEM public keys in SubjectPublicKeyInfo form
  (`BEGIN PUBLIC KEY`), in SRK index order. Other labels are refused, including the PKCS#1 `BEGIN RSA PUBLIC KEY`.
  Convert such a key first, for example `openssl rsa -RSAPublicKey_in -pubin -in old.pem -pubout -out spki.pem`
  (the form `nxpcrypto key generate` writes as `.pub` is already SubjectPublicKeyInfo).
- Output: `SRK table hash: <hex>`, then `srk-hash-check: match` or `srk-hash-check: mismatch`.

The script's exit codes are 0 for a match, 1 for a mismatch and 2 for a refused input or usage error. `make` returns
2 for any failed recipe, so through `make` a mismatch and a refused input look alike. A caller that must tell them
apart runs the script directly:

```text
scripts/ahab/srk-hash-check.sh <expected-hash-file> <srk0> <srk1> <srk2> <srk3>
```

## What it refuses

- Any file whose PEM text holds a private key of any kind, encrypted or not.
- Any file that is not a PEM public key or PEM certificate (DER, empty, anything else).
- Any count of files other than four.
- An expected-hash file that is not 128 hex digits.

## How the hash is computed

With the SPSDK pinned in [scripts/ahab/requirements.txt](../../scripts/ahab/requirements.txt) (venv from
`scripts/ahab/spsdk-venv.sh`, outside the clone). `scripts/ahab/srk-hash.py` loads an AHAB configuration for the
`mimx9596` B0 OEM SRK set with the given files as the `srk_array` and prints the hash SPSDK derives from the table.
Nothing is signed or exported. SPSDK needs a signer to load a configuration; the script generates a throwaway key in
its own work directory (outside the clone, deleted on exit) and never uses it to sign. The check of the signing
side is in [boot-container/signing-pipeline.md](../boot-container/signing-pipeline.md).

`test/srk_hash_check_test.sh` covers match, mismatch, wrong SRK count and a refused private key, on a test PKI
generated per run. Its expected value comes from `nxpimage ahab export` of a container signed with that PKI, not from
the script under test.

## Provisional defaults

Each is the owner's to change.

- **Exactly four SRKs.** The i.MX 95 OEM SRK table in SPSDK holds four records; a set of another size is refused
  instead of padded.
- **PEM only.** Other encodings are refused rather than guessed.
- **Hash format.** The value SPSDK writes for the OEM SRK table (128 hex digits, SRK set `oem`, SRK table 0).
  Whether the device compares this digest or a truncation of it is the fuse map's question and is not confirmed
  here ([fuse-map-survey.md](fuse-map-survey.md)).
- **Expected-value custody.** The expected-hash file is supplied by the caller; this repository holds none for any
  device.

## Open

- Who writes the expected-hash file and from which ceremony record
  ([key-ceremony-survey.md](key-ceremony-survey.md)): the owner's.
- Whether the SRK set may have fewer than four keys on a real device: not given by the cited sources.
