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

finish
