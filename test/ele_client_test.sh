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
# A nonexistent parent inside the checkout is still inside it, and nothing is created.
run bash "$script" --work "$ROOT/.fresh-ele/work" --out "$tmp/out"
check "work under a nonexistent directory of the checkout" 1 "outside the checkout"
[ ! -e "$ROOT/.fresh-ele" ] || { rm -rf "$ROOT/.fresh-ele"; fail "the refused work directory was created in the checkout"; }
run bash "$script" --work ".fresh-ele2/work" --out "$tmp/out"
check "relative work under a nonexistent directory (cwd is the checkout)" 1 "outside the checkout"
# A symlink as the final component, or on the way, that points into the checkout.
ln -s "$ROOT/secure-key-handling" "$tmp/lnk"
run bash "$script" --work "$tmp/lnk" --out "$tmp/out"
check "work is a symlink into the checkout" 1 "outside the checkout"
run bash "$script" --work "$tmp/lnk/new/work" --out "$tmp/out"
check "work under a symlink into the checkout, nonexistent tail" 1 "outside the checkout"
ln -s "$ROOT/.fresh-ele3" "$tmp/dangling"
run bash "$script" --work "$tmp/dangling" --out "$tmp/out"
check "work is a dangling symlink into the checkout" 1 "outside the checkout"
[ ! -e "$ROOT/.fresh-ele3" ] || { rm -rf "$ROOT/.fresh-ele3"; fail "a dangling symlink work directory was created in the checkout"; }
run bash "$script" --work "$ROOT/.." --out "$tmp/out"
check "work that contains the checkout" 1 "must not contain the checkout"

# A reused --out is refused before anything is fetched: a stale, lexically
# earlier libele_hsm.so.* in it can never be selected or listed. (The build
# itself stages into $work/stage and publishes only into an empty --out; it
# needs the network, so only the refusal runs here.)
mkdir -p "$tmp/reused"
: >"$tmp/reused/libele_hsm.so.0.0.1"
run bash "$script" --work "$tmp/reused-work" --out "$tmp/reused"
check "a non-empty --out holding an older libele_hsm.so.* is refused" 1 "not an empty directory"
if [ ! -e "$tmp/reused-work" ]; then pass "the refusal came before anything was fetched"; else fail "the refusal came before anything was fetched"; fi
: >"$tmp/afile"
run bash "$script" --work "$tmp/reused-work" --out "$tmp/afile"
check "an --out that is a file is refused" 1 "not an empty directory"

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
	# ele_hsm_open locks all process memory before the library sees the nonce.
	# Try to raise the soft limit to the hard one; the command is refused (exit 2)
	# when the lock still fails, so a host that cannot lock is reported here.
	ulimit -S -l "$(ulimit -H -l)" 2>/dev/null || true
	cli 0 --split-confirmed 5 3 del 7
	case $OUT in *"cannot lock the process memory"*) fail "the host cannot mlockall this process (RLIMIT_MEMLOCK $(ulimit -l)): the CLI tests cannot run" ;; esac
	for bad in 4294967297 1junk -1 "" 0x0x7 0X0x7 0x +7 " 7" "7 "; do
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
	# HSM_NO_ERROR cannot show the counter advanced (a success-tagged warning maps to it): fail closed.
	check "gen with a confirmed split is refused, never reported rollback-protected" 1 "key 7 was generated and is NOT rollback-protected"
	case $OUT in *"key 7 rollback-protected"*) fail "gen claimed rollback protection" ;; esac
	cli 0 5 3 gen
	check "gen with the split unconfirmed fails" 1 "refused"
	no_hsm_call "gen with the split unconfirmed (no session, no service, no generate)"
	cli 0 --split-confirmed 5 3 gen
	check "gen with a confirmed split names the key it generated" 1 "key 7"
	grep -q '^open_session dumpable=0$' "$tmp/hsm.log" || fail "the CLI did not set PR_SET_DUMPABLE 0 before opening the HSM"
	# sign prints the double's known signature bytes, byte i = (3i+1)&0xff.
	want=
	for i in $(seq 0 63); do want+=$(printf '%02x' $(((3 * i + 1) & 255))); done
	cli 0 5 3 sign 7 msg
	check "sign prints the signature as one line of lowercase hex" 0 "$want"
	[ "$OUT" = "$want" ] || fail "sign output is not exactly the signature hex"
	# A producer that writes the nonce line and keeps its end open (no EOF):
	# the client must stop at the newline. The timeout turns a hang into a failure.
	mkfifo "$tmp/nfifo"
	exec 4<>"$tmp/nfifo"
	printf '1234\n' >&4
	ELE_FAKE_ERR=0 ELE_FAKE_LOG="$tmp/hsm.log" run timeout 10 "$tmp/ele_cli" 5 3 sign 7 msg 3<"$tmp/nfifo"
	check "the nonce line is read without waiting for EOF (producer keeps its end open)" 0 "$want"
	# Over-length, empty and newline-only input still fail.
	printf '12345678901234567\n' >&4
	ELE_FAKE_ERR=0 ELE_FAKE_LOG="$tmp/hsm.log" run timeout 10 "$tmp/ele_cli" 5 3 sign 7 msg 3<"$tmp/nfifo"
	check "an over-long nonce line is refused" 2 "cannot read the nonce"
	printf '\n' >&4
	ELE_FAKE_ERR=0 ELE_FAKE_LOG="$tmp/hsm.log" run timeout 10 "$tmp/ele_cli" 5 3 sign 7 msg 3<"$tmp/nfifo"
	check "an empty nonce line is refused" 2 "cannot read the nonce"
	exec 4>&-
	for i in $(seq 0 63); do printf '%b' "\\x$(printf '%02x' $(((3 * i + 1) & 255)))"; done >"$tmp/sig.bin"
	rm -f "$tmp/hsm.log"
	ELE_FAKE_LOG="$tmp/hsm.log" "$tmp/ele_cli" --raw 5 3 sign 7 msg 3<"$tmp/nonce" >"$tmp/sig.out"
	cmp -s "$tmp/sig.out" "$tmp/sig.bin" || fail "sign --raw is not exactly the signature bytes"
	cli 0 --raw 5 3 del 7
	check "--raw on del refused" 2 "usage"
	cli 0x10 --split-confirmed 5 3 gen
	check "counter warning: nonzero exit" 1 "update refused"
	check "counter warning: the accepted key id is reported" 1 "key 7 was generated and is NOT rollback-protected"
	cli 0x10 --split-confirmed 5 3 del 7
	check "counter warning on delete: nonzero exit" 1 "update refused"
	cli 0xfe --split-confirmed 5 3 gen
	check "other HSM error after the started marker: exit 3, unknown outcome" 3 "outcome unknown"
	cli 0 --split-confirmed 5 3 del 7
	check "delete with HSM_NO_ERROR (a hidden counter warning looks the same) fails closed" 1 "update refused (committed-not-rollback-protected); key 7 delete is NOT rollback-protected"
	case $OUT in *"deleted "*) fail "del claimed success without a counter acknowledgement" ;; esac
	# The child dies after the started marker (mode 3: SIGKILL, 4: exit 3 inside
	# the update call): the outcome is unknown, exit 3, never a plain failure.
	for mode in 3 4; do
		ELE_FAKE_MODE=$mode cli 0 --split-confirmed 5 3 gen
		check "generate, child dies after the started marker (mode $mode): exit 3" 3 "outcome unknown"
		ELE_FAKE_MODE=$mode cli 0 --split-confirmed 5 3 del 7
		check "delete, child dies after the started marker (mode $mode): exit 3" 3 "the key store may have changed"
	done
	# Any vendor error after the marker is the same unknown outcome.
	cli 0xfe --split-confirmed 5 3 gen
	check "generate, vendor error after the started marker: exit 3" 3 "outcome unknown"
	cli 0xfe --split-confirmed 5 3 del 7
	check "delete, vendor error after the started marker: exit 3" 3 "outcome unknown"
	# A death before the marker (mode 2: the key store open) is a plain failure.
	ELE_FAKE_MODE=2 cli 0 --split-confirmed 5 3 gen
	check "generate, child dies before the started marker: exit 1" 1 "failed"
	case $OUT in *"outcome unknown"*) fail "a death before the marker was reported as unknown" ;; esac
	# Hexadecimal sign output on an unbuffered stdout that cannot be written.
	if [ -w /dev/full ] && command -v stdbuf >/dev/null 2>&1; then
		rc=0
		ELE_FAKE_LOG="$tmp/hsm.log" stdbuf -o0 "$tmp/ele_cli" 5 3 sign 7 msg 3<"$tmp/nonce" >/dev/full 2>"$tmp/full.err" || rc=$?
		[ "$rc" != 0 ] || fail "hex sign with an unbuffered full stdout exited 0"
		rc=0
		ELE_FAKE_LOG="$tmp/hsm.log" "$tmp/ele_cli" 5 3 sign 7 msg 3<"$tmp/nonce" >/dev/full 2>"$tmp/full.err" || rc=$?
		[ "$rc" != 0 ] || fail "hex sign with a buffered full stdout exited 0"
		rc=0
		ELE_FAKE_LOG="$tmp/hsm.log" "$tmp/ele_cli" --raw 5 3 sign 7 msg 3<"$tmp/nonce" >/dev/full 2>"$tmp/full.err" || rc=$?
		[ "$rc" != 0 ] || fail "raw sign with a full stdout exited 0"
	else
		fail "/dev/full or stdbuf is not available here"
	fi
	# A result that cannot be written: exit 1, the key id and its state on stderr.
	if [ -w /dev/full ]; then
		rc=0
		"$tmp/ele_cli" --split-confirmed 5 3 gen 3<"$tmp/nonce" >/dev/full 2>"$tmp/full.err" || rc=$?
		[ "$rc" = 1 ] || fail "gen with a full stdout: exit $rc, want 1"
		grep -q 'key 7 was generated' "$tmp/full.err" || fail "gen with a full stdout: the key id is not on stderr"
		rc=0
		"$tmp/ele_cli" --split-confirmed 5 3 del 7 3<"$tmp/nonce" >/dev/full 2>"$tmp/full.err" || rc=$?
		[ "$rc" = 1 ] || fail "del with a full stdout: exit $rc, want 1"
		grep -q 'key 7 delete is NOT rollback-protected' "$tmp/full.err" || fail "del with a full stdout: the key id is not on stderr"
	else
		fail "/dev/full is not writable here"
	fi
	# A reader that has gone away: EPIPE reaches the checked write (SIGPIPE is
	# ignored), so the exit is 1 and the key id is on stderr, not a signal death.
	for op in "gen" "del 7"; do
		rm -f "$tmp/pipe.rc" "$tmp/pipe.err"
		{
			sleep 0.5 # the reader below has closed its end by now
			prc=0
			# shellcheck disable=SC2086
			"$tmp/ele_cli" --split-confirmed 5 3 $op 3<"$tmp/nonce" 2>"$tmp/pipe.err" || prc=$?
			echo "$prc" >"$tmp/pipe.rc"
		} | { exec 0<&-; sleep 1; }
		[ "$(cat "$tmp/pipe.rc" 2>/dev/null)" = 1 ] || fail "$op with a closed reader: exit $(cat "$tmp/pipe.rc" 2>/dev/null), want 1"
		grep -Eq 'key 7 (was |delete is)' "$tmp/pipe.err" || fail "$op with a closed reader: the key id is not on stderr"
	done
elif [ "${REQUIRE_ELE_SRC:-}" = 1 ]; then
	# The toolchain image sets REQUIRE_ELE_SRC=1 beside ELE_SRC, the verified
	# pinned source. There, not finding it is a failure, not a skip.
	fail "ELE_SRC is required (REQUIRE_ELE_SRC=1) and does not name the pinned source: ${ELE_SRC:-unset}"
else
	echo "skip: ELE_SRC unset (backend constants check skipped; the build script runs it)"
fi

finish
