#!/usr/bin/env bash
# check-script-tests.sh <threshold-percent>: share of project scripts the test/*_test.sh suite executes, recorded by interpreter shims; below the threshold it fails naming each untested script.
set -euo pipefail

threshold=${1:?usage: check-script-tests.sh <threshold-percent>}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

# Handbook template companions (software/templates/github-actions).
companions=" in-toolchain-image.sh ci-image-cache.sh trim-ci-caches.sh apk-index-sum.sh reap-stale-ci-stacks.sh "

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trace="$work/trace"
: >"$trace"
mkdir "$work/shims"
for interp in bash sh python3; do
	real=$(command -v "$interp") || { echo "check-script-tests: $interp is not on PATH" >&2; exit 1; }
	cat >"$work/shims/$interp" <<EOF
#!/bin/sh
# Records the script operand, then runs the real $interp.
for a in "\$@"; do
	case "\$a" in
	-c | -n) break ;;
	-*) ;;
	*) [ -f "\$a" ] && printf '%s\n' "\$a" >>'$trace'; break ;;
	esac
done
exec '$real' "\$@"
EOF
	chmod +x "$work/shims/$interp"
done

tests=(test/*_test.sh)
[ -f "${tests[0]}" ] || { echo "check-script-tests: no test/*_test.sh found" >&2; exit 1; }
# `make coverage`'s only run of the suite: each test's output is printed as
# `make test` prints it, and a failing test fails the count.
fail=0
for t in "${tests[@]}"; do
	echo "--- $t"
	PATH="$work/shims:$PATH" bash "$t" 2>&1 || {
		echo "FAIL $t"
		echo "check-script-tests: $t failed" >&2
		fail=1
	}
done
[ "$fail" = 0 ] || exit 1

total=0
covered=0
for f in scripts/*.sh scripts/*.py; do
	[ -f "$f" ] || continue
	base=${f##*/}
	case "$companions" in *" $base "*) continue ;; esac
	[ "$base" = tool-pins.sh ] && continue # data, sourced by the others
	total=$((total + 1))
	ran=0
	while IFS= read -r p; do
		case "$p" in scripts/"$base" | */scripts/"$base") ran=1 && break ;; esac
	done <"$trace"
	if [ "$ran" = 1 ]; then
		covered=$((covered + 1))
	else
		echo "check-script-tests: $f: no test under test/ runs it"
	fi
done

if [ "$total" -eq 0 ]; then
	echo "check-script-tests: no project script found under scripts/" >&2
	exit 1
fi
pct=$((covered * 100 / total))
echo "check-script-tests: $covered of $total scripts tested ($pct%, threshold $threshold%)"
[ "$pct" -ge "$threshold" ]
