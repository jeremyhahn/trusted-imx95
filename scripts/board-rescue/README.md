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
the network, and every message after the board's nonce (the command, each
chunk of a write's image, the reply) is authenticated with a per-session
key:

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
4. A write's image follows in 1 MiB chunks (the last one shorter), chunk `k`
   (from 0) as the line `chunk <k> <mac>` and then its bytes, `<mac>` being
   the SHA-256 of `<key>:<nonce>:c:<k+1>:<k>:<bytes>:<len>:` followed by the
   chunk's `<len>` bytes (`<bytes>` is the write's total, `k+1` the chunk's
   sequence number after the command). The board reads the chunk into RAM
   and checks its MAC before it writes a byte of it at offset `k` MiB. The
   first chunk line that is missing or out of order, chunk cut short or
   wrong MAC aborts the write: nothing of that chunk or after it is written,
   the refusal is logged, and the reply is `ERR write aborted: chunk <k>:
   <why>`. A complete write is still read back and checked against
   `<sha256>`.
5. Every reply is `reply <mac> <reply>`, `<mac>` being the SHA-256 of
   `<key>:<nonce>:b:1:<length of reply>:<reply>`. `restore.sh` takes a reply
   only when its MAC is right for its key and that connection's nonce;
   anything else (no nonce, no MAC, a wrong MAC, a reply replayed from
   another connection) it prints as `UNAUTHENTICATED ...` and never takes for
   `OK` or for a digest. The replies before authentication (`ERR no session
   key`, `ERR auth refused`) carry no MAC, so they count as failures too.

Every length that precedes variable bytes is inside the MAC, and the
direction tag (`c` client, `b` board) and sequence number keep a MAC from
standing for any other message, so the SHA-256 construction the command MAC
used is kept and no other primitive is needed. What an attacker on the path
can still do, without the key, is deny service: drop or cut the connection,
alter a chunk so the board aborts, or replace a reply so `restore.sh` fails.
An aborted write leaves the chunks before the bad one written, so the eMMC
holds a mix of old and backup bytes until a retry (`--no-kexec`, same key)
completes; the attacker cannot make the board write a byte the key holder
did not send, or make `restore.sh` report a write or a digest the board did
not.

The device is one of `mmcblk0`, `mmcblk0boot0`, `mmcblk0boot1`;
anything else is refused.

| Command | Reply |
| --- | --- |
| `hash <dev> <bytes>` | SHA-256 of the first `<bytes>` of the device (read only) |
| `write <dev> <bytes> <sha256>`, then that many bytes in authenticated chunks after the auth line | `OK`, or `MISMATCH <sha256 read back>` after the last chunk and a re-read, or `ERR write aborted: ...` at the first bad chunk |
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
