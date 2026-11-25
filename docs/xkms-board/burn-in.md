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
records the key id at once, before any follow-up call, then an artefact made
by the key and a fingerprint of its metadata; a follow-up that fails never
drops the id. Verification checks that every acknowledged id exists, decrypts
the old ciphertext, verifies the old signature, and compares the fingerprint
and any certificate.

Background writers (`restart-load.sh`, `powerloss.sh`) look at a stop flag only
between requests. To stop them the script sets the flag and waits for each to
finish the request it is in, so a create xkmsctl acknowledged is in the ledger
before the verify. A writer still running after three xkmsctl timeouts plus
10 s (`BI_DRAIN_SECS`) is killed with its whole process group, its xkmsctl
included. Each create is noted as tried before it is sent; one never
acknowledged (failed, or cut off) is reported as unknown and never counted lost.

A restart counts only when it is proven: every systemctl step must succeed, a
graceful or `kill -9` restart must change xkmsd's MainPID, and a hard reboot
must change the board's `/proc/sys/kernel/random/boot_id`.

| Script | Proves | Fails when |
| --- | --- | --- |
| `functional.sh` | every `xkmsctl` operation works against the live daemon (create, get, list, sign/verify, encrypt/decrypt, copy, delete, certificates; rotate where a key-version store exists) | an operation errors, or a refused-by-policy operation is accepted |
| `soak.sh` | a steady mixed load for hours: latency p50/p95/p99, error rate, daemon RSS and descriptor growth | error rate over `--max-error-pct`, RSS growth over `--max-rss-growth-pct`, descriptor growth over `--max-fd-growth`, a daemon restart, or a lost key |
| `durability.sh` | acknowledged writes survive a graceful restart and two `kill -9` | any ledger entry lost or changed (CRITICAL) |
| `powerloss.sh` | acknowledged writes survive `echo b > /proc/sysrq-trigger` (no sync). Off unless `--hard-reboot`. Does not test the eMMC's own write cache | any acknowledged write lost (CRITICAL) |
| `diskfull.sh` | a filler leaves xkmsd `--margin-kib` (covering the blocks reserved for root when xkmsd runs as root; both reported), then writes go on until xkmsd reports no space; writes are acknowledged or refused promptly, xkmsd stays up, nothing acknowledged is lost, writes work again once the filler is removed | no no-space error within `--max-writes` writes or `--max-kib` KiB (the disk was never seen full), a hang, a crash, a loss, or no recovery. The filler `.burnin-filler` is removed on exit |
| `concurrency.sh` | parallel clients racing on one key id: at most one create wins, concurrent signatures verify, delete leaves the key gone, unique-id writes all survive | two creates acknowledged, a failed or bad signature (each client needs one verified signature), a lost write |
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
