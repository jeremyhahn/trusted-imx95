#!/bin/sh
# Print the rootfs identity of the tree in $1: a SHA-256 over every file's content hash and
# every entry's path, type, mode, numeric UID, numeric GID and symlink target. It reads the
# tree only, never the clock, so identical inputs give identical bytes. The caller removes
# the identity file from the tree first. Numeric ownership is what pseudo/fakeroot reports
# at do_rootfs time. ROOTFS_ID_FIND names the find command (the test substitutes a fake
# ownership source, since changing an owner needs root).
set -eu
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: rootfs-id.sh TREE" >&2; exit 1; }
find_cmd=${ROOTFS_ID_FIND:-find}
cd "$1"
{
	find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
	"$find_cmd" . -printf '%p %y %m %U %G %l\n' | LC_ALL=C sort
} | sha256sum | cut -d' ' -f1
