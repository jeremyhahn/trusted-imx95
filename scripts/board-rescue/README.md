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
one reply line. The device is one of `mmcblk0`, `mmcblk0boot0`, `mmcblk0boot1`;
anything else is refused.

| Command | Reply |
| --- | --- |
| `hash <dev> <bytes>` | SHA-256 of the first `<bytes>` of the device (read only) |
| `write <dev> <bytes> <sha256>` + that many bytes | `OK`, or `MISMATCH <sha256 read back>` after `dd bs=4M conv=fsync` and a re-read |
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
