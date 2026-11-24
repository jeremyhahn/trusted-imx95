#!/usr/bin/env bash
# okp_station_preflight_helper.sh: a test helper that checks a station's tool pin, and runs
# nothing else. It lives under test/ on purpose: it is not a CLI of this repository, no SPEC
# row names it, nothing installs it and no Makefile target runs it. Only
# test/okp_station_preflight_test.sh calls it, with test doubles.
#
# Owner ruling 1234: the key exchange, the key import, the counter fuses and the life-cycle
# close run only at the provisioning station. The owner chose SPSDK for this hardware
# (2026-11-23); the pin is scripts/ahab/requirements.txt.
#
#   okp_station_preflight_helper.sh --dry-run
#
# With no argument it prints usage and exits 2. --dry-run is the only mode: any other
# argument is refused. It
#   (i)   stops and names SPSDK_VENV when it is unset or inside the clone,
#   (ii)  stops when the SPSDK the venv's interpreter reports differs from the pin,
#   (iii) prints the station steps of docs/oem-key-provisioning/architecture.md in order
#         and says it runs none of them.
# It opens no device, runs no SPSDK tool and writes nothing: the only program it starts is
# the venv's interpreter, to read an installed version.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
req="$root/scripts/ahab/requirements.txt"
arch="$root/docs/oem-key-provisioning/architecture.md"

usage() {
	echo "usage: okp_station_preflight_helper.sh --dry-run" >&2
	echo "  --dry-run  check SPSDK_VENV and the SPSDK pin, list the station steps, run none" >&2
	echo "  There is no mode that runs a step, opens a device or writes a fuse." >&2
}

die() {
	echo "station-preflight: $*" >&2
	exit 1
}

if [ "$#" -eq 0 ]; then
	usage
	exit 2
fi
if [ "$#" -ne 1 ] || [ "$1" != "--dry-run" ]; then
	echo "station-preflight: refused: '$*' is not an accepted argument" >&2
	usage
	exit 2
fi

[ -n "${SPSDK_VENV:-}" ] || die "SPSDK_VENV is unset; it names a Python venv outside the clone that holds the pinned SPSDK"
venv=$(realpath -m "$SPSDK_VENV")
case "$venv/" in "$root"/*) die "SPSDK_VENV=$SPSDK_VENV is inside the clone; it must live outside it" ;; esac

pin=""
while IFS= read -r line; do
	if [[ $line =~ ^spsdk==([0-9][0-9A-Za-z.]*) ]]; then
		pin=${BASH_REMATCH[1]}
		break
	fi
done <"$req"
[ -n "$pin" ] || die "no spsdk== pin found in $req"

[ -x "$venv/bin/python" ] || die "$venv/bin/python is not executable; SPSDK_VENV must be a Python venv"
got=$("$venv/bin/python" -I -c 'import importlib.metadata as m; print(m.version("spsdk"))' 2>/dev/null || true)
[ -n "$got" ] || die "$venv/bin/python reports no installed spsdk; the pin is SPSDK $pin ($req)"
[ "$got" = "$pin" ] || die "installed SPSDK is $got; the pin is SPSDK $pin ($req)"
echo "station-preflight: SPSDK $got matches the pin ($venv)"

# The steps are read from the architecture table: the first cell of each data row.
steps=()
in_table=0
while IFS= read -r line; do
	if [[ $line == "| Step |"* ]]; then
		in_table=1
		continue
	fi
	((in_table == 1)) || continue
	[[ $line == "|"* ]] || break
	[[ $line == "|---"* ]] && continue
	cell=${line#"| "}
	steps+=("${cell%% | *}")
done <"$arch"
[ "${#steps[@]}" -gt 0 ] || die "no step table found in $arch"

n=0
for s in "${steps[@]}"; do
	n=$((n + 1))
	echo "step $n: $s: provisioning station only (ruling 1234)"
done
echo "station-preflight: dry run; it ran none of these steps, opened no device and wrote no fuse"
