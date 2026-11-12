#!/usr/bin/env bash
# End to end through make, in a fixture copy of the repository: the build
# stage, the CST guard as a build prerequisite would meet it, and make test
# and make security refusing a tracked CST tree. Runs offline, as uid 10001
# on a read-only root in the integration image (make integration-test).
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

repo="$TMP_ROOT/repo"
fixture_repo "$repo"

run make -s -C "$repo" build
check "make build: every script parses and the base image matches the pin file" 0 "build: OK"

run make -s -C "$repo" check-tracked-cst
check "make check-tracked-cst: the fixture tracks no CST" 0 "OK"

# The CST as a build would meet it: unset, wrong, then an extracted tree.
run env -u CST_PATH make -s -C "$repo" cst-check
check "make cst-check: unset CST_PATH stops the build naming CST_PATH" nonzero "CST_PATH is not set"

empty="$TMP_ROOT/empty"
mkdir -p "$empty"
run env CST_PATH="$empty" make -s -C "$repo" cst-check
check "make cst-check: an empty directory is not a CST tree" nonzero "is not a CST tree"

cst="$TMP_ROOT/extract/cst-3.1.0"
mkdir -p "$cst/release/docs" "$cst/release/code/back_end-hsm/doc"
: >"$cst/release/docs/CST_UG.pdf"
run env CST_PATH="$cst" make -s -C "$repo" cst-check
check "make cst-check: an extracted CST tree outside the repository passes" 0 "OK"

# A Dockerfile base that drifts from the pin file fails the build stage.
drift="$TMP_ROOT/drift"
fixture_repo "$drift"
# shellcheck disable=SC2016 # a literal Dockerfile line
printf 'ARG ALPINE_IMAGE=alpine:3.0.0\nFROM ${ALPINE_IMAGE}\n' >"$drift/build/docker/devcontainer/Dockerfile"
run make -s -C "$drift" build
check "make build: a Dockerfile base off the pin file fails" nonzero "lacks 'ARG ALPINE_IMAGE=alpine:"

# A tracked extracted tree fails make test and the security gates.
mkdir -p "$repo/third_party/cst-3.1.0/release/docs"
: >"$repo/third_party/cst-3.1.0/release/docs/CST_UG.pdf"
git -C "$repo" add -f third_party/cst-3.1.0
run make -s -C "$repo" test
check "make test: a tracked cst-*/ tree fails it" nonzero "third_party/cst-3.1.0/release/docs/CST_UG.pdf: tracked inside a CST tree"
run make -s -C "$repo" gosec
check "make gosec: a tracked cst-*/ tree fails it" nonzero "tracked inside a CST tree"

finish
