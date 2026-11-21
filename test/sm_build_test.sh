#!/usr/bin/env bash
# test/sm_build_test.sh: scripts/sm-build.sh, `make system-manager`
# (docs/system-manager-config/build.md). Offline: a fake imx-sm repository and
# a fake Arm toolchain tarball stand in for NXP's and Arm's.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sm="$ROOT/scripts/sm-build.sh"
unset FAKE_NONDET FAKE_FAIL SM_OUT

run bash "$sm" --check "$ROOT/system-manager/sm.lock"
check "the committed lock validates" 0 "lf-6.18.37-2.1.0" "mx95frdm-pro" "15.2.rel1"

# A fake toolchain: a tarball with one top directory holding bin/arm-none-eabi-gcc.
tc="$TMP_ROOT/tc/arm-gnu-toolchain-9.9.rel1-x86_64-arm-none-eabi/bin"
mkdir -p "$tc"
printf '#!/bin/sh\necho fake-gcc\n' >"$tc/arm-none-eabi-gcc"
chmod +x "$tc/arm-none-eabi-gcc"
tar -C "$TMP_ROOT/tc" -cJf "$TMP_ROOT/tc.tar.xz" .
tc_sha=$(sha256sum "$TMP_ROOT/tc.tar.xz" | cut -d' ' -f1)

# A fake imx-sm: `make cfg` copies the .cfg, `make all` writes an image from
# the compiler, M and SOURCE_DATE_EPOCH; FAKE_NONDET adds the tree's path,
# FAKE_FAIL fails the build.
repo="$TMP_ROOT/imx-sm"
mkdir -p "$repo/configs/other"
echo "board=fake" >"$repo/configs/other/fakepro.cfg"
# shellcheck disable=SC2016 # make's $(...), not the shell's
printf '%s\n' 'cfg:' \
	'	mkdir -p configs/$(config) && cp configs/other/$(config).cfg configs/$(config)/config.h' \
	'all:' \
	'	[ -z "$(FAKE_FAIL)" ]' \
	'	mkdir -p build/$(config)' \
	'	{ $(SM_CROSS_COMPILE)gcc; echo $(M) $(SOURCE_DATE_EPOCH); date +%FT%T; [ -z "$(FAKE_NONDET)" ] || pwd; } >build/$(config)/m33_image.bin' \
	>"$repo/Makefile"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
git -C "$repo" init -q
g add -A
GIT_COMMITTER_DATE=@1700000000 g commit -q -m fake
g tag -a v1 -m v1
commit=$(git -C "$repo" rev-parse HEAD)
cfg_sha=$(sha256sum "$repo/configs/other/fakepro.cfg" | cut -d' ' -f1)

# The repository's patch, faked: one patch beside the lock, changing the fake
# configuration. patched_sha is the configuration after it applies.
mkdir -p "$TMP_ROOT/patches" "$TMP_ROOT/pa/configs/other" "$TMP_ROOT/pb/configs/other"
echo "board=fake" >"$TMP_ROOT/pa/configs/other/fakepro.cfg"
echo "board=fake-closed" >"$TMP_ROOT/pb/configs/other/fakepro.cfg"
(cd "$TMP_ROOT" && diff -u pa/configs/other/fakepro.cfg pb/configs/other/fakepro.cfg |
	{ read -r _; read -r _; echo "--- a/configs/other/fakepro.cfg"; echo "+++ b/configs/other/fakepro.cfg"; cat; }) \
	>"$TMP_ROOT/patches/0001-fake.patch" || true
patch_sha=$(sha256sum "$TMP_ROOT/patches/0001-fake.patch" | cut -d' ' -f1)
patched_sha=$(sha256sum "$TMP_ROOT/pb/configs/other/fakepro.cfg" | cut -d' ' -f1)

# lock [key=value...]: a good lock in $TMP_ROOT/lock, with the overrides.
lock() {
	local f="$TMP_ROOT/lock"
	{
		echo "# fake"
		echo "sm_repo=file://$repo"
		echo "sm_tag=v1"
		echo "sm_commit=$commit"
		echo "sm_config=fakepro"
		echo "sm_config_file=configs/other/fakepro.cfg"
		echo "sm_config_sha256=$cfg_sha"
		echo "sm_patch_sha256=$patch_sha"
		echo "sm_patched_config_sha256=$patched_sha"
		echo "sm_monitor_mode=2"
		echo "toolchain_version=9.9.rel1"
		echo "toolchain_url=file://$TMP_ROOT/tc.tar.xz"
		echo "toolchain_sha256=$tc_sha"
	} >"$f"
	local kv
	for kv in "$@"; do
		python3 -I -c 'import sys; f, kv = sys.argv[1:]; k = kv.split("=")[0]
lines = [l for l in open(f) if not l.startswith(k + "=")]
open(f, "w").write("".join(lines) + (kv + "\n" if "=" in kv else ""))' "$f" "$kv"
	done
}

# has_line <line> <file>: the file holds the line.
has_line() {
	local l
	while IFS= read -r l; do [ "$l" != "$1" ] || return 0; done <"$2"
	return 1
}

lock
out="$TMP_ROOT/out"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "two identical builds pass" 0 "fetching" "reproducible, m33_image.bin"
expect "the manifest says reproducible" has_line "reproducible=yes" "$out/sm-manifest.txt"
expect "the image's date stamp is the commit's" has_line "2023-11-14T22:13:20" "$out/m33_image.bin"
expect "the manifest has the commit's time" has_line "source_date_epoch=1700000000" "$out/sm-manifest.txt"
# shellcheck disable=SC2016 # expands in the child shell
expect "SHA256SUMS checks the image" bash -c 'cd "$1" && sha256sum -c --quiet SHA256SUMS' _ "$out"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a second run uses the cache" 0 "reproducible"
if [[ $OUT == *fetching* ]]; then fail "a second run fetches nothing" "$OUT"; else pass "a second run fetches nothing"; fi

run env SM_OUT="$out" FAKE_NONDET=1 bash "$sm" "$TMP_ROOT/lock"
check "differing builds fail" nonzero "not reproducible"
expect "the manifest says not reproducible" has_line "reproducible=no" "$out/sm-manifest.txt"

run env SM_OUT="$out" FAKE_FAIL=1 bash "$sm" "$TMP_ROOT/lock"
check "a failing build fails by name" nonzero "build 1 failed"

lock sm_commit=0123456789abcdef0123456789abcdef01234567
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a tag on another commit fails" nonzero "v1 is commit $commit"

lock sm_config_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a changed configuration fails" nonzero "configs/other/fakepro.cfg SHA-256 is $cfg_sha"

lock sm_patch_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$TMP_ROOT/out3" bash "$sm" "$TMP_ROOT/lock"
check "a patch of another digest fails" nonzero "patches SHA-256 is $patch_sha"
lock sm_patched_config_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a patched configuration of another digest fails" nonzero "patched configs/other/fakepro.cfg SHA-256 is $patched_sha"
expect "the patch reached the fake build" has_line "board=fake-closed" "$out/tree-1/configs/other/fakepro.cfg"
lock
printf '+x\n' >>"$TMP_ROOT/patches/0001-fake.patch"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "an edited patch fails" nonzero "patches SHA-256 is"
head -n -1 "$TMP_ROOT/patches/0001-fake.patch" >"$TMP_ROOT/patches/x" && mv "$TMP_ROOT/patches/x" "$TMP_ROOT/patches/0001-fake.patch"

# The committed patch, offline: it changes only the M7 LM's fault reactions
# (build.md section 5), each lm_reset to sys_reset or sys_shutdown, and
# matches the lock.
patch_file="$ROOT/system-manager/patches/0001-m7-faults-fail-closed.patch"
expect "the committed patch matches the lock's patch digest" \
	has_line "sm_patch_sha256=$(sha256sum "$patch_file" | cut -d' ' -f1)" "$ROOT/system-manager/sm.lock"
run python3 -I -c '
import re, sys
want = {"FAULT_M7_LOCKUP", "FAULT_M7_RESET", "FAULT_SW1", "FAULT_WDOG5"}
old, new = {}, {}
for l in open(sys.argv[1]).read().split("\n"):
    if l.startswith(("---", "+++", "@@", " ")) or not l:
        continue
    m = re.match(r"^([-+])(FAULT_[A-Z0-9_]+) +OWNER, reaction=([a-z_]+)$", l)
    if not m:
        sys.exit("changed line is not a fault reaction: " + l)
    (old if m[1] == "-" else new)[m[2]] = m[3]
if set(old) != want or set(new) != want:
    sys.exit("changed faults %s, want %s" % (sorted(old), sorted(want)))
if any(v != "lm_reset" for v in old.values()):
    sys.exit("a changed reaction was not lm_reset")
if any(v not in ("sys_reset", "sys_shutdown") for v in new.values()):
    sys.exit("a new reaction is not sys_reset or sys_shutdown")
print("patch touches only M7 faults")
' "$patch_file"
check "the committed patch changes only the M7 LM's fault reactions" 0 "patch touches only M7 faults"

lock toolchain_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$TMP_ROOT/out2" bash "$sm" "$TMP_ROOT/lock"
check "a toolchain of another digest fails" nonzero "toolchain SHA-256 is $tc_sha"

# The lock's form, offline.
lock
echo "sm_extra=1" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "an unknown key fails" nonzero "unknown key sm_extra"
lock
echo "sm_tag=v2" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "a key set twice fails" nonzero "sm_tag set twice"
lock sm_tag
run bash "$sm" --check "$TMP_ROOT/lock"
check "a missing key fails" nonzero "sm_tag is missing"
lock
echo "sm_tag v1" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "a line not key=value fails" nonzero "not key=value"
lock sm_commit=eec2328
run bash "$sm" --check "$TMP_ROOT/lock"
check "a short commit fails" nonzero "sm_commit must be a full 40-hex commit"
lock sm_monitor_mode=3
run bash "$sm" --check "$TMP_ROOT/lock"
check "a bad monitor mode fails" nonzero "sm_monitor_mode must be 0, 1 or 2"
lock sm_config=other
run bash "$sm" --check "$TMP_ROOT/lock"
check "a config file of another name fails" nonzero "is not other.cfg"
lock sm_repo=http://example.invalid/imx-sm
run bash "$sm" --check "$TMP_ROOT/lock"
check "a plain-http repository fails" nonzero "sm_repo must be an https:// or file:// URL"
run bash "$sm" --check "$TMP_ROOT/no-such.lock"
check "a missing lock fails" nonzero "no lock file"

# The pinned Arm toolchain is glibc-hosted, and the devcontainer image is musl:
# the toolchain stage must add a glibc loader (gcompat), or the real compiler
# cannot start there. The fake compiler above cannot see this; `make
# sm-toolchain-check` runs the real one in the image.
run bash -c "awk '/^FROM base AS toolchain/{t=1;next} /^FROM /{t=0} t' '$ROOT/build/docker/devcontainer/Dockerfile' | grep -E '^RUN apk add .*[[:space:]]gcompat([[:space:]]|\$)'"
check "the toolchain image provides a glibc loader (gcompat)" 0 "gcompat"

# make sm-toolchain-check must hand the image one script, with no shell `$`
# crossing Make twice (the inline find/$g form expanded to an empty check).
run bash -c "make -n -C '$ROOT' sm-toolchain-check 2>&1 | grep -F 'bash -c '"
check "sm-toolchain-check: the image runs scripts/sm-toolchain-check.sh" 0 "bash -c 'scripts/sm-toolchain-check.sh'"
run bash -c "make -n -C '$ROOT' sm-toolchain-check 2>&1 | grep -c -F 'find out/system-manager' || true"
expect "sm-toolchain-check: no inline find passes through Make" [ "$OUT" = 0 ]
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/smout"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/fakebin/make"
chmod +x "$TMP_ROOT/fakebin/make"
run env PATH="$TMP_ROOT/fakebin:$PATH" SM_OUT="$TMP_ROOT/smout" "$ROOT/scripts/sm-toolchain-check.sh"
check "sm-toolchain-check.sh: a build with no compiler fails" 1 "no arm-none-eabi-gcc"
expect "sm-toolchain-check.sh is executable" [ -x "$ROOT/scripts/sm-toolchain-check.sh" ]

# The CI job must not bind-mount the checkout (the daemon may not see it): it
# runs the script through in-toolchain-image.sh, which copies the checkout in.
job=$(awk '/^  system-manager-build:/{f=1;next} f&&/^  [a-z][a-z-]*:/{exit} f&&!/^ *#/' "$ROOT/.github/workflows/ci.yml")
expect "ci: system-manager-build job exists" [ -n "$job" ]
expect "ci: system-manager-build runs sm-toolchain-check.sh through in-toolchain-image.sh" \
	grep -Eq 'scripts/in-toolchain-image\.sh .*scripts/sm-toolchain-check\.sh' <<<"$job"
expect "ci: system-manager-build uses IN_IMAGE_NETWORK=bridge" \
	grep -Eq 'IN_IMAGE_NETWORK: bridge' <<<"$job"
# shellcheck disable=SC2016 # expands in the child shell
expect "ci: system-manager-build does not call make sm-toolchain-check" \
	bash -c '! grep -Eq "make +sm-toolchain-check" <<<"$1"' _ "$job"
# shellcheck disable=SC2016 # expands in the child shell
expect "ci: system-manager-build does not call docker-run" \
	bash -c '! grep -Eq "docker-run" <<<"$1"' _ "$job"
# The container's /src is root-owned (only the copied files are the image
# user's), so the job must point SM_OUT under the container's $TMPDIR, and the
# container's shell, not the runner's, must expand it. Behavioural: take the
# arguments the step hands in-toolchain-image.sh, compose them as the wrapper
# does (`sh -c "$guard; $*"`), and run them where sm-toolchain-check.sh is a
# stub that records SM_OUT and fails. The old `sh -c 'SM_OUT=...' script` form
# ran only the assignment, exited 0 and never ran the script.
step_line=$(grep -F 'scripts/in-toolchain-image.sh' <<<"$job" | head -n1)
expect "ci: system-manager-build has one in-toolchain-image.sh call" [ -n "$step_line" ]
wrapper_guard=$(awk '/^guard=/' "$ROOT/scripts/in-toolchain-image.sh")
# shellcheck disable=SC2016 # the literal text of the wrapper
expect "in-toolchain-image.sh composes sh -c \"\$guard; \$*\"" \
	grep -Fq 'sh -c "$guard; $*"' "$ROOT/scripts/in-toolchain-image.sh"
cap="$TMP_ROOT/cap"
croot="$TMP_ROOT/croot"
mkdir -p "$cap/scripts" "$croot/scripts" "$TMP_ROOT/ctmp"
# shellcheck disable=SC2016 # the stub's own text
printf '#!/bin/bash\nprintf "%%s\\0" "$@" >"$ARGS_OUT"\n' >"$cap/scripts/in-toolchain-image.sh"
# shellcheck disable=SC2016 # the stub's own text
printf '#!/bin/sh\necho "stub sm-toolchain-check ran SM_OUT=$SM_OUT"\nexit 1\n' >"$croot/scripts/sm-toolchain-check.sh"
chmod +x "$cap/scripts/in-toolchain-image.sh" "$croot/scripts/sm-toolchain-check.sh"
# shellcheck disable=SC2016 # expands in the child shell
run bash -c 'cd "$1" && ARGS_OUT="$2" TOOLCHAIN_IMAGE=img bash -c "$3"' _ "$cap" "$TMP_ROOT/args" "$step_line"
check "ci: the system-manager-build step line runs" 0 ""
# shellcheck disable=SC2016 # expands in the child shell
run bash -c '
	mapfile -d "" -t a <"$1"
	eval "$2"
	shift_args=("${a[@]:1}")
	cd "$3" && TMPDIR="$4" sh -c "$guard; ${shift_args[*]}"
' _ "$TMP_ROOT/args" "$wrapper_guard" "$croot" "$TMP_ROOT/ctmp"
check "ci: system-manager-build runs sm-toolchain-check.sh and its failure reaches the step" nonzero "stub sm-toolchain-check ran SM_OUT=$TMP_ROOT/ctmp/system-manager"

finish
