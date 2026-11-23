#!/usr/bin/env bash
# Tests of secure-key-handling: scripts/ele-lib-build.sh --check-lock and its
# refusals, and the client policy unit tests on the host against the stub.
# Offline; no board, no key. The cross-build itself needs the network and the
# toolchain (scripts/ele-lib-build.sh --work ... --out ...), so it is not run here.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script=$ROOT/scripts/ele-lib-build.sh
lock=$ROOT/secure-key-handling/ele-lib.lock
tmp=$TMP_ROOT

run bash "$script" --check-lock
check "check-lock on the shipped lock" 0 "lock OK"

# mutate NAME REPL: copy the lock to $tmp/lock with the NAME= line replaced by
# REPL (dropped when REPL is empty).
mutate() {
	local name=$1 repl=$2 line
	while IFS= read -r line; do
		case $line in
		"$name="*) [ -z "$repl" ] || printf '%s\n' "$repl" ;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$lock" >"$tmp/lock"
}
# refuse LABEL NAME REPL WANT: the mutated lock is refused with WANT in the message.
refuse() {
	mutate "$2" "$3"
	run bash "$script" --check-lock --lock "$tmp/lock"
	check "$1" 1 "$4"
}
refuse "short commit" ELE_COMMIT "ELE_COMMIT=abc123" "not 40 hex digits"
refuse "bad digest" ELE_ARCHIVE_SHA256 "ELE_ARCHIVE_SHA256=zz" "not 64 hex digits"
refuse "UNREAD commit" ELE_COMMIT "ELE_COMMIT=UNREAD" "is UNREAD"
refuse "missing name" ELE_PLAT "" "ELE_PLAT is missing"
refuse "http repo" ELE_REPO "ELE_REPO=http://example.invalid/x.git" "not an https URL"
refuse "toolchain lock outside the tree" TOOLCHAIN_LOCK "TOOLCHAIN_LOCK=/etc/passwd" "inside the tree"
refuse "toolchain lock missing" TOOLCHAIN_LOCK "TOOLCHAIN_LOCK=secure-world/none.lock" "is not a file"
{ cat "$lock"; echo "ELE_PLAT=ele"; } >"$tmp/lock"
run bash "$script" --check-lock --lock "$tmp/lock"
check "duplicate name" 1 "appears twice"

run bash "$script" --work "$ROOT/.ele-work" --out "$tmp/out"
check "work inside the checkout" 1 "outside the checkout"

# The client policy tests, built with the host compiler.
d=$ROOT/secure-key-handling/client
if command -v cc >/dev/null 2>&1; then
	run cc -std=c99 -Wall -Wextra -Werror -o "$tmp/ele_client_test" \
		"$d/ele_client.c" "$d/ele_stub.c" "$d/ele_client_test.c"
	check "client tests compile" 0
	run "$tmp/ele_client_test"
	check "client policy tests: both flags, strict only, counter only, neither" 0 "all passed"
else
	fail "client policy tests: no C compiler (cc) on PATH"
fi

# The backend's flag constants against the library's headers. Needs the fetched
# source (ELE_SRC=<work>/src from scripts/ele-lib-build.sh), which `make test`
# does not fetch: without it the check is reported as skipped, not passed.
# The build script runs the same check on every build.
if [ -n "${ELE_SRC:-}" ] && [ -d "$ELE_SRC/include/hsm" ]; then
	inc=(-I"$ELE_SRC/include" -I"$ELE_SRC/include/hsm" -I"$ELE_SRC/include/common" -I"$ELE_SRC/include/she"
		-I"$ELE_SRC/include/crrm" -I"$ELE_SRC/include/prime" -I"$ELE_SRC/src/plat/ele/include"
		-I"$ELE_SRC/src/common/include" -I"$d" -DPSA_COMPLIANT)
	run cc -std=gnu11 -fsyntax-only "${inc[@]}" "$d/ele_hsm_consts_check.c"
	check "backend flag constants equal the library header's (strict 1<<7, counter 1<<5, delete strict only)" 0
	# The check bites: a wrong expected value fails the compile.
	python3 -I -c 'import sys
s=open(sys.argv[1]).read().replace("HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER == (1u << 5)","HSM_OP_KEY_GENERATION_FLAGS_MONOTONIC_COUNTER == (1u << 6)")
open(sys.argv[2],"w").write(s)' "$d/ele_hsm_consts_check.c" "$tmp/bad_consts.c"
	run cc -std=gnu11 -fsyntax-only "${inc[@]}" "$tmp/bad_consts.c"
	check "a wrong constant fails the check" nonzero "static assertion failed"
	run cc -std=gnu11 -fsyntax-only "${inc[@]}" "$d/ele_hsm_backend.c"
	check "backend compiles against the library headers" 0
else
	echo "skip backend constants check: ELE_SRC is not set (the build script runs it)"
fi

finish
