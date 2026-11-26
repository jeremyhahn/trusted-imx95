# xkmsd on the board

Build, deploy and burn in the go-xkms daemon on the i.MX95 board. The board's
ssh target is always an argument; no address is kept in the repository.

Scope: the `xkms-board` row of [SPEC.md](../SPEC.md#features), in progress;
the owner approved it on 2026-11-25. It is not done.

| Step | Command | Result |
| --- | --- | --- |
| Build | `scripts/xkms/xkmsd-build.sh [<commit>]` | `build/xkms/<commit>/{xkmsd,xkmsctl,manifest.txt}`, static linux/arm64, stamped with the go-xkms commit (`xkmsd --version` prints it); `XKMSCTL_HOST=1` also builds `host/xkmsctl` for the build host |
| Deploy | `scripts/xkms/xkmsd-deploy.sh <ssh target> build/xkms/<commit>` | new binary running, backup in `/var/backups/xkms/<stamp>/` |
| Roll back | `scripts/xkms/xkmsd-deploy.sh --rollback <stamp> <ssh target>` | that backup restored |
| Upgrade | `scripts/xkms/xkmsd-upgrade.sh [--apply] <ssh target>` | says whether the board runs the latest go-xkms; with `--apply`, builds and deploys it |
| Burn in | `scripts/xkms/burnin/*.sh` | see [burn-in.md](burn-in.md) |

## Build

The script clones go-xkms read-only into `build/go-xkms/src` (ignored by git)
as an object cache only. Every build runs in a fresh checkout of the commit in
a temporary directory next to it, so an untracked or ignored file left in the
cache (a stray `.go` file would be compiled in) never reaches the build; the
script refuses to build if `git status --ignored` of that checkout is not
empty. It builds with `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 -trimpath`, tags
`codec_cbor codec_json codec_msgpack pkcs8 frost`. The version is the commit
and the build date is the commit date, so a rebuild at one commit gives the
same SHA-256 on the same toolchain.

The toolchain is pinned. The script refuses to build, before it clones or
compiles anything, unless `go version` is the release named by `go_pin` at the
top of `scripts/xkms/xkmsd-build.sh` (the comment there gives its source).
Go runs in a clean environment (`env -i`): `GOFLAGS` and `GOEXPERIMENT` empty,
`GOTOOLCHAIN=local` (go.mod cannot swap the toolchain), `GOAMD64=v1`,
`GOARM64=v8.0`, `CGO_ENABLED=0`, `GOWORK=off`, `GOENV=off`, `GOFIPS140=off`,
and a fixed `GOPATH` and `GOCACHE` under `build/go-xkms/`, outside the source
tree. Nothing from the caller's shell reaches the build except `PATH` and the
proxy and CA variables the module download needs. The manifest lists the
commit, the pinned and the actual Go version, the exact environment, the flags
(with the `-X` version stamp: `git describe` of the commit, the full sha, the
commit's own date) and the hashes.

## Deploy

Preflight, upload and hash check, stop, back up `/usr/local/bin/xkmsd`,
`/etc/xkms` and `/var/lib/xkms` with a SHA256SUMS list, install, start, then a
health check: unit active, a listener owned by the daemon, the version names
the build's commit, the unit stays up. Any failure restores the backup and
exits nonzero. A restore first stops the unit and proves it stopped (the
stop succeeded, the unit is inactive with no MainPID, no xkmsd process is
left); otherwise it refuses and leaves the live tree untouched. A restore
renames each live item aside before its restored copy takes its place and
deletes nothing live until the restored tree matches the backup's hashes; a
failed rename puts back what was already swapped and stops, naming the
backup. Because a restore replaces `/usr/local/bin/xkmsd`, `/etc/xkms` and
`/var/lib/xkms` whole, preflight (and `--rollback`) refuses, before stopping
xkmsd, when any of them is or holds a mount point (`findmnt`, else
`/proc/self/mountinfo`). Preflight
reserves room on each filesystem for the backup, the staged binary and the
copies a rollback makes beside the live trees. The newest 5 backups are kept. `--dry-run` contacts nothing.
xkmsd has no config validate mode, so a bad config shows as a failed start.
The board needs systemctl and one of `ss`, `netstat` or `/proc/net/tcp` (tried
in that order) to find the listener; `XKMS_PORT` pins the port.

`bash test/xkms_board_tools_test.sh` runs the deploy against a fake board
(stub ssh, systemctl, df and, per case, ss, netstat or /proc/net/tcp), the
burn-in ledger, restart proofs and `concurrency.sh` against a stub xkmsctl,
and every burn-in `--help` and `--dry-run`.
It does not touch a real board.

## Upgrade

The board runs the latest go-xkms (the owner's 2026-11-24 directive).
`scripts/xkms/xkmsd-upgrade.sh [--apply] [--ref <go-xkms ref>] <ssh target>`
resolves the ref (default `refs/heads/main` of `XKMS_REPO`, the same default as
the build script; an annotated tag is peeled) to exactly one commit, runs
`/usr/local/bin/xkmsd --version` on the board over ssh and matches the commit
the way the deploy's health check does. It prints one line:

| Line | Exit |
| --- | --- |
| `current <commit>` | 0 |
| `behind: board <reported>, latest <commit>` | 10 (without `--apply`) |
| `unknown: <reason>` (no commit in the answer, or ssh failed) | 1 |
| any other error (the ref does not resolve, the build failed) | 1 |
| usage | 2 |

With `--apply` and behind, it runs the build for that commit, then the deploy
with the build directory the build printed, and exits with the deploy's
status. It never deploys after a failed build, nor when the build directory's
manifest names another commit. With `--apply` and an unknown version it
refuses: installing over a board whose version is not known is done by hand
with the deploy script. Every upgrade goes through the deploy, so its backup
and its restore on a failed health check cover every upgrade. `--dry-run`
contacts nothing.

`make integration-test-xkms-board` runs the host-side tests of this row in
turn (the deploy and burn-in tools, the upgrade check, the rescue protocol),
stops on the first failure and ends with `integration-test-xkms-board: OK`.
The upgrade test uses a local bare repository, a stub ssh and stub build and
deploy scripts. The burn-in run on the board is a separate step.

## Rescue

To put the whole eMMC back to a stock backup,
`scripts/board-rescue/restore.sh` kexecs the board, over its ssh session,
into a rescue initramfs that writes the eMMC from the backup; the protocol is in
[the rescue README](../../scripts/board-rescue/README.md#rescue-protocol).
The rescue port is open to the network, so everything on it after the
board's nonce is authenticated under a per-session key that never crosses
the network: the command line, each 1 MiB chunk of a write's image (the
board checks a chunk's MAC before it writes a byte of it, and the first bad,
missing or short chunk aborts the write) and every reply (`restore.sh`
takes no reply without a MAC good for that connection's nonce). The
whole-image digest is still checked by reading the eMMC back.

An attacker on the path, without the key, can only deny service: drop or
cut a connection, alter a chunk so the write aborts, or replace a reply so
the restore fails. An aborted write leaves the chunks before the bad one
written, so the eMMC stays broken until a retry (`--no-kexec` with the same
key file) completes; the attacker cannot get a byte onto the eMMC that the
operator did not send, nor make `restore.sh` report OK or a digest the board
did not. `bash test/board_rescue_test.sh` drives the rescue handler and
`restore.sh` against plain files, with an on-path proxy that alters a chunk
and forges or replays an OK.
