#!/usr/bin/env bash
# image-tag.sh <toolchain|secure-world|integration> <repo-name>: prints the CI image tag named by its content hash.
set -euo pipefail

family=${1:?usage: image-tag.sh <toolchain|secure-world|integration> <repo-name>}
name=${2:?usage: image-tag.sh <toolchain|secure-world|integration> <repo-name>}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

case "$family" in
toolchain)
	hash=$(cat build/docker/devcontainer/Dockerfile scripts/tool-pins.sh scripts/fetch-tools.sh \
		scripts/ahab/spsdk-venv.sh scripts/ahab/requirements.txt scripts/ahab/build-requirements.txt | sha256sum)
	echo "${name}-toolchain:${hash:0:16}"
	;;
secure-world)
	hash=$(cat build/docker/devcontainer/Dockerfile scripts/tool-pins.sh | sha256sum)
	echo "${name}-secure-world:${hash:0:16}"
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
	echo "image-tag: unknown family '$family' (toolchain, secure-world or integration)" >&2
	exit 2
	;;
esac
