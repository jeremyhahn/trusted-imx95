#!/usr/bin/env bash
# Build the rescue initramfs: build/board-rescue/rescue.cpio.gz for linux/arm64.
#
# The only binary in it is the static arm64 busybox of a pinned Debian
# busybox-static .deb, fetched by exact version and checked against the SHA-256
# pinned below (no compiler needed). The archive is a newc cpio written by this
# script with sorted names, mtime 0, uid and gid 0 and sequential inodes, then
# gzip -n, so two builds give the same bytes.
#
# usage: build-initramfs.sh [<output dir>]    (default build/board-rescue)
# BUSYBOX_DEB=<file> uses a local copy of the pinned .deb instead of fetching.
set -uo pipefail

BUSYBOX_VERSION='1.37.0-6+b9'
BUSYBOX_DEB_NAME="busybox-static_${BUSYBOX_VERSION}_arm64.deb"
BUSYBOX_URL="https://deb.debian.org/debian/pool/main/b/busybox/${BUSYBOX_DEB_NAME}"
BUSYBOX_DEB_SHA256='c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c'

die() {
	echo "build-initramfs: $*" >&2
	exit 1
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
out=${1:-$root/build/board-rescue}
mkdir -p "$out" || die "cannot create $out"
out=$(cd "$out" && pwd -P)
[ -f "$here/init" ] && [ -f "$here/udhcpc.script" ] || die "init or udhcpc.script missing beside the script"

for t in ar tar xz gzip sha256sum python3; do
	command -v "$t" >/dev/null || die "$t not found"
done
[ -n "${BUSYBOX_DEB:-}" ] || command -v curl >/dev/null || die "curl not found"

work=$(mktemp -d "${TMPDIR:-/tmp}/rescue-build.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT

deb=${BUSYBOX_DEB:-$out/cache/$BUSYBOX_DEB_NAME}
if [ -z "${BUSYBOX_DEB:-}" ] && [ ! -f "$deb" ]; then
	mkdir -p "$out/cache"
	echo "build-initramfs: fetching $BUSYBOX_DEB_NAME"
	curl -fsSL --retry 3 -m 120 -o "$work/fetch.deb" "$BUSYBOX_URL" || die "fetch of $BUSYBOX_URL failed"
	mv "$work/fetch.deb" "$deb" || die "cannot cache the .deb"
fi
got=$(sha256sum "$deb") || die "cannot hash $deb"
got=${got%% *}
[ "$got" = "$BUSYBOX_DEB_SHA256" ] || die "$deb has SHA-256 $got, pinned $BUSYBOX_DEB_SHA256"

mkdir "$work/deb" || die "mkdir failed"
(cd "$work/deb" && ar x "$deb" && tar -xJf data.tar.xz ./usr/bin/busybox) || die "cannot unpack the .deb"
bb=$work/deb/usr/bin/busybox
[ -f "$bb" ] || die "no busybox in the .deb"

cpio=$out/rescue.cpio
python3 -I - "$bb" "$here/init" "$here/udhcpc.script" "$cpio" <<'PY' || die "cpio write failed"
import struct, sys

bb, init, dhcp, dest = sys.argv[1:5]

def rd(p):
    with open(p, "rb") as f:
        return f.read()

busybox = rd(bb)
# The busybox must be a static aarch64 ELF: ELF64 LE, ET_EXEC or ET_DYN,
# EM_AARCH64, no PT_INTERP and no PT_DYNAMIC program header.
if busybox[:4] != b"\x7fELF" or busybox[4] != 2 or busybox[5] != 1:
    sys.exit("busybox is not an ELF64 little-endian file")
e_type, e_machine = struct.unpack_from("<HH", busybox, 16)
if e_machine != 0xB7:
    sys.exit("busybox is not aarch64")
e_phoff, = struct.unpack_from("<Q", busybox, 32)
e_phentsize, e_phnum = struct.unpack_from("<HH", busybox, 54)
for i in range(e_phnum):
    p_type, = struct.unpack_from("<I", busybox, e_phoff + i * e_phentsize)
    if p_type in (2, 3):  # PT_DYNAMIC, PT_INTERP
        sys.exit("busybox is not static")

applets = ("sh mount umount mkdir sleep cat dd head tail wc sha256sum nc ip udhcpc reboot "
           "sync mkfifo blockdev echo test ls rm tr").split()

S_DIR, S_REG, S_LNK, S_CHR = 0o040000, 0o100000, 0o120000, 0o020000
entries = {}  # name -> (mode, data, rdev_major, rdev_minor)
for d in ("bin", "dev", "etc", "proc", "sbin", "sys", "tmp", "usr", "usr/bin",
          "usr/share", "usr/share/udhcpc"):
    entries[d] = (S_DIR | 0o755, b"", 0, 0)
entries["bin/busybox"] = (S_REG | 0o755, busybox, 0, 0)
for a in applets:
    entries["bin/" + a] = (S_LNK | 0o777, b"busybox", 0, 0)
entries["init"] = (S_REG | 0o755, rd(init), 0, 0)
entries["usr/share/udhcpc/default.script"] = (S_REG | 0o755, rd(dhcp), 0, 0)
entries["dev/console"] = (S_CHR | 0o600, b"", 5, 1)
entries["dev/null"] = (S_CHR | 0o666, b"", 1, 3)

def pad(n):
    return b"\0" * (-n % 4)

out = bytearray()
for ino, name in enumerate(sorted(entries), start=1):
    mode, data, maj, mnr = entries[name]
    nm = name.encode() + b"\0"
    out += b"070701" + b"".join(
        b"%08X" % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, maj, mnr, len(nm), 0))
    out += nm + pad(110 + len(nm)) + data + pad(len(data))
nm = b"TRAILER!!!\0"
out += b"070701" + b"".join(b"%08X" % v for v in (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(nm), 0))
out += nm + pad(110 + len(nm))
with open(dest, "wb") as f:
    f.write(out)
PY

gzip -9n -c "$cpio" >"$out/rescue.cpio.gz.tmp" || die "gzip failed"
mv "$out/rescue.cpio.gz.tmp" "$out/rescue.cpio.gz"
rm -f "$cpio"
sum=$(sha256sum "$out/rescue.cpio.gz")
echo "build-initramfs: $out/rescue.cpio.gz ${sum%% *} $(wc -c <"$out/rescue.cpio.gz") bytes"
