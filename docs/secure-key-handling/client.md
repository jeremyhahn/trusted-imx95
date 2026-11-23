# secure-key-handling: the enclave HSM API client

> **Status: PROVISIONAL, awaiting the owner's answer** · Scope: trusted-imx95 · Last verified: 2026-11-23

A minimal key-store client over the EdgeLock enclave's HSM API, built from NXP's public secure-enclave user library
at a pinned revision. It follows [architecture.md](architecture.md). Every default below is provisional and can be
reversed without losing the work.

## The default taken, and the question left open

The client runs on the Cortex-A55 Linux side. That is a **provisional default**; the owner's question is still open:
does the Cortex-A55 Linux side or the Cortex-M7 call the HSM API
([architecture.md](architecture.md#open-questions), question 1). The policy code does not depend on the answer: it
reaches the library through an ops table, so a Cortex-M7 caller would reuse the policy and replace the binding.

## The library, pinned

[`secure-key-handling/ele-lib.lock`](../../secure-key-handling/ele-lib.lock) pins NXP's public library
(`NXP/imx-secure-enclave`) by repository, commit and the SHA-256 of `git archive --format=tar` of that commit.
The revision is the one the BSP's recipe uses: the `imx-secure-enclave%.bbappend` in meta-imx, at the commit
[platform-image/manifest.lock](../../platform-image/manifest.lock) names, sets `SRCREV`, and meta-freescale's
`imx-secure-enclave_git.bb` builds it with `PLAT = "ele"` for the i.MX 9 machines. The toolchain is the Arm GNU
Toolchain pin of [secure-world/bsp.lock](../../secure-world/bsp.lock), read by name from that file.

- `make ele-lib-check` (the same check, with its refusals, runs in `make test`) parses the lock and the toolchain pin offline and refuses a short
  commit, a bad digest, an `UNREAD` value, a missing or repeated name, a non-https repository and a toolchain lock
  outside the tree.
- `make ele-lib` fetches the commit outside the checkout, checks the commit and the archive digest, checks the
  toolchain digest before it unpacks it, and cross-builds the library part for aarch64 (`make PLAT=ele libs`; the
  library's tests and tools need OpenSSL and mbedTLS for the target and are not built). It fails closed on a
  mismatch and checks the output is AArch64. It needs the network and is not in CI.

Vendor documentation is not copied here; the library's public headers are the interface, and RM00284 is cited by
section only.

## The client and its policy

[`secure-key-handling/client/`](../../secure-key-handling/client/ele_client.h) holds a small C client: key generate,
sign and delete. No key material crosses its interface: a key is a numeric id and sign returns only a signature.

An update or delete reports **rollback-protected** only when both the strict-operation flag and the
monotonic-counter flag were sent and acknowledged for that same operation, with no counter warning and the counter
split configured (owner decision 241; [architecture.md](architecture.md#key-store-rollback-protection)).

| Flags sent and acknowledged | No counter warning, split configured | Result |
|---|---|---|
| Both | yes | rollback-protected |
| Both | no (warning, or no split) | the call fails; state kept: committed, not rollback-protected |
| Strict only | n/a | committed, not rollback-protected |
| Monotonic counter only | n/a | not committed (the call fails) |
| Neither | n/a | not committed (the call fails) |

The table is for an update that can carry both flags (key generate). A delete cannot, so it is at best committed, never
rollback-protected ([below](#delete-is-never-rollback-protected-a-gap-for-the-owner)).

**The call fails, and the command exits nonzero, whenever the update is not what was asked for:** a counter warning
(`HSM_KEY_STORE_COUNTER`: accepted, counter not advanced, so the prior blob can still be replayed;
[architecture.md](architecture.md#key-store-rollback-protection)), a missing strict acknowledgement, or a send of both
flags that is not rollback-protected (counter not acknowledged, or the split not confirmed). The commit state is still
returned and printed (`update refused (...)`), so the diagnostic is kept. A strict-only send (a delete) succeeds on the
strict acknowledgement, as committed and not rollback-protected.

The host tests (`test/ele_client_test.sh`, run by `make test`) cover all four combinations, a counter warning, a
missing split and an acknowledgement of one flag only, against a stub that holds no key. The default client sends
both flags.

## Delete is never rollback-protected (a gap, for the owner)

The library's key delete takes the strict-operation flag only: `op_delete_key_args_t` has a key identifier and
flags, and its one flag is `HSM_OP_DEL_KEY_FLAGS_STRICT_OPERATION` (`internal/hsm_delete_key.h`). There is no
monotonic-counter flag on a delete, so the enclave can never acknowledge both flags for one. Decision 241 is not
weakened: the client sends the strict flag alone on a delete and reports every delete as committed but **not
rollback-protected**, and a test asserts it. The consequence is that a deleted key can come back if the key store is
rolled back to an earlier copy. **Provisional; this is the owner's to decide** (for example: accept it, delete by
another route, or ask NXP). It is recorded here, not solved.

## What is bound

[`ele_hsm_backend.c`](../../secure-key-handling/client/ele_hsm_backend.c) is the ops-table backend over the pinned
library's HSM API (`include/hsm/hsm_api.h` and `include/hsm/internal/*.h` at the pinned commit), built with
`PSA_COMPLIANT` as the library's `PLAT=ele` build is (its build log). It calls:

- session and key store: `hsm_open_session`, `hsm_open_key_store_service` (flags `LOAD`, `STRICT_OPERATION`,
  `MONOTONIC`; never `CREATE` here), `hsm_close_key_store_service`, `hsm_close_session`;
- key management: `hsm_open_key_management_service`, `hsm_generate_key` (flags `STRICT_OPERATION` 1<<7 and
  `MONOTONIC_COUNTER` 1<<5; `PLAINTEXT_KEY` is never set, so no key leaves the enclave), `hsm_delete_key` (strict
  only), `hsm_close_key_management_service`;
- signing: `hsm_open_signature_generation_service`, `hsm_generate_signature` (ECDSA P-256 with SHA-256),
  `hsm_close_signature_generation_service`.

The return code maps to the acknowledgement: `HSM_NO_ERROR` acknowledges the flags sent; `HSM_KEY_STORE_COUNTER` is a
counter warning (accepted, counter not advanced: strict acknowledged, counter not); any other code fails the call.
The counter split cannot be read through these calls, so the backend reports it configured only when the caller sets
`counter_split_confirmed` after confirming it on the device. It is false by default, so nothing is reported
rollback-protected on an unconfirmed split.

**The `ele_client` command** (`ele_client [--split-confirmed] <store-id> <nonce-fd> gen | sign <key-id> <msg> | del
<key-id>`) is the front end of this backend; it widens the row beyond the host stub, at the coordinator's resume brief
2 ([plan](../plans/162.md)). The nonce is an access credential for the key store, so it is read from a file
descriptor (`3<nonce-file`; a terminal is refused) and never from the arguments, where a process listing would show
it. Every number (store id, descriptor, key id) is parsed strictly (decimal or `0x` hex, no sign, no space, no
trailing character, at most `UINT32_MAX`) and the whole command line is checked before any HSM service is opened, so
`del 4294967297` is refused rather than truncated to key 1. `--split-confirmed` is the caller's statement that the
counter split is configured on the device; without it nothing is rollback-protected, and generate is refused before any
HSM call is made (a test asserts zero generate calls on the double).

**`sign` output.** `sign` writes the signature bytes to stdout as one line of lowercase hex, or as raw bytes with
`--raw` (`ele_client --raw <store-id> <nonce-fd> sign <key-id> <msg>`; `--raw` is refused on any other command). A test
compares the output with the double's known signature bytes exactly.

**Nonce handling.** The command first sets the process non-dumpable (`prctl(PR_SET_DUMPABLE, 0)`) and `RLIMIT_CORE` to
0. The nonce is held in one buffer locked with `mlock` where available. `ele_hsm_open` takes a pointer to it, and the
buffer, the library argument structure's `authentication_nonce` copy and the text buffer it was read through are erased
with a non-elidable volatile erase (`ele_secure.h`) on every exit path, success or error. A test hook shows the buffer
is zero after `ele_hsm_open` returns, on success, a key-store open failure and a session open failure.

**Contract evidence and tests.** `scripts/ele-lib-build.sh` compiles `ele_hsm_consts_check.c`, whose `_Static_assert`s
pin the flag and return-code values to the library's headers (a mismatch fails the build); that is the evidence the
constants match the pinned library's contract. `test/ele_client_test.sh` also builds the shipped backend against
`ele_hsm_fake.c`, a test double of the library's calls compiled on the same headers, and checks the request flags it
sends (key store `LOAD`, `STRICT_OPERATION` and `MONOTONIC`, never `CREATE`; generate strict and counter, never
`PLAINTEXT_KEY`; delete strict only) and its translation of `HSM_NO_ERROR`, `HSM_KEY_STORE_COUNTER` and another code,
and runs the command over the double. These need the fetched source, `ELE_SRC`. In the toolchain
image it comes from the Dockerfile's `ele-src` stage, which runs `scripts/ele-lib-build.sh --src-only`: the commit and
archive digest pinned by `ele-lib.lock` are checked, and the source is unpacked to `/opt/ele-src` (`ENV ELE_SRC`).
Outside the image, set `ELE_SRC=<work>/src` from a `--src-only` run. With `ELE_SRC` unset the test prints that these
parts were skipped (`skip: ELE_SRC unset`), unless `REQUIRE_ELE_SRC=1` is set, in which case it fails instead. The
toolchain image sets `REQUIRE_ELE_SRC=1` beside `ELE_SRC`, so the GitHub CI job that runs `make coverage` in that image
(`scripts/in-toolchain-image.sh`) fails when the source is missing; `make test` and `make coverage` themselves do not set
it, so they skip on a host without the image. `CI=true` alone does not require it. The build script runs the constants check on every build. Whether the firmware acknowledges the flags as assumed is board validation, below.

`scripts/ele-lib-build.sh` then cross-builds `ele_client` for aarch64 and links it
against the built `libele_hsm`; the script checks the result is AArch64 and needs that library. `test/ele_client_test.sh` runs the same
check when `ELE_SRC` names the fetched source, and shows that a wrong value fails it. No vendor header or text is
copied into this repository.

## What is left open

- **Owner:** which side calls the HSM API (above); the delete gap (above); the SE051's role.
- **Needs the board, none run here:** the client was built and linked, never run. The key-store identifier, nonce,
  the key store's creation and its counter split are provisioning (`oem-key-provisioning` row); the structure
  members and key attributes the backend sets (ECC NIST P-256, persistent, sign-hash) are taken from the library's
  headers by compilation and are untested against the enclave. Whether the i.MX 95 firmware acknowledges the two
  flags as the architecture assumes stays **unconfirmed**
  ([architecture.md](architecture.md#key-store-rollback-protection)).
- **The Linux path to the enclave** (the library's daemon and device, and the TrustZone configuration) is under
  Missing in [architecture.md](architecture.md#missing).
- The counter fuse split is provisioning, the `oem-key-provisioning` row's; nothing here sets it.
