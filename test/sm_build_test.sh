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

finish
