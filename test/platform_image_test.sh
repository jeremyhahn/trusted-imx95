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
	if [[ $k =~ ^layer_(.+)_(repo|path|commit)$ ]]; then
		for f in repo path commit; do
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

signs=0 derives=0 fslreq=0 obsolete=0
while IFS= read -r line; do
	case $line in
	'#'*) ;;
	require*conf/distro/poky.conf) derives=1 ;;
	require*fsl-imx-*) fslreq=1 ;;
	*DISTRO_FEATURES_DEFAULT:* | *DISTRO_FEATURES_DEFAULT[\ =]* | *DISTRO_FEATURES_BACKFILL_CONSIDERED*) obsolete=1 ;;
	*[Ss][Ii][Gg][Nn]* | *[Cc][Ss][Tt]* | *spsdk* | *SPSDK* | *ahab* | *AHAB* | *fuse* | *rpmb*) signs=1 ;;
	esac
done <"$distro"
expect "distro requires poky's conf/distro/poky.conf" test "$derives" -eq 1
expect "distro does not require an fsl-imx-* distro (the release's fsl-imx-fb-minimal.conf sets the obsolete DISTRO_FEATURES_DEFAULT)" test "$fslreq" -eq 0
expect "distro sets neither DISTRO_FEATURES_DEFAULT nor DISTRO_FEATURES_BACKFILL_CONSIDERED (obsolete on wrynose)" test "$obsolete" -eq 0
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

# Root-login relaxations are in no image recipe, conf or template (comments aside).
# login_clean DIR: true when no non-comment line under DIR names one.
login_clean() {
	local f
	while IFS= read -r f; do
		noncomment "$f" '(debug-tweaks|empty-root-password|allow-empty-password|allow-root-login)' && return 1
	done <<EOF
$(find "$1" -type f)
EOF
	return 0
}
expect "no platform-image file relaxes root login" login_clean "$ROOT/platform-image"
expect "the debug image does not enable debug-tweaks" test "$(noncomment "$dbg" 'debug-tweaks' && echo yes || echo no)" = no
nt=$(mktemp -d)
trap 'rm -rf "$nt"' EXIT
cp -R "$ROOT/platform-image" "$nt/pi"
printf 'IMAGE_FEATURES += "debug-tweaks"\n' >>"$nt/pi/recipes-core/images/trusted-imx95-image-debug.bb"
expect "negative: debug-tweaks in the debug image is caught" test "$(login_clean "$nt/pi" && echo clean || echo caught)" = caught
rm -rf "$nt/pi"
cp -R "$ROOT/platform-image" "$nt/pi"
printf 'EXTRA_IMAGE_FEATURES += "empty-root-password"\n' >>"$nt/pi/conf/local.conf.template"
expect "negative: empty-root-password in a template is caught" test "$(login_clean "$nt/pi" && echo clean || echo caught)" = caught
rm -rf "$nt/pi"

# The templates agree with the lock and the distro (POSIX sed on the copies).
localt=$ROOT/platform-image/conf/local.conf.template
bblt=$ROOT/platform-image/conf/bblayers.conf.template
# conf_val FILE KEY: the quoted value BitBake gives KEY after the whole file:
# the last `=` or `:=` wins; else the first `?=` (a later `?=` finds it set);
# else the first `??=` (the weakest). Fails when KEY is never assigned.
conf_val() {
	local l strong='' soft='' weak='' hs=0 hf=0 hw=0 op v
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; esac
		if [[ $l =~ ^$2[[:space:]]*(\?\?=|\?=|:=|=)[[:space:]]*\"([^\"]*)\" ]]; then
			op=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
			case $op in
			'=' | ':=') strong=$v hs=1 ;;
			'?=') [ "$hf" -eq 1 ] || { soft=$v hf=1; } ;;
			'??=') [ "$hw" -eq 1 ] || { weak=$v hw=1; } ;;
			esac
		fi
	done <"$1"
	if [ "$hs" -eq 1 ]; then printf '%s\n' "$strong"
	elif [ "$hf" -eq 1 ]; then printf '%s\n' "$soft"
	elif [ "$hw" -eq 1 ]; then printf '%s\n' "$weak"
	else return 1; fi
}
# check_local LOCAL DISTRODIR: MACHINE is the lock's, DISTRO names an existing distro conf.
check_local() {
	local m d
	m=$(conf_val "$1" MACHINE) || return 1
	[ -n "$machine" ] && [ "$m" = "$machine" ] || return 1
	d=$(conf_val "$1" DISTRO) || return 1
	[ -n "$d" ] && [ -f "$2/$d.conf" ]
}
# The layers the image lists, as full paths under the fetch directory. Each is
# a pinned path or lies inside one.
expected_layers=' sources/openembedded-core/meta sources/meta-openembedded/meta-oe sources/meta-openembedded/meta-python sources/meta-openembedded/meta-perl sources/meta-openembedded/meta-multimedia sources/meta-openembedded/meta-networking sources/meta-openembedded/meta-filesystems sources/meta-yocto/meta-poky sources/meta-arm/meta-arm sources/meta-arm/meta-arm-toolchain sources/meta-freescale sources/meta-freescale-3rdparty sources/meta-freescale-distro sources/meta-imx/meta-imx-bsp sources/meta-imx/meta-imx-sdk '
# Pinned paths that are not listed in BBLAYERS, and why:
#   sources/bitbake                 not a layer: the BitBake tool itself
#   sources/base                    not a layer: fsl-community-bsp-base, the setup scripts
#   sources/meta-clang, meta-freescale-ml, meta-qt6, meta-browser, meta-security,
#   meta-timesys, meta-virtualization, meta-nxp-connectivity, meta-nxp-demo-experience
#                                   optional, not in LAYERDEPENDS of meta-imx-bsp/meta-imx-sdk
#                                   (a claim from the manifest's layer set, NOT checked
#                                   against the pinned conf/layer.conf files: no fetched
#                                   copy is available offline)
# sources/meta-yocto is not exempt: its meta-poky sublayer is listed.
notlisted=' sources/bitbake sources/base sources/meta-clang sources/meta-freescale-ml sources/meta-qt6 sources/meta-browser sources/meta-security sources/meta-timesys sources/meta-virtualization sources/meta-nxp-connectivity sources/meta-nxp-demo-experience '
# check_layers BBLAYERS: the listed set is exactly expected_layers (full paths),
# each inside a pinned path; every pinned path is the root of a listed layer or
# exempt; the repo's platform-image layer is listed.
check_layers() {
	local l p q k listed=' ' pinned=' ' repo=0 ok
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; esac
		if [[ $l =~ \#\#FETCH_DIR\#\#/(sources/[A-Za-z0-9._/-]+) ]]; then
			p=${BASH_REMATCH[1]}
			listed="$listed${p%/} "
		fi
		[[ $l =~ ^[[:space:]]*\#\#REPO_DIR\#\#/platform-image[[:space:]]*\\?$ ]] && repo=1
	done <"$1"
	[ "$repo" -eq 1 ] || return 1
	[ "$listed" != ' ' ] || return 1
	for k in "${!seen[@]}"; do
		[[ $k =~ ^layer_.+_path$ ]] && pinned="$pinned${seen[$k]} "
	done
	for p in $listed; do
		case $expected_layers in *" $p "*) ;; *) return 1 ;; esac
		ok=0
		for q in $pinned; do
			case $p in "$q" | "$q"/*) ok=1 ;; esac
		done
		[ "$ok" -eq 1 ] || return 1
	done
	for p in $expected_layers; do
		case $listed in *" $p "*) ;; *) return 1 ;; esac
	done
	for q in $pinned; do
		case $notlisted in *" $q "*) continue ;; esac
		ok=0
		for p in $listed; do
			case $p in "$q" | "$q"/*) ok=1 ;; esac
		done
		[ "$ok" -eq 1 ] || return 1
	done
	return 0
}
# check_distro FILE: keeps its base require/include and the last effective
# INIT_MANAGER is systemd.
check_distro() {
	local l base=0
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in
		'#'*) continue ;;
		require[[:space:]]* | include[[:space:]]*) base=1 ;;
		esac
	done <"$1"
	[ "$base" -eq 1 ] && [ "$(conf_val "$1" INIT_MANAGER || true)" = systemd ]
}
# check_target RECIPEDIR NAME FILE...: the recipe exists and every FILE names it.
check_target() {
	local d=$1 t=$2 f
	shift 2
	[ -f "$d/$t.bb" ] || return 1
	for f in "$@"; do matches "$f" "$t" || return 1; done
}
# neg DESC CMD...: the check must fail.
neg() {
	local d=$1 r=0
	shift
	"$@" && r=1
	expect "negative: $d" test "$r" -eq 0
}
export LC_ALL=C
expect "local.conf.template MACHINE is the lock's machine" check_local "$localt" "$ROOT/platform-image/conf/distro"
sed 's/^MACHINE = .*/MACHINE = "other-machine"/' "$localt" >"$nt/local.machine"
neg "a changed MACHINE is caught" check_local "$nt/local.machine" "$ROOT/platform-image/conf/distro"
sed 's/^DISTRO = .*/DISTRO = "no-such-distro"/' "$localt" >"$nt/local.distro"
neg "a DISTRO with no conf file is caught" check_local "$nt/local.distro" "$ROOT/platform-image/conf/distro"
expect "bblayers.conf.template lists the pinned layers and only those" check_layers "$bblt"
sed '/sources\/meta-freescale-distro/d' "$bblt" >"$nt/bbl.removed"
neg "a removed layer entry is caught" check_layers "$nt/bbl.removed"
sed 's|^\(  ##FETCH_DIR##/sources/meta-arm/meta-arm \\\)$|\1\
  ##FETCH_DIR##/sources/meta-unpinned \\|' "$bblt" >"$nt/bbl.extra"
neg "an unpinned layer entry is caught" check_layers "$nt/bbl.extra"
sed '/sources\/meta-imx\/meta-imx-sdk/d' "$bblt" >"$nt/bbl.nosdk"
neg "a removed meta-imx-sdk entry is caught while meta-imx-bsp stays" check_layers "$nt/bbl.nosdk"
sed '/sources\/meta-yocto\/meta-poky/d' "$bblt" >"$nt/bbl.nopoky"
neg "a removed meta-poky entry is caught" check_layers "$nt/bbl.nopoky"
sed '/##REPO_DIR##\/platform-image/d' "$bblt" >"$nt/bbl.norepo"
neg "a removed ##REPO_DIR##/platform-image entry is caught" check_layers "$nt/bbl.norepo"
sed 's|##FETCH_DIR##/sources/meta-imx/meta-imx-sdk|##FETCH_DIR##/sources/meta-imx/meta-other|' "$bblt" >"$nt/bbl.other"
neg "a sibling path under a pinned layer is caught" check_layers "$nt/bbl.other"
# BitBake semantics: a later assignment wins over an earlier one.
conf_val_is() { [ "$(conf_val "$1" "$2" || echo none)" = "$3" ]; }
cp "$localt" "$nt/local.append.machine"
printf 'MACHINE = "other"\n' >>"$nt/local.append.machine"
neg "an appended MACHINE = other is caught" check_local "$nt/local.append.machine" "$ROOT/platform-image/conf/distro"
cp "$localt" "$nt/local.append.distro"
printf 'DISTRO = "other"\n' >>"$nt/local.append.distro"
neg "an appended DISTRO = other is caught" check_local "$nt/local.append.distro" "$ROOT/platform-image/conf/distro"
cp "$distro" "$nt/distro.append.init"
printf 'INIT_MANAGER = "sysvinit"\n' >>"$nt/distro.append.init"
neg "an appended INIT_MANAGER = sysvinit is caught" check_distro "$nt/distro.append.init"
printf 'A = "1"\nA ?= "2"\nA = "3"\nB ??= "w"\nB ?= "s"\nC ??= "w"\nC = "x"\nD = "1"\nD := "2"\n' >"$nt/sem.conf"
expect "conf_val: a later = wins over an earlier one" conf_val_is "$nt/sem.conf" A 3
expect "conf_val: ?= beats ??= whatever the order" conf_val_is "$nt/sem.conf" B s
expect "conf_val: = beats ??=" conf_val_is "$nt/sem.conf" C x
expect "conf_val: a later := wins over =" conf_val_is "$nt/sem.conf" D 2
printf 'M = "1"\nM ?= "2"\n' >"$nt/sem2.conf"
expect "conf_val: a later ?= does not override a set value" conf_val_is "$nt/sem2.conf" M 1
expect "the distro keeps its base require and selects systemd" check_distro "$distro"
sed '/^require /d' "$distro" >"$nt/distro.norequire"
neg "a dropped require is caught" check_distro "$nt/distro.norequire"
sed '/^INIT_MANAGER/d' "$distro" >"$nt/distro.nosystemd"
neg "a dropped INIT_MANAGER is caught" check_distro "$nt/distro.nosystemd"
imgdir=$ROOT/platform-image/recipes-core/images
for t in trusted-imx95-image trusted-imx95-image-debug; do
	expect "image target $t is a recipe named by the Makefile and the docs" \
		check_target "$imgdir" "$t" "$ROOT/Makefile" "$ROOT/docs/platform-image/build.md"
	sed "s/$t/$t-renamed/g" "$ROOT/Makefile" >"$nt/Makefile.renamed"
	neg "a Makefile naming $t differently is caught" check_target "$imgdir" "$t" "$nt/Makefile.renamed"
done

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
trap 'rm -rf "$tmp" "$nt"' EXIT
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

# Incomplete layer records: a good layer plus one broken one, so the old
# commit-keyed discovery (which skipped the broken one) would still pass.
goodc=$(git -C "$tmp/src" rev-parse HEAD)
incomplete_rc() { # lock-body; prints the exit status, output in $tmp/inc.out
	local r=0
	rm -rf "$tmp/inc-out"
	{
		printf 'layer_stub_repo=file://%s/src\nlayer_stub_path=sources/stub\nlayer_stub_commit=%s\n' "$tmp" "$goodc"
		printf '%s\n' "$1"
	} >"$tmp/inc.lock"
	"$ROOT/scripts/platform-image-fetch.sh" "$tmp/inc.lock" "$tmp/inc-out" >"$tmp/inc.out" 2>&1 || r=$?
	echo "$r"
}
rr='layer_other_repo=file:///nonexistent'
pp='layer_other_path=sources/other'
cc='layer_other_commit=0000000000000000000000000000000000000001'
expect "fetch: a layer with repo and path but no commit fails" test "$(incomplete_rc "$rr"$'\n'"$pp")" -ne 0
expect "fetch: the missing-commit failure names the layer and key" grep -q 'layer other: no commit (layer_other_commit)' "$tmp/inc.out"
expect "fetch: a misspelled _commt key fails" test "$(incomplete_rc "$rr"$'\n'"$pp"$'\n'layer_other_commt=0000000000000000000000000000000000000001)" -ne 0
expect "fetch: the misspelled key failure names the missing commit" grep -q 'layer other: no commit' "$tmp/inc.out"
expect "fetch: a layer with repo and commit but no path fails" test "$(incomplete_rc "$rr"$'\n'"$cc")" -ne 0
expect "fetch: the missing-path failure names the layer and key" grep -q 'layer other: no path (layer_other_path)' "$tmp/inc.out"
expect "fetch: a missing path is refused before any layer is fetched" test ! -e "$tmp/inc-out/sources/stub"

# Two pins: pin B starts tracking a path that holds an ignored local file under
# pin A. The fetch of B must be refused and the file must survive byte for byte.
git init -q "$tmp/src2"
gc2() { git -C "$tmp/src2" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
printf 'secret.txt\n' >"$tmp/src2/.gitignore"
git -C "$tmp/src2" add .gitignore
gc2 commit -q -m pinA
pa=$(git -C "$tmp/src2" rev-parse HEAD)
printf 'tracked by B\n' >"$tmp/src2/secret.txt"
git -C "$tmp/src2" add -f secret.txt
gc2 commit -q -m pinB
pb=$(git -C "$tmp/src2" rev-parse HEAD)
lockpin() { printf 'layer_stub_repo=file://%s/src2\nlayer_stub_path=sources/stub\nlayer_stub_commit=%s\n' "$tmp" "$1" >"$2"; }
lockpin "$pa" "$tmp/pa.lock"
lockpin "$pb" "$tmp/pb.lock"
t2=$tmp/out-two
rc=0
"$ROOT/scripts/platform-image-fetch.sh" "$tmp/pa.lock" "$t2" >"$tmp/two.out" 2>&1 || rc=$?
expect "fetch: pin A passes" test "$rc" -eq 0
printf 'local secret\n' >"$t2/sources/stub/secret.txt"
printf 'local secret\n' >"$tmp/secret.want"
rc=0
"$ROOT/scripts/platform-image-fetch.sh" "$tmp/pb.lock" "$t2" >"$tmp/two.out" 2>&1 || rc=$?
expect "fetch: pin B over an ignored file it tracks is refused" test "$rc" -ne 0
expect "fetch: the ignored file survives byte for byte" cmp -s "$tmp/secret.want" "$t2/sources/stub/secret.txt"
expect "fetch: the layer is still at pin A" test "$(git -C "$t2/sources/stub" rev-parse HEAD)" = "$pa"

finish
