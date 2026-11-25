#!/usr/bin/env bash
# sm-perf-placement-check.sh <built tree>   test where a PERF_M7 PRIV line must go
#
# docs/system-manager-config/scmi-permissions-survey.md section 8.2 item 7: in
# the M7 LM (LMn name="M7") an explicit `PERF_M7  PRIV` line in the API list does
# not lower the grant of `M7P  OWNER`; only one after it does. This script
# generates the SCMI table for two scratch variants of the tree's patched
# configuration and reads the M7 agent's PERF_M7 grant back with
# scripts/sm-perf-check.sh:
#   (a) the line at the end of the API list (before the Resources list): ALL
#   (b) the line right after `M7P  OWNER` in the Resources list:         PRIV
# Anchors are found by content inside the M7 block, never by line number; a
# missing anchor is an error. The tree is copied to a scratch directory beside it
# (under the same output directory) and only `make config=<config> cfg` runs
# there, so the tree, its patches and its image are untouched. The variants are
# not patches and are never committed. The pins are read from the lock
# (SM_LOCK, default system-manager/sm.lock). Host side only.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() {
	echo "sm-perf-placement-check: $*" >&2
	exit 1
}

[ $# -eq 1 ] || die "usage: sm-perf-placement-check.sh <built tree>"
tree=${1%/}
[ -d "$tree" ] || die "no tree ${tree##*/}"
lock=${SM_LOCK:-$root/system-manager/sm.lock}
[ -r "$lock" ] || die "no lock file ${lock##*/}"

config="" cfgfile=""
while IFS= read -r l || [ -n "$l" ]; do
	case $l in
	sm_config=*) config=${l#sm_config=} ;;
	sm_config_file=*) cfgfile=${l#sm_config_file=} ;;
	esac
done <"$lock"
[ -n "$config" ] && [ -n "$cfgfile" ] || die "${lock##*/} lacks sm_config or sm_config_file"
[ -f "$tree/$cfgfile" ] || die "no $cfgfile in ${tree##*/}"

# variant <kind> <src> <dst>: copy <src> to <dst>, adding the PERF_M7 PRIV line
# for kind api (before the Resources header of the M7 block, after its API
# header) or res (right after the M7 block's `M7P OWNER` line).
variant() {
	local kind=$1 src=$2 dst=$3 l in=0 seen=0 api=0 res=0 done_=0 line='PERF_M7             PRIV'
	: >"$dst"
	while IFS= read -r l || [ -n "$l" ]; do
		if [[ $l =~ ^LM[0-9]+[[:space:]] ]]; then
			in=0
			if [[ $l == *'name="M7"'* ]]; then in=1 seen=1; fi
		elif [ "$in" = 1 ]; then
			if [[ $l =~ ^#[[:space:]]*API([[:space:]]|$) ]]; then
				api=1
			elif [[ $l =~ ^#[[:space:]]*Resources([[:space:]]|$) ]]; then
				res=1
				if [ "$kind" = api ] && [ "$api" = 1 ] && [ "$done_" = 0 ]; then
					printf '%s\n' "$line" >>"$dst"
					done_=1
				fi
			elif [ "$kind" = res ] && [ "$res" = 1 ] && [ "$done_" = 0 ] &&
				[[ $l =~ ^M7P[[:space:]]+OWNER([[:space:]]|,|$) ]]; then
				printf '%s\n' "$l" >>"$dst"
				printf '%s\n' "$line" >>"$dst"
				done_=1
				continue
			fi
		fi
		printf '%s\n' "$l" >>"$dst"
	done <"$src"
	[ "$seen" = 1 ] || die "no M7 LM block in ${src##*/}"
	[ "$kind" = res ] && [ "$res" = 0 ] && die "no Resources header in the M7 block"
	[ "$kind" = api ] && { [ "$api" = 1 ] || die "no API header in the M7 block"; }
	[ "$done_" = 1 ] || die "anchor for the $kind variant missing in the M7 block"
}

scratch="$(dirname "$tree")/placement-$$"
trap 'rm -rf "$scratch"' EXIT
rm -rf "$scratch"
mkdir -p "$scratch"

run_one() { # <kind> <want>
	local kind=$1 want=$2 t="$scratch/$1" got
	cp -a "$tree" "$t"
	variant "$kind" "$tree/$cfgfile" "$t/$cfgfile"
	(cd "$t" && make config="$config" cfg) >"$scratch/$kind.log" 2>&1 ||
		{ tail -n 10 "$scratch/$kind.log" >&2; die "make cfg failed for the $kind variant"; }
	if got=$("$root/scripts/sm-perf-check.sh" --want "$want" "$t/configs/$config/config_scmi.h" 2>&1); then
		echo "sm-perf-placement-check: $kind variant: M7 PERF_M7=$want (as item 7 says)"
	else
		echo "sm-perf-placement-check: $kind variant: want $want; ${got#sm-perf-check: }" >&2
		return 1
	fi
}

rc=0
run_one api ALL || rc=1
run_one res PRIV || rc=1
[ "$rc" = 0 ] || die "the placement result differs from survey 8.2 item 7"
echo "sm-perf-placement-check: OK (API list: ALL, after M7P OWNER: PRIV)"
