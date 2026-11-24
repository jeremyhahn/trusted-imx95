#!/usr/bin/env bash
# scripts/pins-drift-check.sh [pin-file [root]]
#
# Rule j of the pins (scripts/pins-check.sh judges the pin file itself): no
# file restates a pinned version that has moved. Every `python:<ver>-slim` and
# `alpine:<ver>` in docs/**/*.md, scripts/ and test/ under <root> (default: the
# repository) must agree with SW_PYTHON_VERSION and ALPINE_VERSION of the pin
# file. Agreement is equality or a dotted prefix either way, so prose may say
# `alpine:3.24` for 3.24.4. Offline, bash only. Each failure names file, line
# and the pin.
#
# Excluded, by path under <root>:
#   scripts/tool-pins.sh                  the pins themselves
#   scripts/pins-drift-check.sh           this script
#   test/pins_check_test.sh               carry old versions on purpose
#   test/ci_scripts_test.sh
#   test/integration/make_targets_test.sh a fixture Dockerfile with alpine:3.0.0
#   test/pins_drift_check_test.sh         its fixtures are stale versions
# The Dockerfile's ARG lines are outside the three trees; `make build` checks
# them against the pin file.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pins=${1:-$here/tool-pins.sh}
root=${2:-$here/..}

[ -f "$pins" ] || { echo "pins-drift-check: $pins: no such file" >&2; exit 1; }
[ -d "$root" ] || { echo "pins-drift-check: $root: no such directory" >&2; exit 1; }

# shellcheck disable=SC1090
. "$pins"
py=${SW_PYTHON_VERSION:-}
al=${ALPINE_VERSION:-}
[ -n "$py" ] || { echo "pins-drift-check: $pins: SW_PYTHON_VERSION is not defined" >&2; exit 1; }
[ -n "$al" ] || { echo "pins-drift-check: $pins: ALPINE_VERSION is not defined" >&2; exit 1; }

excluded=" scripts/tool-pins.sh scripts/pins-drift-check.sh test/pins_check_test.sh test/ci_scripts_test.sh test/integration/make_targets_test.sh test/pins_drift_check_test.sh "

# agrees <found> <pinned>: equal, or one is a dotted prefix of the other.
agrees() {
	[ "$1" = "$2" ] || [[ "$2" == "$1".* ]] || [[ "$1" == "$2".* ]]
}

errors=0
nfiles=0
nrefs=0
bad() {
	echo "pins-drift-check: $1:$2: $3" >&2
	errors=$((errors + 1))
}

py_re='python:([0-9]+(\.[0-9]+)*)-slim'
al_re='alpine:([0-9]+(\.[0-9]+)+)'

scan() {
	local f=$1 rel=${1#"$root"/} line lineno=0 rest
	case "$excluded" in *" $rel "*) return 0 ;; esac
	nfiles=$((nfiles + 1))
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		rest=$line
		while [[ "$rest" =~ $py_re ]]; do
			nrefs=$((nrefs + 1))
			agrees "${BASH_REMATCH[1]}" "$py" ||
				bad "$rel" "$lineno" "python:${BASH_REMATCH[1]}-slim restates a pin that moved: SW_PYTHON_VERSION is $py"
			rest=${rest#*"${BASH_REMATCH[0]}"}
		done
		rest=$line
		while [[ "$rest" =~ $al_re ]]; do
			nrefs=$((nrefs + 1))
			agrees "${BASH_REMATCH[1]}" "$al" ||
				bad "$rel" "$lineno" "alpine:${BASH_REMATCH[1]} restates a pin that moved: ALPINE_VERSION is $al"
			rest=${rest#*"${BASH_REMATCH[0]}"}
		done
	done <"$f"
}

while IFS= read -r -d '' f; do
	scan "$f"
done < <(
	{
		[ ! -d "$root/docs" ] || find "$root/docs" -type f -name '*.md' -print0
		[ ! -d "$root/scripts" ] || find "$root/scripts" -type f -print0
		[ ! -d "$root/test" ] || find "$root/test" -type f -print0
	} | sort -z
)

if [ "$errors" -ne 0 ]; then
	echo "pins-drift-check: FAILED ($errors stale pins restated)" >&2
	exit 1
fi
echo "pins-drift-check: OK ($nrefs restated pins in $nfiles files)"
