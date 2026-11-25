#!/usr/bin/env bash
# The hsm-device-protocol row end to end through make: make hdp-boundary-check
# on the repository (the row holds: go-xkms defines the wire protocol and
# xkmsd, this repository defines neither) and on a copy that breaks the
# boundary with a protocol schema. Runs offline on a read-only root (make
# integration-test, make integration-test-hsm-device-protocol); writes only
# under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

run make -s -C "$ROOT" hdp-boundary-check
check "make hdp-boundary-check: the repository keeps the hsm-device-protocol row" 0 \
	"ok B1 row" "ok B3 no-protocol" "ok B4 owner" "hdp-boundary-check: OK (5 checks"

t="$TMP_ROOT/tree"
mkdir -p "$t/docs/references"
cp "$ROOT/docs/SPEC.md" "$t/docs/"
cp "$ROOT/docs/references/README.md" "$t/docs/references/"
cp -R "$ROOT/docs/hsm-device-protocol" "$t/docs/"
printf 'syntax = "proto3";\n' >"$t/docs/hsm-device-protocol/wire.proto"
run make -s -C "$ROOT" hdp-boundary-check HDP_TREE="$t"
check "make hdp-boundary-check: a tree that defines a wire protocol breaks the row" nonzero \
	"FAIL B3 no-protocol" "wire.proto defines a wire protocol"

# HDP_TREE is a path, never shell source: a directory whose name holds a
# backtick command, a $( ) command and a space reaches the check literally and
# no command runs. The directory lives under $TMP_ROOT, never in the clone.
HDP_MARK="$TMP_ROOT/hdp-mark-backtick"
HDP_MARK2="$TMP_ROOT/hdp-mark-dollar"
export HDP_MARK HDP_MARK2
rm -f "$HDP_MARK" "$HDP_MARK2"
t="$TMP_ROOT/inj/a \`touch \"\$HDP_MARK\"\` \$(touch \"\$HDP_MARK2\") b"
mkdir -p "$t/docs/references"
cp "$ROOT/docs/SPEC.md" "$t/docs/"
cp "$ROOT/docs/references/README.md" "$t/docs/references/"
cp -R "$ROOT/docs/hsm-device-protocol" "$t/docs/"
RC=0
OUT=$(HDP_TREE="$t" make -s -C "$ROOT" hdp-boundary-check 2>&1) || RC=$?
check "make hdp-boundary-check: a tree path with a backtick, \$( ) and a space reaches the check literally" 0 \
	"hdp-boundary-check: OK (5 checks"
expect "make hdp-boundary-check: no command in the tree path ran" \
	test ! -e "$HDP_MARK" -a ! -e "$HDP_MARK2"
RC=0
OUT=$(make -s -C "$ROOT" hdp-boundary-check HDP_TREE="$t/docs/none \`touch \"\$HDP_MARK\"\`" 2>&1) || RC=$?
check "make hdp-boundary-check: a command-line path with a backtick and a dollar sign is refused, not run" 2 \
	"hdp-boundary-check: a command-line HDP_TREE holding a dollar sign is refused"
expect "make hdp-boundary-check: the command-line backtick did not run" test ! -e "$HDP_MARK"

# Make runs a function in a command-line variable while it builds the recipe
# environment: a literal $(shell ...) on the command line is refused before it
# runs, and the same text in the environment reaches the check as a path that
# does not exist (exit 2) with no command run.
HDP_MARK3="$TMP_ROOT/hdp-mark-shell-cmdline"
HDP_MARK4="$TMP_ROOT/hdp-mark-shell-env"
rm -f "$HDP_MARK3" "$HDP_MARK4"
run make -s -C "$ROOT" hdp-boundary-check "HDP_TREE=$TMP_ROOT/\$(shell touch $HDP_MARK3)"
check "make hdp-boundary-check: a command-line \$(shell ...) HDP_TREE is refused" 2 \
	"a command-line HDP_TREE holding a dollar sign is refused"
expect "make hdp-boundary-check: the command-line \$(shell ...) did not run" test ! -e "$HDP_MARK3"
run env HDP_TREE="$TMP_ROOT/\$(shell touch $HDP_MARK4)" make -s -C "$ROOT" hdp-boundary-check
check "make hdp-boundary-check: an environment \$(shell ...) HDP_TREE reaches the check literally, unreadable" 2 \
	"hdp-boundary-check:" "No such file or directory"
expect "make hdp-boundary-check: the environment \$(shell ...) did not run" test ! -e "$HDP_MARK4"

finish
