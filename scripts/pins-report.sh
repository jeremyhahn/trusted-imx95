#!/usr/bin/env bash
# scripts/pins-report.sh [pin-file [requirements-file [build-requirements-file [workflows-dir]]]]
#
# The offline inventory of every pin, read from files in the tree only (no
# network, no pip): read it before the network `make deps-check` to see what a
# bump would touch. It reports and does not judge (scripts/pins-check.sh
# judges). Exit 1 only when a named file or directory is missing.
#
# Sections: each PINNED_TOOLS tool (version, repo, release tag taken from its
# URL, HOLD reason or -); the Alpine, Python, uv and Debian snapshot pins; the
# requirement count of each requirements file; for each workflow, every
# remote `uses:` as owner/repo@<first 12 hex> # <tag>.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pins=${1:-$here/tool-pins.sh}
reqs=${2:-$here/ahab/requirements.txt}
buildreqs=${3:-$here/ahab/build-requirements.txt}
wfdir=${4:-$here/../.github/workflows}

for f in "$pins" "$reqs" "$buildreqs"; do
	[ -f "$f" ] || { echo "pins-report: $f: no such file" >&2; exit 1; }
done
[ -d "$wfdir" ] || { echo "pins-report: $wfdir: no such directory" >&2; exit 1; }

unset PINNED_TOOLS
# shellcheck disable=SC1090
. "$pins"

echo "== tools ($pins)"
printf '%-12s %-10s %-24s %-10s %s\n' TOOL VERSION REPO TAG HOLD
IFS=',' read -r -a tools <<<"${PINNED_TOOLS:-}"
for t in "${tools[@]}"; do
	[ -n "$t" ] || continue
	v="${t}_VERSION" r="${t}_REPO" u="${t}_URL" h="${t}_HOLD"
	url=${!u:-}
	tag=-
	if [[ "$url" == */releases/download/* ]]; then
		tag=${url#*/releases/download/}
		tag=${tag%%/*}
	fi
	printf '%-12s %-10s %-24s %-10s %s\n' "$t" "${!v:--}" "${!r:--}" "$tag" "${!h:--}"
done

echo
echo "== base images and build inputs"
printf '%-18s %s\n' \
	"Alpine" "${ALPINE_VERSION:--} ${ALPINE_DIGEST:--}" \
	"Python (secure)" "${SW_PYTHON_VERSION:--} ${SW_PYTHON_DIGEST:--}" \
	"uv" "${SW_UV_VERSION:--} sha256:${SW_UV_SHA256:--}" \
	"Debian snapshot" "${SW_DEBIAN_SNAPSHOT:--}"

echo
echo "== requirements"
count_reqs() {
	local n=0 line
	while IFS= read -r line || [ -n "$line" ]; do
		[[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*== ]] && n=$((n + 1))
	done <"$1"
	echo "$n"
}
printf '%-48s %s\n' "$reqs" "$(count_reqs "$reqs") requirements"
printf '%-48s %s\n' "$buildreqs" "$(count_reqs "$buildreqs") requirements"

echo
echo "== workflow actions ($wfdir)"
uses_re='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]#]+)[[:space:]]*(#[[:space:]]*(.*))?$'
for wf in "$wfdir"/*.yml "$wfdir"/*.yaml; do
	[ -f "$wf" ] || continue
	echo "${wf##*/}:"
	while IFS= read -r line || [ -n "$line" ]; do
		[[ "$line" =~ $uses_re ]] || continue
		target=${BASH_REMATCH[2]//[\"\']/}
		tagc=${BASH_REMATCH[4]:-}
		[[ "$target" == ./* || "$target" == docker://* ]] && continue
		name=${target%%@*}
		ref=
		[[ "$target" == *@* ]] && ref=${target#*@}
		printf '  %s@%s # %s\n' "$name" "${ref:0:12}" "${tagc:--}"
	done <"$wf"
done
