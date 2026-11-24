#!/usr/bin/env bash
# scripts/pins-check.sh [pin-file [requirements-file]]
#
# Offline consistency of the pins: is each pin well formed and does it agree
# with its siblings? (scripts/deps-check.sh, which needs the network, says
# whether a pin is behind.) No network, no pip, no SPSDK install.
#
# Pin file (default scripts/tool-pins.sh), each failure names the variable:
#   a  every PINNED_TOOLS tool defines <T>_VERSION, _REPO, _URL, _SHA256, _HOLD
#   b  <T>_URL holds /<T>_REPO/releases/download/[v]<T>_VERSION/
#   c  <T>_SHA256 and SW_UV_SHA256 are exactly 64 lowercase hex
#   d  ALPINE_DIGEST and SW_PYTHON_DIGEST are sha256: plus 64 hex
#   e  SW_DEBIAN_SNAPSHOT is YYYYMMDDTHHMMSSZ
#   f  every <T>_URL in the file has <T> in PINNED_TOOLS
# Requirements file (default scripts/ahab/requirements.txt): each requirement
# is name==version plus at least one --hash=sha256:<64 hex>; no duplicate name.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pins=${1:-$here/tool-pins.sh}
reqs=${2:-$here/ahab/requirements.txt}

errors=0
bad() {
	echo "pins-check: $1: $2" >&2
	errors=$((errors + 1))
}

[ -f "$pins" ] || { echo "pins-check: $pins: no such file" >&2; exit 1; }
[ -f "$reqs" ] || { echo "pins-check: $reqs: no such file" >&2; exit 1; }

hex64='^[0-9a-f]{64}$'
dig='^sha256:[0-9a-f]{64}$'
snap='^[0-9]{8}T[0-9]{6}Z$'

unset PINNED_TOOLS
# shellcheck disable=SC1090
. "$pins"
tool_list=${PINNED_TOOLS:-}
[ -n "$tool_list" ] || bad PINNED_TOOLS "must name at least one tool"

ntools=0
IFS=',' read -r -a tools <<<"$tool_list"
declare -A listed=()
for t in "${tools[@]}"; do
	[ -n "$t" ] || continue
	listed[$t]=1
	ntools=$((ntools + 1))
	missing=0
	for f in VERSION REPO URL SHA256 HOLD; do
		v="${t}_$f"
		if [ -z "${!v+x}" ]; then
			bad "$v" "rule a: tool $t is in PINNED_TOOLS but $v is not defined"
			missing=1
		elif [ "$f" != HOLD ] && [ -z "${!v}" ]; then
			bad "$v" "rule a: $v is empty (only ${t}_HOLD may be empty)"
			missing=1
		fi
	done
	[ "$missing" = 0 ] || continue
	ver="${t}_VERSION" repo="${t}_REPO" url="${t}_URL" sha="${t}_SHA256"
	[[ "${!url}" == *"/${!repo}/releases/download/"* ]] ||
		bad "$url" "rule b: URL lacks /${!repo}/releases/download/ (${t}_REPO)"
	[[ "${!url}" == *"/releases/download/${!ver}/"* || "${!url}" == *"/releases/download/v${!ver}/"* ]] ||
		bad "$url" "rule b: URL's release tag is not ${t}_VERSION ${!ver}"
	[[ "${!sha}" =~ $hex64 ]] || bad "$sha" "rule c: not exactly 64 lowercase hex"
done

[[ "${SW_UV_SHA256:-}" =~ $hex64 ]] || bad SW_UV_SHA256 "rule c: not exactly 64 lowercase hex"
for v in ALPINE_DIGEST SW_PYTHON_DIGEST; do
	[[ "${!v:-}" =~ $dig ]] || bad "$v" "rule d: not sha256: plus 64 lowercase hex"
done
[[ "${SW_DEBIAN_SNAPSHOT:-}" =~ $snap ]] ||
	bad SW_DEBIAN_SNAPSHOT "rule e: not YYYYMMDDTHHMMSSZ"

# Rule f: a tool with a _URL line that deps-check never compares.
while IFS= read -r line || [ -n "$line" ]; do
	if [[ "$line" =~ ^([A-Z0-9_]+)_URL= ]]; then
		name=${BASH_REMATCH[1]}
		[ -n "${listed[$name]:-}" ] ||
			bad "${name}_URL" "rule f: $name has a URL but is missing from PINNED_TOOLS"
	fi
done <"$pins"

# Requirements: join backslash continuations, then check each requirement.
nreq=0
declare -A seen=()
req_re='^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9._!+-]+)((  *--hash=sha256:[0-9a-f]{64})+)$'
check_req() {
	local r=$1 key
	r=${r//$'\t'/ }
	while [[ "$r" == *"  "* ]]; do r=${r//  / }; done
	r=${r# }
	r=${r% }
	nreq=$((nreq + 1))
	if [[ ! "$r" =~ $req_re ]]; then
		bad "$reqs" "requirement '${r%% *}' is not name==version with at least one --hash=sha256:<64 hex>"
		return
	fi
	key=${BASH_REMATCH[1],,}
	key=${key//[_.]/-}
	if [ -n "${seen[$key]:-}" ]; then
		bad "$reqs" "duplicate requirement '${BASH_REMATCH[1]}'"
	fi
	seen[$key]=1
}
acc=
bs=$'\\'
while IFS= read -r line || [ -n "$line" ]; do
	line=${line%%#*}
	line=${line%"${line##*[![:space:]]}"}
	[ -n "$line" ] || continue
	if [[ "$line" == *"$bs" ]]; then
		acc+="${line%\\} "
		continue
	fi
	check_req "$acc$line"
	acc=
done <"$reqs"
[ -z "$acc" ] || check_req "$acc"
[ "$nreq" -gt 0 ] || bad "$reqs" "no requirement found"

if [ "$errors" -ne 0 ]; then
	echo "pins-check: FAILED ($errors problems)" >&2
	exit 1
fi
echo "pins-check: OK ($ntools tools, $nreq requirements)"
