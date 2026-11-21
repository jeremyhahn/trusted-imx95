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
check "the committed bsp.lock checks" 0 "bsp.lock OK" "lf-6.18.37-2.1.0" "toolchain 15.2.rel1"

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
	"shape|not NAME=value"; do
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
fetch) echo "${!#}" >"$dir/.stubhead" ;;
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
optee) mkdir -p "$o/core" && echo tee >"$o/core/tee-raw.bin" ;;
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
	run env PATH="$fp" STUB_TARBALL="$TMP_ROOT/fix/toolchain.tar.xz" STUB_LOG="$TMP_ROOT/$n/make.log" "$@" \
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
expect "the fTPM TA is an early TA" has "$optee_line" "EARLY_TA_PATHS=$TMP_ROOT/ok/work/build/ftpm/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf"
expect "the PKCS#11 TA is an early TA" has "$optee_line" "CFG_IN_TREE_EARLY_TAS=pkcs11/fd02c9da-306c-48c7-a49c-bbd827ae86ee"
expect "the fTPM TA keeps its NV in REE FS storage" has "$ftpm_line" "CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE"
expect "PKCS#11 is built" has "$optee_line" "CFG_PKCS11_TA=y"

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
# configuration. build.md records the SHA-256 of that configuration (TFA_REPO
# and TFA_COMMIT from bsp.lock, the bl31 make call, the
# optee_flags array and the final OP-TEE make call, whitespace squeezed), and
# this check recomputes it from the script, so a changed flag cannot leave old
# hashes standing.
optee_config_digest() {
	local l on=0 acc=
	while IFS= read -r l; do
		[[ "$l" == TFA_REPO=* || "$l" == TFA_COMMIT=* ]] && acc+="$l"$'\n'
	done <"$good"
	while IFS= read -r l; do
		if [[ "$l" == "optee_flags=("* ]]; then on=1; fi
		if [[ "$l" == "step bl31 make"* || "$l" == "step optee make"* ]]; then on=2; fi
		if [ "$on" != 0 ]; then
			l=${l//$'\t'/ }
			while [[ "$l" == *"  "* ]]; do l=${l//  / }; done
			acc+="$l"$'\n'
		fi
		if [ "$on" = 1 ] && [[ "$l" == ")" ]]; then on=0; fi
		if [ "$on" = 2 ] && [[ "$l" != *"\\" ]]; then on=0; fi
	done <"$sw"
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
expect "build.md records the digest of the TF-A pin and the script's build configuration" config_tied

finish
