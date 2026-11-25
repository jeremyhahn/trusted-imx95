#!/usr/bin/env bash
# cst-check.sh: CST_PATH must name an extracted CST 3.1.0 tree (release/docs/CST_UG.pdf) outside the repository; exit 0 ok, 2 unset, 1 invalid.
set -euo pipefail

readonly MARKER=release/docs/CST_UG.pdf

if [ -z "${CST_PATH:-}" ]; then
	echo "cst-check: CST_PATH is not set. Set CST_PATH to the directory of NXP's Code Signing Tool 3.1.0, extracted outside this repository (docs/references/README.md, The Code Signing Tool in the build)." >&2
	exit 2
fi

if [ ! -d "$CST_PATH" ]; then
	echo "cst-check: CST_PATH=$CST_PATH is not a directory; it must name an extracted CST 3.1.0 tree." >&2
	exit 1
fi

cst=$(cd "$CST_PATH" && pwd -P)
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
case "$cst/" in
"$repo"/*)
	echo "cst-check: CST_PATH=$CST_PATH is inside this repository; the CST is never read from this tree. Extract it outside the repository." >&2
	exit 1
	;;
esac

if [ ! -f "$cst/$MARKER" ]; then
	echo "cst-check: CST_PATH=$CST_PATH is not a CST tree: $MARKER is missing." >&2
	exit 1
fi

echo "cst-check: OK, CST_PATH is a CST tree"
