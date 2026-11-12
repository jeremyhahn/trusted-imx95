#!/bin/sh
# fetch-tools.sh <pin-file> <out-dir>
#
# Downloads every pinned tool of the pin file, checks each archive against
# its SHA-256 and installs the binary into <out-dir>. Run by the Dockerfile's
# fetch stage, and by `make tools` into .tools/bin where there is no image; a
# missing pin, a failed download or a digest mismatch fails by name.
set -eu

pins=${1:?usage: fetch-tools.sh <pin-file> <out-dir>}
out=${2:?usage: fetch-tools.sh <pin-file> <out-dir>}
# shellcheck disable=SC1090
. "$pins"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# fetch <NAME> <binary path inside the archive>
fetch() {
	eval "url=\${$1_URL:-}"
	eval "sum=\${$1_SHA256:-}"
	# shellcheck disable=SC2154 # set by the eval above
	if [ -z "$url" ] || [ -z "$sum" ]; then
		echo "fetch-tools: $1_URL or $1_SHA256 missing from $pins" >&2
		exit 1
	fi
	archive="$work/$1.tar"
	curl -fsSL --retry 3 -o "$archive" "$url"
	if ! echo "$sum  $archive" | sha256sum -c - >/dev/null 2>&1; then
		echo "fetch-tools: $1: SHA-256 mismatch for $url" >&2
		exit 1
	fi
	mkdir -p "$work/$1"
	tar -xf "$archive" -C "$work/$1"
	install -m 0755 "$work/$1/$2" "$out/$(basename "$2")"
}

fetch SHELLCHECK "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
fetch ACTIONLINT actionlint
fetch GITLEAKS gitleaks
fetch TRIVY trivy
