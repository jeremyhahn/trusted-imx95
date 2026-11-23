#!/usr/bin/env bash
# image-tag.sh <toolchain|integration> <repo-name>
#
# Prints a CI image tag named by its content (handbook ci-standard.md §9):
#   toolchain    <repo>-toolchain:<hash of the Dockerfile and every file it
#                COPYs as a pin: tool and SPSDK pins, and the ele-src stage's
#                ele-lib-build.sh, ele-lib.lock and bsp.lock>
#   integration  <repo>-ci-it:<hash of the commit's tree, on a dirty checkout
#                the diff and every untracked file .gitignore keeps, and
#                APK_INDEX_SUM>
set -euo pipefail

family=${1:?usage: image-tag.sh <toolchain|integration> <repo-name>}
name=${2:?usage: image-tag.sh <toolchain|integration> <repo-name>}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

case "$family" in
toolchain)
	hash=$(cat build/docker/devcontainer/Dockerfile scripts/tool-pins.sh scripts/fetch-tools.sh \
		scripts/ahab/spsdk-venv.sh scripts/ahab/requirements.txt scripts/ahab/build-requirements.txt \
		scripts/ele-lib-build.sh secure-key-handling/ele-lib.lock secure-world/bsp.lock | sha256sum)
	echo "${name}-toolchain:${hash:0:16}"
	;;
integration)
	hash=$({
		echo "apk ${APK_INDEX_SUM:-none}"
		git rev-parse 'HEAD^{tree}'
		git diff HEAD --binary
		git ls-files -z --others --exclude-standard | xargs -0 -r sha256sum
	} | sha256sum)
	echo "${name}-ci-it:${hash:0:16}"
	;;
*)
	echo "image-tag: unknown family '$family' (toolchain or integration)" >&2
	exit 2
	;;
esac
