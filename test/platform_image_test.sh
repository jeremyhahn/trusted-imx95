#!/usr/bin/env bash
# Offline checks of platform-image/ (provisional default, pending the owner's
# answer on #14): the lock parses, every commit is 40 hex, the machine matches
# sm.lock, and the distro configuration names no signing step.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILS=0

lock=$ROOT/platform-image/manifest.lock
distro=$ROOT/platform-image/conf/distro/trusted-imx95.conf

bad=0 n=0 commits=0 machine=
declare -A seen=()
while IFS= read -r line || [ -n "$line" ]; do
	case $line in '' | '#'*) continue ;; esac
	if [[ ! $line =~ ^([a-z0-9_]+)=(.+)$ ]]; then bad=$((bad + 1)); continue; fi
	k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
	[ -z "${seen[$k]+x}" ] || bad=$((bad + 1))
	seen[$k]=$v
	n=$((n + 1))
	case $k in
	manifest_commit | layer_*_commit)
		commits=$((commits + 1))
		[[ $v =~ ^[0-9a-f]{40}$ ]] || bad=$((bad + 1))
		;;
	machine) machine=$v ;;
	esac
done <"$lock"

expect "lock parses, no duplicate key" test "$bad" -eq 0 -a "$n" -gt 0
expect "lock has the manifest and at least one layer commit" test "$commits" -gt 1
expect "manifest file named" test "${seen[manifest_file]:-}" = imx-6.18.37-2.1.0.xml
for k in "${!seen[@]}"; do
	if [[ $k =~ ^layer_(.+)_commit$ ]]; then
		for f in repo path; do
			[ -n "${seen[layer_${BASH_REMATCH[1]}_$f]:-}" ] || { bad=$((bad + 1)); echo "missing $f of ${BASH_REMATCH[1]}"; }
		done
	fi
done
expect "every layer has a repo and a path" test "$bad" -eq 0

sm_machine_found=0
while IFS= read -r line; do
	case $line in '#'*"$machine"*) sm_machine_found=1 ;; esac
done <"$ROOT/system-manager/sm.lock"
expect "machine is set" test -n "$machine"
expect "machine matches the sm.lock comment" test "$sm_machine_found" -eq 1

signs=0 derives=0
while IFS= read -r line; do
	case $line in
	require*fsl-imx-*) derives=1 ;;
	require*poky*) signs=1 ;;
	'#'*) ;;
	*[Ss][Ii][Gg][Nn]* | *[Cc][Ss][Tt]* | *spsdk* | *SPSDK* | *ahab* | *AHAB* | *fuse* | *rpmb*) signs=1 ;;
	esac
done <"$distro"
expect "distro requires an fsl-imx-* distro, not poky" test "$derives" -eq 1
expect "distro names no signing step" test "$signs" -eq 0

finish
