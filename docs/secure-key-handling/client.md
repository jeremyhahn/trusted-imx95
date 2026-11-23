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
| Both | no (warning, or no split) | committed, not rollback-protected |
| Strict only | n/a | committed, not rollback-protected |
| Monotonic counter only | n/a | not committed (the call fails) |
| Neither | n/a | not committed (the call fails) |

The host tests (`test/ele_client_test.sh`, run by `make test`) cover all four combinations, a counter warning, a
missing split and an acknowledgement of one flag only, against a stub that holds no key. The default client sends
both flags.

## What is left open

- **Owner:** which side calls the HSM API (above). The SE051's role is also open.
- **The binding to the library's real calls.** The client's ops table is bound to a stub only. Binding it to the
  library's key-store, key-generation, signing and key-deletion calls, and mapping their return codes and flags to
  the acknowledgement fields, needs the library's headers read by a reader against RM00284; this session did not
  read them. The check that the i.MX 95 firmware behaves as the architecture assumes stays **unconfirmed** until it
  runs on the board ([architecture.md](architecture.md#key-store-rollback-protection)).
- **The Linux path to the enclave** (the library's daemon and device, and the TrustZone configuration) is under
  Missing in [architecture.md](architecture.md#missing).
- The counter fuse split is provisioning, the `oem-key-provisioning` row's; nothing here sets it.
