#!/usr/bin/env bash
# Keeps the oem-key-provisioning documents in line with owner ruling 1234: the life
# cycle is closed only at the provisioning station, never on a development board.
# Reads files only.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DOCS=${OKP_DOCS_DIR:-$ROOT/docs/oem-key-provisioning}
FAILS=${FAILS:-0}

# Phrases that recommend or plan a close on a board that is not the station. A line
# with one needs "ruling 1234" on the same line or the next.
PHRASES=(
	# fuse-map-survey.md question 7: "on one sacrificial board first"
	'sacrificial board'
	# fuse-map-survey.md question 10 and the P8 row: "spare board" for the first close
	'spare board'
	# fuse-map-survey.md question 9: "on the bench over the U-Boot console"
	'on the bench'
	# key-ceremony-survey.md question 5 style: a close on a development board
	'close[a-z]* [a-z ]*on (a|the|one) development board'
)

# scan_file <file>: report each unmarked phrase line; return 1 if any.
scan_file() {
	local f=$1 n=0 prev="" prevn=0 line bad=0 p
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		if [ -n "$prev" ] && [[ "$line" != *"ruling 1234"* ]]; then
			echo "$f:$prevn: $prev"
			bad=1
		fi
		prev=""
		for p in "${PHRASES[@]}"; do
			if [[ "${line,,}" =~ $p ]]; then
				if [[ "$line" == *"ruling 1234"* ]]; then
					break
				fi
				prev=$line
				prevn=$n
				break
			fi
		done
	done <"$f"
	if [ -n "$prev" ]; then
		echo "$f:$prevn: $prev"
		bad=1
	fi
	return $bad
}

scan_all() {
	local f rc=0
	for f in "$DOCS"/*.md; do
		scan_file "$f" || rc=1
	done
	return $rc
}

if OUT=$(scan_all); then
	pass "no survey recommends a close away from the provisioning station"
else
	fail "survey line recommends or plans a close off the station without ruling 1234" "$OUT"
fi

if [[ "$(<"$DOCS/architecture.md")" == *"Owner ruling 1234"* ]]; then
	pass "architecture.md records Owner ruling 1234"
else
	fail "architecture.md lacks 'Owner ruling 1234'"
fi

spec_ok=0
while IFS= read -r line || [ -n "$line" ]; do
	if [[ "$line" == "| oem-key-provisioning |"* && "$line" == *"ruling 1234"* ]]; then
		spec_ok=1
	fi
done <"$ROOT/docs/SPEC.md"
if [ "$spec_ok" -eq 1 ]; then
	pass "SPEC.md oem-key-provisioning row cites ruling 1234"
else
	fail "SPEC.md oem-key-provisioning row lacks 'ruling 1234'"
fi

finish
