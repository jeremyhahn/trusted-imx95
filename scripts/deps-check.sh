#!/usr/bin/env bash
# deps-check.sh [pin-file] | --fetch <dir> [pin-file]: fails when a pinned tool, the Alpine base, a pinned Python package (DEPS_REQUIREMENTS) or a pinned workflow action (DEPS_WORKFLOWS) is behind a release older than 7 days, unless <TOOL>_HOLD gives a reason (a Python pin that a package pinned beside it caps below the latest release is CAPPED, not stale); one unreadable item fails and does not hide the others; --fetch writes each tool's and each pinned action's latest release to <dir> (the actions of DEPS_WORKFLOWS, by default .github/workflows), and DEPS_RELEASES_DIR=<dir> reads them back.
set -euo pipefail

fetch=
if [ "${1:-}" = --fetch ]; then
	[ -n "${2:-}" ] || { echo "usage: deps-check.sh --fetch <dir> [pin-file]" >&2; exit 2; }
	fetch=$2
	shift 2
	mkdir -p "$fetch"
fi
pins=${1:-$(dirname "${BASH_SOURCE[0]}")/tool-pins.sh}
# shellcheck disable=SC1090
. "$pins"

readonly WEEK=$((7 * 24 * 3600))
now=$(date -u +%s)
bad=0
caps=
trap '[ -z "$caps" ] || rm -f "$caps"' EXIT

# latest_github <owner/repo> prints "<tag> <published_at>"; a token goes to curl on stdin, never on its command line.
latest_github() {
	local body code rc=0 xt=
	body=$(mktemp)
	case $- in *x*) xt=1 && set +x ;; esac
	if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
		code=$(printf 'header = "Authorization: Bearer %s"\n' "${GITHUB_TOKEN:-${GH_TOKEN:-}}" |
			curl -fsSL --retry 2 --config - -H 'Accept: application/vnd.github+json' \
				-o "$body" --write-out '%{http_code}' \
				"https://api.github.com/repos/$1/releases/latest") || rc=$?
	else
		code=$(curl -fsSL --retry 2 -H 'Accept: application/vnd.github+json' \
			-o "$body" --write-out '%{http_code}' \
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

# valid_release <tag> <published_at>: true for a version tag and a UTC timestamp.
valid_release() {
	[[ $1 =~ ^v?[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]] &&
		[[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# latest_pypi <package> prints "<version> <upload time>" of the newest release; a failure prints the reason.
latest_pypi() {
	local body code rc=0
	body=$(mktemp)
	code=$(curl -fsSL --retry 2 -o "$body" --write-out '%{http_code}' \
		"https://pypi.org/pypi/$1/json") || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$body"
		if [ -n "$code" ] && [ "$code" != 000 ]; then echo "HTTP $code"; else echo "curl exit $rc"; fi
		return 1
	fi
	if ! python3 -c '
import json, re, sys
d = json.load(sys.stdin)
t = d["urls"][0]["upload_time_iso_8601"]
print(d["info"]["version"], re.sub(r"\.\d+Z$", "Z", t))' <"$body" 2>/dev/null; then
		rm -f "$body"
		echo "HTTP ${code:-200}, a reply with no version and upload time"
		return 1
	fi
	rm -f "$body"
}

# load_caps: sets caps to a file of "<pinned package><TAB><its requirement>" lines, one per requirement (extras
# excluded) of every package pinned in DEPS_REQUIREMENTS, read from PyPI's metadata of the pinned release. A package
# whose metadata cannot be read adds nothing, so a pin it might have capped still fails.
load_caps() {
	local line pkg
	caps=$(mktemp)
	while IFS= read -r line || [ -n "$line" ]; do
		[[ $line =~ $pkg_re ]] || continue
		pkg=${BASH_REMATCH[1]}
		{ curl -fsSL --retry 2 "https://pypi.org/pypi/$pkg/${BASH_REMATCH[2]}/json" 2>/dev/null |
			python3 -c '
import json, sys
for r in json.load(sys.stdin)["info"].get("requires_dist") or []:
    if "extra" not in r.partition(";")[2]:
        print(sys.argv[1] + "\t" + r)' "$pkg" 2>/dev/null; } </dev/null >>"$caps" || true
	done <"$DEPS_REQUIREMENTS"
}

# capping_package <package> <pinned> <latest>: reads caps; prints the pinned package whose requirement admits
# <pinned> and excludes <latest>, and fails when there is none (nothing caps the pin: it is stale).
capping_package() {
	python3 -c '
import re, sys

def norm(n):
    return re.sub(r"[-_.]+", "-", n).lower()

RANK = {"a": 0, "alpha": 0, "b": 1, "beta": 1, "c": 2, "rc": 2, "pre": 2, "preview": 2}

def parse(v):
    m = re.match(r"^v?(\d+(?:\.\d+)*)(?:[-._]?(a|alpha|b|beta|c|rc|pre|preview)[-._]?\d*)?", v)
    if not m:
        return None
    return [int(x) for x in m.group(1).split(".")], RANK.get(m.group(2), 3)

def pad(a, n):
    return a + [0] * (n - len(a))

def cmp(a, b):
    n = max(len(a[0]), len(b[0]))
    x, y = (pad(a[0], n), a[1]), (pad(b[0], n), b[1])
    return (x > y) - (x < y)

def prefix(v, w):
    return pad(v[0], len(w[0]))[: len(w[0])] == w[0]

def sat(v, op, w):
    if op == "===":
        return None
    star = w.endswith(".*")
    p = parse(w[:-2] if star else w)
    if p is None or v is None:
        return None
    if star:
        return prefix(v, p) == (op == "==") if op in ("==", "!=") else None
    if op == "~=":
        return cmp(v, p) >= 0 and prefix(v, ([*p[0][:-1]], 3)) if len(p[0]) > 1 else None
    c = cmp(v, p)
    return {"==": c == 0, "!=": c != 0, "<": c < 0, "<=": c <= 0, ">": c > 0, ">=": c >= 0}[op]

pkg, pinned, latest = sys.argv[1:4]
target, p, l = norm(pkg), parse(pinned), parse(latest)
for line in sys.stdin:
    who, _, req = line.rstrip("\n").partition("\t")
    m = re.match(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^]]*\])?\s*\(?([^;)]*)", req)
    if not m or norm(m.group(1)) != target:
        continue
    clauses = re.findall(r"(===|==|!=|~=|<=|>=|<|>)\s*([^\s,]+)", m.group(2))
    if any(sat(l, op, w) is False for op, w in clauses) and not any(sat(p, op, w) is False for op, w in clauses):
        print(who)
        sys.exit(0)
sys.exit(1)' "$@" <"$caps"
}

# judge <name> <pinned> <latest> <released-at> <hold-reason> [<remedy>]
judge() {
	local name=$1 pinned=$2 latest=${3#v} when=$4 hold=$5 remedy=${6:-bump scripts/tool-pins.sh or set ${1}_HOLD} age
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
		echo "deps-check: FAIL   $name $pinned is behind $latest (released $when); $remedy"
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
	tag='' when='' got=''
	if [ -n "${DEPS_RELEASES_DIR:-}" ] && [ -z "$fetch" ]; then
		if ! read -r tag when 2>/dev/null <"$DEPS_RELEASES_DIR/$tool" || ! valid_release "$tag" "$when"; then
			echo "deps-check: FAIL   $tool: $DEPS_RELEASES_DIR/$tool holds no release tag and date"
			bad=1
			continue
		fi
	elif ! got=$(latest_github "$repo") || ! read -r tag when <<<"$got" || ! valid_release "$tag" "$when"; then
		echo "deps-check: FAIL   $tool: the latest release of $repo cannot be read (${got:-no reply})"
		bad=1
		continue
	fi
	if [ -n "$fetch" ]; then
		printf '%s %s\n' "$tag" "$when" >"$fetch/$tool"
		echo "deps-check: FETCH  $tool $tag ($when)"
	else
		judge "$tool" "$version" "$tag" "$when" "$hold"
	fi
done

# workflow_files <dir>: sets files to every *.yml and *.yaml workflow in <dir>, as GitHub and pins-check.sh read both.
workflow_files() {
	shopt -s nullglob
	files=("$1"/*.yml "$1"/*.yaml)
	shopt -u nullglob
}

# action_pins <file>...: prints "<owner/repo> <comment version>" once per pair of every
# `uses: owner/repo[/path]@<40-hex sha> # <version>` line, in file order.
action_pins() {
	local f line key re='uses:[[:space:]]*([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(/[^@[:space:]]*)?@[0-9a-f]{40}[[:space:]]*#[[:space:]]*(v?[0-9][^[:space:]]*)'
	local -A seen=()
	for f in "$@"; do
		while IFS= read -r line || [ -n "$line" ]; do
			[[ $line =~ $re ]] || continue
			key="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
			[ -z "${seen[$key]:-}" ] || continue
			seen[$key]=1
			printf '%s\n' "$key"
		done <"$f"
	done
}

# action_file <owner/repo>: the release file of an action under --fetch's directory; '@' is in no owner or repo name.
action_file() { printf 'ACTION@%s' "${1//\//@}"; }

# --fetch also writes the latest release of every action the workflows pin (DEPS_WORKFLOWS, by default the
# repository's .github/workflows), so a check run with DEPS_RELEASES_DIR judges the actions with no token.
if [ -n "$fetch" ]; then
	wfdir=${DEPS_WORKFLOWS:-$(dirname "${BASH_SOURCE[0]}")/../.github/workflows}
	workflow_files "$wfdir"
	if [ "${#files[@]}" -eq 0 ]; then
		echo "deps-check: FAIL   ACTIONS: no workflow files in $wfdir"
		exit 1
	fi
	declare -A fetched=()
	while read -r repo version; do
		[ -z "${fetched[$repo]:-}" ] || continue
		fetched[$repo]=1
		tag='' when='' got=''
		if got=$(latest_github "$repo") && read -r tag when <<<"$got" && valid_release "$tag" "$when"; then
			printf '%s %s\n' "$tag" "$when" >"$fetch/$(action_file "$repo")"
			echo "deps-check: FETCH  ACTION:$repo $tag ($when)"
		else
			echo "deps-check: FAIL   ACTION:$repo: the latest release of $repo cannot be read (${got:-no reply})"
			bad=1
		fi
	done < <(action_pins "${files[@]}")
	exit "$bad"
fi

if read -r tag when < <(latest_alpine) && [ -n "${when:-}" ]; then
	judge ALPINE "$ALPINE_VERSION" "$tag" "$when" "${ALPINE_HOLD:-}"
else
	echo "deps-check: FAIL   ALPINE: the latest Alpine release cannot be read"
	bad=1
fi

# The Python and Actions sections run when the caller names the files (make deps-check does). PyPI needs no
# token and is read live in every mode, as Alpine is; with DEPS_RELEASES_DIR the actions' releases are read
# from the files --fetch wrote, and an action with none fails.

# Python: every name==version in the requirements file against the newest PyPI release.
if [ -n "${DEPS_REQUIREMENTS:-}" ]; then
	if [ ! -r "$DEPS_REQUIREMENTS" ]; then
		echo "deps-check: FAIL   PYPI: $DEPS_REQUIREMENTS cannot be read"
		bad=1
	else
		pkg_re='^[[:space:]]*([A-Za-z0-9][A-Za-z0-9._-]*)==([^[:space:];\\]+)'
		while IFS= read -r line || [ -n "$line" ]; do
			[[ $line =~ $pkg_re ]] || continue
			pkg=${BASH_REMATCH[1]} version=${BASH_REMATCH[2]}
			tag='' when='' got=''
			if ! got=$(latest_pypi "$pkg") || ! read -r tag when <<<"$got" ||
				[[ ! $when =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
				echo "deps-check: FAIL   PYPI:$pkg: the latest release cannot be read (${got:-no reply})"
				bad=1
				continue
			fi
			# A pin behind the newest release is fine when a package pinned beside it requires a version below
			# that release (SPSDK caps its own dependencies): CAPPED, not stale.
			if [ "$version" != "${tag#v}" ]; then
				[ -n "$caps" ] || load_caps
				if holder=$(capping_package "$pkg" "$version" "${tag#v}"); then
					echo "deps-check: CAPPED PYPI:$pkg $version, latest $tag is excluded by the requirement of $holder"
					continue
				fi
			fi
			judge "PYPI:$pkg" "$version" "$tag" "$when" "" "bump $DEPS_REQUIREMENTS"
		done <"$DEPS_REQUIREMENTS"
	fi
fi

# Actions: every `uses: owner/repo@<sha> # vX.Y.Z` in the workflows; one lookup per action, one verdict per
# action and pinned tag. The pin is a full commit SHA, which never moves, so its comment must name the exact
# release; a coarser one (`# v6`) fails, and is judged as an exact version.
if [ -n "${DEPS_WORKFLOWS:-}" ]; then
	workflow_files "$DEPS_WORKFLOWS"
	if [ "${#files[@]}" -eq 0 ]; then
		echo "deps-check: FAIL   ACTIONS: no workflow files in $DEPS_WORKFLOWS"
		bad=1
	else
		declare -A act_latest=()
		while read -r repo version; do
			if [ -z "${act_latest[$repo]:-}" ]; then
				tag='' when='' got=''
				if [ -n "${DEPS_RELEASES_DIR:-}" ]; then
					if read -r tag when 2>/dev/null <"$DEPS_RELEASES_DIR/$(action_file "$repo")" && valid_release "$tag" "$when"; then
						act_latest[$repo]="$tag $when"
					else
						act_latest[$repo]="FAIL $DEPS_RELEASES_DIR/$(action_file "$repo") holds no release tag and date"
					fi
				elif got=$(latest_github "$repo") && read -r tag when <<<"$got" && valid_release "$tag" "$when"; then
					act_latest[$repo]="$tag $when"
				else
					act_latest[$repo]="FAIL ${got:-no reply}"
				fi
			fi
			if [ "${act_latest[$repo]%% *}" = FAIL ]; then
				echo "deps-check: FAIL   ACTION:$repo: the latest release of $repo cannot be read (${act_latest[$repo]#FAIL })"
				bad=1
				continue
			fi
			read -r tag when <<<"${act_latest[$repo]}"
			# A full-SHA pin never moves, so its comment must name the exact release: a coarser one (`# v6`)
			# is a failure of its own, and the pin is still judged against the latest tag as an exact version.
			if [[ ! $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
				echo "deps-check: FAIL   ACTION:$repo: the comment '$version' on the SHA pin must name the exact release (vX.Y.Z)"
				bad=1
			fi
			judge "ACTION:$repo" "${version#v}" "$tag" "$when" "" "bump the pin in $DEPS_WORKFLOWS"
		done < <(action_pins "${files[@]}")
	fi
fi

exit "$bad"
