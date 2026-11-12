#!/usr/bin/env bash
# check-tracked-cst.sh [repo-dir]
#
# Fails when any path git tracks is a Code Signing Tool archive (cst-*.tgz)
# or lies inside a directory named cst-* (an extracted tree). The CST stays
# outside the repository (docs/references/README.md §The Code Signing Tool in
# the build); .gitignore keeps it out, and this check catches a forced add.
# A finding prints the path and the rule only. An unreadable index fails.
set -euo pipefail

dir=${1:-.}
if ! list=$(git -C "$dir" ls-files -z --cached 2>/dev/null | tr '\0' '\n'); then
	echo "check-tracked-cst: cannot list the tracked files of $dir" >&2
	exit 1
fi

bad=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	base=${path##*/}
	# shellcheck disable=SC2254 # the globs are the rule
	case "$base" in
	cst-*.tgz)
		echo "check-tracked-cst: $path: tracked CST archive (cst-*.tgz)"
		bad=1
		continue
		;;
	esac
	parent=${path%/*}
	[ "$parent" != "$path" ] || continue
	IFS=/ read -r -a parts <<<"$parent"
	for part in "${parts[@]}"; do
		case "$part" in
		cst-*)
			echo "check-tracked-cst: $path: tracked inside a CST tree (cst-*/)"
			bad=1
			break
			;;
		esac
	done
done <<<"$list"

if [ "$bad" -ne 0 ]; then
	echo "check-tracked-cst: FAIL: the CST is read from CST_PATH, never tracked; git rm --cached the paths above" >&2
	exit 1
fi
echo "check-tracked-cst: OK"
