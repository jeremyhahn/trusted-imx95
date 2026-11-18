#!/usr/bin/env bash
# deps-check.sh [pin-file]
#
# The latest-version check (handbook ci-standard.md §1, devops.md §9): each
# pinned tool of scripts/tool-pins.sh against its latest GitHub release, and
# the Alpine base against the newest Alpine release tag. A pin behind a
# release older than 7 days fails, unless the pin carries <TOOL>_HOLD, the
# documented reason, which is reported. A release younger than 7 days is
# reported, not failed. A release that cannot be read fails: no answer is
# never a pass. Needs the network (CI runs it with IN_IMAGE_NETWORK=bridge).
set -euo pipefail

pins=${1:-$(dirname "${BASH_SOURCE[0]}")/tool-pins.sh}
# shellcheck disable=SC1090
. "$pins"

readonly WEEK=$((7 * 24 * 3600))
now=$(date -u +%s)
bad=0

# latest_github <owner/repo>: prints "<tag> <published_at>". On failure it
# prints the reason (the HTTP status, or curl's exit code) and returns 1.
# With GITHUB_TOKEN or GH_TOKEN set, the request is authenticated, so CI is
# not held to the unauthenticated rate limit. The token goes to curl on stdin
# through --config, never on its command line, and xtrace is off while it is
# in a command, so neither ps nor `set -x` shows it.
latest_github() {
	local body code rc=0 xt=
	body=$(mktemp)
	case $- in *x*) xt=1 && set +x ;; esac
	if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
		code=$(printf 'header = "Authorization: Bearer %s"\n' "${GITHUB_TOKEN:-${GH_TOKEN:-}}" |
			curl -fsSL --retry 2 --config - -H 'Accept: application/vnd.github+json' \
				-o "$body" --write-out='%{http_code}' \
				"https://api.github.com/repos/$1/releases/latest") || rc=$?
	else
		code=$(curl -fsSL --retry 2 -H 'Accept: application/vnd.github+json' \
			-o "$body" --write-out='%{http_code}' \
			"https://api.github.com/repos/$1/releases/latest") || rc=$?
	fi
	[ -z "$xt" ] || set -x
	if [ "$rc" -ne 0 ]; then
		rm -f "$body"
		if [ -n "$code" ] && [ "$code" != 000 ]; then echo "HTTP $code"; else echo "curl exit $rc"; fi
		return 1
	fi
	if ! python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tag_name"], d["published_at"])' \
		<"$body" 2>/dev/null; then
		rm -f "$body"
		echo "HTTP ${code:-200}, a reply with no tag_name and published_at"
		return 1
	fi
	rm -f "$body"
}

# latest_alpine: prints "<x.y.z> <pushed_at>" of the newest release tag.
latest_alpine() {
	curl -fsSL --retry 2 "https://registry.hub.docker.com/v2/repositories/library/alpine/tags?page_size=100" |
		python3 -c '
import json, re, sys
tags = [t for t in json.load(sys.stdin)["results"] if re.fullmatch(r"\d+\.\d+\.\d+", t["name"])]
t = max(tags, key=lambda t: tuple(int(x) for x in t["name"].split(".")))
print(t["name"], t.get("tag_last_pushed") or t["last_updated"])'
}

# judge <name> <pinned> <latest> <released-at> <hold-reason>
judge() {
	local name=$1 pinned=$2 latest=${3#v} when=$4 hold=$5 age
	if [ "$pinned" = "$latest" ]; then
		echo "deps-check: OK     $name $pinned (latest)"
		return
	fi
	age=$((now - $(date -u -d "$when" +%s)))
	if [ -n "$hold" ]; then
		echo "deps-check: HELD   $name $pinned, latest $latest: $hold"
	elif [ "$age" -lt "$WEEK" ]; then
		echo "deps-check: REPORT $name $pinned, latest $latest released $when (under 7 days)"
	else
		echo "deps-check: FAIL   $name $pinned is behind $latest (released $when); bump scripts/tool-pins.sh or set ${name}_HOLD"
		bad=1
	fi
}

IFS=, read -r -a tools <<<"${PINNED_TOOLS:-}"
if [ "${#tools[@]}" -eq 0 ]; then
	echo "deps-check: FAIL   PINNED_TOOLS is empty in $pins"
	exit 1
fi
for tool in "${tools[@]}"; do
	eval "repo=\${${tool}_REPO:-} version=\${${tool}_VERSION:-} hold=\${${tool}_HOLD:-}"
	# shellcheck disable=SC2154 # set by the eval above
	if [ -z "$repo" ] || [ -z "$version" ]; then
		echo "deps-check: FAIL   $tool has no ${tool}_REPO or ${tool}_VERSION in $pins"
		bad=1
		continue
	fi
	tag='' when=''
	if ! got=$(latest_github "$repo") || ! read -r tag when <<<"$got" || [ -z "${when:-}" ]; then
		echo "deps-check: FAIL   $tool: the latest release of $repo cannot be read (${got:-no reply})"
		bad=1
		continue
	fi
	judge "$tool" "$version" "$tag" "$when" "$hold"
done

if read -r tag when < <(latest_alpine) && [ -n "${when:-}" ]; then
	judge ALPINE "$ALPINE_VERSION" "$tag" "$when" "${ALPINE_HOLD:-}"
else
	echo "deps-check: FAIL   ALPINE: the latest Alpine release cannot be read"
	bad=1
fi

exit "$bad"
