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
	check "client policy tests: both flags, strict only, counter only, neither, counter warning fails" 0 "all passed"
	run cc -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -o "$tmp/ele_cli_args_test" \
		"$d/ele_cli_args.c" "$d/ele_cli_args_test.c"
	check "cli argument tests compile" 0
	run "$tmp/ele_cli_args_test"
	check "cli args: strict numbers (4294967297, 1junk, -1, '' refused), nonce never from argv" 0 "all passed"
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

	# The shipped backend against a test double of libele_hsm (built on the
	# library's headers): the flags it sends and its return-code translation.
	bsrc=("$d/ele_hsm_backend.c" "$d/ele_hsm_fake.c" "$d/ele_client.c")
	run cc -std=gnu11 -Wall -Wextra -Werror "${inc[@]}" -o "$tmp/ele_hsm_backend_test" \
		"${bsrc[@]}" "$d/ele_hsm_backend_test.c"
	check "backend test compiles against the double" 0
	run "$tmp/ele_hsm_backend_test"
	check "backend: flags sent (strict+counter; delete strict only; no CREATE/PLAINTEXT) and HSM_NO_ERROR/HSM_KEY_STORE_COUNTER/other" 0 "all passed"

	# The command line over the same double.
	run cc -std=gnu11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror "${inc[@]}" -o "$tmp/ele_cli" \
		"${bsrc[@]}" "$d/ele_cli_args.c" "$d/ele_client_cli.c"
	check "ele_client command line compiles against the double" 0
	printf '1234\n' >"$tmp/nonce"
	cli() { # cli ERR ARGS...: run with nonce on fd 3, the double's log in $tmp/hsm.log
		local err=$1
		shift
		rm -f "$tmp/hsm.log"
		ELE_FAKE_ERR=$err ELE_FAKE_LOG="$tmp/hsm.log" run "$tmp/ele_cli" "$@" 3<"$tmp/nonce"
	}
	no_hsm_call() { [ ! -e "$tmp/hsm.log" ] || fail "$1: an HSM call was made"; }
	for bad in 4294967297 1junk -1 ""; do
		cli 0 --split-confirmed 5 3 del "$bad"
		check "del '$bad' refused" 2 "usage"
		no_hsm_call "del '$bad'"
	done
	cli 0 --split-confirmed 5 1234 gen
	check "a nonce in argv is not accepted" 2 "usage"
	no_hsm_call "nonce in argv"
	cli 0 --split-confirmed 5 99 gen
	check "an unreadable nonce descriptor is refused before the store opens" 2 "cannot read the nonce"
	no_hsm_call "bad nonce fd"
	cli 0 --split-confirmed 5 3 gen
	check "gen with a confirmed split" 0 "rollback-protected"
	cli 0 5 3 gen
	check "gen with the split unconfirmed fails, state shown" 1 "update refused (committed-not-rollback-protected)"
	cli 0x10 --split-confirmed 5 3 gen
	check "counter warning: nonzero exit" 1 "update refused"
	cli 0x10 --split-confirmed 5 3 del 7
	check "counter warning on delete: nonzero exit" 1 "update refused"
	cli 0xfe --split-confirmed 5 3 gen
	check "other HSM error: nonzero exit" 1 "failed"
	cli 0 --split-confirmed 5 3 del 7
	check "delete: committed, not rollback-protected" 0 "deleted committed-not-rollback-protected"
else
	echo "skip backend constants check: ELE_SRC is not set (the build script runs it)"
fi

finish
