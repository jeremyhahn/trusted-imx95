#!/usr/bin/env bash
# The test-only helper test/okp_station_preflight_helper.sh refuses by default, checks SPSDK_VENV and the SPSDK pin,
# and runs no step (issue #176, owner ruling 1234). Test doubles only: the venv's python is a
# stub script, and every device tool on PATH is a double that logs its call. The log must be
# empty in every case.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
script="$here/test/okp_station_preflight_helper.sh"
pin=$(grep -m1 -oE '^spsdk==[0-9][0-9A-Za-z.]*' "$here/scripts/ahab/requirements.txt")
pin=${pin#spsdk==}

work=$(mktemp -d)
inside=$(mktemp -d -p "$here" .okp-preflight-venv.XXXXXX)
trap 'rm -rf "$work" "$inside"' EXIT

log="$work/doubles.log"
: >"$log"
mkdir -p "$work/bin"
for t in nxpele blhost uuu nxpuuu fastboot; do
	printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$t" "$log" >"$work/bin/$t"
	chmod +x "$work/bin/$t"
done

# mkvenv <dir> <version>: a venv whose bin/python is a stub reporting <version>.
mkvenv() {
	mkdir -p "$1/bin"
	printf '#!/bin/sh\necho "%s"\n' "$2" >"$1/bin/python"
	chmod +x "$1/bin/python"
}
mkvenv "$work/venv-pin" "$pin"
mkvenv "$work/venv-old" "3.12.0"
mkvenv "$inside" "$pin"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=1; }

# run <expect: pass|fail> <name> <want text or ""> <env var=value ...> -- <args...>
run() {
	local expect=$1 name=$2 want=$3 out rc=0
	shift 3
	local envs=()
	while [ "$1" != "--" ]; do
		envs+=("$1")
		shift
	done
	shift
	out=$(env -u SPSDK_VENV "${envs[@]}" PATH="$work/bin:$PATH" bash "$script" "$@" 2>&1) || rc=$?
	if [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then
		bad "$name: failed rc=$rc: $out"
	elif [ "$expect" = fail ] && [ "$rc" -eq 0 ]; then
		bad "$name: passed, expected a refusal"
	elif [ -n "$want" ] && [[ $out != *"$want"* ]]; then
		bad "$name: output lacks '$want': $out"
	else
		ok "$name"
	fi
	last=$out
}

run fail "no argument fails" "usage" X=1 --
run fail "--run is refused" "refused" SPSDK_VENV="$work/venv-pin" -- --run
run fail "--dry-run plus a second argument is refused" "refused" SPSDK_VENV="$work/venv-pin" -- --dry-run --run
run fail "unset SPSDK_VENV names it" "SPSDK_VENV" X=1 -- --dry-run
run fail "a venv inside the clone fails" "inside the clone" SPSDK_VENV="$inside" -- --dry-run
run fail "an installed 3.12.0 fails naming both versions" "3.12.0" SPSDK_VENV="$work/venv-old" -- --dry-run
[[ $last == *"$pin"* ]] || bad "the mismatch message does not name the pin $pin: $last"
run pass "the pinned version passes" "ruling 1234" SPSDK_VENV="$work/venv-pin" -- --dry-run
count=$(grep -c 'ruling 1234' <<<"$last" || true)
if [ "$count" -ge 4 ]; then ok "four steps each name ruling 1234"; else bad "expected 4 steps with ruling 1234, got $count: $last"; fi
if [[ $last == *"ran none of these steps"* ]]; then ok "it says it runs no step"; else bad "it does not say it runs no step"; fi

if [ -s "$log" ]; then bad "a device double was called: $(cat "$log")"; else ok "the device doubles were never called"; fi
exit $fails
