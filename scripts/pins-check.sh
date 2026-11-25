#!/usr/bin/env bash
# scripts/pins-check.sh [pin-file [requirements-file [build-requirements-file [workflows-dir]]]]
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
# Requirements files (default scripts/ahab/requirements.txt and
# scripts/ahab/build-requirements.txt), each failure naming file and line:
#   g  each requirement is name==version plus at least one
#      --hash=sha256:<64 hex>; no duplicate name in a file
#   h  a name pinned in both files has the same version and hash set
# Workflows directory (default .github/workflows):
#   i  every remote `uses:` ends in @ plus 40 lowercase hex and a `# <tag>`
#      comment; one action repository (actions/checkout) names one commit
#      across the directory; `uses: ./...` is ignored
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pins=${1:-$here/tool-pins.sh}
reqs=${2:-$here/ahab/requirements.txt}
buildreqs=${3:-$here/ahab/build-requirements.txt}
wfdir=${4:-$here/../.github/workflows}

errors=0
bad() {
	echo "pins-check: $1: $2" >&2
	errors=$((errors + 1))
}

[ -f "$pins" ] || { echo "pins-check: $pins: no such file" >&2; exit 1; }
for f in "$reqs" "$buildreqs"; do
	[ -f "$f" ] || { echo "pins-check: $f: no such file" >&2; exit 1; }
done

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
# check_reqfile <file> <versions-array> <hashes-array>: rules g's per-file part
# (the requirement form, no duplicate name) and the record of each name's
# version and sorted hash set, for the equality rule h.
nreq=0
req_re='^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9._!+-]+)((  *--hash=sha256:[0-9a-f]{64})+)$'
check_req() {
	local file=$1 lineno=$2 r=$3 tag=$4 key hs
	r=${r//$'\t'/ }
	while [[ "$r" == *"  "* ]]; do r=${r//  / }; done
	r=${r# }
	r=${r% }
	nreq=$((nreq + 1))
	if [[ ! "$r" =~ $req_re ]]; then
		bad "$file" "line $lineno: requirement '${r%% *}' is not name==version with at least one --hash=sha256:<64 hex> (rule g)"
		return
	fi
	key=${BASH_REMATCH[1],,}
	key=${key//[_.]/-}
	if [ -n "${req_ver["$tag/$key"]:-}" ]; then
		bad "$file" "line $lineno: duplicate requirement '${BASH_REMATCH[1]}' (rule g)"
	fi
	req_ver["$tag/$key"]=${BASH_REMATCH[2]}
	hs=${BASH_REMATCH[3]//--hash=sha256:/}
	req_hash["$tag/$key"]=$(printf '%s\n' "$hs" | tr ' ' '\n' | sort -u | tr '\n' ' ')
}
check_reqfile() {
	local path=$1 tag=$2 line acc='' lineno=0 start=0 bs=$'\\'
	local before=$nreq label=$1
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		line=${line%%#*}
		line=${line%"${line##*[![:space:]]}"}
		[ -n "$line" ] || continue
		[ -n "$acc" ] || start=$lineno
		if [[ "$line" == *"$bs" ]]; then
			acc+="${line%\\} "
			continue
		fi
		check_req "$label" "$start" "$acc$line" "$tag"
		acc=''
	done <"$path"
	[ -z "$acc" ] || check_req "$label" "$start" "$acc" "$tag"
	[ "$nreq" -gt "$before" ] || bad "$label" "no requirement found (rule g)"
}
declare -A req_ver=() req_hash=()
check_reqfile "$reqs" main
check_reqfile "$buildreqs" build

# Rule h: a name pinned in both requirements files has one version and one
# hash set (the header of build-requirements.txt says so).
for k in "${!req_ver[@]}"; do
	[[ "$k" == build/* ]] || continue
	n=${k#build/}
	[ -n "${req_ver[main/$n]:-}" ] || continue
	[ "${req_ver[main/$n]}" = "${req_ver[$k]}" ] ||
		bad "$buildreqs" "rule h: '$n' is ${req_ver[$k]} here and ${req_ver[main/$n]} in $reqs"
	[ "${req_hash[main/$n]}" = "${req_hash[$k]}" ] ||
		bad "$buildreqs" "rule h: '$n' has a different hash set here than in $reqs"
done

# Rule i: workflow actions. Every remote `uses:` ends in @<40 lowercase hex>
# and a `# <tag>` comment; one action repository names one commit across the
# directory; a local `uses: ./...` and a docker:// image are not checked.
nuses=0
declare -A act_commit=() act_where=()
uses_re='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]#]+)[[:space:]]*(#[[:space:]]*(.*))?$'
if [ -d "$wfdir" ]; then
	for wf in "$wfdir"/*.yml "$wfdir"/*.yaml; do
		[ -f "$wf" ] || continue
		lineno=0
		wfname=$wf
		while IFS= read -r line || [ -n "$line" ]; do
			lineno=$((lineno + 1))
			[[ "$line" =~ $uses_re ]] || continue
			target=${BASH_REMATCH[2]//[\"\']/}
			tagc=${BASH_REMATCH[4]:-}
			[[ "$target" == ./* || "$target" == docker://* ]] && continue
			nuses=$((nuses + 1))
			if [[ ! "$target" =~ ^([^@]+)@([0-9a-f]{40})$ ]]; then
				bad "$wfname" "line $lineno: rule i: 'uses: $target' does not end in @ plus a 40-hex commit"
				continue
			fi
			if [ -z "${tagc//[[:space:]]/}" ]; then
				bad "$wfname" "line $lineno: rule i: 'uses: ${BASH_REMATCH[1]}' has no '# <tag>' comment"
			fi
			repo=${BASH_REMATCH[1]}
			repo=${repo%%/*}/$(
				r=${BASH_REMATCH[1]#*/}
				echo "${r%%/*}"
			)
			commit=${BASH_REMATCH[2]}
			if [ -z "${act_commit[$repo]:-}" ]; then
				act_commit[$repo]=$commit
				act_where[$repo]="$wf:$lineno"
			elif [ "${act_commit[$repo]}" != "$commit" ]; then
				bad "$wfname" "line $lineno: rule i: $repo is pinned to $commit here but ${act_commit[$repo]} at ${act_where[$repo]}"
			fi
		done <"$wf"
	done
else
	bad "$wfdir" "rule i: no such directory"
fi

if [ "$errors" -ne 0 ]; then
	echo "pins-check: FAILED ($errors problems)" >&2
	exit 1
fi
echo "pins-check: OK ($ntools tools, $nreq requirements, $nuses workflow actions)"
