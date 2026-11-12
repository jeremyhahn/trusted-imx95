# shellcheck shell=bash
# test/lib.sh: shared helpers for the test/*_test.sh suites. Source it.
# No test skips: a tool a test needs that is missing fails the test by name.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAILS=0
OUT=
RC=0

# run <cmd...>: runs the command, keeps its combined output in OUT and its
# exit code in RC.
run() {
	RC=0
	OUT=$("$@" 2>&1) || RC=$?
}

pass() { echo "ok   $1"; }
fail() {
	echo "FAIL $1"
	[ -z "${2:-}" ] || echo "     $2"
	FAILS=$((FAILS + 1))
}

# expect_rc <name> <rc>: the last run exited <rc> ("nonzero" for any but 0).
expect_rc() {
	if [ "$2" = nonzero ] && [ "$RC" -ne 0 ]; then
		return 0
	elif [ "$2" = "$RC" ]; then
		return 0
	fi
	fail "$1" "exit $RC, want $2; output: $OUT"
	return 1
}

# expect_out <name> <substring>: the last run's output holds <substring>.
expect_out() {
	if [[ "$OUT" == *"$2"* ]]; then
		return 0
	fi
	fail "$1" "output lacks '$2'; output: $OUT"
	return 1
}

# check <name> <rc> [substring...]: expect_rc and every expect_out, then pass.
check() {
	local name=$1 rc=$2 s
	shift 2
	expect_rc "$name" "$rc" || return 0
	for s in "$@"; do expect_out "$name" "$s" || return 0; done
	pass "$name"
}

# expect <name> <command...>: passes when the command succeeds.
expect() {
	local name=$1
	shift
	if "$@"; then pass "$name"; else fail "$name"; fi
}

# fixture_repo <dir>: a git repository holding a copy of the Makefile, the
# scripts, the tests and the Dockerfile, everything staged.
fixture_repo() {
	mkdir -p "$1"
	cp -R "$ROOT/Makefile" "$ROOT/scripts" "$ROOT/test" "$ROOT/build" "$1/"
	git -C "$1" init -q
	git -C "$1" add -A
}

# finish: the suite's verdict.
finish() {
	if [ "$FAILS" -ne 0 ]; then
		echo "$FAILS failed"
		exit 1
	fi
	echo "all passed"
}
