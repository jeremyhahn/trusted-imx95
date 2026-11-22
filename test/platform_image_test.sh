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

# The image recipes (provisional default, hardening-survey section 7).
img=$ROOT/platform-image/recipes-core/images/trusted-imx95-image.bb
dbg=$ROOT/platform-image/recipes-core/images/trusted-imx95-image-debug.bb
layer=$ROOT/platform-image/conf/layer.conf
banned='(debug-tweaks|allow-empty-password|allow-root-login|empty-root-password|package-management|tools-debug|bash|gdb|strace|imx-test)'

# matches FILE ERE: true when a line of FILE matches the ERE (whole word).
matches() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		[[ $l =~ (^|[^A-Za-z0-9_-])$2([^A-Za-z0-9_-]|$) ]] && return 0
	done <"$1"
	return 1
}
# noncomment FILE ERE: as matches, ignoring comment lines.
noncomment() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; esac
		[[ $l =~ (^|[^A-Za-z0-9_-])$2([^A-Za-z0-9_-]|$) ]] && return 0
	done <"$1"
	return 1
}

expect "production image exists" test -f "$img"
expect "production image requires core-image-minimal" noncomment "$img" 'require[[:space:]]+.*core-image-minimal'
! noncomment "$img" '(fsl-image-[a-z0-9-]*|imx-image-[a-z0-9-]*)' && r=0 || r=1
expect "production image requires no fsl-image-* or imx-image-*" test "$r" -eq 0
expect "production image has read-only-rootfs" noncomment "$img" 'IMAGE_FEATURES[[:space:]]*\+?=.*read-only-rootfs'
! matches "$img" "$banned" && r=0 || r=1
expect "production image names no banned feature or package" test "$r" -eq 0
expect "debug image exists" test -f "$dbg"
expect "debug image requires the production image" noncomment "$dbg" 'require[[:space:]]+trusted-imx95-image\.bb'
expect "debug image names the banned features and packages" noncomment "$dbg" "$banned"
expect "debug image says it never holds production keys" matches "$dbg" 'NEVER holds production keys'
only=1
for f in "$ROOT"/platform-image/conf/layer.conf "$ROOT"/platform-image/conf/distro/*.conf \
	"$ROOT"/platform-image/conf/*.template "$img"; do
	! matches "$f" "$banned" || only=0
done
expect "the debug image is the only file naming the banned features" test "$only" -eq 1
expect "layer.conf has the BBFILES line" noncomment "$layer" 'BBFILES[[:space:]]*\+=.*recipes-\*/\*/\*\.bb'

# No file of ours overrides Yocto's reproducible or SBOM defaults (reproducible-build-survey sections 3, 4).
ovr=0
for f in "$ROOT"/platform-image/conf/layer.conf "$ROOT"/platform-image/conf/distro/*.conf \
	"$ROOT"/platform-image/conf/*.template "$img" "$dbg"; do
	noncomment "$f" '(SOURCE_DATE_EPOCH|REPRODUCIBLE_TIMESTAMP_ROOTFS)' && ovr=1
	noncomment "$f" 'INHERIT_DISTRO[^#]*(:remove|-=)[^#]*create-spdx' && ovr=1
	noncomment "$f" 'INHERIT:remove[^#]*create-spdx' && ovr=1
done
expect "no platform-image file overrides the epoch, the rootfs timestamp or create-spdx" test "$ovr" -eq 0

# Every assignment is preceded by a comment citing a survey or saying MISSING.
assign_re='^[A-Za-z_][A-Za-z0-9_.:-]*[[:space:]]*[?:+.]*='
for f in "$img" "$dbg" "$distro"; do
	cited=0 uncited=0 prev=
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in
		'#'*)
			[[ $l == *survey* || $l == *MISSING* ]] && cited=1
			prev=c
			continue
			;;
		'' | require* | inherit*) cited=0 prev= ; continue ;;
		esac
		if [[ $l =~ $assign_re ]]; then
			{ [ "$prev" = c ] && [ "$cited" -eq 1 ]; } || uncited=$((uncited + 1))
		fi
		cited=0 prev=
	done <"$f"
	expect "every assignment in ${f##*/} cites a survey or MISSING" test "$uncited" -eq 0
done

# scripts/platform-image-fetch.sh against a local file:// stub, no network.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/src"
git -C "$tmp/src" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
	commit -q --allow-empty -m stub
good=$(git -C "$tmp/src" rev-parse HEAD)
mklock() { # commit file
	printf 'layer_stub_repo=file://%s/src\nlayer_stub_path=sources/stub\nlayer_stub_commit=%s\n' "$tmp" "$1" >"$2"
}
mklock "$good" "$tmp/good.lock"
mklock aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tmp/bad.lock"

rc=0
out=$("$ROOT/scripts/platform-image-fetch.sh" "$tmp/good.lock" "$tmp/out-good" 2>&1) || rc=$?
expect "fetch: a matching commit passes" test "$rc" -eq 0
expect "fetch: the layer is checked out at the pin" test "$(git -C "$tmp/out-good/sources/stub" rev-parse HEAD)" = "$good"
expect "fetch: it reports OK" test "${out##*OK*}" != "$out"

rc=0
out=$("$ROOT/scripts/platform-image-fetch.sh" "$tmp/bad.lock" "$tmp/out-bad" 2>&1) || rc=$?
expect "fetch: a differing commit fails" test "$rc" -ne 0
expect "fetch: the failure names the layer" test "${out##*layer stub*}" != "$out"

# The "checked out X, the lock pins Y" branch: the lock pins an annotated tag
# object, checkout peels it to the commit, so HEAD differs from the pin.
git -C "$tmp/src" -c user.name=t -c user.email=t@example.invalid -c tag.gpgsign=false \
	tag -a -m stub stub-tag "$good"
tagobj=$(git -C "$tmp/src" rev-parse stub-tag)
expect "stub tag object differs from its commit" test "$tagobj" != "$good"
mklock "$tagobj" "$tmp/tag.lock"
rc=0
out=$("$ROOT/scripts/platform-image-fetch.sh" "$tmp/tag.lock" "$tmp/out-tag" 2>&1) || rc=$?
expect "fetch: a tag object pin fails" test "$rc" -ne 0
expect "fetch: it says checked out <commit>, the lock pins <tag object>" \
	test "${out##*"checked out $good, the lock pins $tagobj"*}" != "$out"

rc=0
inside="$ROOT/.inside-clone.$$.$RANDOM" # an absent path; nothing is created or removed
[ ! -e "$inside" ] || { echo "FAIL: $inside exists" >&2; exit 1; }
out=$("$ROOT/scripts/platform-image-fetch.sh" "$tmp/good.lock" "$inside" 2>&1) || rc=$?
expect "fetch: a directory inside the clone is refused" test "$rc" -ne 0
expect "fetch: it says the directory is inside this clone" \
	test "${out##*"is inside this clone"*}" != "$out"
expect "fetch: the refused path was not created" test ! -e "$inside"

# A locally modified layer is refused on a re-fetch.
mkdir -p "$tmp/src/recipes"
printf 'A = "1"\n' >"$tmp/src/recipes/r.bb"
git -C "$tmp/src" add recipes/r.bb
git -C "$tmp/src" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
	commit -q -m recipe
rec=$(git -C "$tmp/src" rev-parse HEAD)
mklock "$rec" "$tmp/rec.lock"
tl="$tmp/out-dirty"
fetch_rc() { # prints the exit status of a fetch into the temp layer root
	local r=0
	"$ROOT/scripts/platform-image-fetch.sh" "$tmp/rec.lock" "$tl" >"$tmp/fetch.out" 2>&1 || r=$?
	echo "$r"
}
expect "fetch: first fetch of the recipe layer passes" test "$(fetch_rc)" -eq 0
expect "fetch: a clean re-fetch passes" test "$(fetch_rc)" -eq 0
layer="$tl/sources/stub"

printf 'A = "2"\n' >"$layer/recipes/r.bb"
expect "fetch: an unstaged edit to a tracked recipe fails" test "$(fetch_rc)" -ne 0
expect "fetch: the dirty failure names the layer" grep -q 'layer stub: .* is not clean' "$tmp/fetch.out"
git -C "$layer" add recipes/r.bb
expect "fetch: a staged edit to a tracked recipe fails" test "$(fetch_rc)" -ne 0
git -C "$layer" reset -q --hard
expect "fetch: a clean re-fetch passes after the edit is removed" test "$(fetch_rc)" -eq 0

printf 'x\n' >"$layer/recipes/extra.bbappend"
expect "fetch: an untracked .bbappend fails" test "$(fetch_rc)" -ne 0
rm -f "$layer/recipes/extra.bbappend"
expect "fetch: a clean re-fetch passes after the file is removed" test "$(fetch_rc)" -eq 0

printf '*.bbappend\n' >"$layer/.git/info/exclude"
printf 'x\n' >"$layer/ignored.bbappend"
expect "fetch: an ignored .bbappend fails" test "$(fetch_rc)" -ne 0

finish
