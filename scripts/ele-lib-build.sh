#!/usr/bin/env bash
# Fetch NXP's public secure-enclave user library at the commit and SHA-256
# secure-key-handling/ele-lib.lock pins, and cross-build it for aarch64 with
# the toolchain secure-world/bsp.lock pins. Documented in
# docs/secure-key-handling/client.md.
#
#   ele-lib-build.sh --check-lock [--lock FILE]
#       offline: parse the lock and the toolchain pin, check every value
#   ele-lib-build.sh --work DIR --out DIR [--cache DIR] [--lock FILE]
#       fetch (outside the tree), verify, build; needs the network
#   ele-lib-build.sh --work DIR --src-only [--lock FILE]
#       fetch and verify only: DIR/src is the pinned source (the toolchain
#       image's ELE_SRC); no toolchain, no build
#
# Fails closed: a commit or digest mismatch removes what was fetched and stops.
# Nothing here touches a board, a fuse or a block device.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lock=$root/secure-key-handling/ele-lib.lock
work=
out=
cache=
check_only=0
src_only=0

die() { echo "ele-lib-build: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--check-lock) check_only=1 ;;
	--lock) [ $# -ge 2 ] || die "--lock needs a file"; lock=$2; shift ;;
	--work) [ $# -ge 2 ] || die "--work needs a directory"; work=$2; shift ;;
	--out) [ $# -ge 2 ] || die "--out needs a directory"; out=$2; shift ;;
	--cache) [ $# -ge 2 ] || die "--cache needs a directory"; cache=$2; shift ;;
	--src-only) src_only=1 ;;
	*) die "unknown argument $1" ;;
	esac
	shift
done

# parse_lock FILE ARRAYNAME NAME...: read key=value lines into the associative
# array, each listed name exactly once, no other name, no UNREAD value.
parse_lock() {
	local file=$1 arr=$2 line name value n
	shift 2
	[ -f "$file" ] || die "$file is not a file"
	declare -n dst=$arr
	local -A seen=()
	local -A want=()
	for n in "$@"; do want[$n]=1; done
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in '' | '#'*) continue ;; esac
		[[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "$file: malformed line: $line"
		name=${BASH_REMATCH[1]}
		value=${BASH_REMATCH[2]}
		[ -n "${want[$name]:-}" ] || die "$file: unknown name $name"
		[ -z "${seen[$name]:-}" ] || die "$file: $name appears twice"
		[ "$value" != UNREAD ] || die "$file: $name is UNREAD"
		[ -n "$value" ] || die "$file: $name is empty"
		seen[$name]=1
		# shellcheck disable=SC2034
		dst["$name"]=$value
	done <"$file"
	for n in "$@"; do [ -n "${seen[$n]:-}" ] || die "$file: $n is missing"; done
}

declare -A pin=() tc=()
parse_lock "$lock" pin ELE_REPO ELE_BRANCH ELE_COMMIT ELE_ARCHIVE_SHA256 ELE_PLAT TOOLCHAIN_LOCK
[[ ${pin[ELE_COMMIT]} =~ ^[0-9a-f]{40}$ ]] || die "ELE_COMMIT is not 40 hex digits"
[[ ${pin[ELE_ARCHIVE_SHA256]} =~ ^[0-9a-f]{64}$ ]] || die "ELE_ARCHIVE_SHA256 is not 64 hex digits"
[[ ${pin[ELE_REPO]} =~ ^https://[A-Za-z0-9./_-]+$ ]] || die "ELE_REPO is not an https URL"
[[ ${pin[ELE_PLAT]} =~ ^[a-z0-9]+$ ]] || die "ELE_PLAT is not a platform name"
case ${pin[TOOLCHAIN_LOCK]} in /* | *..*) die "TOOLCHAIN_LOCK must be a path inside the tree" ;; esac

# The toolchain pin is read from bsp.lock: only the names this script needs
# (that file has more, which this reader does not accept, so it reads by name).
toolchain_pin() {
	local file=$root/${pin[TOOLCHAIN_LOCK]} line name
	[ -f "$file" ] || die "$file is not a file"
	while IFS= read -r line || [ -n "$line" ]; do
		[[ $line =~ ^(TOOLCHAIN_VERSION|TOOLCHAIN_URL|TOOLCHAIN_SHA256)=(.+)$ ]] || continue
		name=${BASH_REMATCH[1]}
		[ -z "${tc[$name]:-}" ] || die "$file: $name appears twice"
		tc[$name]=${BASH_REMATCH[2]}
	done <"$file"
	for name in TOOLCHAIN_VERSION TOOLCHAIN_URL TOOLCHAIN_SHA256; do
		[ -n "${tc[$name]:-}" ] || die "$file: $name is missing"
		[ "${tc[$name]}" != UNREAD ] || die "$file: $name is UNREAD"
	done
	[[ ${tc[TOOLCHAIN_SHA256]} =~ ^[0-9a-f]{64}$ ]] || die "$file: TOOLCHAIN_SHA256 is not 64 hex digits"
	[[ ${tc[TOOLCHAIN_URL]} =~ ^https:// ]] || die "$file: TOOLCHAIN_URL is not https"
}
toolchain_pin

if [ "$check_only" = 1 ]; then
	echo "ele-lib-build: lock OK (${pin[ELE_REPO]} ${pin[ELE_COMMIT]}, toolchain ${tc[TOOLCHAIN_VERSION]})"
	exit 0
fi

if [ "$src_only" = 1 ]; then
	[ -n "$work" ] || die "--src-only needs --work"
else
	[ -n "$work" ] && [ -n "$out" ] || die "give --check-lock, or --work and --out, or --work and --src-only"
	# A reused --out could hold a stale libele_hsm.so.*: refuse it before
	# anything is fetched. The build is published into an empty or new one.
	if [ -e "$out" ] && { [ ! -d "$out" ] || [ -n "$(ls -A -- "$out")" ]; }; then
		die "--out $out exists and is not an empty directory; give a new or empty one"
	fi
fi
# resolve_phys PATH: the physical location of PATH, which need not exist: the
# deepest existing ancestor is resolved with pwd -P, every symlink on the way
# (a final component included, dangling or not) is followed, and what does not
# exist yet is appended. Fails (nonzero) on anything it cannot resolve.
resolve_phys() {
	local p=$1 rest="" base t d n=0
	case $p in /*) ;; *) p=$PWD/$p ;; esac
	while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
	while :; do
		n=$((n + 1))
		[ "$n" -le 64 ] || return 1
		if [ -L "$p" ]; then
			t=$(readlink "$p") || return 1
			case $t in /*) p=$t ;; *) p=${p%/*}/$t ;; esac
			[ -n "$p" ] || return 1
			continue
		fi
		if [ -e "$p" ]; then
			d=$(cd "$p" 2>/dev/null && pwd -P) || return 1
			[ "$d" = / ] && d=
			# The filesystem root (an ancestor of a checkout placed at /name)
			# is "/", not an empty string.
			if [ -z "$d$rest" ]; then printf '/\n'; else printf '%s%s\n' "$d" "$rest"; fi
			return 0
		fi
		base=${p##*/}
		case $base in '' | . | ..) return 1 ;; esac
		rest=/$base$rest
		p=${p%/*}
		[ -n "$p" ] || p=/
	done
}

# The work directory is resolved in full before anything is fetched or removed,
# and must be outside the checkout and not contain it.
work_phys=$(resolve_phys "$work") || die "cannot resolve --work $work"
[ -n "$work_phys" ] || die "cannot resolve --work $work"
# Compare with a trailing slash on both sides; the root "/" becomes the empty
# prefix, so "/" contains every checkout (a checkout at /name has "/" as its parent).
wp=${work_phys%/}
rp=${root%/}
case $wp/ in
"$rp"/*) die "--work must be outside the checkout" ;;
esac
case $rp/ in
"$wp"/*) die "--work must not contain the checkout" ;;
esac
work=$work_phys
[ -n "$cache" ] || cache=$work/cache

# Only a directory this script made is ever emptied: a non-empty one must carry
# the script's marker, and nothing is removed before this check.
work_marker=.ele-lib-build-work
if [ -e "$work" ]; then
	[ -d "$work" ] || die "--work $work is not a directory"
	if [ ! -e "$work/$work_marker" ] && [ -n "$(ls -A "$work")" ]; then
		die "--work $work is not empty and was not made by this script; name an empty or new directory"
	fi
fi
mkdir -p "$work"
: >"$work/$work_marker"
# The directory just made is where it was resolved to, and still outside.
made=$(cd "$work" && pwd -P) || die "cannot enter $work"
[ "$made" = "$work" ] || die "--work $work resolved elsewhere ($made)"
# The build is staged in a fresh directory of its own: the library is chosen
# from this build's outputs only, never from whatever a reused --out holds.
final_out=$out
if [ "$src_only" != 1 ]; then
	out=$work/stage
	rm -rf "$out"
	mkdir -p "$out" "$cache"
fi
rm -rf "$work/src" "$work/git" "$work/toolchain"

# Fetch the commit and check it, then check the archive digest.
git init -q "$work/git"
git -C "$work/git" fetch -q --depth 1 "${pin[ELE_REPO]}" "${pin[ELE_COMMIT]}"
got=$(git -C "$work/git" rev-parse FETCH_HEAD)
[ "$got" = "${pin[ELE_COMMIT]}" ] || die "fetched commit $got, pinned ${pin[ELE_COMMIT]}"
got=$(git -C "$work/git" archive --format=tar "${pin[ELE_COMMIT]}" | sha256sum | cut -d' ' -f1)
[ "$got" = "${pin[ELE_ARCHIVE_SHA256]}" ] || {
	rm -rf "$work/git"
	die "archive SHA-256 $got, pinned ${pin[ELE_ARCHIVE_SHA256]}"
}
mkdir -p "$work/src"
git -C "$work/git" archive --format=tar "${pin[ELE_COMMIT]}" | tar -x -C "$work/src"
if [ "$src_only" = 1 ]; then
	rm -rf "$work/git"
	echo "ele-lib-build: source OK (${pin[ELE_COMMIT]}, archive SHA-256 ${pin[ELE_ARCHIVE_SHA256]}) in $work/src"
	exit 0
fi

# The pinned toolchain, checked before it is unpacked.
tarball=$cache/toolchain-${tc[TOOLCHAIN_VERSION]}.tar.xz
if ! { [ -f "$tarball" ] && [ "$(sha256sum "$tarball" | cut -d' ' -f1)" = "${tc[TOOLCHAIN_SHA256]}" ]; }; then
	curl -fsSL --retry 3 -o "$tarball.part" "${tc[TOOLCHAIN_URL]}"
	got=$(sha256sum "$tarball.part" | cut -d' ' -f1)
	[ "$got" = "${tc[TOOLCHAIN_SHA256]}" ] || {
		rm -f "$tarball.part"
		die "toolchain SHA-256 $got, pinned ${tc[TOOLCHAIN_SHA256]}"
	}
	mv "$tarball.part" "$tarball"
fi
mkdir -p "$work/toolchain"
tar -xJf "$tarball" -C "$work/toolchain" --strip-components=1

cross=$work/toolchain/bin/aarch64-none-linux-gnu-
[ -x "${cross}gcc" ] || die "${cross}gcc is not in the toolchain"

# The library part only (no tests, no tools: those need OpenSSL and mbedTLS
# for the target). The version header the Makefile writes is regenerated.
make -C "$work/src" -j"$(nproc)" PLAT="${pin[ELE_PLAT]}" CC="${cross}gcc" libs >"$work/build.log" 2>&1 ||
	{ tail -n 20 "$work/build.log" >&2; die "build failed, log $work/build.log"; }

n=0
for f in "$work"/src/*.so.*; do
	[ -f "$f" ] || continue
	cp -a "$f" "$out/"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || die "the build produced no shared library"
(cd "$out" && sha256sum -- *.so.* >SHA256SUMS)
for f in "$out"/*.so.*; do
	m=$("${cross}readelf" -h "$f" | while IFS= read -r l; do case $l in *Machine:*) echo "$l" ;; esac; done)
	case $m in *AArch64*) ;; *) die "$f is not aarch64: $m" ;; esac
done
# The client: first the constants check on the host compiler (a mismatch of a
# flag or return-code value against the library's headers fails the build),
# then the aarch64 client linked against the libele_hsm just built.
cdir=$root/secure-key-handling/client
inc=(-I"$work/src/include" -I"$work/src/include/hsm" -I"$work/src/include/common"
	-I"$work/src/include/she" -I"$work/src/include/crrm" -I"$work/src/include/prime"
	-I"$work/src/src/plat/${pin[ELE_PLAT]}/include" -I"$work/src/src/common/include"
	-I"$cdir" -DPSA_COMPLIANT)
cc -std=gnu11 -fsyntax-only "${inc[@]}" "$cdir/ele_hsm_consts_check.c" ||
	die "the library's flag or return-code values differ from the client's (ele_hsm_consts_check.c)"
hsmlib=
for f in "$out"/libele_hsm.so.*; do
	[ -f "$f" ] && { hsmlib=$(basename "$f"); break; }
done
[ -n "$hsmlib" ] || die "libele_hsm is not in $out"
"${cross}gcc" -std=gnu11 -O1 -Wall -Wextra -Werror -o "$out/ele_client" "${inc[@]}" \
	"$cdir/ele_client.c" "$cdir/ele_hsm_backend.c" "$cdir/ele_cli_args.c" "$cdir/ele_client_cli.c" \
	-L"$out" -l:"$hsmlib" -lpthread ||
	die "the client does not build or link against $hsmlib"
m=$("${cross}readelf" -h "$out/ele_client" | while IFS= read -r l; do case $l in *Machine:*) echo "$l" ;; esac; done)
case $m in *AArch64*) ;; *) die "ele_client is not aarch64: $m" ;; esac
needed=$("${cross}readelf" -d "$out/ele_client" | while IFS= read -r l; do case $l in *NEEDED*"[libele_hsm.so."*) echo "$l" ;; esac; done)
[ -n "$needed" ] || die "ele_client does not need libele_hsm (its soname)"
(cd "$out" && sha256sum -- *.so.* ele_client >SHA256SUMS)
[ ! -e "$final_out" ] || { [ -d "$final_out" ] && [ -z "$(ls -A -- "$final_out")" ]; } ||
	die "--out $final_out was filled while the build ran; nothing was published"
mkdir -p "$final_out"
cp -a "$out"/. "$final_out"/
echo "ele-lib-build: OK ($n libraries and ele_client in $final_out)"
