#!/usr/bin/env bash
# platform-image-fetch.sh [LOCK [DIR]]: check out every layer platform-image/
# manifest.lock pins into DIR, outside this clone, and fail when a layer's
# checked-out commit differs from the lock. Needs the network; no Yocto build,
# no key and no board is touched. Provisional default, pending the owner's
# answer on #14 (docs/platform-image/build.md).
#
# DIR defaults to $PLATFORM_IMAGE_DIR, then ${XDG_CACHE_HOME:-$HOME/.cache}/
# trusted-imx95/platform-image.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lock=${1:-$root/platform-image/manifest.lock}
dir=${2:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
die() {
	echo "platform-image-fetch: $*" >&2
	exit 1
}
[ -f "$lock" ] || die "no lock file: $lock"

# Parse, never source.
declare -A kv=()
layers=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
	n=$((n + 1))
	case $line in '' | '#'*) continue ;; esac
	[[ $line =~ ^([a-z0-9_]+)=(.+)$ ]] || die "$lock:$n: not key=value: $line"
	k=${BASH_REMATCH[1]}
	[ -z "${kv[$k]+x}" ] || die "$lock:$n: duplicate key $k"
	kv[$k]=${BASH_REMATCH[2]}
	if [[ $k =~ ^layer_(.+)_commit$ ]]; then layers+=("${BASH_REMATCH[1]}"); fi
done <"$lock"
[ "${#layers[@]}" -gt 0 ] || die "$lock: no layer"

# The fetch directory is never inside this clone.
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)
case "$dir/" in "$root"/*) die "$dir is inside this clone; use a directory outside it" ;; esac

fetch_one() { # name repo path commit
	local name=$1 repo=$2 path=$3 commit=$4 d=$dir/$3 head
	[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "layer $name: commit '$commit' is not 40 hex (MISSING or malformed)"
	[[ $path =~ ^sources/[A-Za-z0-9._-]+$ ]] || die "layer $name: unexpected path $path"
	[ -d "$d/.git" ] || git init -q "$d"
	if [ "$(git -C "$d" rev-parse -q --verify "$commit^{commit}" 2>/dev/null || true)" != "$commit" ]; then
		git -C "$d" fetch -q --depth 1 "$repo" "$commit" 2>/dev/null ||
			git -C "$d" fetch -q "$repo" "$commit" 2>/dev/null ||
			git -C "$d" fetch -q "$repo" '+refs/heads/*:refs/remotes/pin/*' '+refs/tags/*:refs/tags/*' ||
			die "layer $name: cannot fetch $repo"
	fi
	git -C "$d" checkout -q --detach "$commit" || die "layer $name: $commit is not in $repo"
	head=$(git -C "$d" rev-parse HEAD)
	[ "$head" = "$commit" ] || die "layer $name: checked out $head, the lock pins $commit"
	echo "platform-image-fetch: $name $commit"
}

for name in "${layers[@]}"; do
	for f in repo path; do
		[ -n "${kv[layer_${name}_$f]:-}" ] || die "layer $name: no $f in $lock"
	done
	fetch_one "$name" "${kv[layer_${name}_repo]}" "${kv[layer_${name}_path]}" "${kv[layer_${name}_commit]}"
done
echo "platform-image-fetch: OK (${#layers[@]} layers in $dir)"
