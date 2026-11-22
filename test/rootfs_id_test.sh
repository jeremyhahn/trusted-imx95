#!/usr/bin/env bash
# Behavioural test of platform-image/files/rootfs-id.sh (the fTPM NV wipe's rootfs identity,
# SPEC row ftpm, issue #140): content, mode, link target and numeric ownership each change
# the identity; identical trees give equal identities. Changing a real owner needs root, so
# the ownership cases use a fake find (ROOTFS_ID_FIND) that rewrites the owner column.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

idsh=$ROOT/platform-image/files/rootfs-id.sh
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

mktree() { # DIR: a small tree
	mkdir -p "$1/etc" "$1/bin"
	printf 'one\n' >"$1/etc/a"
	printf 'two\n' >"$1/bin/b"
	chmod 0644 "$1/etc/a"
	ln -s a "$1/etc/link"
}
mktree "$w/t1"
mktree "$w/t2"

# A find that reports another owner for ./bin/b (or all, when FAKE_ALL is set).
cat >"$w/fakefind" <<'EOF'
#!/bin/sh
find "$@" | awk -v u="${FAKE_UID:-}" -v g="${FAKE_GID:-}" '
	$1 == "./bin/b" { if (u != "") $4 = u; if (g != "") $5 = g }
	{ print }'
EOF
chmod +x "$w/fakefind"

id() { sh "$idsh" "$1"; }
idf() { ROOTFS_ID_FIND="$w/fakefind" sh "$idsh" "$1"; }

expect "identical trees give equal identities" test "$(id "$w/t1")" = "$(id "$w/t2")"
expect "identical trees give equal identities with the fake source" test "$(idf "$w/t1")" = "$(idf "$w/t2")"
expect "the fake source with no override equals the real one" test "$(idf "$w/t1")" = "$(id "$w/t1")"
expect "the identity is a SHA-256 hex digest" test "$(id "$w/t1" | tr -d '0-9a-f' | wc -c)" -eq 1
expect "a different UID changes the identity" test "$(FAKE_UID=1234 idf "$w/t1")" != "$(idf "$w/t2")"
expect "a different GID changes the identity" test "$(FAKE_GID=1234 idf "$w/t1")" != "$(idf "$w/t2")"
expect "an ownership change on one side only differs, same on both is equal" \
	test "$(FAKE_UID=7 idf "$w/t1")" = "$(FAKE_UID=7 idf "$w/t2")"

printf 'three\n' >"$w/t2/etc/a"
expect "a content change changes the identity" test "$(id "$w/t1")" != "$(id "$w/t2")"
mktree "$w/t3"
chmod 0600 "$w/t3/etc/a"
expect "a mode change changes the identity" test "$(id "$w/t1")" != "$(id "$w/t3")"
mktree "$w/t4"
ln -sf b "$w/t4/etc/link"
expect "a link target change changes the identity" test "$(id "$w/t1")" != "$(id "$w/t4")"
expect "no tree argument fails" test "$(sh "$idsh" >/dev/null 2>&1 && echo 0 || echo 1)" -eq 1

finish
