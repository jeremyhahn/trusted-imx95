#!/usr/bin/env bash
# test/hsd_a55_test.sh: host tests of the A55 tamper-event parser and the
# quarantine state machine (hsm-self-defence/a55/, issue #26, proposed).
# Compiles each C test with cc -std=c99 -Wall -Wextra -Werror (plus
# -fsanitize=address,undefined when the compiler supports it), runs it, and
# checks that every vector of the design note appears in the parser test.
# No cc fails the test; nothing is skipped. Nothing opens a device.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=test/lib.sh
. "$here/lib.sh"

src=$ROOT/hsm-self-defence/a55
note=$ROOT/docs/hsm-self-defence/a55-tamper-response-design.md

if ! command -v cc >/dev/null 2>&1; then
	echo "FAIL hsd_a55: no C compiler (cc) on PATH; the host tests cannot run"
	exit 1
fi

cflags=(-std=c99 -Wall -Wextra -Werror -O1 -g)
mode=plain
printf 'int main(void){return 0;}\n' >"$TMP_ROOT/probe.c"
if cc "${cflags[@]}" -fsanitize=address,undefined "$TMP_ROOT/probe.c" -o "$TMP_ROOT/probe" >/dev/null 2>&1 &&
	"$TMP_ROOT/probe" >/dev/null 2>&1; then
	cflags+=(-fsanitize=address,undefined -fno-sanitize-recover=undefined)
	mode=sanitized
fi
echo "hsd_a55: compiler flags: ${cflags[*]} ($mode)"

# build_run <name> <srcdir> <file.c...>: compile and run one test binary.
build_run() {
	local name=$1 dir=$2 bin
	shift 2
	bin=$TMP_ROOT/$name
	run cc "${cflags[@]}" -I"$dir" -o "$bin" "$@"
	expect_rc "$name compiles" 0 || { echo "$OUT"; return 0; }
	run "$bin"
	check "$name runs" 0 "all passed"
}

build_run tamper_event_test "$src" "$src/tamper_event_test.c" "$src/tamper_event.c"

# Every hex vector of the note appears in the parser test (and the state
# machine test, when it carries them).
vectors=0
missing=
testtxt=$(<"$src/tamper_event_test.c")
re='`([0-9a-f]{2}( [0-9a-f]{2})+)`'
while IFS= read -r line; do
	[[ $line =~ ^\|\ (V|R)[0-9]+\  ]] || continue
	[[ $line =~ $re ]] || continue
	hex=${BASH_REMATCH[1]}
	vectors=$((vectors + 1))
	id=${line#| }
	id=${id%% *}
	# R12 (replay) is the same bytes as V1 and is the state machine's.
	[[ $testtxt == *"\"$hex\""* ]] || [ "$id" = R12 ] || missing+=" $id"
done <"$note"
if [ "$vectors" -ge 18 ] && [ -z "$missing" ]; then
	pass "every note vector ($vectors) is in tamper_event_test.c"
else
	fail "note vectors in tamper_event_test.c" "vectors found: $vectors; missing:$missing"
fi

# Negative case: a scratch copy whose parser accepts an unknown version must
# make the test fail.
scratch=$TMP_ROOT/mutant
mkdir -p "$scratch"
cp "$src"/tamper_event.[ch] "$src/tamper_event_test.c" "$scratch/"
parser=$(<"$scratch/tamper_event.c")
needle='if (le16(buf + 4) != TAMPER_EVENT_VERSION)'
if [[ $parser != *"$needle"* ]]; then
	fail "mutant: version check present in parser" "needle not found"
else
	printf '%s\n' "${parser/"$needle"/if (0)}" >"$scratch/tamper_event.c"
	run cc "${cflags[@]}" -I"$scratch" -o "$scratch/t" "$scratch/tamper_event_test.c" "$scratch/tamper_event.c"
	if [ "$RC" -ne 0 ]; then
		fail "mutant parser (accepts unknown version) compiles" "$OUT"
	else
		run "$scratch/t"
		check "mutant parser accepting an unknown version fails the test" nonzero "FAIL"
	fi
fi

finish
