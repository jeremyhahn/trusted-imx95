#!/usr/bin/env bash
# platform-image-verify.sh [--allow-dirty] OUT [LOCK]
#
# Check that a published platform-image output directory came from the pins in
# LOCK (default platform-image/manifest.lock). Offline: no network, no bitbake.
# A consumer runs it before AHAB signing (#14 Q4 (b)) or provisioning.
#
# PROVISIONAL, pending #14: what an output directory must carry is not final.
# It has not been run on real artefacts: the EULA (#14) blocks the build.
#
# Checks, and every problem is named, not only the first:
#   - OUT/SHA256SUMS verifies and OUT holds no unlisted file (the logic of
#     platform-image-repro-compare.sh, which is called, not copied);
#   - build-info.txt has every key once;
#   - machine=, manifest_commit= and every layer_*_commit= equal LOCK's (a
#     layer missing from either side, or extra, fails);
#   - platform_image_dirty=yes fails unless --allow-dirty;
#   - every target in targets= has a listed <target>-<machine>*.spdx.json.
# Exit 0 OK, 1 mismatch, 2 usage error.
set -u
LC_ALL=C
export LC_ALL

self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bad=0

say() { echo "platform-image-verify: $*" >&2; }
fail() {
	say "FAIL: $*"
	bad=1
}
usage() {
	say "$*"
	echo "usage: platform-image-verify.sh [--allow-dirty] OUT [LOCK]" >&2
	exit 2
}

allow_dirty=0
args=()
for a in "$@"; do
	case $a in
	--allow-dirty) allow_dirty=1 ;;
	-*) usage "unknown option $a" ;;
	*) args+=("$a") ;;
	esac
done
[ "${#args[@]}" -ge 1 ] && [ "${#args[@]}" -le 2 ] || usage "expected OUT and an optional LOCK"
out=${args[0]}
lock=${args[1]:-$self/../platform-image/manifest.lock}
[ -d "$out" ] || usage "$out is not a directory"
[ -f "$lock" ] || usage "$lock is not a file"

# The hash check and the unlisted-file check: the compare script's own, run
# with OUT on both sides; each message appears twice, so keep one.
cmp_out=$("$self/platform-image-repro-compare.sh" "$out" "$out" 2>&1)
cmp_rc=$?
if [ "$cmp_rc" -ne 0 ]; then
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		fail "${line#platform-image-repro-compare: }"
	done < <(printf '%s\n' "$cmp_out" | sort -u)
fi

# key=value lines of FILE (not comments) into the array named $1; a key seen
# twice goes into the array named $2.
# shellcheck disable=SC2034 # the arrays are written through namerefs
readkv() {
	local -n kv=$1 dup=$2
	local line k
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in '' | '#'*) continue ;; esac
		case $line in *=*) ;; *) continue ;; esac
		k=${line%%=*}
		if [ -n "${kv["$k"]+x}" ]; then dup["$k"]=1; fi
		kv["$k"]=${line#*=}
	done <"$3"
}

# shellcheck disable=SC2034 # lk_dup is written through a nameref
declare -A lk=() lk_dup=() bi=() bi_dup=()
readkv lk lk_dup "$lock"

if [ ! -f "$out/build-info.txt" ]; then
	fail "$out has no build-info.txt"
else
	readkv bi bi_dup "$out/build-info.txt"
	for k in machine distro targets SOURCE_DATE_EPOCH build_seconds checkout_commit \
		platform_image_dirty platform_image_dirty_sha256 manifest_commit; do
		[ -n "${bi[$k]+x}" ] || fail "build-info.txt: key $k is missing"
	done
	for k in "${!bi_dup[@]}"; do fail "build-info.txt: key $k appears twice"; done

	for k in machine manifest_commit; do
		[ -n "${lk[$k]+x}" ] || { fail "$lock: key $k is missing"; continue; }
		[ -z "${bi[$k]+x}" ] || [ "${bi[$k]}" = "${lk[$k]}" ] ||
			fail "$k differs: build-info.txt has ${bi[$k]}, $lock has ${lk[$k]}"
	done
	for k in "${!lk[@]}"; do
		case $k in layer_*_commit) ;; *) continue ;; esac
		if [ -z "${bi[$k]+x}" ]; then
			fail "$k: in $lock but missing from build-info.txt"
		elif [ "${bi[$k]}" != "${lk[$k]}" ]; then
			fail "$k differs: build-info.txt has ${bi[$k]}, $lock has ${lk[$k]}"
		fi
	done
	for k in "${!bi[@]}"; do
		case $k in layer_*_commit) ;; *) continue ;; esac
		[ -n "${lk[$k]+x}" ] || fail "$k: in build-info.txt but not in $lock"
	done

	if [ "${bi[platform_image_dirty]:-}" = yes ] && [ "$allow_dirty" -eq 0 ]; then
		fail "platform_image_dirty=yes: built from a tree with uncommitted inputs (--allow-dirty accepts it)"
	fi

	# An SBOM for each target, listed in SHA256SUMS.
	if [ -f "$out/SHA256SUMS" ] && [ -n "${bi[targets]+x}" ]; then
		for t in ${bi[targets]}; do
			found=0
			while IFS= read -r line || [ -n "$line" ]; do
				n=${line#*[ ]}
				n=${n#[ *]}
				case $n in "$t-${lk[machine]:-${bi[machine]:-}}"*.spdx.json) found=1 ;; esac
			done <"$out/SHA256SUMS"
			[ "$found" -eq 1 ] || fail "$t: no .spdx.json listed in SHA256SUMS"
		done
	fi
fi

if [ "$bad" -ne 0 ]; then
	say "$out does not match $lock"
	exit 1
fi
n=0
while IFS= read -r line || [ -n "$line" ]; do
	[ -z "$line" ] || n=$((n + 1))
done <"$out/SHA256SUMS"
echo "platform-image-verify: OK, $n artefacts, pins match $lock"
