#!/usr/bin/env bash
# check-script-tests.sh <threshold-percent>
#
# `make coverage` for a repository of scripts: the share of the project's own
# scripts (scripts/, less the CI companions copied from the handbook
# templates, which the handbook tests) that the tests under test/ execute.
# Below the threshold it fails and names each untested script.
#
# A script counts only when a test runs it: test/*_test.sh run with shims for
# bash, sh and python3 first on PATH, and each shim records the script it is
# asked to run (not `-c` code, not a `-n` parse) before it execs the real
# interpreter. Every project script starts through one of them (`#!/usr/bin/env
# bash`, `#!/usr/bin/env python3`, or `sh script`). A name in a comment, a
# string or a parse-only `bash -n` is not a test. A failing test fails this too.
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
fail=0
for t in "${tests[@]}"; do
	PATH="$work/shims:$PATH" bash "$t" >"$work/out" 2>&1 || {
		echo "check-script-tests: $t failed:" >&2
		cat "$work/out" >&2
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
