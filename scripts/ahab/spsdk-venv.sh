#!/usr/bin/env bash
# spsdk-venv.sh prints the path of a venv holding the pinned SPSDK (SPSDK_VENV, default under the user cache), creating it with hash-checked installs; an existing venv is only checked.
set -euo pipefail

SPSDK_PIN=3.13.0
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
req="$here/requirements.txt"
breq="$here/build-requirements.txt"

die() {
	echo "spsdk-venv: $*" >&2
	exit 1
}

if [ -z "${SPSDK_VENV:-}" ]; then
	sum=$(cat "$breq" "$req" | sha256sum)
	SPSDK_VENV="${XDG_CACHE_HOME:-$HOME/.cache}/trusted-imx95/spsdk-$SPSDK_PIN-${sum:0:12}"
fi
venv=$(realpath -m "$SPSDK_VENV")
case "$venv/" in "$root"/*) die "SPSDK_VENV=$SPSDK_VENV is inside the clone; it must live outside it" ;; esac

if [ ! -x "$venv/bin/nxpimage" ]; then
	[ ! -e "$venv" ] || [ -z "$(ls -A "$venv")" ] ||
		die "$venv exists but holds no nxpimage; remove it or point SPSDK_VENV elsewhere"
	python3 -m pip --version >/dev/null 2>&1 || die "python3 -m pip is not available; it installs the pinned closure"
	mkdir -p "$venv"
	trap 'rm -rf "$venv"' EXIT
	python3 -m venv --without-pip "$venv"
	pip=(python3 -m pip --python "$venv/bin/python" install --quiet --no-cache-dir
		--disable-pip-version-check --require-hashes)
	"${pip[@]}" -r "$breq" >&2
	"${pip[@]}" --no-build-isolation -r "$req" >&2
	trap - EXIT
fi

# stdout only: SPSDK logs cache warnings to stderr on a first run.
got=$("$venv/bin/nxpimage" --version 2>/dev/null || true)
[ "$got" = "nxpimage, version $SPSDK_PIN" ] ||
	die "$venv/bin/nxpimage reports '$got'; the pin is SPSDK $SPSDK_PIN ($req)"
echo "$venv"
