#!/bin/bash
# Behavioural test of platform-image/files/rootfs-id.sh (the fTPM NV wipe's rootfs identity,
# SPEC row ftpm, issue #140): the identity is random per build, 64 lowercase hex characters,
# and a tree that already carries one keeps it.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

idsh=$ROOT/platform-image/files/rootfs-id.sh
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

mkdir -p "$w/t1/etc" "$w/t2/etc"
printf 'one\n' >"$w/t1/etc/a"
cp "$w/t1/etc/a" "$w/t2/etc/a"

id() { sh "$idsh" "$1"; }
hex64() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{64}'; }

a=$(id "$w/t1")
b=$(id "$w/t1")
c=$(id "$w/t2")
expect "the identity is 64 lowercase hex characters" hex64 "$a"
expect "two runs on the same tree give different identities" test "$a" != "$b"
expect "identical trees give different identities" test "$a" != "$c"

# A metadata-only change cannot keep the identity: every run is new anyway.
chmod 0600 "$w/t2/etc/a"
expect "a mode-only change gives a different identity" test "$(id "$w/t2")" != "$c"

# A tree carrying an identity keeps it.
printf '%s\n' "$a" >"$w/t1/etc/trusted-imx95-rootfs-id"
expect "a tree carrying an identity gives it back" test "$(id "$w/t1")" = "$a"
expect "a second read gives it back again" test "$(id "$w/t1")" = "$a"
printf 'not-hex\n' >"$w/t2/etc/trusted-imx95-rootfs-id"
d=$(id "$w/t2")
expect "an invalid carried identity is replaced by a valid one" hex64 "$d"
printf 'ABCDEF%058d\n' 0 >"$w/t2/etc/trusted-imx95-rootfs-id"
expect "an uppercase carried identity is replaced" test "$(id "$w/t2")" != "ABCDEF$(printf '%058d' 0)"
expect "the script writes nothing into the tree" test "$(find "$w/t1" -type f | wc -l)" -eq 2
expect "no tree argument fails" test "$(sh "$idsh" >/dev/null 2>&1 && echo 0 || echo 1)" -eq 1

finish
