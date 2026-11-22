#!/bin/sh
# Print the rootfs identity of the tree in $1: 32 bytes from /dev/urandom, hex encoded (64
# lowercase hex characters). It is drawn once per build, so every build of the image, even
# one with identical inputs, gets a new identity and the NV is wiped; no list of
# security-relevant attributes (ownership, xattrs, ACLs, capabilities, ...) can be
# incomplete. A tree that already carries a valid identity (etc/trusted-imx95-rootfs-id)
# keeps it: the same image bytes give the same identity, so this is not regenerated.
set -eu
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: rootfs-id.sh TREE" >&2; exit 1; }
idf=$1/etc/trusted-imx95-rootfs-id
if [ -f "$idf" ] && [ ! -L "$idf" ]; then
	cur=$(cat "$idf")
	case $cur in
	*[!0-9a-f]*) ;;
	????????????????????????????????????????????????????????????????) printf '%s\n' "$cur"; exit 0 ;;
	esac
fi
id=$(od -An -v -tx1 -N32 /dev/urandom | tr -d ' \n')
[ ${#id} -eq 64 ] || { echo "rootfs-id.sh: could not read /dev/urandom" >&2; exit 1; }
printf '%s\n' "$id"
