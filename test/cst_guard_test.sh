#!/usr/bin/env bash
# The Code Signing Tool guard (#8): scripts/cst-check.sh, `make cst-check`,
# scripts/check-tracked-cst.sh and `make test` with a CST tracked.
# docs/references/README.md §The Code Signing Tool in the build.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake CST tree outside the repository: the one documented layout entry.
fake_cst="$TMP_ROOT/cst-3.1.0"
mkdir -p "$fake_cst/release/docs"
: >"$fake_cst/release/docs/CST_UG.pdf"
not_cst="$TMP_ROOT/not-a-cst"
mkdir -p "$not_cst/bin"

# --- scripts/cst-check.sh -------------------------------------------------

run env -u CST_PATH "$ROOT/scripts/cst-check.sh"
check "cst-check: CST_PATH unset exits 2 naming CST_PATH" 2 "CST_PATH is not set"

run env CST_PATH= "$ROOT/scripts/cst-check.sh"
check "cst-check: CST_PATH empty is unset" 2 "CST_PATH is not set"

run env CST_PATH="$not_cst" "$ROOT/scripts/cst-check.sh"
check "cst-check: a directory that is not a CST tree is refused" 1 \
	"is not a CST tree" "release/docs/CST_UG.pdf is missing"

run env CST_PATH="$TMP_ROOT/absent" "$ROOT/scripts/cst-check.sh"
check "cst-check: a missing path is refused" 1 "is not a directory"

run env CST_PATH="$fake_cst/release/docs/CST_UG.pdf" "$ROOT/scripts/cst-check.sh"
check "cst-check: a file is refused" 1 "is not a directory"

run env CST_PATH="$fake_cst" "$ROOT/scripts/cst-check.sh"
check "cst-check: a CST tree outside the repository passes" 0 "OK"

repo="$TMP_ROOT/repo-inside"
fixture_repo "$repo"
mkdir -p "$repo/vendor/cst/release/docs"
: >"$repo/vendor/cst/release/docs/CST_UG.pdf"
run env CST_PATH="$repo/vendor/cst" "$repo/scripts/cst-check.sh"
check "cst-check: a CST tree inside the repository is refused" 1 "inside this repository"

# --- make cst-check -------------------------------------------------------

repo="$TMP_ROOT/repo-make"
fixture_repo "$repo"
run env -u CST_PATH make -s -C "$repo" cst-check
check "make cst-check: CST_PATH unset fails naming CST_PATH" nonzero "CST_PATH is not set"

run env CST_PATH="$not_cst" make -s -C "$repo" cst-check
check "make cst-check: not a CST tree fails saying so" nonzero "is not a CST tree"

run env CST_PATH="$fake_cst" make -s -C "$repo" cst-check
check "make cst-check: a CST tree passes" 0 "OK"

# --- scripts/check-tracked-cst.sh -----------------------------------------

repo="$TMP_ROOT/repo-clean"
fixture_repo "$repo"
run "$ROOT/scripts/check-tracked-cst.sh" "$repo"
check "check-tracked-cst: a clean tree passes (cst-check.sh is not a CST path)" 0 "OK"

repo="$TMP_ROOT/repo-tgz"
fixture_repo "$repo"
mkdir -p "$repo/tools"
: >"$repo/tools/cst-x.tgz"
git -C "$repo" add -f tools/cst-x.tgz
run "$ROOT/scripts/check-tracked-cst.sh" "$repo"
check "check-tracked-cst: a tracked cst-x.tgz fails naming it" 1 "tools/cst-x.tgz: tracked CST archive"

repo="$TMP_ROOT/repo-tree"
fixture_repo "$repo"
mkdir -p "$repo/cst-3.1.0/release/docs"
: >"$repo/cst-3.1.0/release/docs/CST_UG.pdf"
git -C "$repo" add -f cst-3.1.0
run "$ROOT/scripts/check-tracked-cst.sh" "$repo"
check "check-tracked-cst: a tracked cst-*/ tree fails naming the path" 1 \
	"cst-3.1.0/release/docs/CST_UG.pdf: tracked inside a CST tree"

run "$ROOT/scripts/check-tracked-cst.sh" "$TMP_ROOT/absent"
check "check-tracked-cst: an unreadable repository fails" 1 "cannot list"

run git -C "$ROOT" check-ignore -q --no-index tools/cst-3.1.0.tgz
check ".gitignore keeps a CST archive out" 0
run git -C "$ROOT" check-ignore -q --no-index cst-3.1.0/release/docs/CST_UG.pdf
check ".gitignore keeps an extracted CST tree out" 0

# --- make test with a CST tracked -----------------------------------------
# make test runs check-tracked-cst first, so it stops before the unit tests.

repo="$TMP_ROOT/repo-tgz"
run make -s -C "$repo" test
check "make test: a tracked cst-x.tgz fails it" nonzero "tools/cst-x.tgz: tracked CST archive"

finish
