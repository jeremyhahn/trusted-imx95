#!/usr/bin/env bash
# Tests of scripts/xkms/xkmsd-upgrade.sh: a local bare repository as XKMS_REPO,
# a stub ssh on PATH that prints a version or fails, and stub build and deploy
# scripts that log their arguments. No board, no network, no keys.
set -uo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

upgrade=${XKMSD_UPGRADE:-$ROOT/scripts/xkms/xkmsd-upgrade.sh}

# A throwaway repository must not read the caller's git configuration (signing).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# --- the go-xkms stand-in: a bare repo with two commits and two tags ---------
bare=$TMP_ROOT/go-xkms.git
git init -q --bare "$bare"
empty=$(git -C "$bare" mktree </dev/null)
A=$(git -C "$bare" commit-tree -m first "$empty")
B=$(git -C "$bare" commit-tree -m second -p "$A" "$empty")
git -C "$bare" update-ref refs/heads/main "$B"
git -C "$bare" tag -a -m annotated v1 "$A"
git -C "$bare" tag v0 "$A"
# a tag named like the branch makes the ref "main" ambiguous
git -C "$bare" tag main "$A"
OTHER=0123456789abcdef0123456789abcdef01234567

# --- the stubs ---------------------------------------------------------------
fakebin=$TMP_ROOT/fakebin
mkdir -p "$fakebin"
LOG=$TMP_ROOT/calls.log
BUILD_OUT=$TMP_ROOT/out
cat >"$fakebin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >>"$CALL_LOG"
[ -z "${FAKE_SSH_FAIL:-}" ] || exit 255
[ -z "${FAKE_VERSION:-}" ] || printf '%s\n' "$FAKE_VERSION"
EOF
cat >"$TMP_ROOT/build.sh" <<'EOF'
#!/bin/sh
echo "build $*" >>"$CALL_LOG"
echo "xkmsd-build: building go-xkms $1"
[ -z "${BUILD_FAIL:-}" ] || { echo "xkmsd-build: boom" >&2; exit 3; }
d=$BUILD_OUT/$1
mkdir -p "$d"
echo "go-xkms-commit: ${BUILD_MANIFEST_COMMIT:-$1}" >"$d/manifest.txt"
[ -z "${BUILD_NO_DIR:-}" ] || exit 0
echo "xkmsd-build: output $d"
echo "xkmsd-build: sha256: 00  xkmsd"
EOF
cat >"$TMP_ROOT/deploy.sh" <<'EOF'
#!/bin/sh
echo "deploy $*" >>"$CALL_LOG"
exit "${DEPLOY_RC:-0}"
EOF
chmod +x "$fakebin/ssh" "$TMP_ROOT/build.sh" "$TMP_ROOT/deploy.sh"

export CALL_LOG=$LOG BUILD_OUT
export XKMS_REPO=$bare XKMSD_BUILD=$TMP_ROOT/build.sh XKMSD_DEPLOY=$TMP_ROOT/deploy.sh
export PATH=$fakebin:$PATH
unset FAKE_SSH_FAIL FAKE_VERSION BUILD_FAIL BUILD_MANIFEST_COMMIT BUILD_NO_DIR DEPLOY_RC

# up <args...>: one run of the script with a fresh call log
up() {
	: >"$LOG"
	run "$upgrade" "$@"
}
calls() { printf '%s' "$(<"$LOG")"; }
# called <name> <prefix>: some logged call begins with <prefix>
called() {
	local l
	while IFS= read -r l; do [[ $l == "$2"* ]] && return 0; done <"$LOG"
	return 1
}
# not_called <name> <prefix>
not_called() { ! called "$@"; }
# only <prefix>: the log's lines that begin with build or deploy, in order
bd() {
	local l out=""
	while IFS= read -r l; do
		case $l in build* | deploy*) out+="$l;" ;; esac
	done <"$LOG"
	printf '%s' "$out"
}

T=board.test

# --- help and usage ----------------------------------------------------------
up --help
check "help" 0 "usage: xkmsd-upgrade.sh" "--apply" "--ref"
up
check "no target is a usage error" 2 "no ssh target"
up --bogus "$T"
check "unknown option is a usage error" 2 "unknown option"
up "$T" other
check "two targets are a usage error" 2 "more than one"
up --ref
check "--ref without a value is a usage error" 2 "--ref needs a value"
up --ref -x "$T"
check "--ref starting with a dash is a usage error" 2 "bad --ref"
expect "usage errors contacted nothing" test -z "$(calls)"

# --- current -----------------------------------------------------------------
export FAKE_VERSION="xkmsd 0.1.0+g${B:0:12} commit $B"
up "$T"
check "current: exit 0 and the commit" 0 "current $B"
expect "current: the board was asked" called x "ssh "
expect "current: build not called" not_called x build
up --apply "$T"
check "current with --apply: exit 0" 0 "current $B"
expect "current with --apply: build and deploy not called" test -z "$(bd)"

# --- behind, without --apply -------------------------------------------------
export FAKE_VERSION="xkmsd 0.1.0+g${A:0:12} commit $A"
up "$T"
check "behind: exit 10, the board's report and the latest commit" 10 "behind: board xkmsd 0.1.0+g${A:0:12} commit $A, latest $B"
expect "behind without --apply: build and deploy not called" test -z "$(bd)"
expect "behind: one line" test "$(printf '%s\n' "$OUT" | wc -l)" -eq 1
# the version command runs on the board, with the ssh options of the deploy
expect "behind: ssh runs xkmsd --version on the target" called x "ssh -o BatchMode=yes -o ConnectTimeout=10 $T /usr/local/bin/xkmsd --version"
# a short-hash-only version (no full commit) is behind, not current
export FAKE_VERSION="xkmsd 0.0.1+gabcdef1234"
up "$T"
check "a short hash that is not the commit's is behind" 10 "behind: board xkmsd 0.0.1+gabcdef1234"

# --- behind, with --apply ----------------------------------------------------
export FAKE_VERSION="xkmsd 0.1.0+g${A:0:12} commit $A"
up --apply "$T"
check "apply: exit 0" 0 "behind: board"
expect "apply: build with the commit, then deploy with the target and the build dir" test "$(bd)" = "build $B;deploy $T $BUILD_OUT/$B;"
DEPLOY_RC=7 up --apply "$T"
check "apply: the deploy's status is the exit status" 7
expect "apply: deploy ran" called x "deploy $T $BUILD_OUT/$B"

# --- build failure -----------------------------------------------------------
BUILD_FAIL=1 up --apply "$T"
check "build fails: nonzero exit" nonzero "nothing is deployed"
expect "build fails: build was called" called x "build $B"
expect "build fails: deploy not called" not_called x deploy
BUILD_NO_DIR=1 up --apply "$T"
check "build prints no directory: exit 1" 1 "no build directory"
expect "build prints no directory: deploy not called" not_called x deploy
BUILD_MANIFEST_COMMIT=$OTHER up --apply "$T"
check "build dir holds another commit: exit 1" 1 "not $B"
expect "build dir holds another commit: deploy not called" not_called x deploy

# --- the ref does not resolve ------------------------------------------------
XKMS_REPO=$TMP_ROOT/missing.git up --apply "$T"
check "ls-remote fails: exit 1" 1 "ls-remote"
expect "ls-remote fails: nothing called" test -z "$(calls)"
up --ref refs/heads/nope --apply "$T"
check "ls-remote finds nothing: exit 1" 1 "names 0 refs"
expect "ls-remote finds nothing: nothing called" test -z "$(calls)"
up --ref main "$T"
check "an ambiguous ref is refused" 1 "names 2 refs"
expect "an ambiguous ref: nothing called" test -z "$(calls)"

# --- ssh fails ---------------------------------------------------------------
FAKE_SSH_FAIL=1 up --apply "$T"
check "ssh fails: exit 1, unknown" 1 "unknown: ssh to the board failed"
expect "ssh fails: build and deploy not called" test -z "$(bd)"
FAKE_SSH_FAIL=1 up "$T"
check "ssh fails without --apply: exit 1" 1 "unknown:"

# --- an unknown version ------------------------------------------------------
export FAKE_VERSION="not a version at all"
up "$T"
check "garbage version: unknown, exit 1" 1 "unknown: board reported 'not a version at all'"
up --apply "$T"
check "garbage version with --apply: refused, exit 1" 1 "unknown:" "refusing to --apply"
expect "garbage version with --apply: build and deploy not called" test -z "$(bd)"
export FAKE_VERSION=""
up --apply "$T"
check "an empty answer is unknown" 1 "unknown:"
expect "an empty answer: build not called" test -z "$(bd)"

# --- --ref -------------------------------------------------------------------
export FAKE_VERSION="xkmsd commit $A"
up --ref refs/tags/v1 "$T"
check "--ref an annotated tag: the peeled commit is current" 0 "current $A"
up --ref v0 "$T"
check "--ref a lightweight tag: current" 0 "current $A"
export FAKE_VERSION="xkmsd commit $B"
up --ref v1 --apply "$T"
check "--ref a tag the board is not on: apply deploys that commit" 0 "latest $A"
expect "--ref a tag: build got the tag's commit" test "$(bd)" = "build $A;deploy $T $BUILD_OUT/$A;"
up --ref refs/heads/main "$T"
check "--ref the branch: current" 0 "current $B"

# --- --dry-run ---------------------------------------------------------------
export FAKE_SSH_FAIL=1
XKMS_REPO=$TMP_ROOT/missing.git up --dry-run --apply "$T"
check "dry-run: plan only, exit 0" 0 "plan: git ls-remote" "plan: ssh $T" "plan: when behind"
expect "dry-run: nothing called" test -z "$(calls)"
up --dry-run "$T"
check "dry-run without --apply" 0 "plan: without --apply"
expect "dry-run without --apply: nothing called" test -z "$(calls)"
up --dry-run
check "dry-run still needs a target" 2 "no ssh target"
unset FAKE_SSH_FAIL

finish
