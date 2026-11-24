#!/usr/bin/env bash
# Build xkmsd (and the xkmsctl client) from go-xkms for the board:
# a static linux/arm64 binary, versioned by the go-xkms commit.
#
#   scripts/xkms/xkmsd-build.sh [<go-xkms commit>]
#
# With no argument the tip of go-xkms main is used. The commit chosen is
# printed. Output: build/xkms/<commit>/{xkmsd,xkmsctl,manifest.txt}.
# go-xkms is only read: it is cloned into build/go-xkms/src (gitignored).
#
# Environment:
#   XKMS_REPO   go-xkms git URL (default https://github.com/jeremyhahn/go-xkms)
#   XKMSD_TAGS  Go build tags (default: the codec, pkcs8 and frost tags of
#               go-xkms's own CGO-free build)
#   XKMS_OUT    output root (default build/xkms under the repository)
set -euo pipefail

usage() {
	cat <<'EOF'
usage: xkmsd-build.sh [--help] [--dry-run] [<go-xkms commit>]

Build a static linux/arm64 xkmsd and xkmsctl at a go-xkms commit (default:
the tip of go-xkms main) into build/xkms/<commit>/ with a manifest.txt of
the commit, the Go version, the build flags and each binary's SHA-256.

  --dry-run   print the plan; clone and build nothing
EOF
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
repo=${XKMS_REPO:-https://github.com/jeremyhahn/go-xkms}
tags=${XKMSD_TAGS:-codec_cbor codec_json codec_msgpack pkcs8 frost}
outroot=${XKMS_OUT:-$root/build/xkms}
src=${XKMS_SRC:-$root/build/go-xkms/src}

dry=0
want=""
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	--dry-run) dry=1 ;;
	-*)
		echo "xkmsd-build: unknown option $1" >&2
		exit 2
		;;
	*) want=$1 ;;
	esac
	shift
done

if [ -z "$want" ]; then
	want=$(git ls-remote "$repo" refs/heads/main | cut -f1)
	[ -n "$want" ] || {
		echo "xkmsd-build: cannot resolve main of $repo" >&2
		exit 1
	}
	echo "xkmsd-build: go-xkms main resolves to $want"
fi

if [ "$dry" = 1 ]; then
	echo "plan: clone $repo into $src at $want"
	echo "plan: CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -tags '$tags' ./cmd/xkmsd ./cmd/xkmsctl"
	echo "plan: write $outroot/<commit>/{xkmsd,xkmsctl,manifest.txt}"
	exit 0
fi

mkdir -p "$(dirname "$src")"
if [ ! -d "$src/.git" ]; then
	git clone -q "$repo" "$src"
fi
git -C "$src" fetch -q origin
git -C "$src" -c advice.detachedHead=false checkout -q --force "$want"
commit=$(git -C "$src" rev-parse HEAD)
echo "xkmsd-build: building go-xkms $commit"

short=$(git -C "$src" rev-parse --short=12 HEAD)
base=$(tr -d '[:space:]' <"$src/VERSION" 2>/dev/null || true)
version="${base:-0.0.0}+g$short"
# The commit date, not the wall clock, so a rebuild is byte-identical.
bdate=$(TZ=UTC git -C "$src" show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD)
ldflags="-s -w -X main.Version=$version -X main.GitCommit=$commit -X main.BuildDate=$bdate"

out=$outroot/$commit
mkdir -p "$out"
for b in xkmsd xkmsctl; do
	(
		cd "$src"
		CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
			go build -trimpath -buildvcs=false -tags "$tags" \
			-ldflags "$ldflags" -o "$out/$b" "./cmd/$b"
	)
done

{
	echo "go-xkms-commit: $commit"
	echo "version: $version"
	echo "build-date: $bdate"
	echo "go-version: $(go version)"
	echo "env: CGO_ENABLED=0 GOOS=linux GOARCH=arm64"
	echo "flags: -trimpath -buildvcs=false -tags '$tags' -ldflags '$ldflags'"
	(cd "$out" && sha256sum xkmsd xkmsctl | while read -r h f; do echo "sha256: $h  $f"; done)
} >"$out/manifest.txt"

echo "xkmsd-build: output $out"
echo "xkmsd-build: $(grep '^sha256: .* xkmsd$' "$out/manifest.txt")"
