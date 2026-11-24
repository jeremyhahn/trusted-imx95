#!/usr/bin/env bash
# sm-perf-check.sh <generated config_scmi.h>   check the M7 agent's PERF_M7 grant
#
# The generated SCMI configuration of the pinned System Manager build
# (configs/<config>/config_scmi.h, written by `make cfg`) must give the M7 agent
# the PERF_M7 performance domain at the permission named below, and no other
# agent may hold that domain: exactly one perfPerms[DEV_SM_PERF_M7] line in the
# file, inside the M7 agent's record (the one whose header comment names the
# M7). Fails closed: a missing file, no M7 record, no PERF_M7 line, more than
# one, or another value is an error. Failure output names what was found and
# shows one line at most.
#
# Why: docs/system-manager-config/scmi-permissions-survey.md section 8 rests on
# this table. Nothing generated or vendor-written is committed; sm-build.sh
# runs this check on every build, so CI re-reads the table each time.
# Host side only.
set -euo pipefail

# The one expected value (survey section 8): the permission the M7 agent holds
# on PERF_M7. Change it only with the survey.
want_perm=SM_SCMI_PERM_ALL

die() {
	echo "sm-perf-check: $*" >&2
	exit 1
}

# --want <ALL|PRIV|...> as the first arguments overrides it:
# scripts/sm-perf-placement-check.sh asks for the value a scratch variant should
# produce. The default, which sm-build.sh uses, is unchanged.
if [ "${1:-}" = "--want" ]; then
	[ $# -ge 2 ] && [[ $2 =~ ^[A-Z]+$ ]] || die "usage: sm-perf-check.sh [--want <ALL|PRIV|...>] <generated config_scmi.h>"
	want_perm=SM_SCMI_PERM_$2
	shift 2
fi
[ $# -eq 1 ] || die "usage: sm-perf-check.sh [--want <ALL|PRIV|...>] <generated config_scmi.h>"
f=$1
[ -r "$f" ] && [ -f "$f" ] || die "cannot read ${f##*/}"

in=0 seen=0 total=0 first="" mine=0 mine_line=""
re_hdr='^/\*[[:space:]]+SCMI[[:space:]]+AGENT[0-9]+[[:space:]]+Config[[:space:]]+\(M7\)'
re_any='^/\*[[:space:]]+SCMI[[:space:]]'
re_perf='perfPerms\[DEV_SM_PERF_M7\]'
while IFS= read -r l || [ -n "$l" ]; do
	if [[ $l =~ $re_hdr ]]; then
		in=1 seen=1
		continue
	fi
	if [[ $l =~ $re_any ]]; then
		in=0
		continue
	fi
	if [[ $l =~ $re_perf ]]; then
		total=$((total + 1))
		[ -n "$first" ] || first=$l
		if [ "$in" = 1 ]; then
			mine=$((mine + 1))
			mine_line=$l
		fi
	fi
done <"$f"

trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	s=${s%\\}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

[ "$seen" = 1 ] || die "no M7 agent record in ${f##*/}"
[ "$total" -ne 0 ] || die "no perfPerms[DEV_SM_PERF_M7] line in ${f##*/}"
[ "$total" -eq 1 ] || die "$total perfPerms[DEV_SM_PERF_M7] lines in ${f##*/}, want exactly 1; first: $(trim "$first")"
[ "$mine" -eq 1 ] || die "the perfPerms[DEV_SM_PERF_M7] line is not in the M7 agent's record: $(trim "$first")"
got=$(trim "$mine_line")
[ "$got" = ".perfPerms[DEV_SM_PERF_M7] = $want_perm," ] ||
	die "the M7 agent's PERF_M7 grant is not ${want_perm#SM_SCMI_PERM_}: $got"
echo "sm-perf-check: M7 PERF_M7=${want_perm#SM_SCMI_PERM_}, no other agent"
