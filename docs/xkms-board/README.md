# xkmsd on the board

Build, deploy and burn in the go-xkms daemon on the i.MX95 board. The board's
ssh target is always an argument; no address is kept in the repository.

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
same SHA-256. The manifest lists the commit, Go version, flags and hashes.

## Deploy

Preflight, upload and hash check, stop, back up `/usr/local/bin/xkmsd`,
`/etc/xkms` and `/var/lib/xkms` with a SHA256SUMS list, install, start, then a
health check: unit active, a listener owned by the daemon, the version names
the build's commit, the unit stays up. Any failure restores the backup and
exits nonzero. The newest 5 backups are kept. `--dry-run` contacts nothing.
xkmsd has no config validate mode, so a bad config shows as a failed start.

`bash test/xkms_board_tools_test.sh` runs the deploy against a fake board
(stub ssh, systemctl and ss) and every burn-in `--help` and `--dry-run`.
It does not touch a real board.
