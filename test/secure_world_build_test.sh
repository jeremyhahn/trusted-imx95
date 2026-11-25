#!/usr/bin/env bash
# Unit tests of scripts/secure-world-build.sh: the committed lock file checks,
# a bad lock file or argument fails naming the fault, and the work directory
# rule holds. Offline: no source, toolchain or wheel is fetched; a stub curl
# fails the first fetch, after the work directory is set up.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sw=$ROOT/scripts/secure-world-build.sh
good=$ROOT/secure-world/bsp.lock

run bash "$sw" --help
check "help prints the usage" 0 "usage: secure-world-build.sh"

run bash "$sw" --check-lock
check "the committed bsp.lock checks" 0 "bsp.lock OK" "lf-6.18.37-2.1.0" "TF-A v2.15.0 da738d5eae93" "toolchain 15.2.rel1"

# Owner ruling 771 and docs/SPEC.md: TF-A is upstream Arm TF-A, not NXP's fork.
tfa_repo=$(sed -n 's/^TFA_REPO=//p' "$good")
case "$tfa_repo" in
https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git | https://github.com/ARM-software/arm-trusted-firmware.git)
	tfa_ok=0 ;;
*) tfa_ok=1 ;;
esac
expect "bsp.lock's TFA_REPO is upstream TF-A (ruling 771), not NXP's imx-atf: $tfa_repo" test "$tfa_ok" -eq 0

run bash "$sw" --frobnicate
check "an unknown argument fails" nonzero "unknown argument: --frobnicate"

run bash "$sw" --jobs 0 --check-lock
check "--jobs 0 fails" nonzero "--jobs must be a positive number"

run bash "$sw" --lock "$TMP_ROOT/absent.lock" --check-lock
check "a missing lock file fails" nonzero "no such lock file"

# lockcopy <name> <edit>: prints the path of a copy of the good lock with
# each line passed through the function <edit>, which changes one pin.
lockcopy() {
	local f=$TMP_ROOT/$1.lock line
	: >"$f"
	while IFS= read -r line || [ -n "$line" ]; do
		"$2" "$line" >>"$f"
	done <"$good"
	printf '%s\n' "$f"
}
edit_unread() { [[ "$1" == TFA_COMMIT=* ]] && echo TFA_COMMIT=UNREAD || printf '%s\n' "$1"; }
edit_short() { [[ "$1" == OPTEE_COMMIT=* ]] && echo OPTEE_COMMIT=99f40897 || printf '%s\n' "$1"; }
edit_digest() { [[ "$1" == TOOLCHAIN_SHA256=* ]] && echo TOOLCHAIN_SHA256=abc || printf '%s\n' "$1"; }
edit_url() { [[ "$1" == FTPM_REPO=* ]] && echo FTPM_REPO=http://example.org/x.git || printf '%s\n' "$1"; }
edit_chars() { [[ "$1" == TFA_PLAT=* ]] && echo 'TFA_PLAT=imx95;true' || printf '%s\n' "$1"; }
edit_unknown() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nEXTRA_FLAG=y\n' "$1" || printf '%s\n' "$1"; }
edit_twice() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\n%s\n' "$1" "$1" || printf '%s\n' "$1"; }
edit_missing() { [[ "$1" == MSTPM_COMMIT=* ]] || printf '%s\n' "$1"; }
edit_nowheel() { [[ "$1" == PYWHEEL=* ]] || printf '%s\n' "$1"; }
edit_badwheel() { [[ "$1" == PYWHEEL=cffi* ]] && echo PYWHEEL=cffi==2.1.1 || printf '%s\n' "$1"; }
edit_shape() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nnot a pin\n' "$1" || printf '%s\n' "$1"; }
# Owner ruling 771: the script itself refuses NXP's TF-A fork, a TF-A pin that
# is not a release tag, and an OP-TEE that is not NXP's BSP OP-TEE.
edit_imxatf() { [[ "$1" == TFA_REPO=* ]] && echo TFA_REPO=https://github.com/nxp-imx/imx-atf.git || printf '%s\n' "$1"; }
edit_rctag() { [[ "$1" == TFA_TAG=* ]] && echo TFA_TAG=v2.15.0-rc0 || printf '%s\n' "$1"; }
edit_branchtag() { [[ "$1" == TFA_TAG=* ]] && echo TFA_TAG=master || printf '%s\n' "$1"; }
edit_notag() { [[ "$1" == TFA_TAG=* ]] || printf '%s\n' "$1"; }
edit_upoptee() { [[ "$1" == OPTEE_REPO=* ]] && echo OPTEE_REPO=https://github.com/OP-TEE/optee_os.git || printf '%s\n' "$1"; }

for c in \
	"unread|is marked UNREAD" \
	"short|must be a 40-hex commit" \
	"digest|must be a 64-hex SHA-256" \
	"url|must be an https URL" \
	"chars|has characters outside" \
	"unknown|unknown name EXTRA_FLAG" \
	"twice|TFA_PLAT is set twice" \
	"missing|MSTPM_COMMIT is missing" \
	"nowheel|no PYWHEEL line" \
	"badwheel|PYWHEEL must be" \
	"shape|not NAME=value" \
	"imxatf|is not upstream Arm TF-A (owner ruling 771" \
	"rctag|TFA_TAG v2.15.0-rc0 is not an upstream release tag" \
	"branchtag|TFA_TAG master is not an upstream release tag" \
	"notag|TFA_TAG is missing" \
	"upoptee|is not NXP's BSP OP-TEE"; do
	name=${c%%|*} want=${c#*|}
	f=$(lockcopy "$name" "edit_$name")
	run bash "$sw" --lock "$f" --check-lock
	check "a lock with $name fails" nonzero "$want"
done

# The host and the work directory: stubs make the host look like x86_64
# Linux with every tool, and curl fail, so a run stops at the first fetch.
stubs=$TMP_ROOT/stubs
mkdir -p "$stubs"
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo "${STUB_ARCH:-x86_64}" ;; esac
EOF
cat >"$stubs/curl" <<'EOF'
#!/bin/sh
echo "curl: stub, offline" >&2
exit 7
EOF
for t in git make tar xz sha256sum uv; do
	command -v "$t" >/dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' >"$stubs/$t"
done
chmod +x "$stubs"/*
sp=$stubs:$PATH

w=$TMP_ROOT/w
mkdir -p "$w/work"
: >"$w/work/foreign"
run env PATH="$sp" bash "$sw" --work "$w/work" --out "$w/out" --cache "$w/cache"
check "a non-empty work directory not made by the script is refused" nonzero "is not empty and was not made by this script"
expect "the refused work directory keeps its file" test -f "$w/work/foreign"

: >"$w/afile"
run env PATH="$sp" bash "$sw" --work "$w/afile" --out "$w/out" --cache "$w/cache"
check "a work path that is a file is refused" nonzero "is not a directory"

run env PATH="$sp" STUB_ARCH=aarch64 bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a host other than x86_64 Linux is refused" nonzero "this host is Linux-aarch64"

run env PATH="$sp" bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a new work directory is made, then the offline fetch fails" nonzero "toolchain failed"
expect "the new work directory holds the marker" test -f "$w/new/.secure-world-build-work"

: >"$w/new/stale"
run env PATH="$sp" bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a work directory the script made is recreated" nonzero "toolchain failed"
expect "the recreated work directory lost its stale file" test ! -e "$w/new/stale"

# --- A whole offline build ----------------------------------------------------
# Full stubs: curl serves a fixture toolchain tarball, git "fetches" the pinned
# commit, uv makes a venv, and make writes the artefacts and logs its arguments.
# Nothing is fetched and no key is used.
fs=$TMP_ROOT/fullstubs
mkdir -p "$fs" "$TMP_ROOT/fix/tc/bin"
cp "$stubs/uname" "$fs/uname"
printf '#!/bin/sh\necho "aarch64-none-linux-gnu-gcc (stub) 15.2.rel1"\n' >"$TMP_ROOT/fix/tc/bin/aarch64-none-linux-gnu-gcc"
chmod +x "$TMP_ROOT/fix/tc/bin/aarch64-none-linux-gnu-gcc"
tar -C "$TMP_ROOT/fix" -cJf "$TMP_ROOT/fix/toolchain.tar.xz" tc
tcsum=$(sha256sum "$TMP_ROOT/fix/toolchain.tar.xz" | cut -d' ' -f1)

cat >"$fs/curl" <<'EOF'
#!/bin/bash
out=
while [ $# -gt 0 ]; do
	case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cp "$STUB_TARBALL" "$out"
EOF
cat >"$fs/git" <<'EOF'
#!/bin/bash
dir=
while [ $# -gt 0 ]; do
	case "$1" in -C) dir=$2; shift 2 ;; -c) shift 2 ;; *) break ;; esac
done
cmd=$1
shift
case "$cmd" in
init) mkdir -p "${!#}" ;;
fetch)
	# A tag fetch moves FETCH_HEAD to the tag's commit: the pinned one, or
	# another when STUB_TAG_MOVED is set.
	case "${!#}" in
	refs/tags/*) echo "${!#}" >"$dir/.stubtag"; [ -z "${STUB_TAG_MOVED:-}" ] || echo 1111111111111111111111111111111111111111 >"$dir/.stubhead" ;;
	*) echo "${!#}" >"$dir/.stubhead" ;;
	esac ;;
checkout) ;;
rev-parse)
	if [ "${STUB_GIT_BAD:-}" = "${dir##*/}" ]; then echo 0000000000000000000000000000000000000000; else cat "$dir/.stubhead"; fi ;;
log) echo 1788777083 ;;
esac
EOF
cat >"$fs/uv" <<'EOF'
#!/bin/bash
[ "$1" != venv ] || mkdir -p "${!#}/bin"
exit 0
EOF
cat >"$fs/make" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
dir= o= bb= plat= target=
while [ $# -gt 0 ]; do
	case "$1" in
	-C) dir=$2; shift 2; continue ;;
	O=*) o=${1#O=} ;;
	BUILD_BASE=*) bb=${1#BUILD_BASE=} ;;
	PLAT=*) plat=${1#PLAT=} ;;
	-j* | *=*) ;;
	*) target=$1 ;;
	esac
	shift
done
key=${dir##*/}
[ "$key" = optee ] && [ "$target" = ta_dev_kit ] && key=optee-devkit
[ "${STUB_MAKE_FAIL:-}" != "$key" ] || { echo "make: *** $key stub failure" >&2; exit 2; }
case "$key" in
tfa) mkdir -p "$bb/$plat/release" && echo bl31 >"$bb/$plat/release/bl31.bin" ;;
ftpm) mkdir -p "$o" && echo ta >"$o/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf" ;;
optee) mkdir -p "$o/core" && echo "tee${STUB_DIFF_TEE:+$([[ "$o" == */build-2/* ]] && echo -2)}" >"$o/core/tee-raw.bin" ;;
esac
EOF
cat >"$fs/cp" <<'EOF'
#!/bin/bash
/bin/cp "$@"
last=${!#}
if [ -n "${STUB_CORRUPT_CP:-}" ] && [[ "$last" == */stage/bl31.bin ]]; then echo corrupt >>"$last"; fi
EOF
chmod +x "$fs"/*
fp=$fs:$PATH

edit_tcsum() { [[ "$1" == TOOLCHAIN_SHA256=* ]] && echo "TOOLCHAIN_SHA256=$tcsum" || printf '%s\n' "$1"; }
edit_badtcsum() { [[ "$1" == TOOLCHAIN_SHA256=* ]] && echo "TOOLCHAIN_SHA256=$(printf '0%.0s' {1..64})" || printf '%s\n' "$1"; }
oklock=$(lockcopy oklock edit_tcsum)
badlock=$(lockcopy badtclock edit_badtcsum)

# fullrun <name> <lock> [VAR=value...]: one stubbed build in its own directories.
fullrun() {
	local n=$1 l=$2
	shift 2
	mkdir -p "$TMP_ROOT/$n"
	: >"$TMP_ROOT/$n/make.log"
	run env PATH="$fp" STUB_TARBALL="$TMP_ROOT/fix/toolchain.tar.xz" STUB_LOG="$TMP_ROOT/$n/make.log" PLATFORM_IMAGE_DIR="$TMP_ROOT/pi-none" "$@" \
		bash "$sw" --lock "$l" --work "$TMP_ROOT/$n/work" --out "$TMP_ROOT/$n/out" --cache "$TMP_ROOT/$n/cache"
}
nothing_published() { [ ! -e "$TMP_ROOT/$1/out/SHA256SUMS" ] && [ ! -e "$TMP_ROOT/$1/out/bl31.bin" ] && [ ! -e "$TMP_ROOT/$1/out/tee.bin" ]; }

fullrun ok "$oklock"
check "an offline build reaches publication" 0 "secure-world-build: OK" "bl31.bin" "tee.bin"
expect "the artefacts are published" test -s "$TMP_ROOT/ok/out/bl31.bin" -a -s "$TMP_ROOT/ok/out/tee.bin" -a -s "$TMP_ROOT/ok/out/build-info.txt"
sums_verify() { (cd "$1" && sha256sum -c --quiet SHA256SUMS); }
expect "the published SHA256SUMS verifies" sums_verify "$TMP_ROOT/ok/out"

mlog=$(<"$TMP_ROOT/ok/make.log")
optee_line=$(printf '%s\n' "$mlog" | while IFS= read -r l; do [[ "$l" == *"/optee "* && "$l" == *" all" ]] && echo "$l"; done || true)
ftpm_line=$(printf '%s\n' "$mlog" | while IFS= read -r l; do [[ "$l" == *"/ftpm "* ]] && echo "$l"; done || true)
devkit_line=$(printf '%s\n' "$mlog" | while IFS= read -r l; do [[ "$l" == *ta_dev_kit* ]] && echo "$l"; done || true)
has() { [[ "$1" == *"$2"* ]]; }
expect "OP-TEE rejects REE FS TAs" has "$optee_line" "CFG_REE_FS_TA=n"
expect "the dev kit build rejects REE FS TAs too" has "$devkit_line" "CFG_REE_FS_TA=n"
# every OP-TEE make invocation (dev kit and image) carries CFG_REE_FS_TA=n
all_optee_reject_reefs() {
	local l n=0
	while IFS= read -r l; do
		[[ "$l" == *"/optee "* ]] || continue
		n=$((n + 1))
		[[ "$l" == *" CFG_REE_FS_TA=n "* && "$l" != *CFG_REE_FS_TA=y* ]] || return 1
	done <<<"$1"
	[ "$n" -ge 2 ]
}
expect "every OP-TEE make call sets CFG_REE_FS_TA=n" all_optee_reject_reefs "$mlog"
# without REE FS TAs the secure storage TA management PTA does not link
all_optee_no_secstor_pta() {
	local l n=0
	while IFS= read -r l; do
		[[ "$l" == *"/optee "* ]] || continue
		n=$((n + 1))
		[[ "$l" == *" CFG_SECSTOR_TA_MGMT_PTA=n "* && "$l" != *CFG_SECSTOR_TA_MGMT_PTA=y* ]] || return 1
	done <<<"$1"
	[ "$n" -ge 2 ]
}
expect "every OP-TEE make call sets CFG_SECSTOR_TA_MGMT_PTA=n" all_optee_no_secstor_pta "$mlog"
expect "early TAs are on" has "$optee_line" "CFG_EARLY_TA=y"
expect "the fTPM TA is an early TA" has "$optee_line" "EARLY_TA_PATHS=$TMP_ROOT/ok/work/build-1/build/ftpm/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf"
expect "the PKCS#11 TA is an early TA" has "$optee_line" "CFG_IN_TREE_EARLY_TAS=pkcs11/fd02c9da-306c-48c7-a49c-bbd827ae86ee"
expect "the fTPM TA keeps its NV in REE FS storage" has "$ftpm_line" "CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE"
expect "PKCS#11 is built" has "$optee_line" "CFG_PKCS11_TA=y"

# The OP-TEE the boot container ships takes its NV storage from the selector
# the platform image uses (optee-ftpm-flags.inc, owner ruling 1234): for each
# value, the same OP-TEE flag set on the dev kit and OS builds, and the fTPM
# TA's storage ID from optee-ftpm_*.bb. A script that hard-codes one set, or
# ignores the selector, fails here.
nv_inc=$ROOT/platform-image/recipes-security/optee/optee-ftpm-flags.inc
nv_bb=$ROOT/platform-image/recipes-security/optee/optee-ftpm_4.10.0.bb
# flag_value <file> <name> <key>: the quoted value of `name[key] = "..."`.
flag_value() {
	local l
	while IFS= read -r l; do
		if [[ "$l" == "$2[$3] = \""*\" ]]; then
			l=${l#*\"}
			printf '%s\n' "${l%\"}"
			return 0
		fi
	done <"$1"
	return 1
}
# carries_set <make line> <flags>: every K=V of the set, and no other K=.
carries_set() {
	local w line=" $1 "
	[ -n "$2" ] || return 1
	for w in $2; do
		[[ "$line" == *" $w "* ]] || return 1
		[[ "${line//" $w "/ }" != *" ${w%%=*}="* ]] || return 1
	done
}
for nv in reefs rpmb; do
	nv_set=$(flag_value "$nv_inc" TRUSTED_IMX95_FTPM_NV_FLAGS "$nv" || true)
	nv_sid=$(flag_value "$nv_bb" FTPM_TA_STORAGE_ID "$nv" || true)
	expect "optee-ftpm-flags.inc has a $nv flag set" test -n "$nv_set"
	expect "optee-ftpm_4.10.0.bb has a $nv storage ID" test -n "$nv_sid"
	fullrun "nv-$nv" "$oklock" TRUSTED_IMX95_FTPM_NV="$nv"
	check "TRUSTED_IMX95_FTPM_NV=$nv builds and publishes" 0 "secure-world-build: OK"
	nv_log=$(<"$TMP_ROOT/nv-$nv/make.log")
	nv_os=$(printf '%s\n' "$nv_log" | while IFS= read -r l; do [[ "$l" == *"/optee "* && "$l" == *" all" ]] && echo "$l"; done | head -n 1 || true)
	nv_kit=$(printf '%s\n' "$nv_log" | while IFS= read -r l; do [[ "$l" == *ta_dev_kit* ]] && echo "$l"; done | head -n 1 || true)
	nv_ta=$(printf '%s\n' "$nv_log" | while IFS= read -r l; do [[ "$l" == *"/ftpm "* ]] && echo "$l"; done | head -n 1 || true)
	expect "$nv: OP-TEE OS carries the inc's flag set ($nv_set)" carries_set "$nv_os" "$nv_set"
	expect "$nv: the TA dev kit carries the inc's flag set" carries_set "$nv_kit" "$nv_set"
	expect "$nv: the fTPM TA's storage ID is the recipe's ($nv_sid)" has "$nv_ta" " CFG_FTPM_TA_TEE_STORAGE_ID=$nv_sid"
	expect "$nv: build-info.txt names the NV selection" has "$(<"$TMP_ROOT/nv-$nv/out/build-info.txt")" "ftpm-nv: $nv"
done
fullrun nv-bad "$oklock" TRUSTED_IMX95_FTPM_NV=emmc
check "an unknown TRUSTED_IMX95_FTPM_NV is refused" nonzero "TRUSTED_IMX95_FTPM_NV must be reefs or rpmb, not emmc"
expect "nothing is published for an unknown NV selection" nothing_published nv-bad

# One selection for both builds (owner ruling 1234): the image build's own
# configuration, the conf/*.conf of its build directory, selects the NV backend
# of this build when the environment does not, and a disagreement with the
# environment or between two files fails closed before anything is built.
pi=$TMP_ROOT/pi-conf
mkdir -p "$pi/build/conf"
for nv in reefs rpmb; do
	printf 'MACHINE = "x"\nTRUSTED_IMX95_FTPM_NV = "%s"\n' "$nv" >"$pi/build/conf/local.conf"
	fullrun "nvconf-$nv" "$oklock" PLATFORM_IMAGE_DIR="$pi"
	check "$nv in the image build's local.conf reaches this build" 0 "secure-world-build: OK"
	nvc_log=$(<"$TMP_ROOT/nvconf-$nv/make.log")
	nvc_set=$(flag_value "$nv_inc" TRUSTED_IMX95_FTPM_NV_FLAGS "$nv" || true)
	nvc_os=$(printf '%s\n' "$nvc_log" | while IFS= read -r l; do [[ "$l" == *"/optee "* && "$l" == *" all" ]] && echo "$l"; done | head -n 1 || true)
	expect "$nv in local.conf: OP-TEE OS carries the $nv flag set" carries_set "$nvc_os" "$nvc_set"
	expect "$nv in local.conf: build-info.txt names $nv" has "$(<"$TMP_ROOT/nvconf-$nv/out/build-info.txt")" "ftpm-nv: $nv"
	# the same value in the environment agrees
	fullrun "nvconf-env-$nv" "$oklock" PLATFORM_IMAGE_DIR="$pi" TRUSTED_IMX95_FTPM_NV="$nv"
	check "$nv in the environment and in local.conf agree" 0 "secure-world-build: OK"
done
printf 'TRUSTED_IMX95_FTPM_NV = "rpmb"\n' >"$pi/build/conf/local.conf"
fullrun nvconf-clash "$oklock" PLATFORM_IMAGE_DIR="$pi" TRUSTED_IMX95_FTPM_NV=reefs
check "reefs in the environment against rpmb in local.conf fails closed" nonzero "the fTPM NV backends disagree" "'reefs' in the environment" "'rpmb' in $pi/build/conf/local.conf"
expect "an environment/local.conf NV disagreement publishes nothing" nothing_published nvconf-clash
expect "an environment/local.conf NV disagreement builds nothing" test ! -s "$TMP_ROOT/nvconf-clash/make.log"
printf 'TRUSTED_IMX95_FTPM_NV = "reefs"\n' >"$pi/build/conf/auto.conf"
fullrun nvconf-two "$oklock" PLATFORM_IMAGE_DIR="$pi"
check "two conf files that select different backends fail closed" nonzero "the fTPM NV backends disagree" "make them equal"
expect "two disagreeing conf files publish nothing" nothing_published nvconf-two
rm -f "$pi/build/conf/auto.conf"

# BitBake's assignment semantics inside one conf file (Codex round 3, P1): a ?=
# applies only while nothing has set the value, = and := override, and the
# forms this script cannot resolve are refused. The build never picks a backend
# BitBake would not.
# nv_conf_case <name> <backend> <conf text>: the build runs and selects backend.
nv_conf_case() {
	printf '%b' "$3" >"$pi/build/conf/local.conf"
	fullrun "nvsem-$1" "$oklock" PLATFORM_IMAGE_DIR="$pi"
	check "conf semantics, $1: builds" 0 "secure-world-build: OK"
	expect "conf semantics, $1: the selection is $2" has "$(<"$TMP_ROOT/nvsem-$1/out/build-info.txt")" "ftpm-nv: $2"
}
# nv_conf_refused <name> <conf text>: the build is refused and builds nothing.
nv_conf_refused() {
	printf '%b' "$2" >"$pi/build/conf/local.conf"
	fullrun "nvsem-$1" "$oklock" PLATFORM_IMAGE_DIR="$pi"
	check "conf semantics, $1: refused" nonzero "refusing the line"
	expect "conf semantics, $1: nothing is published" nothing_published "nvsem-$1"
	expect "conf semantics, $1: nothing is built" test ! -s "$TMP_ROOT/nvsem-$1/make.log"
}
nv_conf_case eq-then-weak rpmb 'TRUSTED_IMX95_FTPM_NV = "rpmb"\nTRUSTED_IMX95_FTPM_NV ?= "reefs"\n'
nv_conf_case immediate-then-weak rpmb 'TRUSTED_IMX95_FTPM_NV := "rpmb"\nTRUSTED_IMX95_FTPM_NV ?= "reefs"\n'
nv_conf_case weak-then-eq rpmb 'TRUSTED_IMX95_FTPM_NV ?= "reefs"\nTRUSTED_IMX95_FTPM_NV = "rpmb"\n'
nv_conf_case weak-then-weak reefs 'TRUSTED_IMX95_FTPM_NV ?= "reefs"\nTRUSTED_IMX95_FTPM_NV ?= "rpmb"\n'
nv_conf_case eq-then-eq reefs 'TRUSTED_IMX95_FTPM_NV = "rpmb"\nTRUSTED_IMX95_FTPM_NV = "reefs"\n'
nv_conf_refused default-weak 'TRUSTED_IMX95_FTPM_NV ??= "reefs"\n'
nv_conf_refused eq-then-default-weak 'TRUSTED_IMX95_FTPM_NV = "rpmb"\nTRUSTED_IMX95_FTPM_NV ??= "reefs"\n'
nv_conf_refused default-weak-then-eq 'TRUSTED_IMX95_FTPM_NV ??= "reefs"\nTRUSTED_IMX95_FTPM_NV = "rpmb"\n'
nv_conf_refused append 'TRUSTED_IMX95_FTPM_NV = "rpmb"\nTRUSTED_IMX95_FTPM_NV:append = "x"\n'
nv_conf_refused single-quoted "TRUSTED_IMX95_FTPM_NV = 'reefs'\\n"
rm -f "$pi/build/conf/local.conf"

has_line() {
	local l
	while IFS= read -r l; do
		[[ "$l" == "$1"* ]] && return 0
	done <"$2"
	return 1
}
two_builds() { local n; n=$(printf '%s\n' "$mlog" | while IFS= read -r l; do [[ "$l" == *"/build-1/src/tfa "* || "$l" == *"/build-2/src/tfa "* ]] && echo x; done | wc -l); [ "$n" -eq 2 ]; }
expect "TF-A is built twice, once in each clean build directory" two_builds
expect "the reproducibility result is recorded" has_line 'reproducible: yes' "$TMP_ROOT/ok/out/build-info.txt"
expect "the work directory holds both clean builds" test -d "$TMP_ROOT/ok/work/build-1" -a -d "$TMP_ROOT/ok/work/build-2"
tag_fetched() { [ "$(<"$TMP_ROOT/ok/work/build-1/src/tfa/.stubtag")" = refs/tags/v2.15.0 ]; }
expect "the TF-A release tag is fetched from upstream and checked" tag_fetched
expect "build-info.txt records the TF-A tag" has_line "tfa: da738d5eae93af342fdc4995dd3c05acb4c9d757 tag v2.15.0 PLAT=imx95" "$TMP_ROOT/ok/out/build-info.txt"

# The release tag peels to another commit than TFA_COMMIT: the build stops.
fullrun tagmoved "$oklock" STUB_TAG_MOVED=1
check "a TF-A tag that does not peel to TFA_COMMIT stops the build" nonzero "tfa-tag failed" "tag v2.15.0 peels to 1111111111111111111111111111111111111111"
expect "a moved tag publishes nothing" nothing_published tagmoved

# A difference between the two builds: the second build's tee.bin differs.
fullrun differ "$oklock" STUB_DIFF_TEE=1
check "builds that differ fail naming the artefact and both hashes" nonzero "tee.bin differs: build 1" "build 2" "not reproducible"
expect "builds that differ publish nothing" nothing_published differ
bl31_same() { [ "$(sha256sum <"$TMP_ROOT/differ/work/out-1/bl31.bin")" = "$(sha256sum <"$TMP_ROOT/differ/work/out-2/bl31.bin")" ]; }
expect "the matching artefact is not blamed" bl31_same
no_bl31_blame() { [[ "$OUT" != *"bl31.bin differs"* ]]; }
expect "bl31.bin is not reported as differing" no_bl31_blame

fullrun baddigest "$badlock"
check "a wrong archive digest stops the build" nonzero "toolchain failed" "toolchain SHA-256"
expect "a wrong archive digest publishes nothing" nothing_published baddigest

fullrun badcommit "$oklock" STUB_GIT_BAD=optee
check "a fetched commit that is not the pin stops the build" nonzero "src-optee failed" "pinned"
expect "a wrong commit publishes nothing" nothing_published badcommit

fullrun buildfail "$oklock" STUB_MAKE_FAIL=optee
check "a build failure stops the build" nonzero "optee failed"
expect "a build failure publishes nothing" nothing_published buildfail

fullrun badhash "$oklock" STUB_CORRUPT_CP=1
check "a wrong artefact hash stops the build" nonzero "differs from the build output" "nothing published"
expect "a wrong artefact hash publishes nothing" nothing_published badhash

# --- build.md records the script's build configuration -------------------------
# The artefact hashes in docs/secure-world/build.md hold for one build
# configuration. build.md records the SHA-256 of that configuration: every
# non-comment, non-blank line of bsp.lock (all the source, toolchain and wheel
# pins), the uuid assignments, the optee_flags array and every make build step
# of the script (bl31, optee-devkit, ftpm and optee, with their flags and
# continuation lines), whitespace squeezed. This check recomputes it from the
# files, so a changed pin or flag cannot leave old hashes standing.
# The NV storage selection is part of it: the TRUSTED_IMX95_FTPM_NV lines of
# optee-ftpm-flags.inc and the FTPM_TA_STORAGE_ID lines of the fTPM recipe,
# which the script reads its OP-TEE storage flags and TA storage ID from.
# optee_config_digest [lock [script [inc [recipe]]]]: defaults to the committed files.
optee_config_digest() {
	local lk=${1:-$good} sc=${2:-$sw} inc=${3:-$nv_inc} bb=${4:-$nv_bb} l on=0 acc=
	while IFS= read -r l || [ -n "$l" ]; do
		[[ "$l" == TRUSTED_IMX95_FTPM_NV* ]] && acc+="${l//[[:space:]]/ }"$'\n'
	done <"$inc"
	while IFS= read -r l || [ -n "$l" ]; do
		[[ "$l" == "FTPM_TA_STORAGE_ID["* || "$l" == "TRUSTED_IMX95_FTPM_NV ?="* ]] && acc+="${l//[[:space:]]/ }"$'\n'
	done <"$bb"
	while IFS= read -r l || [ -n "$l" ]; do
		# TFA_TAG names TFA_COMMIT (checked at fetch) and reaches no build step.
		[[ -z "${l//[[:space:]]/}" || "$l" == \#* || "$l" == TFA_TAG=* ]] && continue
		acc+="$l"$'\n'
	done <"$lk"
	while IFS= read -r l; do
		if [[ "$l" == "optee_flags=("* ]]; then on=1; fi
		if [[ "$l" == "ftpm_uuid="* || "$l" == "pkcs11_uuid="* ]]; then acc+="$l"$'\n'; fi
		if [[ "$l" == "step "*" make "* ]]; then on=2; fi
		if [ "$on" != 0 ]; then
			l=${l//$'\t'/ }
			while [[ "$l" == *"  "* ]]; do l=${l//  / }; done
			acc+="$l"$'\n'
		fi
		if [ "$on" = 1 ] && [[ "$l" == ")" ]]; then on=0; fi
		if [ "$on" = 2 ] && [[ "$l" != *"\\" ]]; then on=0; fi
	done <"$sc"
	printf '%s' "$acc" | sha256sum | cut -d' ' -f1
}
recorded_config_digest() {
	local l
	while IFS= read -r l; do
		if [[ "$l" =~ ^Build\ configuration\ digest:\ \`([0-9a-f]{64})\`$ ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
			return 0
		fi
	done <"$ROOT/docs/secure-world/build.md"
	return 1
}
config_tied() { [ "$(recorded_config_digest)" = "$(optee_config_digest)" ]; }
expect "build.md records the digest of the lock file and the script's build steps" config_tied

# The guard fails when a pin the old digest left out, or an fTPM flag, changes.
edit_optee_pin() { [[ "$1" == OPTEE_COMMIT=* ]] && echo OPTEE_COMMIT=0123456789abcdef0123456789abcdef01234567 || printf '%s\n' "$1"; }
edit_ftpm_pin() { [[ "$1" == FTPM_COMMIT=* ]] && echo FTPM_COMMIT=0123456789abcdef0123456789abcdef01234567 || printf '%s\n' "$1"; }
edit_mstpm_pin() { [[ "$1" == MSTPM_COMMIT=* ]] && echo MSTPM_COMMIT=0123456789abcdef0123456789abcdef01234567 || printf '%s\n' "$1"; }
tied_with() { [ "$(recorded_config_digest)" = "$(optee_config_digest "$@")" ]; }
not_tied_with() { ! tied_with "$@"; }
for n in optee_pin ftpm_pin mstpm_pin; do
	lk=$(lockcopy "dg$n" "edit_$n")
	expect "a changed ${n%_pin} commit in the lock fails the digest guard" not_tied_with "$lk" "$sw"
done
lk=$(lockcopy dgtag edit_rctag)
expect "the TF-A tag line, which no build step reads, leaves the digest" tied_with "$lk" "$sw"
lk=$(lockcopy dgtfa edit_unread)
expect "a changed TF-A commit in the lock fails the digest guard" not_tied_with "$lk" "$sw"
# edited_copy <name> <file> <from> <to>: a copy of the file with from -> to.
edited_copy() {
	local l c=$TMP_ROOT/$1
	: >"$c"
	while IFS= read -r l || [ -n "$l" ]; do
		printf '%s\n' "${l//"$3"/"$4"}" >>"$c"
	done <"$2"
	cmp -s "$c" "$2" && return 1
	printf '%s\n' "$c"
}
ftpm_script=$(edited_copy ftpm-script.sh "$sw" CFG_PKCS11_TA=y CFG_PKCS11_TA=n)
expect "a changed OP-TEE flag in the script fails the digest guard" not_tied_with "$good" "$ftpm_script"
dg_inc=$(edited_copy flags.inc "$nv_inc" '[reefs] = "CFG_REE_FS=y CFG_RPMB_FS=n"' '[reefs] = "CFG_REE_FS=y CFG_RPMB_FS=y"')
expect "a changed NV flag set in optee-ftpm-flags.inc fails the digest guard" not_tied_with "$good" "$sw" "$dg_inc"
dg_bb=$(edited_copy ftpm.bb "$nv_bb" '[reefs] = "TEE_STORAGE_PRIVATE_REE"' '[reefs] = "TEE_STORAGE_PRIVATE_RPMB"')
expect "a changed fTPM storage ID in the recipe fails the digest guard" not_tied_with "$good" "$sw" "$nv_inc" "$dg_bb"

finish
