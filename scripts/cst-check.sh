#!/usr/bin/env bash
# cst-check.sh: the prerequisite of every build step that needs NXP's Code
# Signing Tool (CST). The build takes the tool only from CST_PATH, a CST 3.1.0
# tree extracted outside this repository (docs/references/README.md §The Code
# Signing Tool in the build). The tool is never downloaded or copied here.
#
# Exit 0: CST_PATH names a CST tree outside the repository.
# Exit 2: CST_PATH is unset or empty.
# Exit 1: CST_PATH is set but is not a directory, is inside this repository,
#         or is not a CST tree.
#
# What "a CST tree" is: docs/references/README.md names no executable and no
# top-level layout of the extracted tool. The one layout it gives is the
# documents inside the archive, release/docs/CST_UG.pdf among them, so the
# check is that CST_PATH/release/docs/CST_UG.pdf exists. When a document names
# the CST executable, the check adds it.
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
