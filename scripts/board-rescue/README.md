# Board rescue: restore the stock eMMC image from RAM

When the U-Boot console is not reachable, the board's running Linux can kexec
its own kernel (`/boot/Image`) with a rescue initramfs. The rescue system runs
from RAM, takes the image over the network and writes the eMMC. Scope: the
`xkms-board` row of [SPEC.md](../../docs/SPEC.md#features), proposed.

| Step | Command |
| --- | --- |
| Build | `scripts/board-rescue/build-initramfs.sh` gives `build/board-rescue/rescue.cpio.gz` |
| Verify the board against a backup | `scripts/board-rescue/restore.sh <ssh target> <backup dir> --verify-only` |
| Restore | `scripts/board-rescue/restore.sh <ssh target> <backup dir>` |
| Retry from the rescue system | `scripts/board-rescue/restore.sh <ssh target> <backup dir> --no-kexec --ip <addr/prefix>` |

The board's target and addresses are always arguments.

## Build

The only binary is the static arm64 busybox of a pinned Debian
`busybox-static` `.deb`, fetched by exact version and checked against the
SHA-256 pinned in the script (the `.deb` is cached under `build/board-rescue/`,
which git ignores). The cpio is written by the script itself (sorted names,
mtime 0, uid and gid 0), then `gzip -n`, so two builds give the same bytes.
The script refuses a busybox that is not a static aarch64 ELF.

## Backup directory

`manifest.txt` has one line per device, `<dev> <file> <raw bytes> <sha256 of
the raw bytes>`, for `mmcblk0`, `mmcblk0boot0` and `mmcblk0boot1`; `<file>` is
the zstd dump, relative to the directory. `--manifest` names another file.
The size of `mmcblk0` in the manifest must equal the board's.

## Rescue protocol

One TCP port (`rescue.port=`, default 7777), one command per connection,
one reply line. The rescue system has no sshd, so the port is reachable from
the network, and every command is authenticated with a per-session key:

1. Before the kexec, over the operator's ssh session, the board generates a
   random 256-bit key and appends it to the uploaded initramfs as one more
   cpio archive holding `/rescue.key` (mode 0400), giving
   `/tmp/rescue-initrd.img`, the initrd the kexec loads. The key comes back
   over the same ssh session; `restore.sh` keeps it in a mode 0600 file
   (`--key-file`, default `<backup dir>/rescue-session.key`, which a
   `--no-kexec` retry reads) and deletes it once the board is back in its own
   system. The key is never printed, logged or put on a command line.
2. On each connection the board sends `nonce <64 hex>`, fresh per connection.
   The client answers `auth <mac> <command line>`, `<mac>` being the SHA-256
   of `<key>:<nonce>:<command line>`. The key never crosses the network, and a
   captured MAC is good for no other connection or command.
3. Without `/rescue.key`, or with a missing or wrong MAC, the board answers
   `ERR no session key` or `ERR auth refused` and runs nothing.

The device is one of `mmcblk0`, `mmcblk0boot0`, `mmcblk0boot1`;
anything else is refused.

| Command | Reply |
| --- | --- |
| `hash <dev> <bytes>` | SHA-256 of the first `<bytes>` of the device (read only) |
| `write <dev> <bytes> <sha256>`, then that many bytes after the auth line | `OK`, or `MISMATCH <sha256 read back>` after `dd bs=4M conv=fsync` and a re-read |
| `reboot` | `OK`, then sync and `reboot -f` |

The boot partitions are unlocked (`force_ro` 0) for the write and locked again
after. The kernel command line carries `rescue.ip=<addr/prefix>`,
`rescue.gw=`, `rescue.if=` (default eth0) and `rescue.port=`; without
`rescue.ip` the init runs `udhcpc`. The init logs every step to the console and
never reads a file on the eMMC.

## Limits

The initramfs has no kernel modules: the board's Ethernet and eMMC drivers must
be built into `/boot/Image`. The restore replaces the whole eMMC, so anything
written since the backup is lost; fuses, life-cycle and RPMB are not touched.
