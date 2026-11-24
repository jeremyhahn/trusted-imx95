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
#   - every target in targets= has a listed <target>-<machine>*.spdx.json;
#   - trusted-imx95-image has a listed, non-empty .manifest naming none of the
#     packages that IMAGE_INSTALL:append in trusted-imx95-image-debug.bb adds
#     (read from that recipe; exit 2 if it cannot be parsed), and none of the
#     package managers rpm opkg dnf apt dpkg (a list here; whole names). The
#     debug target is not checked. Provisional, pending #14; not run on real artefacts.
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

# The debug packages: the one list, read from the debug recipe.
debug_recipe=$self/../platform-image/recipes-core/images/trusted-imx95-image-debug.bb
declare -A dbgpkg=()
dbgline=$(sed -n 's/^IMAGE_INSTALL:append[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$debug_recipe" 2>/dev/null | head -n 1)
for p in $dbgline; do dbgpkg[$p]=1; done
[ "${#dbgpkg[@]}" -gt 0 ] || usage "cannot parse IMAGE_INSTALL:append in $debug_recipe"

# The package managers: hardening-survey section 7 says the production image
# has none. The debug recipe gets one through the package-management image
# feature, not through a package name, so the recipe cannot supply this list.
# A provisional default, pending #14; a name is matched whole.
declare -A pmpkg=()
for p in rpm opkg dnf apt dpkg; do pmpkg[$p]=1; done

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
		# targets= must name the production target, and only known targets.
		tprod=0
		for t in ${bi[targets]}; do
			case $t in
			trusted-imx95-image) tprod=1 ;;
			trusted-imx95-image-debug) ;;
			*) fail "build-info.txt: unknown target $t" ;;
			esac
		done
		[ "$tprod" -eq 1 ] || fail "build-info.txt: targets= is empty or lacks trusted-imx95-image"
		for t in ${bi[targets]}; do
			found=0
			while IFS= read -r line || [ -n "$line" ]; do
				n=${line#*[ ]}
				n=${n#[ *]}
				case $n in "$t-${lk[machine]:-${bi[machine]:-}}"*.spdx.json) found=1 ;; esac
			done <"$out/SHA256SUMS"
			[ "$found" -eq 1 ] || fail "$t: no .spdx.json listed in SHA256SUMS"

			# A real wic or rootfs image, not a bmap, manifest or SBOM alone.
			ifound=0
			while IFS= read -r line || [ -n "$line" ]; do
				n=${line#*[ ]}
				n=${n#[ *]}
				case $n in
				"$t-${lk[machine]:-${bi[machine]:-}}"*.wic.bmap | "$t-${lk[machine]:-${bi[machine]:-}}"*.manifest | "$t-${lk[machine]:-${bi[machine]:-}}"*.spdx.json) ;;
				"$t-${lk[machine]:-${bi[machine]:-}}"*.wic* | "$t-${lk[machine]:-${bi[machine]:-}}"*.rootfs*) ifound=1 ;;
				esac
			done <"$out/SHA256SUMS"
			[ "$ifound" -eq 1 ] || fail "$t: no wic or rootfs image listed in SHA256SUMS"

			# The production target's package manifest holds no debug package.
			[ "$t" = trusted-imx95-image ] || continue
			mfound=0
			while IFS= read -r line || [ -n "$line" ]; do
				n=${line#*[ ]}
				n=${n#[ *]}
				case $n in "$t-${lk[machine]:-${bi[machine]:-}}"*.manifest) ;; *) continue ;; esac
				mfound=1
				mpk=0
				while IFS= read -r ml || [ -n "$ml" ]; do
					[ -n "${ml//[[:space:]]/}" ] || continue
					mpk=1
					read -r pkg _ <<<"$ml"
					[ -z "${dbgpkg[$pkg]+x}" ] || fail "$n: debug package $pkg is in the production manifest"
					[ -z "${pmpkg[$pkg]+x}" ] || fail "$n: package manager $pkg is in the production manifest"
				done <"$out/$n" || fail "$n: cannot read the production manifest"
				[ "$mpk" -eq 1 ] || fail "$n: the production manifest is empty"
			done <"$out/SHA256SUMS"
			[ "$mfound" -eq 1 ] || fail "$t: no .manifest listed in SHA256SUMS"
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
