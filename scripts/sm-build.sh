#!/usr/bin/env bash
# sm-build.sh [--check] [lock]: build NXP's System Manager (m33_image.bin)
# from the pins in the lock (default system-manager/sm.lock), twice, each in
# its own clean tree, and fail unless both images are identical.
#
#   --check  validate the lock and stop (offline)
#
# Every input is pinned and checked: the imx-sm commit behind the tag, the
# board configuration file's SHA-256 (the upstream file, unchanged), and the
# Arm GNU Toolchain tarball's SHA-256. The image's build date and time are the
# commit's (SOURCE_DATE_EPOCH, and a `date` shim below), so they do not vary
# between builds.
#
# Output in SM_OUT (default out/system-manager, gitignored): m33_image.bin,
# SHA256SUMS and sm-manifest.txt (the pins and both builds' digests), with
# the downloads cached under cache/ for the next run. Run it in the
# devcontainer image with `make docker-run CMD='make system-manager'`, or in
# any Linux x86_64 environment with git, curl, tar, xz, make and perl
# (docs/system-manager-config/build.md).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
check_only=0
if [ "${1:-}" = --check ]; then
	check_only=1
	shift
fi
lock=${1:-$root/system-manager/sm.lock}
die() {
	echo "sm-build: $*" >&2
	exit 1
}
[ -f "$lock" ] || die "no lock file: $lock"

# Parse, never source: only the known keys, each once, each well formed.
keys="sm_repo sm_tag sm_commit sm_config sm_config_file sm_config_sha256 sm_patch_sha256 sm_patched_config_sha256 sm_monitor_mode toolchain_version toolchain_url toolchain_sha256"
declare -A pin=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
	n=$((n + 1))
	case $line in '' | '#'*) continue ;; esac
	[[ $line =~ ^([a-z0-9_]+)=(.+)$ ]] || die "$lock:$n: not key=value: $line"
	k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
	case " $keys " in *" $k "*) ;; *) die "$lock:$n: unknown key $k" ;; esac
	[ -z "${pin[$k]+set}" ] || die "$lock:$n: $k set twice"
	pin[$k]=$v
done <"$lock"
for k in $keys; do
	[ -n "${pin[$k]+set}" ] || die "$lock: $k is missing"
done
want() { [[ ${pin[$1]} =~ $2 ]] || die "$lock: $1 must be $3: ${pin[$1]}"; }
want sm_repo '^(https|file)://[^[:space:]]+$' "an https:// or file:// URL"
want toolchain_url '^(https|file)://[^[:space:]]+\.tar\.xz$' "an https:// or file:// URL of a .tar.xz"
want sm_tag '^[A-Za-z0-9._-]+$' "a tag name"
want sm_commit '^[0-9a-f]{40}$' "a full 40-hex commit"
want sm_config '^[A-Za-z0-9_-]+$' "a configuration name"
want sm_config_file '^configs/([a-z]+/)?[A-Za-z0-9_-]+\.cfg$' "a .cfg path under configs/"
want sm_config_sha256 '^[0-9a-f]{64}$' "a SHA-256"
want sm_patch_sha256 '^[0-9a-f]{64}$' "a SHA-256"
want sm_patched_config_sha256 '^[0-9a-f]{64}$' "a SHA-256"
want sm_monitor_mode '^[0-2]$' "0, 1 or 2"
want toolchain_version '^[0-9]+\.[0-9]+\.rel[0-9]+$' "an Arm GNU version such as 15.2.rel1"
want toolchain_sha256 '^[0-9a-f]{64}$' "a SHA-256"
[ "${pin[sm_config_file]##*/}" = "${pin[sm_config]}.cfg" ] ||
	die "$lock: sm_config_file ${pin[sm_config_file]} is not ${pin[sm_config]}.cfg"
if [ "$check_only" = 1 ]; then
	echo "sm-build: $lock OK (${pin[sm_tag]} ${pin[sm_commit]:0:12}, ${pin[sm_config]}, Arm GNU ${pin[toolchain_version]})"
	exit 0
fi

for t in git curl tar xz make perl sha256sum; do
	command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH"
done
out=${SM_OUT:-$root/out/system-manager}
jobs=${SM_JOBS:-$(nproc)}
mkdir -p "$out/cache"
out=$(cd "$out" && pwd -P)
start=$SECONDS
sha() { sha256sum "$1" | cut -d' ' -f1; }

# m7_clean <config>: the M7 LM's block of the (patched) configuration, from its
# "LM<n> ... name="M7"" line to the next LM line, holds no `test` key and no
# BRD_SM_CTRL_TEST* grant (the survey's production rule; the delta in
# system-manager/patches/0002). No M7 block is an error too.
m7_clean() {
	local l in=0 seen=0 bad=""
	while IFS= read -r l; do
		l=${l%%#*}
		if [[ $l =~ ^LM[0-9]+[[:space:]] ]]; then
			in=0
			if [[ $l == *'name="M7"'* ]]; then in=1; seen=1; fi
			continue
		fi
		[ "$in" = 1 ] || continue
		# The configuration tool refuses a file with no default test channel
		# ("missing default test channel"), so `test=default` stays.
		l=${l//test=default/}
		if [[ $l =~ (^|[[:space:],])test([=,[:space:]]|$) ]] || [[ $l == *BRD_SM_CTRL_TEST* ]]; then
			bad=$l
			break
		fi
	done <"$1"
	[ "$seen" = 1 ] || die "no M7 LM block in ${1##*/}"
	[ -z "$bad" ] || die "the M7 LM block of ${1##*/} still holds a test grant: $bad"
}

# The repository's patches of the configuration, in name order: their
# concatenation must match the lock before anything is downloaded.
patches_dir=$(cd "$(dirname "$lock")" && pwd -P)/patches
patches=("$patches_dir"/*.patch)
[ -f "${patches[0]}" ] || die "no patch in $patches_dir"
got=$(cat "${patches[@]}" | sha256sum | cut -d' ' -f1)
[ "$got" = "${pin[sm_patch_sha256]}" ] ||
	die "patches SHA-256 is $got, the lock pins ${pin[sm_patch_sha256]}"

# The toolchain: downloaded once, checked on every run, extracted fresh.
tarball="$out/cache/${pin[toolchain_url]##*/}"
if ! [ -f "$tarball" ] || [ "$(sha "$tarball")" != "${pin[toolchain_sha256]}" ]; then
	echo "sm-build: fetching ${pin[toolchain_url]}"
	curl -fsSL --retry 3 -o "$tarball.part" "${pin[toolchain_url]}"
	got=$(sha "$tarball.part")
	[ "$got" = "${pin[toolchain_sha256]}" ] ||
		{ rm -f "$tarball.part"; die "toolchain SHA-256 is $got, the lock pins ${pin[toolchain_sha256]}"; }
	mv "$tarball.part" "$tarball"
fi
rm -rf "$out/toolchain"
mkdir -p "$out/toolchain"
tar -C "$out/toolchain" -xJf "$tarball"
gccs=("$out"/toolchain/*/bin/arm-none-eabi-gcc)
[ -x "${gccs[0]}" ] || die "no bin/arm-none-eabi-gcc in ${tarball##*/}"
cross=${gccs[0]%gcc}

# The source: the tag fetched once into a bare cache, which must name the
# pinned commit.
src="$out/cache/imx-sm.git"
tag_ref="refs/tags/${pin[sm_tag]}"
if ! git -C "$src" rev-parse -q --verify "$tag_ref^{commit}" >/dev/null 2>&1; then
	echo "sm-build: fetching ${pin[sm_repo]} ${pin[sm_tag]}"
	rm -rf "$src"
	git init -q --bare "$src"
	git -C "$src" fetch -q --depth 1 "${pin[sm_repo]}" "+$tag_ref:$tag_ref"
fi
got=$(git -C "$src" rev-parse "$tag_ref^{commit}")
[ "$got" = "${pin[sm_commit]}" ] || die "${pin[sm_tag]} is commit $got, the lock pins ${pin[sm_commit]}"
epoch=$(git -C "$src" log -1 --format=%ct "${pin[sm_commit]}")

# imx-sm's sm/makefiles/build_info.mak stamps the image with `date +FORMAT`,
# which ignores SOURCE_DATE_EPOCH. A `date` first on PATH answers any
# `date +FORMAT` with the commit's time in UTC and passes every other call
# to the real one; NXP's makefiles stay unchanged.
real_date=$(command -v date)
mkdir -p "$out/shim"
# shellcheck disable=SC2016 # expands in the shim, not here
printf '%s\n' '#!/bin/sh' \
	'# scripts/sm-build.sh: `date +FORMAT` at SOURCE_DATE_EPOCH, in UTC.' \
	'case "$#:$1" in 1:+*) exec '"$real_date"' -u -d "@$SOURCE_DATE_EPOCH" "$1" ;; esac' \
	'exec '"$real_date"' "$@"' >"$out/shim/date"
chmod +x "$out/shim/date"

# build <n>: a clean checkout in tree-<n>, `make cfg` and `make all` as
# meta-imx's recipe runs them; prints the image's SHA-256.
build() {
	local tree="$out/tree-$1" log="$out/build-$1.log" img
	rm -rf "$tree"
	git -c advice.detachedHead=false clone -q --no-checkout "$src" "$tree"
	git -C "$tree" checkout -q --detach "${pin[sm_commit]}"
	got=$(sha "$tree/${pin[sm_config_file]}")
	[ "$got" = "${pin[sm_config_sha256]}" ] ||
		die "${pin[sm_config_file]} SHA-256 is $got, the lock pins ${pin[sm_config_sha256]}"
	local p
	for p in "${patches[@]}"; do
		git -C "$tree" apply "$p" || die "patch ${p##*/} does not apply to ${pin[sm_config_file]}"
	done
	got=$(sha "$tree/${pin[sm_config_file]}")
	[ "$got" = "${pin[sm_patched_config_sha256]}" ] ||
		die "patched ${pin[sm_config_file]} SHA-256 is $got, the lock pins ${pin[sm_patched_config_sha256]}"
	m7_clean "$tree/${pin[sm_config_file]}"
	"$root/scripts/sm-grants-check.sh" "$tree/${pin[sm_config_file]}" "$patches_dir/../m7-grants.txt" >&2 ||
		die "the M7 LM's grants differ from system-manager/m7-grants.txt"
	if ! (cd "$tree" && export SOURCE_DATE_EPOCH="$epoch" SM_CROSS_COMPILE="$cross" PATH="$out/shim:$PATH" &&
		make config="${pin[sm_config]}" cfg &&
		make -j"$jobs" config="${pin[sm_config]}" M="${pin[sm_monitor_mode]}" all) >"$log" 2>&1; then
		tail -n 20 "$log" >&2
		die "build $1 failed; log: $log"
	fi
	img="$tree/build/${pin[sm_config]}/m33_image.bin"
	[ -f "$img" ] || die "build $1 made no ${img#"$tree"/}; log: $log"
	sha "$img"
}

h1=$(build 1)
echo "sm-build: build 1 m33_image.bin $h1"
h2=$(build 2)
echo "sm-build: build 2 m33_image.bin $h2"
reproducible=yes
[ "$h1" = "$h2" ] || reproducible=no

cp "$out/tree-1/build/${pin[sm_config]}/m33_image.bin" "$out/m33_image.bin"
(cd "$out" && sha256sum m33_image.bin >SHA256SUMS)
{
	for k in $keys; do echo "$k=${pin[$k]}"; done
	echo "source_date_epoch=$epoch"
	echo "build1_sha256=$h1"
	echo "build2_sha256=$h2"
	echo "reproducible=$reproducible"
} >"$out/sm-manifest.txt"
echo "sm-build: manifest $out/sm-manifest.txt ($((SECONDS - start)) s)"
[ "$reproducible" = yes ] || die "not reproducible: build 1 $h1, build 2 $h2"
echo "sm-build: reproducible, m33_image.bin $h1"
