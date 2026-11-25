# xkmsd on the board

Build, deploy and burn in the go-xkms daemon on the i.MX95 board. The board's
ssh target is always an argument; no address is kept in the repository.

Scope: the `xkms-board` row of [SPEC.md](../SPEC.md#features), proposed,
pending owner approval. It is not done.

| Step | Command | Result |
| --- | --- | --- |
| Build | `scripts/xkms/xkmsd-build.sh [<commit>]` | `build/xkms/<commit>/{xkmsd,xkmsctl,manifest.txt}`, static linux/arm64 |
| Deploy | `scripts/xkms/xkmsd-deploy.sh <ssh target> build/xkms/<commit>` | new binary running, backup in `/var/backups/xkms/<stamp>/` |
| Roll back | `scripts/xkms/xkmsd-deploy.sh --rollback <stamp> <ssh target>` | that backup restored |
| Burn in | `scripts/xkms/burnin/*.sh` | see [burn-in.md](burn-in.md) |

## Build

The script clones go-xkms read-only into `build/go-xkms/src` (ignored by git)
and builds with `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 -trimpath`, tags
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
and the hashes.

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
