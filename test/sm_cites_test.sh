#!/usr/bin/env bash
# test/sm_cites_test.sh: the repo-script line cites of the PERF_M7 survey
# (docs/system-manager-config/scmi-permissions-survey.md, sections 8.0 and 8.2,
# and docs/system-manager-config/build.md) still point at the lines they name.
# Offline, no vendor source. One row per cite: the script, the first and last
# cited line (1-based), and the token the FIRST cited line must contain, so a
# line inserted above the cited code moves the token out of its line and fails.
# Change a row only together with the cite in the docs.
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# script|first|last|token on the first line
CITES=(
	"scripts/sm-perf-check.sh|21|21|want_perm=SM_SCMI_PERM_ALL"
	"scripts/sm-perf-check.sh|31|31|\"--want\""
	"scripts/sm-perf-check.sh|72|79|no M7 agent record"
	"scripts/sm-build.sh|133|144|The source"
	"scripts/sm-build.sh|140|143|git init"
	"scripts/sm-build.sh|165|166|clone"
	"scripts/sm-build.sh|189|190|scripts/sm-perf-check.sh"
	"scripts/sm-build.sh|196|196|h1=\$(build 1)"
	"scripts/sm-build.sh|198|198|h2=\$(build 2)"
	"scripts/sm-build.sh|201|201|reproducible=no"
	"scripts/sm-build.sh|208|208|m7_perf_m7=ALL"
	"scripts/sm-build.sh|211|211|reproducible=\$reproducible"
	"scripts/sm-build.sh|214|214|die \"not reproducible"
	"scripts/sm-perf-placement-check.sh|46|46|variant()"
	"scripts/sm-perf-placement-check.sh|83|95|run_one()"
	"scripts/sm-toolchain-check.sh|12|12|make system-manager"
	"scripts/sm-toolchain-check.sh|25|25|scripts/sm-perf-placement-check.sh"
)

# cite_ok <root> <script> <first> <last> <token>: the range exists and its
# first line contains the token. Prints the reason on failure.
cite_ok() {
	local root=$1 file=$2 first=$3 last=$4 token=$5
	local -a lines
	[ -f "$root/$file" ] || { echo "no such file $file"; return 1; }
	mapfile -t lines <"$root/$file"
	[ "$last" -le "${#lines[@]}" ] || { echo "$file has ${#lines[@]} lines, cite ends at $last"; return 1; }
	[[ ${lines[first - 1]} == *"$token"* ]] || { echo "$file:$first does not contain '$token'"; return 1; }
}

for row in "${CITES[@]}"; do
	IFS='|' read -r file first last token <<<"$row"
	name="cite $file:$first-$last"
	if why=$(cite_ok "$ROOT" "$file" "$first" "$last" "$token"); then
		pass "$name"
	else
		fail "$name" "$why"
	fi
done

# The test must be able to fail: a copy of sm-build.sh with one line inserted
# above the cited perf-check call no longer satisfies its row.
scratch="$TMP_ROOT/drift"
mkdir -p "$scratch/scripts"
mapfile -t src <"$ROOT/scripts/sm-build.sh"
{
	printf '%s\n' "${src[@]:0:188}"
	echo "# inserted"
	printf '%s\n' "${src[@]:188}"
} >"$scratch/scripts/sm-build.sh"
if cite_ok "$scratch" scripts/sm-build.sh 189 190 scripts/sm-perf-check.sh >/dev/null; then
	fail "a line inserted above sm-build.sh:189 is detected" "the cite still held"
else
	pass "a line inserted above sm-build.sh:189 is detected"
fi

finish
