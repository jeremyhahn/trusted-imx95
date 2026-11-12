#!/usr/bin/env bash
# check-script-tests.sh <threshold-percent>
#
# `make coverage` for a repository of scripts: the share of the project's own
# scripts (scripts/, less the CI companions copied from the handbook
# templates, which the handbook tests) that a test under test/ runs by name.
# Below the threshold it fails and names each untested script.
set -euo pipefail

threshold=${1:?usage: check-script-tests.sh <threshold-percent>}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

# Handbook template companions (software/templates/github-actions).
companions=" in-toolchain-image.sh ci-image-cache.sh trim-ci-caches.sh apk-index-sum.sh reap-stale-ci-stacks.sh "

tests=$(cat test/*.sh)
total=0
covered=0
for f in scripts/*.sh scripts/*.py; do
	base=${f##*/}
	case "$companions" in *" $base "*) continue ;; esac
	[ "$base" = tool-pins.sh ] && continue # data, sourced by the others
	total=$((total + 1))
	if [[ "$tests" == *"$f"* ]]; then
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
