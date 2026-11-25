#!/bin/sh
# The xkmsd build, one script for the recipe (do_compile) and for the smoke
# test (scripts/platform-image-xkmsd-smoke.sh), so both build the same way.
# The caller sets the toolchain (GOROOT on PATH, GOOS, GOARCH, CC, CGO_*), the
# source tree and the pin; this script fixes what makes the build the
# project's: the local toolchain only, modules checked against go.sum, no
# module file rewritten, and go-xkms's own server build tags.
#
# Usage: xkmsd-build.sh SRCDIR OUTFILE VERSION COMMIT
# Environment: GOPATH, GOCACHE, GOMODCACHE (the caller's cache dirs).
set -eu
[ $# -eq 4 ] || { echo "usage: xkmsd-build.sh SRCDIR OUTFILE VERSION COMMIT" >&2; exit 2; }
src=$1 out=$2 version=$3 commit=$4

# The build tags of go-xkms's own server build (Dockerfile.server).
XKMS_TAGS="pkcs8,tpm2,awskms,gcpkms,azurekv,vault,pkcs11"

# Never let go fetch another toolchain than the pinned one.
export GOTOOLCHAIN=local
export GOFLAGS="-mod=readonly -modcacherw -trimpath -buildvcs=false"
export CGO_ENABLED=1

cd "$src"
go mod download
go mod verify
go build -tags "$XKMS_TAGS" \
    -ldflags "-X main.version=$version -X main.commit=$commit" \
    -o "$out" ./cmd/xkmsd
