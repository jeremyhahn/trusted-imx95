# secure-key-handling: the enclave HSM API client

> **Status: the Linux-side client is the chosen design (owner ruling 1234); other defaults below stay PROVISIONAL, awaiting the owner's answer** · Scope: trusted-imx95 · Last verified: 2026-11-23

A minimal key-store client over the EdgeLock enclave's HSM API, built from NXP's public secure-enclave user library
at a pinned revision. It follows [architecture.md](architecture.md). The calling side is decided; every other default
marked provisional below can be reversed without losing the work.

## The calling side, and what is left open

The client runs on the Cortex-A55 Linux side: owner ruling 1234 decided that the Cortex-A55 Linux side calls the HSM
API. The policy code reaches the library through an ops table. The owner's counter-acknowledgement question (Q2) is
not decided by that ruling and stays open; its default is (c), fail closed (provisional): no update is reported
rollback-protected.

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
returned and printed (`update refused (...)`), so the diagnostic is kept. A generate the enclave accepted leaves a key
even when its update is refused (a counter warning): its identifier is returned with the failure and the command
prints it (`key N was generated and is NOT rollback-protected`) so it can be reconciled or deleted, not presented as a
protected key. A strict-only send (a delete) does **not** succeed:
`ele_delete_key` returns failure unless the counter is acknowledged, which the binding never reports (owner Q2). The
delete may nevertheless have taken effect on the device while failing the rollback policy, so a caller must treat the
key as possibly deleted; the commit state is returned for that.

The host tests (`test/ele_client_test.sh`, run by `make test`) cover all four combinations, a counter warning, a
missing split and an acknowledgement of one flag only, against a stub that holds no key. The default client sends
both flags.

## A lost result after the update started is an unknown outcome

The key-store child writes a one-byte marker to the parent just before the vendor update call (`hsm_generate_key` or
`hsm_delete_key`): `S` = started; `N` precedes a result when no update call was started. The parent tells two cases apart:

- **Before the marker** (the child died, exited nonzero or sent a short result before the update call, or any setup
  step failed): a plain failure, state `not-committed`, exit 1 (or 2 for setup).
- **After the marker** (the child died, exited nonzero, or the result was short or unreadable, or `waitpid` failed, **or
  a complete result carries status -1 or any vendor error code**): a
  generate or a delete returns `ELE_OP_UNKNOWN`, the client sets `ELE_OUTCOME_UNKNOWN` (`outcome-unknown`), and the CLI
  prints that the result was lost, that the key store may have changed and that the operator must check it before any
  retry, then exits **3**. Success is never reported and nothing is retried. A sign is not an update and stays a plain
  failure. If the marker itself cannot be written, the update is not run.

Exit codes: 0 success, 1 failure (or an update refused), 2 usage or setup (including a lock or nonce read failure), 3
outcome unknown (the key store may have changed; check it before retrying). Tests: the backend test splits the
child-killed, exits-nonzero, short-result, status -1 and vendor-error-code cases into before-marker (plain failure) and
after-marker (unknown) cases for generate and delete, and `test/ele_client_test.sh` drives exit 3 end to end.

**A generate that returns `HSM_NO_ERROR` with the key id still at the zero sentinel is an unknown outcome too.** A
success reply that names no key cannot be reconciled or deleted by id, so the child leaves status -1 (exit 3,
`ele_hsm_backend.c`, `op_service`) and never reports a committed key. The only other result path that reads an
identifier from a success reply is sign, which reads the signature and its size, not a key id (a size other than 64 is
refused); delete takes the id from the caller. Tests: `ele_hsm_backend_test.c` and `test/ele_client_test.sh` use the
fake's `ELE_FAKE_ID_ZERO` to return `HSM_NO_ERROR` with id 0 and assert the unknown outcome and exit 3.

**Why every error after the marker is unknown.** The vendor may report a lost device reply as an error after the
update was applied, so the error code does not tell applied from not applied. The classification therefore does not
depend on the vendor's error mapping: after the marker, only a verified success (status 0 in a complete result of a
normal child exit) is anything but unknown. `ELE_NOT_COMMITTED` stays for failures before the marker.

*Vendor call path (citations only, pinned commit 463845060a79).* The update runs through
`src/common/hsm_api/hsm_key_generate.c:hsm_generate_key` and `src/common/hsm_api/hsm_delete_key.c:hsm_delete_key`, which build
the message in `src/common/sab_msg/sab_key_generate.c` and `src/common/sab_msg/sab_delete_key.c` and send it through
`src/common/sab_msg/sab_process_msg.c:process_sab_msg`; the sign runs through `src/common/hsm_api/hsm_sign_gen.c`.

*What a dispatched message whose reply is lost, short or malformed returns* (traced by lane 162-skh-next2 on the
fetched tree, SHA-256 matching `ele-lib.lock`; paths relative to `src/common/` unless given in full). Key generate,
delete and signature generate are not in the v2 error-handling list (`sab_msg/sab_process_msg.c:105-157`), so they take
the legacy path:

- Each API call starts with `rsp_code` set to `SAB_NO_MESSAGE_RATING` (0x00) (`hsm_api/hsm_key_generate.c:26`,
  `hsm_api/hsm_delete_key.c:25`, `hsm_api/hsm_sign_gen.c:122`), maps the return of `process_sab_msg` and then `rsp_code`
  through `sab_rating_to_hsm_err` (generate `:47`, `:54`, `:61`, returned at `:67`; delete `:42`, `:49`, `:55`, returned at
  `:62`; sign `:140`, `:147`, `:153`, returned at `:159`).
- **Lost reply, driver failure, wrong length.** `plat_os_abs_cmd_snd_rcv_rsp` fails, or the received length is 0 or
  neither the expected length nor the header's size (`src/plat/ele/ele_utils.c:198-209`, `val_rcv_rsp_len` at `:85-107`):
  `process_sab_msg` returns `SAB_NO_MESSAGE_RATING` (`sab_msg/sab_process_msg.c:271-278`) and `rsp_code` is not assigned.
  Rating 0x00 is not the success tag, so `sab_rating_to_hsm_err` takes the error map, whose index 0 is
  `HSM_GENERAL_ERROR` (`src/plat/ele/include/plat_err_def.h:14`).
- **Cancelled wait** returns `SAB_SHE_GENERAL_ERROR_RATING` 0xDC (`sab_msg/sab_process_msg.c:288`,
  `sab_msg/include/sab_msg_def.h:199`); **a long reply failing its CRC** returns `SAB_NO_MESSAGE_RATING`
  (`sab_msg/sab_process_msg.c:292-302`). Both are errors.
- **Short reply accepted by its header size** (`src/plat/ele/ele_utils.c:202-211`): the response buffer was zeroed
  (`sab_msg/sab_process_msg.c:175`) and `rsp_code` is the reply's status word (`:313`). A one-word reply gives status 0,
  an error. A short reply that carries the device's success tag runs the response handler on zero-filled fields, and the
  legacy path sets the result to the success tag whatever the handler returned (`:346-350`; the handlers do not check
  the length), so the API returns `HSM_NO_ERROR`. That needs a success-tagged word from the device itself; the fields
  read as zero: the sign handler leaves `exp_signature_size` 0, which the backend refuses (it needs 64), and a generate
  or delete with `HSM_NO_ERROR` is refused by `fill_ack` anyway (the counter is never acknowledged).
- **No stale `exp_signature_size`.** The backend zeroes the argument structure before the call and accepts a signature
  only if the call returns `HSM_NO_ERROR` and `exp_signature_size` is 64, and each child runs one operation, so a size
  left over from an earlier call cannot be read.

Result: no path returns `HSM_NO_ERROR` without a success-tagged reply word from the device, and every return code
after the marker is already the unknown outcome (exit 3), so no code change follows. The classification after the
marker stays "unknown for any non-verified result". **Open (narrowed):** the success tag's value comes from the kernel
driver by ioctl (`src/plat/ele/ele_os_abs_linux.c:78`), not from this tree; the trace assumes it is neither 0x00 nor
0xDC, which only the driver or a board can confirm.

**The nonce is parsed in the locked slot.** The nonce does not go through the generic `ele_parse_u32`, whose running
value lives in an ordinary automatic variable that is never erased. A dedicated parser, `ele_nonce_parse`, applies the
same strict-hex rules and accumulates straight into the locked slot through a volatile pointer; its one other local
(a digit) is erased on every path, and the slot value is zeroed on every refusal. A test counts calls to the generic
parser and shows the nonce path makes none. Stack residue in the optimized binary is minimised by this, not proven
absent.

## Fail-closed default (owner question open)

**Proposed, pending owner approval; the owner's to decide (TENANT ASK 5, Q2).** This policy is not in
[SPEC.md](../SPEC.md): ruling 1234 approved only the Linux calling side. The code's conservative default keeps generate
and delete failing closed until the owner answers. This section is the one statement of it; the other sections link here.

**What the pinned library cannot show.** At the pinned commit, a success-tagged reply that carries a warning rating is
mapped to `HSM_NO_ERROR`: `hsm_api/hsm_utils.c:24-48` logs the rating (counter-warning rating 0x10 included) and
`:223-224` takes that branch for a success-tagged reply, so `:228` returns `HSM_NO_ERROR` (the ELE map,
`src/plat/ele/include/plat_err_def.h:289`, names success rating 0x10 `HSM_KEY_STORE_COUNTER`; second reading,
lane 162-skh-next2). No reply field exposes the counter acknowledgement, and the library's delete
has no counter flag. So `fill_ack` (`ele_hsm_backend.c`) never sets `counter_acked`, and `HSM_NO_ERROR` is not taken as
the acknowledgement.

**What that means in production.** Generate and delete never report success through the shipped backend:

- the strict flag acknowledged and the counter acknowledgement unprovable: exit 1, nothing on stdout, and on stderr the
  key id, `NOT rollback-protected` and the fixed reason `the pinned library cannot prove the monotonic-counter
  acknowledgement (fail closed; owner question open)`;
- any other return code after the started marker (`HSM_KEY_STORE_COUNTER` included), a lost result or a dead child:
  exit 3, an unknown outcome (see above).

**Sign is unaffected.** It is not a key-store update, so the counter acknowledgement does not gate it.

**The tests.** `ele_hsm_backend_test.c` (`fail_closed_default`) drives generate and delete through the shipped backend
over the fake for `HSM_NO_ERROR`, `HSM_KEY_STORE_COUNTER` and three other codes, with the child dying before the started
marker and not dying: the return is nonzero, the state is never rollback-protected and the counter is never reported
acknowledged. `test/ele_client_test.sh` runs the CLI over the shipped backend plus the fake with `HSM_NO_ERROR`: gen and
del exit 1 with empty stdout and the three stderr items, and `rollback-protected` never appears without `NOT`. The same
script checks that the `ele_client` link line in `scripts/ele-lib-build.sh` names neither `ele_hsm_cli_double.c` (the
test-only double that answers every update as committed) nor `ele_hsm_fake.c`, shows the check refuses a copy of the
script with the double added, and checks with `nm` that a host CLI built the shipped way has none of the double's symbols.

**Two options not taken** (no recommendation; both are the owner's to choose):

- (a) A build-time patch of the pinned library, outside the tree, to surface the raw SAB rating.
- (b) Accept strict plus `HSM_NO_ERROR` as a committed but not rollback-protected success.

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

The return code maps to the acknowledgement: `HSM_NO_ERROR` acknowledges the strict flag sent; any other code, `HSM_KEY_STORE_COUNTER` (0x10) included, is
not a result the client can vouch for: it comes from an error-tagged response, which does not show whether the update
was applied. After the started marker it is an unknown outcome for generate and delete (exit 3, "the key store may have
changed; check it before retrying"), and generate never reports a key. Before the marker an error stays a plain failure.
The result table above for a counter warning therefore applies only to a library that exposes it separately; the
binding does not.
**The counter flag is never reported acknowledged (fail closed, provisional).** The library cannot show the counter
acknowledgement, so the backend reports no operation rollback-protected; see
[Fail-closed default (owner question open)](#fail-closed-default-owner-question-open).
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
0. The nonce is held in one slot, an anonymous mapping of its own, locked with `mlock` for its whole life: when the lock
fails (for example `RLIMIT_MEMLOCK`) the command stops before it reads the credential, and the slot is unlocked only
after it is erased (locks are per page, so a shared page would be unlocked under a live credential). A `gen` without
`--split-confirmed` is refused straight after the arguments are parsed, before the nonce is read and before any HSM
call (session, key store or service). `ele_hsm_open` takes a pointer to the slot's value, and the
buffer, the library argument structure's `authentication_nonce` copy and the text buffer it was read through are erased
with a non-elidable volatile erase (`ele_secure.h`) on every exit path, success or error. A test hook shows the buffer
is zero after `ele_hsm_open` returns, on success, a key-store open failure and a session open failure.

**Isolation, one child per operation.** The library keeps a stack copy of the nonce that this client cannot reach:
`process_sab_msg` (`src/common/sab_msg/sab_process_msg.c:170`) declares the `cmd[]` word buffer on its stack,
`prepare_sab_msg` fills it (`sab_process_msg.c:216`, from `sab_msg/sab_key_store.c:32`,
`cmd->password = op_args->authentication_nonce`), the message is sent from it (`:268`) and the function returns (`:368`)
without wiping it. No vendor source is patched or copied. Each CLI operation that opens the key store (sign, generate,
delete) runs as one unit in a single forked child (`run_op`, `ele_hsm_backend.c`): open the session, open the key store
with the nonce, open the service, do the operation, close all of them, write one fixed-size result and `_exit()`. The
parent holds no session or key-store handle and never calls the vendor library; `ele_hsm_open` only locks memory and
records the store id and the caller's nonce slot (one operation per open).

- ordering: `mlockall` is not inherited across `fork`, so the child never inherits the credential. Before the fork the
  parent moves the nonce into its own page (locked under the parent's `mlockall`, marked `MADV_WIPEONFORK`, so it is
  zero in the child) and wipes the caller's slot. The child sets `PR_SET_DUMPABLE` 0 and calls `mlockall` (exit 3 if
  that fails, before saying anything), then writes one byte `L` to the parent. Only after reading `L` does the
  parent write the nonce over a pipe into the child's local, already locked, variable, wipe its page and close the pipe.
  A child that cannot lock gets nothing and the operation fails closed. The backend test logs the events in order
  (child locked, parent sending, child received) and checks a child that fails to lock never sees the nonce;
- the child erases its nonce and arguments copies, scrubs its stack after the key-store open, and writes the result
  (status, and for sign the 64-byte signature) to the same pipe back;
- the parent accepts only a normal exit 0, exactly one full-size result with status 0, and for sign a length of 64. A
  signal, a nonzero exit, a short or long result, a wrong signature length, or a failed `pipe`, `fork`, `read` or
  `waitpid` fails the operation closed. Generate and delete still fail closed on the counter acknowledgement. The
  parent first locks its own memory (`ELE_HSM_OPEN_NOLOCK`, exit 2, nonce erased and never handed over, when that fails).

**What this covers.** The vendor `cmd[]` frame exists only in the child. When the child exits its pages are released, and
the kernel hands out pages zero-filled: an anonymous mapping is "initialized to zero" (`mmap(2)`, `MAP_ANONYMOUS`), and
the kernel clears a page before it reaches another process. The credential is never in a swappable or dumpable page (the
child is locked and non-dumpable). The parent process never holds a vendor copy at all, so a later core, `ptrace` or
stack inspection of the long-lived process finds none. **What it does not cover:** a freed physical page keeps its bytes
until the kernel reuses and zeroes it (unless the host boots with `init_on_free`, which is not assumed), so root or a
physical-memory attacker in that window still sees them; registers and the device driver's own buffers are out of reach;
the in-process stack scrub that remains (16 KiB, in both processes) is defence in depth and **is not evidence of erasure**
of the vendor's copy. A hook test shows the child's arguments copy is zero and the parent's buffer is zero; it cannot
show what the vendor frame held.

**Nothing runs in the parent.** Generate, sign and delete run in the same child as the key-store open, so no handle
crosses a process boundary: the session and key-store handles are created and closed inside the one child.

**Every key-store update fails closed.** `ele_generate_key` and `ele_delete_key` both report success only with the
counter acknowledgement established (counter acknowledged, no warning, split configured), which the binding never
establishes. The reason, the outcomes and the tests are in
[Fail-closed default (owner question open)](#fail-closed-default-owner-question-open). A delete exits 1 with
`update refused (...); key N delete is NOT rollback-protected`, exactly as a generate does; the delete may have taken
effect and its old key-store blob may stay replayable. Memory-lock tests: the open is refused when the lock
fails (a stub, and the real `mlockall` in a child with `RLIMIT_MEMLOCK` 0); `test/ele_client_test.sh` raises the soft
memory-lock limit to the hard one and fails, naming the limit, on a host where the lock still cannot be taken. Isolation
tests (`ele_hsm_backend_test.c`, the double records into shared memory): the vendor call runs in a different pid; a child
killed by a signal, a nonzero child exit, and a short result (0 and 7 of 8 bytes) each fail the open; the parent's nonce
buffer is zero after every outcome; the 64-byte signature length check is unchanged.

**A result that cannot be written.** `gen` and `del` check `printf` and `fflush`. When stdout cannot be written (a full
disk, a closed pipe) the command exits 1 and prints the key id and its commit state on stderr
(`key N was generated, commit state S`, `key N was deleted, commit state S`), because the HSM operation has already
happened. A test sends stdout to `/dev/full` and asserts exit 1 and the key id on stderr. The command ignores `SIGPIPE`
before any HSM call, so a reader that has gone away reaches the same checked path (`EPIPE`) instead of killing the
process after the operation; a closed-reader test asserts exit 1 and the key id on stderr. Because the binding never
reports a rollback-protected generate (above), a refused `gen` already names its key id on stderr; the checked
stdout path of `gen` is kept for a backend that can acknowledge the counter.

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

## Reproduce the vendor read

Vendor source is never copied into this repository. A reviewer fetches the pinned tree outside the checkout:

- upstream: `https://github.com/NXP/imx-secure-enclave.git`, commit `463845060a79dd9a6d39db3b3d8dff60225b9dfd`;
- archive digest (SHA-256 of `git archive --format=tar` of that commit, `ELE_ARCHIVE_SHA256` in
  [`ele-lib.lock`](../../secure-key-handling/ele-lib.lock)):
  `31f7baedab12e5c5b1efe088d609243e63e5992bea9701082f0942fc4c90c079`;
- the command, which fetches the commit, checks the commit and the digest, and fails closed on a mismatch:

```
scripts/ele-lib-build.sh --work <dir> --src-only
```

`<dir>` must be a new or empty directory outside the checkout (the script refuses one inside it or above it); the
source is then `<dir>/src`. `ELE_SRC=<dir>/src REQUIRE_ELE_SRC=1 bash test/ele_client_test.sh` runs the backend tests
against it.

**Status of the third reading (lane 162-skh-fix-r4).** The fetch above was repeated and matched the pinned digest. This
lane could not read the fetched files: its read guard refuses any code path outside the worktree. So no new "read twice"
mark was added here for the PSA argument semantics, the response decoding or the nonce-copy assumptions; the marks in the
table below are those of lane 162-skh-next2, unchanged, and the rows that the guard blocked are still waiting for a
reader who can open `<dir>/src`.

## The library contract the backend relies on

Paths are in the pinned tree (`ele-lib.lock`), under `src/common/` unless stated; line numbers are 1-based and were
re-checked against the fetched source. Nothing here is copied from it. "Provisional" means the source does not settle it
and only the board can. "Read twice" means a second reader (lane 162-skh-next2) re-read the row in a tree fetched by
`scripts/ele-lib-build.sh --src-only`, whose archive SHA-256 matched `ELE_ARCHIVE_SHA256` in `ele-lib.lock`.

| Behaviour the backend assumes | Where in the pinned source | Status |
|---|---|---|
| `PLAT=ele` builds with `-DPSA_COMPLIANT`, so the PSA branches of the message code are the ones compiled | `src/plat/ele/ele.mk:41` | read twice |
| A success-tagged response with a warning rating maps to `HSM_NO_ERROR` (the warning is only logged), so a counter warning on a success-tagged reply is invisible to the caller | `hsm_api/hsm_utils.c:223-224`, `:24-48` (the map lookup at `:26`; every case falls through to `HSM_NO_ERROR` at `:48`); success rating 0x10 is `HSM_KEY_STORE_COUNTER` in `src/plat/ele/include/plat_err_def.h:289` | read twice |
| `HSM_KEY_STORE_COUNTER` reaches the caller only from an error-tagged response | `hsm_api/hsm_utils.c:226` (error path, through the error map at `:54`), `:118` (the error case); the result is returned at `:228` | read twice |
| No per-flag acknowledgement is exposed; "both flags acknowledged" is inferred from `HSM_NO_ERROR` | no field in the argument structures; see the two rows above and the next row | **provisional** (the inference itself; the absence of a field is read twice, next row) |
| No reply field, accessor or delete flag carries the counter acknowledgement for one operation | searched `include/hsm/`, `src/common/hsm_api/`, `src/common/sab_msg/` and `include/common/` for monotonic, counter, rollback and acknowledge: `include/hsm/internal/hsm_delete_key.h:29-34` (key id and flags; the only flag, strict, at `:54`); `include/hsm/internal/hsm_key_generate.h:28-30` (the counter flag is a request, documented as completing only when the counter is updated); `include/hsm/internal/hsm_utils.h:68-70` (the `HSM_KEY_STORE_COUNTER` code). Two indicators that are not a per-operation acknowledgement: `hsm_get_info` returns the device-wide `chip_monotonic_counter` (`include/common/get_info.h:25`, filled at `src/common/sab_msg/sab_get_info.c:57`), a value, not a per-call result; `hsm_dev_mono_counter` (`include/hsm/internal/hsm_dev_mono_counter.h:17-57`) partitions counter fuse words, a provisioning step, never run here. The counter-exhausted warning is documented as returned on each key-store export to the NVM (`include/hsm/mainpage.h:71`, `:148`); the export status is handled on the NVM manager's path (`src/common/sab_msg/sab_storage_export_finish.c:43-52`), not in the client's reply | read twice; for the owner (see "What is left open") |
| Generate writes the key id into the caller's variable whatever the rating | `sab_msg/sab_key_generate.c:94-95` (the handler does not check the rating); the response handler runs at `sab_msg/sab_process_msg.c:333` | read twice |
| A successful sign does not update `signature_size`; the PSA build stores the response size in `exp_signature_size` instead | `sab_msg/sab_sign_gen.c:178` | read twice |
| The signature is 64 bytes (P-256 `r\|\|s`) | not stated at the call; the reply carries a 16-bit `signature_size` (`sab_msg/include/sab_sign_gen.h:75-82`) and the backend refuses any size but 64 | **provisional** (size not fixed by the library; board) |
| The library keeps an unwiped stack copy of the key-store nonce | `sab_msg/sab_process_msg.c:170, 216, 268, 368`; `sab_msg/sab_key_store.c:32` | read twice; the call runs in a child process |

Consequences in the backend: `hsm_sign` refuses a buffer under 64 bytes before the call, reads `exp_signature_size`
after the call and accepts only 64 (this binding supports P-256 only): any other length is refused, the caller's buffer
is zeroed and nothing is printed; on a success it reports 64. The CLI's signature buffer starts zeroed. A generate that fails still returns the key id it was given. The test
double (`ele_hsm_fake.c`) follows the same source: a sign leaves `signature_size` alone.

## What is left open

- **Owner:** Q2, the counter acknowledgement (default (c), fail closed, provisional); the delete gap (above); the SE051's role. The calling side is decided (owner ruling 1234).
  From the second reading, for Q2 (no code change made on it): the counter-flag request is documented as completing
  only once the counter is updated, but the exhausted-counter warning reaches the caller as `HSM_NO_ERROR` on a
  success-tagged reply and is otherwise documented on the NVM export path, which the NVM manager handles, not the
  client; a before-and-after read of `chip_monotonic_counter` through `hsm_get_info` would be indirect evidence only
  (see the contract table).
- **Needs the board, none run here:** the client was built and linked, never run. The key-store identifier, nonce,
  the key store's creation and its counter split are provisioning (`oem-key-provisioning` row); the structure
  members and key attributes the backend sets (ECC NIST P-256, persistent, sign-hash) are taken from the library's
  headers by compilation and are untested against the enclave. Whether the i.MX 95 firmware acknowledges the two
  flags as the architecture assumes stays **unconfirmed**
  ([architecture.md](architecture.md#key-store-rollback-protection)).
- **The Linux path to the enclave** (the library's daemon and device, and the TrustZone configuration) is under
  Missing in [architecture.md](architecture.md#missing).
- The counter fuse split is provisioning, the `oem-key-provisioning` row's; nothing here sets it.
