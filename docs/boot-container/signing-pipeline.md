# Boot-container signing pipeline (test PKI)

Status: host-side pipeline for issue #9, in the `boot-container` row of
[docs/SPEC.md](../SPEC.md). It follows the owner's decision in
[signing-tool-options.md](signing-tool-options.md): SPSDK 3.13.0, ECDSA P-384, i.MX 95 B0
(SPSDK family `mimx9596`, revision `b0`).

`make ahab-sign-test` builds one AHAB OEM container around a random test payload, signs it with a
throwaway test PKI and verifies it with `nxpimage ahab verify`. It never touches a real key, an HSM,
a fuse, the life cycle or a board.

## How to run

In the devcontainer image, where the pinned SPSDK venv is at `/opt/spsdk` (`SPSDK_VENV`):

```sh
make docker-run CMD='make ahab-sign-test'
```

On a host with `python3` and `pip`, `make ahab-sign-test` runs the same steps. The first run
installs the pinned closure (`scripts/ahab/requirements.txt` and `build-requirements.txt`, every
file checked against its SHA-256 with `pip install --require-hashes`) into a venv under
`${XDG_CACHE_HOME:-$HOME/.cache}/trusted-imx95/`; set `SPSDK_VENV` to use another directory
outside the clone. The run fails, naming the pin, if the venv's `nxpimage` is not 3.13.0.

Set `AHAB_OUT_DIR` to keep a copy of the signed `container.bin`; nothing else leaves the run.
`scripts/ahab/sign-test.sh verify <container.bin>` verifies a container on its own and prints
`verify: OK` or `verify: FAILED`.

What one run does, in a `mktemp -d` work directory outside the clone that is removed on exit:

1. `nxpcrypto key generate -k secp384r1` writes four test SRKs (`srkN.pem`, `srkN.pub`).
2. `nxpimage ahab export -c container.yaml` builds and signs the container from
   [scripts/ahab/container.yaml](../../scripts/ahab/container.yaml) with SRK 0.
3. The `.bcf` fuse script that the export writes is deleted unread. It is never run.
4. `nxpimage ahab verify` checks the container.
5. The run prints the SRK table hash, labelled as for this test PKI only. It is not a value for any
   device's fuses.

`test/ahab_sign_test.sh` (in `make test`) checks that the container verifies, that copies with one
signature byte or one payload byte flipped are rejected, that the run writes nothing in the clone,
and that a wrong SPSDK version fails.

## musl and libuuu

SPSDK 3.13.0 requires `libuuu`, which publishes only glibc (manylinux) wheels. On musl (the Alpine
image) pip installs the pinned `libuuu` sdist instead. The sdist compiles nothing. It only packages
NXP's prebuilt glibc `libuuu.so`, which `nxpimage ahab export` and `verify` never load, so the
pipeline runs on musl. Board flashing through `nxpuuu` would load that library and is not part of
this pipeline.

## M7 container

`make ahab-m7-test` (`scripts/ahab/sign-test.sh m7 [<payload file>]`, or `M7_PAYLOAD=<file> make
ahab-m7-test`) builds, with the same test PKI and steps as above, one OEM container whose single image
entry is laid out for the Cortex-M7 of trusted-firmware's `imx95` row, from
[scripts/ahab/m7-container.yaml](../../scripts/ahab/m7-container.yaml). The default payload is a
generated 4 KiB random stand-in (not an ELF). After `nxpimage ahab verify` the run prints the entry's
fields from `nxpimage ahab parse` (the parse output and the `.bcf` fuse script stay in the work
directory or are deleted unread). `test/ahab_sign_test.sh` checks that it verifies, that the parsed core,
load and entry address match the yaml, and that a flipped payload byte is rejected. The board step
(boot it, read the ELE events) is out of scope.

| Field | Value | Source |
|---|---|---|
| `core_id` | `cortex-m7-1` | [m7-load-path-survey.md](m7-load-path-survey.md) §3 (the `-m7` image entry); the only M7 name SPSDK 3.13.0 accepts for `mimx9596` |
| `load_address` | `0x0` | survey §3 and §5, TCM row: the M7's own view of its TCM (first address of mkimage's `-m7`) |
| `entry_point` | `0x303C0000` | survey §3: the TCM seen from the system bus (second address of `-m7`) |
| `image_type` | `executable` | survey §8 (`m7_image.bin` is firmware the core runs) |
| `hash_type` | `sha384` | the test PKI's P-384 (this page) |

The TCM lies in the M7MIX ranges the System Manager grants the M7
([system-manager-config/build.md](../system-manager-config/build.md) §5). The DDR window
(`0x80000000`, survey §5) is not used: the survey's owner question 10.1 (TCM or DDR) is open.

Stays MISSING, never guessed: which of the two addresses the ROM or ELE treats as load and which as
entry (survey U1, needs IMX95RM); the numeric AHAB core id and image type codes behind SPSDK's names
(U1); the TCM sizes and ITCM/DTCM split (U2); the container version, `fuse_version` and SRK hash fuse
values for a real device (U3, as above).

## Policy check

```sh
scripts/ahab/policy-check.sh <container.bin> <policy file> [<manifest>]
```

This is the host side of cases C2, C3 and C4 of
[secure-boot-test-plan.md](secure-boot-test-plan.md) (§4, §5, §7 item 2). It parses the container
with `nxpimage ahab parse` (pinned SPSDK) and fails unless the container's SRK table hash,
`used_srk_id`, `srk_revoke_mask` and `fuse_version` agree with the policy file. It prints one
`policy: <field> OK` or `policy: <field> MISMATCH (container X, policy Y)` line per field, then
`policy: OK` (exit 0) or `policy: FAILED` (exit 1). A missing, empty or unreadable policy file, a
missing field in either input, or a container that does not parse FAILS; nothing is skipped. Every container in the input is checked against the policy (not only the first), as the test plan's "each container" requires. Every SRK table hash SPSDK writes (one file per distinct table; one in all when the containers share a table) must equal the policy's single SRK hash, and at least one must exist. It
touches no board, fuse or key, and deletes the `.bcf` files unread.

The policy file is plain `KEY=VALUE` lines, parsed by the script and never sourced. `#` comments and
blank lines are allowed. An unknown key, a repeated key or a missing key is an error.

| Key | Value | Check |
|---|---|---|
| `SRK_TABLE_HASH` | hex | equal to the container's SRK table hash (case-insensitive, full length) |
| `USED_SRK_ID` | integer | equal to `used_srk_id` |
| `SRK_REVOKE_MASK` | hex or integer | equal to `srk_revoke_mask`, compared numerically |
| `FUSE_VERSION_MIN` | integer | every OEM container's `fuse_version` is at or above it |
| `NXP_CONTAINER_SHA256` | 64 hex, or the environment variable of that name | the pin an nxp manifest position says `policy` for |
| `NXP_SRK_TABLE_HASH`, `NXP_USED_SRK_ID`, `NXP_SRK_REVOKE_MASK`, `NXP_FUSE_VERSION_MIN` | optional | the vendor record, compared with the nxp container only |

Accepted ranges, for the policy file and the container alike (hex `0x..` or decimal, checked before any arithmetic; anything else is a policy error, exit 1): `USED_SRK_ID` 0..3, `SRK_REVOKE_MASK` 0..0xF, `FUSE_VERSION_MIN` 0..255.

Every container the image holds is accounted for, and the check fails closed (provisional, pending #12):

- An `srk_set: none` container fails; so does an entry or `srk_set` the check cannot classify.
- The manifest (third argument, default `scripts/ahab/container-manifest.yaml`) lists the containers in order. A missing, empty or malformed manifest fails; so does any container count, order or role that differs from it. Fields: `containers:` is a list; each entry has `role: nxp|oem`. An `oem` entry has `images:`, the exact ordered entries its container must carry, each `core_id` and `image_type` as SPSDK parses them (the OEM boot container carries `cortex-m7-1`/`executable`). An `nxp` entry has `sha256:`, 64 hex digits or `policy` (from `NXP_CONTAINER_SHA256`, policy file first, else environment); the vendor binary and digest are not in the repository.
- Each OEM container is checked against the OEM policy: the hash of its own SRK table (SPSDK parser and SRK-hash API), `used_srk_id`, `srk_revoke_mask`, `fuse_version`. The SRK hash files stay a cross-check (their number is the OEM count or one, and each equals a computed OEM table hash).
- The nxp container (SPSDK's merged binary container) is held to its pinned sha256, and to the vendor record keys if given; the OEM values are not applied to it.
- Each OEM container carries exactly its role's image entries; a missing M7 image or swapped OEM containers fail.
- Every non-zero byte of the image and of each nxp binary container must lie in a parsed container's header, signature block or referenced image; otherwise the check fails naming the offset.
- An image with no OEM container fails.

SPSDK 3.13.0 gives `used_srk_id`, `srk_revoke_mask` and `fuse_version` in `parsed_config.yaml`, and
the SRK table hash as `ahab_oem0_srk0_hash.txt` in the same output directory (the same file name
`nxpimage ahab export` writes), so no hash algorithm is chosen here.

No policy values are committed. The real values need IMX95RM and the Security Reference Manual
(not in `docs/references`) and `oem-key-provisioning`: they stay MISSING (test plan §9 Q3).
`test/ahab_policy_test.sh` (`make ahab-policy-test`, also in `make test`) writes a policy file from
a test-PKI container's own parsed values in a temp directory, and checks the passing and each
failing case.

This is a proposal, pending the owner's approval of where the real policy file lives (recommendation
(a) of test plan §9 Q3: a reviewed policy file, whose absence fails the check). SPEC and the test
plan stay the owner's.

## MISSING

## Tamper matrix

```sh
make ahab-tamper-test
```

`test/ahab_tamper_test.sh` (also in `make test`) builds one M7 test-PKI container in a temp
directory, writes a tampered copy per case and runs `scripts/ahab/sign-test.sh verify`
(`nxpimage ahab verify`, SPSDK 3.13.0) on it. It covers C2b, C5b and C6 of
[secure-boot-test-plan.md](secure-boot-test-plan.md) (§4, §7 item 1); C1 and a payload byte are in
`test/ahab_sign_test.sh`. Offsets are derived from the container: the signature block offset is the
u16 at byte 12, the SRK table array starts 16 bytes after it, the image entry's hash is found by
searching the entry for the `sha384sum` of the payload. Nothing is committed: no key, container or
policy.

| Case | Change | SPSDK 3.13.0 `verify` |
|---|---|---|
| C6a | truncated to half its size | rejected (exit 1), no traceback |
| C6b | truncated by one byte | rejected, no traceback |
| C6c | truncated to 0 bytes; to the header only | rejected, no traceback |
| C5b | one byte of the image entry's hash | rejected |
| C5b-ii | payload changed, entry hash recomputed, signature untouched | rejected |
| C2b | used SRK index in the SRK data record 0 to 1, signature untouched | rejected |
| SRK table | one byte of the SRK table | rejected |

Not detected by verify: none observed in these cases. A rejection says only that verify failed, not
which check caught it. Verify checks the container against its own SRK table, so it does not stand in
for the fuse and policy checks (`scripts/ahab/policy-check.sh`).

- The container's anti-rollback `fuse_version` and header version for a real device, and a real
  device's SRK hash fuse values. Their sources (IMX95RM, the i.MX 95 Security Reference Manual)
  are not in `docs/references`. See the comments in `container.yaml`.
- HSM signing (go-xkms custody) and the CST cross-check are out of scope here.
