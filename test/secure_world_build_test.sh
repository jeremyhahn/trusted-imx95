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
check "the committed bsp.lock checks" 0 "bsp.lock OK" "lf-6.18.37-2.1.0" "TF-A lf-6.18.37-2.1.0 af9eb2c1748e" "toolchain 15.2.rel1"

# Owner ruling 1234 and docs/SPEC.md: BL31 is NXP's imx-atf, which counts as upstream TF-A.
tfa_repo=$(sed -n 's/^TFA_REPO=//p' "$good")
case "$tfa_repo" in
https://github.com/nxp-imx/imx-atf.git)
	tfa_ok=0 ;;
*) tfa_ok=1 ;;
esac
expect "bsp.lock's TFA_REPO is NXP's imx-atf (ruling 1234): $tfa_repo" test "$tfa_ok" -eq 0

# The documents follow ruling 1234: no tag of upstream Arm TF-A pins BL31, and the
# release criterion names imx-atf and the ruling.
file_has() { local l; while IFS= read -r l || [ -n "$l" ]; do [[ "$l" == *$2* ]] && return 0; done <"$1"; return 1; }
file_lacks() { ! file_has "$@"; }
criterion_ok() { # <file>: the BL31 release criterion line names imx-atf and ruling 1234
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		[[ "$l" == "- BL31 is pinned"* && "$l" == *imx-atf* && "$l" == *"ruling 1234"* && "$l" != *"tagged upstream"* ]] && return 0
	done <"$1"
	return 1
}
expect "docs/SPEC.md has no 'tagged upstream Arm TF-A' text" file_lacks "$ROOT/docs/SPEC.md" "tagged upstream Arm TF-A"
expect "docs/SPEC.md's BL31 release criterion names imx-atf and ruling 1234" criterion_ok "$ROOT/docs/SPEC.md"
expect "docs/secure-world/architecture.md has no 'tagged upstream release'" file_lacks "$ROOT/docs/secure-world/architecture.md" "tagged upstream release"
expect "ROADMAP.md has no 'tagged upstream release'" file_lacks "$ROOT/ROADMAP.md" "tagged upstream release"
planted=$TMP_ROOT/planted-spec.md
printf '%s\n' '- BL31 is pinned to a tagged upstream Arm TF-A release (owner ruling 771), imx-atf ruling 1234.' >"$planted"
expect "a planted 'tagged upstream Arm TF-A' criterion is flagged by the wording check" file_has "$planted" "tagged upstream Arm TF-A"
criterion_flagged() { ! criterion_ok "$1"; }
expect "a planted 'tagged upstream' criterion fails the criterion check" criterion_flagged "$planted"

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
edit_branch() { [[ "$1" == TFA_COMMIT=* ]] && echo TFA_COMMIT=lf_v2.14 || printf '%s\n' "$1"; }
edit_short() { [[ "$1" == OPTEE_COMMIT=* ]] && echo OPTEE_COMMIT=99f40897 || printf '%s\n' "$1"; }
edit_digest() { [[ "$1" == TOOLCHAIN_SHA256=* ]] && echo TOOLCHAIN_SHA256=abc || printf '%s\n' "$1"; }
edit_url() { [[ "$1" == FTPM_REPO=* ]] && echo FTPM_REPO=http://example.org/x.git || printf '%s\n' "$1"; }
edit_chars() { [[ "$1" == TFA_PLAT=* ]] && echo 'TFA_PLAT=imx95;true' || printf '%s\n' "$1"; }
edit_unknown() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nEXTRA_FLAG=y\n' "$1" || printf '%s\n' "$1"; }
edit_twice() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\n%s\n' "$1" "$1" || printf '%s\n' "$1"; }
edit_b32missing() { [[ "$1" == BL32_BASE=* ]] || printf '%s\n' "$1"; }
edit_b32hex() { [[ "$1" == BL32_BASE=* ]] && echo BL32_BASE=8C000000 || printf '%s\n' "$1"; }
edit_b32zero() { [[ "$1" == BL32_SIZE=* ]] && echo BL32_SIZE=0x0 || printf '%s\n' "$1"; }
edit_b32align() { [[ "$1" == BL32_BASE=* ]] && echo BL32_BASE=0x8C000001 || printf '%s\n' "$1"; }
edit_b32sizealign() { [[ "$1" == BL32_SIZE=* ]] && echo BL32_SIZE=0x02000001 || printf '%s\n' "$1"; }
edit_b32wrap() { if [[ "$1" == BL32_BASE=* ]]; then echo BL32_BASE=0x7FFFFFFFFFE00000; elif [[ "$1" == BL32_SIZE=* ]]; then echo BL32_SIZE=0x00400000; else printf '%s\n' "$1"; fi; }

edit_smabove() { [[ "$1" == BL32_BASE=* ]] && echo BL32_BASE=0x8E000000 || printf '%s\n' "$1"; }
edit_smbelow() { [[ "$1" == BL32_BASE=* ]] && echo BL32_BASE=0x89E00000 || printf '%s\n' "$1"; }
edit_smlong() { [[ "$1" == BL32_SIZE=* ]] && echo BL32_SIZE=0x02200000 || printf '%s\n' "$1"; }
edit_smbasemissing() { [[ "$1" == SM_SECURE_BASE=* ]] || printf '%s\n' "$1"; }
edit_smendmissing() { [[ "$1" == SM_SECURE_END=* ]] || printf '%s\n' "$1"; }
edit_smbasehex() { [[ "$1" == SM_SECURE_BASE=* ]] && echo SM_SECURE_BASE=8A000000 || printf '%s\n' "$1"; }
edit_smendhex() { [[ "$1" == SM_SECURE_END=* ]] && echo SM_SECURE_END=0x8DFFFFFZ || printf '%s\n' "$1"; }
edit_smorder() { [[ "$1" == SM_SECURE_BASE=* ]] && echo SM_SECURE_BASE=0x8E000000 || printf '%s\n' "$1"; }
edit_smbasealign() { [[ "$1" == SM_SECURE_BASE=* ]] && echo SM_SECURE_BASE=0x8A000001 || printf '%s\n' "$1"; }
edit_smendalign() { [[ "$1" == SM_SECURE_END=* ]] && echo SM_SECURE_END=0x8DFFFFFE || printf '%s\n' "$1"; }
# Inside the SM window: the exact fit, and the lowest base with the default size.
edit_smexact() { if [[ "$1" == BL32_BASE=* ]]; then echo BL32_BASE=0x8A400000; elif [[ "$1" == BL32_SIZE=* ]]; then echo BL32_SIZE=0x03C00000; else printf '%s\n' "$1"; fi; }
edit_smlow() { [[ "$1" == BL32_BASE=* ]] && echo BL32_BASE=0x8A400000 || printf '%s\n' "$1"; }

# The lock's SM window against the System Manager's DDR EXEC grant (the reviewer's
# example: the lock's end raised to 0x8FFFFFFF with BL32 at 0x8E000000 stays inside
# the pinned window, but not inside what the System Manager grants).
edit_grantend() {
	if [[ "$1" == SM_SECURE_END=* ]]; then echo SM_SECURE_END=0x8FFFFFFF
	elif [[ "$1" == BL32_BASE=* ]]; then echo BL32_BASE=0x8E000000
	else printf '%s\n' "$1"; fi
}
# A grants file with the DDR EXEC line replaced by $2 (one line, or none when empty).
grantscopy() {
	local f=$TMP_ROOT/grants-$1.txt line
	: >"$f"
	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" == "DDR EXEC"* ]]; then
			[ -z "$2" ] || printf '%b\n' "$2" >>"$f"
		else
			printf '%s\n' "$line" >>"$f"
		fi
	done <"$sm_grants"
	printf '%s\n' "$f"
}

# BL32 against BL31 (default BL31 window 0x8A200000, 256 KiB). W holds the
# values a fixture overrides; lockset applies them to a lock line.
declare -A W=()
lockset() { local k=${1%%=*}; if [[ "$1" == *=* && -n "${W[$k]:-}" ]]; then echo "$k=${W[$k]}"; else printf '%s\n' "$1"; fi; }
edit_ovstart() { lockset "$1"; }
edit_ovend() { lockset "$1"; }
edit_ovcontain() { lockset "$1"; }
edit_ovdefault() { lockset "$1"; }
edit_ovadjacent() { lockset "$1"; }
edit_b31zero() { lockset "$1"; }
edit_b31wrap() { lockset "$1"; }
edit_b31outside() { lockset "$1"; }
edit_b31missing() { [[ "$1" == BL31_BASE=* ]] || printf '%s\n' "$1"; }
edit_b31moved() { lockset "$1"; }
edit_b31size() { lockset "$1"; }
edit_missing() { [[ "$1" == MSTPM_COMMIT=* ]] || printf '%s\n' "$1"; }
edit_nowheel() { [[ "$1" == PYWHEEL=* ]] || printf '%s\n' "$1"; }
edit_badwheel() { [[ "$1" == PYWHEEL=cffi* ]] && echo PYWHEEL=cffi==2.1.1 || printf '%s\n' "$1"; }
edit_shape() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nnot a pin\n' "$1" || printf '%s\n' "$1"; }
# Owner rulings 771 and 1234: the script itself refuses a TF-A source that is
# neither upstream Arm TF-A nor NXP's imx-atf, a TF-A pin whose tag is not that
# source's release tag, and an OP-TEE that is not NXP's BSP OP-TEE.
edit_forkrepo() { [[ "$1" == TFA_REPO=* ]] && echo TFA_REPO=https://github.com/example/atf.git || printf '%s\n' "$1"; }
edit_rctag() { [[ "$1" == TFA_TAG=* ]] && echo TFA_TAG=lf-6.18.37-rc0 || printf '%s\n' "$1"; }
edit_branchtag() { [[ "$1" == TFA_TAG=* ]] && echo TFA_TAG=master || printf '%s\n' "$1"; }
edit_uptag() { [[ "$1" == TFA_TAG=* ]] && echo TFA_TAG=v2.15.0 || printf '%s\n' "$1"; }
edit_notag() { [[ "$1" == TFA_TAG=* ]] || printf '%s\n' "$1"; }
edit_upoptee() { [[ "$1" == OPTEE_REPO=* ]] && echo OPTEE_REPO=https://github.com/OP-TEE/optee_os.git || printf '%s\n' "$1"; }

for c in \
	"unread|is marked UNREAD" \
	"branch|must be a 40-hex commit" \
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
	"b32missing|BL32_BASE is missing" \
	"b32hex|BL32_BASE must be hex with a 0x prefix" \
	"b32zero|BL32_SIZE must be nonzero" \
	"b32align|BL32_BASE must be 2 MiB aligned" \
	"b32sizealign|BL32_SIZE must be 2 MiB aligned" \
	"b32wrap|wraps past 64 bits" \
	"smabove|is not inside the SM secure window" \
	"smbelow|is not inside the SM secure window" \
	"smlong|is not inside the SM secure window" \
	"smbasemissing|SM_SECURE_BASE is missing" \
	"smendmissing|SM_SECURE_END is missing" \
	"smbasehex|SM_SECURE_BASE must be hex with a 0x prefix" \
	"smendhex|SM_SECURE_END must be hex with a 0x prefix" \
	"smorder|SM_SECURE_BASE 0x8E000000 must be below SM_SECURE_END" \
	"smbasealign|SM_SECURE_BASE must be 2 MiB aligned" \
	"smendalign|SM_SECURE_END + 1 must be 2 MiB aligned" \
	"forkrepo|is neither upstream Arm TF-A nor NXP's imx-atf" \
	"rctag|TFA_TAG lf-6.18.37-rc0 is not an imx-atf release tag" \
	"branchtag|TFA_TAG master is not an imx-atf release tag" \
	"uptag|TFA_TAG v2.15.0 is not an imx-atf release tag" \
	"notag|TFA_TAG is missing" \
	"upoptee|is not NXP's BSP OP-TEE"; do
	name=${c%%|*} want=${c#*|}
	f=$(lockcopy "$name" "edit_$name")
	run bash "$sw" --lock "$f" --check-lock
	check "a lock with $name fails" nonzero "$want"
done

ovmsg="overlaps the BL31 window"
# BL32 starts inside BL31 (BL31 moved to 0x8A100000, 2 MiB, so 0x8A200000 is inside it).
W=([BL31_BASE]=0x8A100000 [BL31_SIZE]=0x00200000 [BL32_BASE]=0x8A200000 [BL32_SIZE]=0x00200000)
f=$(lockcopy ovstart edit_ovstart)
run bash "$sw" --lock "$f" --check-lock
check "a BL32 window starting inside BL31 fails" nonzero "$ovmsg"
# BL32 ends inside BL31.
W=([BL31_BASE]=0x8A100000 [BL31_SIZE]=0x00200000 [BL32_BASE]=0x8A000000 [BL32_SIZE]=0x00200000)
f=$(lockcopy ovend edit_ovend)
run bash "$sw" --lock "$f" --check-lock
check "a BL32 window ending inside BL31 fails" nonzero "$ovmsg"
# BL32 contains BL31 (the case a containment-only check accepted).
W=([BL32_BASE]=0x8A000000 [BL32_SIZE]=0x04000000)
f=$(lockcopy ovcontain edit_ovcontain)
run bash "$sw" --lock "$f" --check-lock
check "a BL32 window containing BL31 fails" nonzero "$ovmsg"
# The reviewer's case: BL32_BASE 0x8A000000 with the default 32 MiB size.
W=([BL32_BASE]=0x8A000000)
f=$(lockcopy ovdefault edit_ovdefault)
run bash "$sw" --lock "$f" --check-lock
check "BL32_BASE 0x8A000000 with the default size fails" nonzero "$ovmsg"
# BL32 ending exactly at BL31_BASE does not intersect: passes.
W=([BL32_BASE]=0x8A000000 [BL32_SIZE]=0x00200000)
f=$(lockcopy ovadjacent edit_ovadjacent)
run bash "$sw" --lock "$f" --check-lock
check "a BL32 window ending exactly at BL31_BASE passes" 0 "OK"
# The BL31 pins are validated like BL32's.
W=([BL31_SIZE]=0x0)
f=$(lockcopy b31zero edit_b31zero)
run bash "$sw" --lock "$f" --check-lock
check "BL31_SIZE zero fails" nonzero "BL31_SIZE must be nonzero"
W=([BL31_BASE]=0x7FFFFFFFFFFFF000 [BL31_SIZE]=0x00002000)
f=$(lockcopy b31wrap edit_b31wrap)
run bash "$sw" --lock "$f" --check-lock
check "a wrapping BL31 window fails" nonzero "BL31_BASE 0x7FFFFFFFFFFFF000 + BL31_SIZE 0x00002000 wraps"
W=([BL31_BASE]=0x90000000)
f=$(lockcopy b31outside edit_b31outside)
run bash "$sw" --lock "$f" --check-lock
check "a BL31 window outside the SM window fails" nonzero "BL31 window (BL31_BASE 0x90000000"
f=$(lockcopy b31missing edit_b31missing)
run bash "$sw" --lock "$f" --check-lock
check "a lock without BL31_BASE fails" nonzero "BL31_BASE is missing"
# The reviewer's case: a BL31 window that is sane, inside the SM window and clear
# of BL32, but not where the pinned TF-A links BL31 (0x8A200000). BL32 at
# 0x8A000000 (default 32 MiB) then covers the resident BL31.
bl31msg="differs from the BL31 the pinned TF-A links at"
W=([BL31_BASE]=0x8D000000 [BL32_BASE]=0x8A000000)
f=$(lockcopy b31moved edit_b31moved)
run bash "$sw" --lock "$f" --check-lock
check "BL31_BASE 0x8D000000 with BL32_BASE 0x8A000000 is refused" nonzero "$bl31msg"
W=([BL31_SIZE]=0x00200000)
f=$(lockcopy b31size edit_b31size)
run bash "$sw" --lock "$f" --check-lock
check "a BL31_SIZE other than the platform's is refused" nonzero "$bl31msg"
W=()

for c in "smexact|a BL32 window from above BL31 to the SM window end" "smlow|BL32_BASE just above BL31 with the default size"; do
	name=${c%%|*}
	f=$(lockcopy "$name" "edit_$name")
	run bash "$sw" --lock "$f" --check-lock
	check "$name: ${c#*|} passes" 0 "OK"
done

sm_grants=$ROOT/system-manager/ap-s-grants.txt
f=$(lockcopy grantend edit_grantend)
run bash "$sw" --lock "$f" --check-lock
check "the lock's SM window raised to 0x8FFFFFFF with BL32 at 0x8E000000 fails" nonzero "differs from the System Manager's DDR EXEC grant"
run bash "$sw" --lock "$good" --grants "$sm_grants" --check-lock
check "the committed lock passes against the committed DDR EXEC grant" 0 "OK"
for c in \
	"missing|" \
	"dup|DDR EXEC, begin=0x08A000000, end=0x08DFFFFFF\nDDR EXEC, begin=0x08A000000, end=0x08DFFFFFF" \
	"junk|DDR EXEC, begin=0x08A000000" \
	"size|DDR EXEC, begin=0x08A000000, size=64M" \
	"low|DDR EXEC, begin=0x089E00000, end=0x08DFFFFFF" \
	"high|DDR EXEC, begin=0x08A000000, end=0x08FFFFFFF"; do
	name=${c%%|*}
	g=$(grantscopy "$name" "${c#*|}")
	run bash "$sw" --lock "$good" --grants "$g" --check-lock
	case $name in
	missing) want="no DDR EXEC grant line" ;;
	dup) want="2 DDR EXEC grant lines" ;;
	junk | size) want="the DDR EXEC grant is not" ;;
	*) want="differs from the System Manager's DDR EXEC grant" ;;
	esac
	check "a grants file with the DDR EXEC line '$name' fails" nonzero "$want"
done
run bash "$sw" --lock "$good" --grants "$TMP_ROOT/no-such-grants.txt" --check-lock
check "a missing grants file fails" nonzero "no such AP-S grants file"

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
# bash: logs its arguments when STUB_BASH_LOG is set, then runs the real bash, so
# the test can see how the driver starts its two --single children.
cat >"$fs/bash" <<'EOF'
#!/bin/bash
[ -z "${STUB_BASH_LOG:-}" ] || echo "$*" >>"$STUB_BASH_LOG"
exec /bin/bash "$@"
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
	: >"$TMP_ROOT/$n/bash.log"
	run env PATH="$fp" STUB_TARBALL="$TMP_ROOT/fix/toolchain.tar.xz" STUB_LOG="$TMP_ROOT/$n/make.log" \
		STUB_BASH_LOG="$TMP_ROOT/$n/bash.log" "$@" \
		bash "$sw" --lock "$l" ${FR_GRANTS:+--grants "$FR_GRANTS"} --work "$TMP_ROOT/$n/work" --out "$TMP_ROOT/$n/out" --cache "$TMP_ROOT/$n/cache"
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
lock_value() { local l; while IFS= read -r l || [ -n "$l" ]; do [[ "$l" == "$2="* ]] && { printf '%s\n' "${l#"$2="}"; return 0; }; done <"$1"; return 1; }
tag_fetched() { [ "$(<"$TMP_ROOT/ok/work/build-1/src/tfa/.stubtag")" = "refs/tags/$(lock_value "$good" TFA_TAG)" ]; }
expect "the TF-A release tag is fetched from the pinned repository and checked" tag_fetched
expect "build-info.txt records the TF-A tag" has_line "tfa: $(lock_value "$good" TFA_COMMIT) tag $(lock_value "$good" TFA_TAG) PLAT=imx95 SPD=opteed BL32_BASE=$(lock_value "$good" BL32_BASE) BL32_SIZE=$(lock_value "$good" BL32_SIZE)" "$TMP_ROOT/ok/out/build-info.txt"

# The release tag peels to another commit than TFA_COMMIT: the build stops.
fullrun tagmoved "$oklock" STUB_TAG_MOVED=1
check "a TF-A tag that does not peel to TFA_COMMIT stops the build" nonzero "tfa-tag failed" "tag $(lock_value "$good" TFA_TAG) peels to 1111111111111111111111111111111111111111"
expect "a moved tag publishes nothing" nothing_published tagmoved

# The BL31 build call (the only make call in the TF-A tree): its platform is the
# TFA_PLAT of the lock (read here with the script's NAME=value rule, not typed
# twice), the dispatcher is OP-TEE, the target is bl31, the output is under the
# build directory, and each clean build makes exactly one such call.
# lock_value <lock> <NAME>: the value of the one NAME=value line.
# tfa_call_ok <log> <work> <plat>: one correct BL31 call in each of build-1 and build-2
tfa_call_ok() {
	local log=$1 work=$2 plat=$3 base=${4:-$bl32_base} size=${5:-$bl32_size} n l c w
	for n in 1 2; do
		c=0 w=$work/build-$n
		while IFS= read -r l; do
			[[ "$l" == *"-C $w/src/tfa "* ]] || continue
			c=$((c + 1))
			[[ " $l " == *" PLAT=$plat "* && " $l " == *" SPD=opteed "* ]] || return 1
			[[ "$l" == *" BUILD_BASE=$w/build/"* && "$l" == *" bl31" ]] || return 1
			[[ "$l" != *" PLAT="*" PLAT="* && "$l" != *" SPD="*" SPD="* ]] || return 1
			[[ " $l " == *" BL32_BASE=$base "* && " $l " == *" BL32_SIZE=$size "* ]] || return 1
			[[ "$l" != *" BL32_BASE="*" BL32_BASE="* && "$l" != *" BL32_SIZE="*" BL32_SIZE="* ]] || return 1
		done <<<"$log"
		[ "$c" -eq 1 ] || return 1
	done
}
tfa_plat=$(lock_value "$good" TFA_PLAT)
bl32_base=$(lock_value "$good" BL32_BASE)
bl32_size=$(lock_value "$good" BL32_SIZE)
tfa_log_ok() { tfa_call_ok "$mlog" "$TMP_ROOT/ok/work" "$tfa_plat"; }
tfa_log_ok_with() { tfa_call_ok "$1" "$TMP_ROOT/ok/work" "$tfa_plat"; }
tfa_log_bad() { ! tfa_log_ok_with "$1"; }
expect "the BL31 build is one make call per clean build: PLAT=$tfa_plat (from bsp.lock) SPD=opteed bl31, output under the build dir" tfa_log_ok
bl31_line="-C $TMP_ROOT/ok/work/build-1/src/tfa -j1 BUILD_BASE=$TMP_ROOT/ok/work/build-1/build/tfa PLAT=$tfa_plat SPD=opteed BL32_BASE=$bl32_base BL32_SIZE=$bl32_size bl31"
bl31_line2=${bl31_line//build-1/build-2}
expect "the TF-A call check accepts a planted good log" tfa_log_ok_with "$(printf '%s\n%s\n' "$bl31_line" "$bl31_line2")"
expect "a planted SPD=trusty fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "${bl31_line//SPD=opteed/SPD=trusty}" "$bl31_line2")"
expect "a planted other PLAT fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "$bl31_line" "${bl31_line2//PLAT=$tfa_plat/PLAT=imx8mp}")"
expect "a planted missing bl31 target fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "${bl31_line% bl31}" "$bl31_line2")"
expect "a planted BUILD_BASE outside the build dir fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "${bl31_line//\/build\/tfa//elsewhere}" "$bl31_line2")"
expect "a planted second TF-A call fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n%s\n' "$bl31_line" "$bl31_line" "$bl31_line2")"
expect "a planted missing TF-A call fails the TF-A call check" tfa_log_bad "$bl31_line"
expect "a planted bl31 call without BL32_BASE fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "${bl31_line// BL32_BASE=$bl32_base/}" "$bl31_line2")"
expect "a planted other BL32_SIZE fails the TF-A call check" tfa_log_bad "$(printf '%s\n%s\n' "$bl31_line" "${bl31_line2//BL32_SIZE=$bl32_size/BL32_SIZE=0x04000000}")"

# The secure DRAM window: every OP-TEE make call (dev kit and image, in both
# clean builds) carries CFG_TZDRAM_START and CFG_TZDRAM_SIZE equal to the lock's
# BL32_BASE and BL32_SIZE, which the BL31 calls carry too (tfa_call_ok above).
# all_optee_window <log> <base> <size>: each OP-TEE call has the pair once.
all_optee_window() {
	local l n=0
	while IFS= read -r l; do
		[[ "$l" == *"/optee "* ]] || continue
		n=$((n + 1))
		[[ " $l " == *" CFG_TZDRAM_START=$2 "* && " $l " == *" CFG_TZDRAM_SIZE=$3 "* ]] || return 1
		[[ "$l" != *" CFG_TZDRAM_START="*" CFG_TZDRAM_START="* && "$l" != *" CFG_TZDRAM_SIZE="*" CFG_TZDRAM_SIZE="* ]] || return 1
	done <<<"$1"
	[ "$n" -ge 4 ]
}
optee_window_bad() { ! all_optee_window "$@"; }
expect "every OP-TEE make call carries CFG_TZDRAM_START/SIZE equal to the lock's BL32_BASE/BL32_SIZE" all_optee_window "$mlog" "$bl32_base" "$bl32_size"
expect "a planted other CFG_TZDRAM_START fails the OP-TEE window check" optee_window_bad "${mlog//CFG_TZDRAM_START=$bl32_base/CFG_TZDRAM_START=0x8E000000}" "$bl32_base" "$bl32_size"
expect "the published build-info records the window" has_line "tfa: $(lock_value "$good" TFA_COMMIT) tag $(lock_value "$good" TFA_TAG) PLAT=$tfa_plat SPD=opteed BL32_BASE=$bl32_base BL32_SIZE=$bl32_size" "$TMP_ROOT/ok/out/build-info.txt"

# A lock with another BL32_BASE changes the BL31 calls and the OP-TEE calls.
edit_altbase() { if [[ "$1" == BL32_BASE=* ]]; then echo BL32_BASE=0x8A400000; else edit_tcsum "$1"; fi; }
baselock=$(lockcopy altbase edit_altbase)
fullrun altbase "$baselock"
check "a build with another BL32_BASE reaches publication" 0 "secure-world-build: OK"
baselog=$(<"$TMP_ROOT/altbase/make.log")
base_tfa_ok() { tfa_call_ok "$baselog" "$TMP_ROOT/altbase/work" "$tfa_plat" 0x8A400000 "$bl32_size"; }
expect "another BL32_BASE is passed to the BL31 calls" base_tfa_ok
expect "another BL32_BASE is passed to every OP-TEE call" all_optee_window "$baselog" 0x8A400000 "$bl32_size"
expect "another BL32_BASE no longer matches the committed window" optee_window_bad "$baselog" "$bl32_base" "$bl32_size"
expect "the published build-info records the lock's platform" has_line "tfa: $(lock_value "$good" TFA_COMMIT) tag $(lock_value "$good" TFA_TAG) PLAT=$tfa_plat SPD=opteed BL32_BASE=$bl32_base BL32_SIZE=$bl32_size" "$TMP_ROOT/ok/out/build-info.txt"

# A non-default System Manager grant with a matching lock: the whole two-build
# driver must pass --grants to both --single children, or the children check the
# lock against the default grants file and refuse it.
edit_altsm() { if [[ "$1" == SM_SECURE_END=* ]]; then echo SM_SECURE_END=0x8FFFFFFF; else edit_tcsum "$1"; fi; }
altsmlock=$(lockcopy altsm edit_altsm)
altsmgrants=$(grantscopy altsm "DDR EXEC, begin=0x08A000000, end=0x08FFFFFFF")
FR_GRANTS=$altsmgrants fullrun altsm "$altsmlock"
check "a build with a non-default grants file and the matching lock reaches publication" 0 "secure-world-build: OK"
grants_passed() { # <bash.log> <grants>: two --single children, each given --grants <grants>
	local l n=0
	while IFS= read -r l; do
		[[ "$l" == *" --single "* ]] || continue
		n=$((n + 1))
		[[ "$l" == *" --grants $2 "* ]] || return 1
	done <"$1"
	[ "$n" -eq 2 ]
}
expect "both --single children got the driver's grants file" grants_passed "$TMP_ROOT/altsm/bash.log" "$altsmgrants"
grants_not_passed() { ! grants_passed "$@"; }
expect "the default lock's driver run gives the children another grants file than the alternative" grants_not_passed "$TMP_ROOT/ok/bash.log" "$altsmgrants"
# The lock alone, without the matching grants file, is refused by the driver.
fullrun altsmnog "$altsmlock"
check "the alternative lock against the default grants is refused" nonzero "differs from the System Manager's DDR EXEC grant"
expect "that refusal publishes nothing" nothing_published altsmnog

# A lock with another TFA_PLAT: the stub writes bl31.bin under that platform's
# release directory, so publication shows the script stages from the matching path.
edit_altplat() { if [[ "$1" == TFA_PLAT=* ]]; then echo TFA_PLAT=imx95x; else edit_tcsum "$1"; fi; }
altlock=$(lockcopy altplat edit_altplat)
fullrun altplat "$altlock"
check "a build with another TFA_PLAT reaches publication" 0 "secure-world-build: OK"
altlog=$(<"$TMP_ROOT/altplat/make.log")
alt_ok() { tfa_call_ok "$altlog" "$TMP_ROOT/altplat/work" imx95x; }
expect "another TFA_PLAT is passed to the TF-A make call" alt_ok
expect "the other platform's bl31.bin is published" test -s "$TMP_ROOT/altplat/out/bl31.bin"
expect "bl31.bin was staged from the other platform's release path" test -s "$TMP_ROOT/altplat/work/build-1/build/tfa/imx95x/release/bl31.bin" -a ! -e "$TMP_ROOT/altplat/work/build-1/build/tfa/imx95/release/bl31.bin"

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
# optee_config_digest [lock [script]]: defaults to the committed files.
optee_config_digest() {
	local lk=${1:-$good} sc=${2:-$sw} l on=0 acc=
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
tied_with() { [ "$(recorded_config_digest)" = "$(optee_config_digest "$1" "$2")" ]; }
not_tied_with() { ! tied_with "$@"; }
for n in optee_pin ftpm_pin mstpm_pin; do
	lk=$(lockcopy "dg$n" "edit_$n")
	expect "a changed ${n%_pin} commit in the lock fails the digest guard" not_tied_with "$lk" "$sw"
done
lk=$(lockcopy dgtag edit_rctag)
expect "the TF-A tag line, which no build step reads, leaves the digest" tied_with "$lk" "$sw"
lk=$(lockcopy dgtfa edit_unread)
expect "a changed TF-A commit in the lock fails the digest guard" not_tied_with "$lk" "$sw"
ftpm_script=$TMP_ROOT/ftpm-script.sh
: >"$ftpm_script"
while IFS= read -r l; do
	printf '%s\n' "${l//TEE_STORAGE_PRIVATE_REE/TEE_STORAGE_PRIVATE_RPMB}" >>"$ftpm_script"
done <"$sw"
expect "a changed fTPM flag in the script fails the digest guard" not_tied_with "$good" "$ftpm_script"

# --- build.md's pin rows follow bsp.lock ----------------------------------------
# The pin table of build.md states each source's repository and commit as prose.
# pin_row_ok <md> <row-prefix> <REPO name> <COMMIT name>: the one row starting with
# the prefix names the repository path of the lock's REPO (github.com/<path>.git)
# and the lock's whole 40-hex commit. The lock is read with the script's rule.
pin_row_ok() {
	local md=$1 pre=$2 repo commit path l n=0 row=
	repo=$(lock_value "$good" "$3") commit=$(lock_value "$good" "$4") || return 1
	path=${repo#https://github.com/}
	path=${path%.git}
	[[ -n "$path" && "$path" != "$repo" && "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	while IFS= read -r l || [ -n "$l" ]; do
		[[ "$l" == "$pre"* ]] && { n=$((n + 1)); row=$l; }
	done <"$md"
	[ "$n" -eq 1 ] || return 1
	[[ "$row" == *"\`$path\`"* && "$row" == *"\`$commit\`"* ]]
}
md=$ROOT/docs/secure-world/build.md
expect "build.md's TF-A BL31 row names TFA_REPO's path and TFA_COMMIT" pin_row_ok "$md" "| TF-A BL31 |" TFA_REPO TFA_COMMIT
expect "build.md's OP-TEE OS row names OPTEE_REPO's path and OPTEE_COMMIT" pin_row_ok "$md" "| OP-TEE OS" OPTEE_REPO OPTEE_COMMIT
expect "build.md's fTPM TA row names FTPM_REPO's path and FTPM_COMMIT" pin_row_ok "$md" "| fTPM TA |" FTPM_REPO FTPM_COMMIT
# scratch copies of build.md: the TF-A commit changed by one digit; a branch named instead
tfa_commit=$(lock_value "$good" TFA_COMMIT)
md_copy() { # <name> <from> <to>
	local f=$TMP_ROOT/$1.md l
	: >"$f"
	while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "${l//"$2"/"$3"}" >>"$f"; done <"$md"
	printf '%s\n' "$f"
}
off_by_one=$(md_copy md-onedigit "$tfa_commit" "${tfa_commit%?}0")
[ "${tfa_commit: -1}" != 0 ] || off_by_one=$(md_copy md-onedigit "$tfa_commit" "${tfa_commit%?}1")
branch_only=$(md_copy md-branch "\`$tfa_commit\`" "\`lf_v2.14\`")
pin_row_bad() { ! pin_row_ok "$@"; }
expect "a build.md with the TF-A commit changed by one digit fails the pin row check" pin_row_bad "$off_by_one" "| TF-A BL31 |" TFA_REPO TFA_COMMIT
expect "a build.md naming a branch only fails the pin row check" pin_row_bad "$branch_only" "| TF-A BL31 |" TFA_REPO TFA_COMMIT
expect "a build.md without the TF-A row fails the pin row check" pin_row_bad "$md" "| TF-A BL31X |" TFA_REPO TFA_COMMIT

finish
