# xkmsd burn-in and data-loss tests

Scripts in `scripts/xkms/burnin/`. Each takes the board's ssh target (root,
key auth) and drives xkmsd through `xkmsctl`; each has `--help` and
`--dry-run` (prints the plan, touches nothing). They share these options:
`--server <url>`, `--ctl <path>`, `--ctl-args "<..>"` (transport and TLS
files), `--work <dir>`, or the environment `XKMS_SERVER`, `XKMS_CTL`,
`XKMS_CTL_ARGS`, `XKMS_WORK`, `XKMS_BOARD`.

Needs: `xkmsctl` (from the build dir; the linux/arm64 one is for the board, run
a host build of go-xkms's `xkmsctl` on the machine that runs the scripts),
`ssh` to the board as root, and a reachable xkmsd.

Output is one line per check (`PASS` or `FAIL`), `CRITICAL:` for each
acknowledged write that is lost or changed, and a final
`SUMMARY <name>: PASS|FAIL`. Exit status 0 PASS, 1 FAIL or any CRITICAL, 2 usage.
Test keys have ids `bi-*` and stay on the server; the work directory holds
ledgers (ids, hashes, ciphertexts, signatures) but no key material.

A write counts as acknowledged only when xkmsctl returned success. The ledger
records it then, with an artefact made by the key and a fingerprint of its
metadata. Verification decrypts the old ciphertext, verifies the old
signature, and compares the fingerprint and any certificate.

| Script | Proves | Fails when |
| --- | --- | --- |
| `functional.sh` | every `xkmsctl` operation works against the live daemon (create, get, list, sign/verify, encrypt/decrypt, copy, delete, certificates; rotate where a key-version store exists) | an operation errors, or a refused-by-policy operation is accepted |
| `soak.sh` | a steady mixed load for hours: latency p50/p95/p99, error rate, daemon RSS and descriptor growth | error rate over `--max-error-pct`, RSS growth over `--max-rss-growth-pct`, descriptor growth over `--max-fd-growth`, a daemon restart, or a lost key |
| `durability.sh` | acknowledged writes survive a graceful restart and two `kill -9` | any ledger entry lost or changed (CRITICAL) |
| `powerloss.sh` | acknowledged writes survive `echo b > /proc/sysrq-trigger` (no sync). Off unless `--hard-reboot`. Does not test the eMMC's own write cache | any acknowledged write lost (CRITICAL) |
| `diskfull.sh` | with the state filesystem full, writes are acknowledged or refused promptly, xkmsd stays up, nothing acknowledged is lost, writes work again once the filler is removed | a hang, a crash, a loss, or no recovery. The filler `.burnin-filler` is removed on exit |
| `concurrency.sh` | parallel clients racing on one key id: at most one create wins, concurrent signatures verify, delete leaves the key gone, unique-id writes all survive | two creates acknowledged, a bad signature, a lost write |
| `restart-load.sh` | restarts and `kill -9` while writers run: xkmsd comes back each time and no acknowledged write is lost | a restart that does not recover, or any loss (CRITICAL) |

## Running

    scripts/xkms/burnin/functional.sh --ctl-args "<transport/TLS>" <board>
    scripts/xkms/burnin/durability.sh <board>
    scripts/xkms/burnin/soak.sh --hours 8 <board>
    scripts/xkms/burnin/powerloss.sh --hard-reboot <board>

Run `powerloss.sh` and `diskfull.sh` last on a board you can reach again:
the first reboots it, the second fills `/var/lib/xkms` for a short time.
None of the scripts touches fuses, the life cycle or RPMB.

## Status

Written and linted; the scripts' own `--help` and `--dry-run` are tested. Only
`functional.sh` has run, against a local embedded keystore; the rest await a
run on the board.
