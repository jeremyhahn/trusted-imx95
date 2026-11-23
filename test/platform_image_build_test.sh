#!/usr/bin/env bash
# Offline checks of scripts/platform-image-build.sh (provisional default,
# pending the owner's answer on #14): a stub fetcher and a stub bitbake on PATH,
# in a mktemp dir outside the clone. No network, no Yocto, no EULA acceptance.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILS=0
export LC_ALL=C

script=$ROOT/scripts/platform-image-build.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_bash=$(command -v bash)

tools=$tmp/tools
mkdir -p "$tools" "$tmp/stub"
for t in env sed cp mkdir dirname basename cat rm tee sort sha256sum ln; do
	ln -s "$(command -v "$t")" "$tools/$t"
done

cat >"$tmp/fetch" <<'EOF'
#!/bin/sh
mkdir -p "$2/sources/openembedded-core" "$2/sources/bitbake"
: >"$2/sources/openembedded-core/oe-init-build-env"
EOF
chmod +x "$tmp/fetch"
# Stub bitbake: `-m` logs a kill; `-e` prints DEPLOY_DIR_IMAGE; anything else is
# the build: it logs its arguments, then either fails with EULA errors
# (BB_EULA) or writes artefacts of content BB_CONTENT into BB_DEPLOY.
cat >"$tmp/stub/bitbake" <<'EOF'
#!/bin/sh
case $1 in
-m) echo kill >>"$BB_KILL_LOG" ;;
-e) echo "DEPLOY_DIR_IMAGE=\"$BB_DEPLOY\"" ;;
*)
	echo "$*" >>"$BB_LOG"
	if [ -n "${BB_EULA:-}" ]; then
		echo "ERROR: imx-firmware-8.25-r0 do_fetch: requires ACCEPT_FSL_EULA to be set" >&2
		echo "ERROR: firmware-imx-8.25-r0 do_fetch: requires ACCEPT_FSL_EULA to be set" >&2
		echo "ERROR: firmware-imx-8.25-r0 do_fetch: requires ACCEPT_FSL_EULA to be set" >&2
		exit 1
	fi
	[ -z "${BB_FAIL:-}" ] || { echo "ERROR: do_compile failed" >&2; exit 1; }
	mkdir -p "$BB_DEPLOY"
	[ -n "${BB_EMPTY:-}" ] && exit 0
	for f in trusted-imx95-image.wic.zst Image imx95-frdm.dtb trusted-imx95-image.tar.zst trusted-imx95-image.manifest; do
		printf '%s\n' "$BB_CONTENT$f" >"$BB_DEPLOY/$f"
	done
	ln -sf Image "$BB_DEPLOY/Image-link"
	;;
esac
EOF
chmod +x "$tmp/stub/bitbake"

run() { # OUT [env...]: a fresh build dir; sets rc and out
	rm -rf "$tmp/d" "$tmp/deploy" "$tmp/log" "$tmp/kill"
	rc=0
	out=$(PATH=$tmp/stub:$tools PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_KILL_LOG=$tmp/kill \
		BB_DEPLOY=$tmp/deploy BB_CONTENT=${BB_CONTENT-same-} "$real_bash" "$script" "$tmp/d" "$1" 2>&1) || rc=$?
}

run "$tmp/out1"
expect "a clean stub build passes" test "$rc" -eq 0
expect "both image targets were built" test "$(cat "$tmp/log")" = "trusted-imx95-image trusted-imx95-image-debug"
expect "the digest manifest is written" test -s "$tmp/out1/SHA256SUMS"
expect "the manifest lists the four artefact kinds" test "$(sed -n 's/^[0-9a-f]*  //p' "$tmp/out1/SHA256SUMS" | tr '\n' ' ')" = "Image imx95-frdm.dtb trusted-imx95-image.tar.zst trusted-imx95-image.wic.zst "
expect "the manifest is a valid sha256sum file" sh -c "cd '$tmp/deploy' && sha256sum -c '$tmp/out1/SHA256SUMS' >/dev/null"
expect "the server is stopped on exit" test "$(cat "$tmp/kill")" = kill

# EULA failure: nonzero, names each recipe once, says the owner has not accepted.
BB_EULA=1 run "$tmp/out2"
expect "an EULA stop exits nonzero" test "$rc" -ne 0
expect "an EULA stop names firmware-imx" test "${out##*recipe: firmware-imx*}" != "$out"
expect "an EULA stop names imx-firmware" test "${out##*recipe: imx-firmware*}" != "$out"
expect "an EULA stop says the owner has not accepted the EULA" test "${out##*owner has not accepted the NXP EULA*}" != "$out"
expect "an EULA stop lists a repeated recipe once" test "$(printf '%s\n' "$out" | sed -n '/recipe: firmware-imx$/p' | sed -n '$=')" = 1
expect "an EULA stop writes no manifest" test ! -e "$tmp/out2/SHA256SUMS"
BB_FAIL=1 run "$tmp/out2"
expect "another build failure exits nonzero" test "$rc" -ne 0
expect "another build failure is not called an EULA stop" test "${out##*EULA-gated*}" = "$out"

BB_EMPTY=1 run "$tmp/out2"
expect "a build with no artefacts fails" test "$rc" -ne 0

# The EULA is never set: not in the generated confs, not from the environment.
run "$tmp/out1"
set_in_conf=0
for f in "$tmp/d/build/conf/local.conf" "$tmp/d/build/conf/bblayers.conf"; do
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; *ACCEPT_FSL_EULA*) set_in_conf=1 ;; esac
	done <"$f"
done
expect "no generated conf sets ACCEPT_FSL_EULA" test "$set_in_conf" -eq 0
rc=0
out=$(ACCEPT_FSL_EULA=1 PATH=$tmp/stub:$tools PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_KILL_LOG=$tmp/kill \
	BB_DEPLOY=$tmp/deploy BB_CONTENT=x "$real_bash" "$script" "$tmp/d" "$tmp/out3" 2>&1) || rc=$?
expect "ACCEPT_FSL_EULA in the environment is refused" test "$rc" -ne 0
expect "the refusal says why" test "${out##*does not accept the NXP EULA*}" != "$out"
run "$tmp/out1"
printf 'ACCEPT_FSL_EULA = "1"\n' >>"$tmp/d/build/conf/local.conf"
rc=0
out=$(PATH=$tmp/stub:$tools PLATFORM_IMAGE_FETCH=$tmp/fetch BB_LOG=$tmp/log BB_KILL_LOG=$tmp/kill \
	BB_DEPLOY=$tmp/deploy BB_CONTENT=x "$real_bash" "$script" "$tmp/d" "$tmp/out3" 2>&1) || rc=$?
expect "a local.conf that sets the EULA differs from the template and is refused" test "$rc" -ne 0
expect "the script has no EULA switch: no assignment of the variable" test -z "$(sed -n '/^[^#]*ACCEPT_FSL_EULA *=/p' "$script")"

# Reproducibility: identical outputs give identical manifests; a change shows.
run "$tmp/outA"
run "$tmp/outB"
expect "two builds with identical outputs give identical manifests" cmp -s "$tmp/outA/SHA256SUMS" "$tmp/outB/SHA256SUMS"
BB_CONTENT=other- run "$tmp/outC"
expect "a differing output changes the manifest" test "$rc" -eq 0 -a "$(cat "$tmp/outC/SHA256SUMS")" != "$(cat "$tmp/outA/SHA256SUMS")"

# OUT inside the clone is refused before anything is created.
inside=$ROOT/.build-test-inside-$$
run "$inside"
expect "an out directory inside the clone is refused" test "$rc" -ne 0
expect "it says so" test "${out##*is inside this clone*}" != "$out"
expect "nothing is created in the clone" test ! -e "$inside"

finish
