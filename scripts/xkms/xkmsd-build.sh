#!/usr/bin/env bash
# Build xkmsd (and the xkmsctl client) from go-xkms for the board:
# a static linux/arm64 binary, versioned by the go-xkms commit.
#
#   scripts/xkms/xkmsd-build.sh [<go-xkms commit>]
#
# With no argument the tip of go-xkms main is used. The commit chosen is
# printed. Output: build/xkms/<commit>/{xkmsd,xkmsctl,manifest.txt}.
# go-xkms is only read: it is cloned into build/go-xkms/src (gitignored) as an
# object cache, and every build runs in a fresh checkout of the commit (a
# temporary directory next to it, removed at the end), refused unless clean.
#
# Environment:
#   XKMS_REPO   go-xkms git URL (default https://github.com/jeremyhahn/go-xkms)
#   XKMSD_TAGS  Go build tags (default: the codec, pkcs8 and frost tags of
#               go-xkms's own CGO-free build)
#   XKMS_OUT    output root (default build/xkms under the repository)
set -euo pipefail

# The Go release this build is pinned to; any other `go version` is refused
# before anything is built. Source: the Go toolchain of the project's CI build
# image (the go1.27 line of the ci-template in .github/workflows/ci.yml) and
# the release list at https://go.dev/dl/. go-xkms's own go.mod `go` and
# `toolchain` lines were not available when this was pinned; GOTOOLCHAIN=local
# below keeps go.mod from swapping the toolchain for another one. Raising the
# pin is an edit of this line, reviewed like any other change.
go_pin=go1.27.4

usage() {
	cat <<'EOF'
usage: xkmsd-build.sh [--help] [--dry-run] [<go-xkms commit>]

Build a static linux/arm64 xkmsd and xkmsctl at a go-xkms commit (default:
the tip of go-xkms main) into build/xkms/<commit>/ with a manifest.txt of
the commit, the pinned and actual Go version, the build environment, the
build flags and each binary's SHA-256.

The build is reproducible only with one toolchain: it is refused unless
`go version` is the pinned release (go_pin at the top of this script), and
it runs in a clean environment (no GOFLAGS, no GOEXPERIMENT, GOTOOLCHAIN=local,
default GOAMD64/GOARM64, CGO_ENABLED=0, a fixed GOPATH and GOCACHE outside
the source tree).

  --dry-run   print the plan; clone and build nothing
EOF
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
repo=${XKMS_REPO:-https://github.com/jeremyhahn/go-xkms}
tags=${XKMSD_TAGS:-codec_cbor codec_json codec_msgpack pkcs8 frost}
outroot=${XKMS_OUT:-$root/build/xkms}
src=${XKMS_SRC:-$root/build/go-xkms/src}

# Every variable that changes the output is set here, and go runs under
# `env -i` with only these (plus PATH, HOME and the proxy/CA variables the
# module download needs), so nothing from the caller's shell or the user's
# `go env -w` file reaches the build. GOPATH and GOCACHE are fixed and outside
# the source tree. The values are recorded in the manifest, with the two paths
# relative to the repository.
gobase_rel=build/go-xkms
buildenv=(
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64
	GOAMD64=v1 GOARM64=v8.0
	GOFLAGS= GOEXPERIMENT= GODEBUG= GOFIPS140=off
	GOTOOLCHAIN=local GOWORK=off GOENV=off
	"GOPROXY=https://proxy.golang.org,direct" GOSUMDB=sum.golang.org
	GOPATH="$root/$gobase_rel/gopath" GOCACHE="$root/$gobase_rel/gocache"
)
buildenv_record=$(printf '%s ' "${buildenv[@]}")
buildenv_record=${buildenv_record//"$root/"/}
passenv=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR; do
	[ -z "${!v:-}" ] || passenv+=("$v=${!v}")
done
# cleango <go args>: go in the clean environment
cleango() {
	env -i PATH="$PATH" HOME="$root/$gobase_rel/home" ${passenv[@]+"${passenv[@]}"} "${buildenv[@]}" go "$@"
}

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
	echo "plan: clone $repo into $src (object cache), build in a fresh checkout of $want, refused unless git status --ignored is empty"
	echo "plan: refuse to build unless go version is $go_pin"
	echo "plan: env -i $buildenv_record go build -trimpath -buildvcs=false -tags '$tags' ./cmd/xkmsd ./cmd/xkmsctl"
	echo "plan: write $outroot/<commit>/{xkmsd,xkmsctl,manifest.txt}"
	exit 0
fi

# Refuse any other toolchain before the clone and before anything is built.
# The check runs in the build environment, so GOTOOLCHAIN=local decides which
# go answers.
goversion=$(cleango version 2>&1) || {
	echo "xkmsd-build: go does not run: $goversion" >&2
	exit 1
}
case $goversion in
"go version $go_pin "*) ;;
*)
	echo "xkmsd-build: refusing to build: pinned to $go_pin, found: $goversion" >&2
	exit 1
	;;
esac

mkdir -p "$(dirname "$src")"
if [ ! -d "$src/.git" ]; then
	git clone -q "$repo" "$src"
fi
git -C "$src" fetch -q origin
commit=$(git -C "$src" rev-parse --verify -q "$want^{commit}" || git -C "$src" rev-parse --verify -q "origin/$want^{commit}") || {
	echo "xkmsd-build: $want is not a commit of $repo" >&2
	exit 1
}
echo "xkmsd-build: building go-xkms $commit"

# The cached clone is only an object store. A `checkout --force` there leaves
# untracked and ignored files in place, and a stray .go file would be compiled
# into a binary whose manifest names only the commit. So build in a fresh
# directory that holds exactly the commit, and refuse unless git sees it clean,
# ignored files included.
work=$(mktemp -d "$(dirname "$src")/build.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" fetch -q --no-tags "$src" '+refs/*:refs/src/*'
git -C "$work" -c advice.detachedHead=false checkout -q --detach "$commit"
[ "$(git -C "$work" rev-parse HEAD)" = "$commit" ] || {
	echo "xkmsd-build: the fresh checkout is not at $commit" >&2
	exit 1
}
dirty=$(git -C "$work" status --porcelain --ignored)
[ -z "$dirty" ] || {
	echo "xkmsd-build: refusing to build: the source tree is not exactly the commit:" >&2
	printf '%s\n' "$dirty" >&2
	exit 1
}

short=$(git -C "$work" rev-parse --short=12 HEAD)
base=$(tr -d '[:space:]' <"$work/VERSION" 2>/dev/null || true)
version="${base:-0.0.0}+g$short"
# The commit date, not the wall clock, so a rebuild is byte-identical.
bdate=$(TZ=UTC git -C "$work" show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD)
ldflags="-s -w -X main.Version=$version -X main.GitCommit=$commit -X main.BuildDate=$bdate"

out=$outroot/$commit
mkdir -p "$out" "$root/$gobase_rel/home" "$root/$gobase_rel/gopath" "$root/$gobase_rel/gocache"
for b in xkmsd xkmsctl; do
	(
		cd "$work"
		cleango build -trimpath -buildvcs=false -tags "$tags" \
			-ldflags "$ldflags" -o "$out/$b" "./cmd/$b"
	)
done

{
	echo "go-xkms-commit: $commit"
	echo "version: $version"
	echo "build-date: $bdate"
	echo "source: fresh checkout of the commit, git status --ignored empty"
	echo "go-pinned: $go_pin"
	echo "go-version: $goversion"
	echo "env: $buildenv_record"
	echo "flags: -trimpath -buildvcs=false -tags '$tags' -ldflags '$ldflags'"
	(cd "$out" && sha256sum xkmsd xkmsctl | while read -r h f; do echo "sha256: $h  $f"; done)
} >"$out/manifest.txt"

echo "xkmsd-build: output $out"
echo "xkmsd-build: $(grep '^sha256: .* xkmsd$' "$out/manifest.txt")"
