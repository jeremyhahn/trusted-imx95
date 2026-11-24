#!/usr/bin/env bash
# The secure-world row end to end through make, in a fixture copy of the
# repository (make integration-test-secure-world): the committed
# secure-world/bsp.lock checks, and make refuses, before anything is fetched,
# a lock that breaks owner ruling 771 (docs/SPEC.md, secure-world row): NXP's
# imx-atf for BL31, a TF-A pin that is not an upstream release tag, or an
# OP-TEE OS that is not NXP's BSP OP-TEE. Offline; runs as uid 10001 on a
# read-only root in the integration image.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

repo="$TMP_ROOT/repo"
fixture_repo "$repo"
cp -R "$ROOT/secure-world" "$repo/"
git -C "$repo" add -A secure-world

run make -s -C "$repo" secure-world-check-lock
check "make secure-world-check-lock: the committed lock holds ruling 771" 0 \
	"bsp.lock OK" "lf-6.18.37-2.1.0" "TF-A v2.15.0 da738d5eae93"

# badlock <name> <from> <to>: a copy of the lock with the one line <from>
# replaced by <to>; prints its path.
badlock() {
	local f="$TMP_ROOT/$1.lock" line
	: >"$f"
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$line" = "$2" ]; then printf '%s\n' "$3"; else printf '%s\n' "$line"; fi
	done <"$repo/secure-world/bsp.lock" >"$f"
	printf '%s\n' "$f"
}
tfa_repo=TFA_REPO=https://github.com/ARM-software/arm-trusted-firmware.git
optee_repo=OPTEE_REPO=https://github.com/nxp-imx/imx-optee-os.git

for c in \
	"imxatf|$tfa_repo|TFA_REPO=https://github.com/nxp-imx/imx-atf.git|is not upstream Arm TF-A" \
	"rctag|TFA_TAG=v2.15.0|TFA_TAG=v2.15.0-rc0|is not an upstream release tag" \
	"upoptee|$optee_repo|OPTEE_REPO=https://github.com/OP-TEE/optee_os.git|is not NXP's BSP OP-TEE"; do
	IFS='|' read -r name from to want <<<"$c"
	lock=$(badlock "$name" "$from" "$to")
	run make -s -C "$repo" secure-world-check-lock SW_LOCK="$lock"
	check "make secure-world-check-lock: a lock with $name is refused" nonzero "$want" "owner ruling 771"
	# make secure-world stops at the lock: no work directory, nothing published.
	run make -s -C "$repo" secure-world SW_LOCK="$lock" \
		SW_WORK="$TMP_ROOT/$name/work" SW_OUT="$TMP_ROOT/$name/out" SW_CACHE="$TMP_ROOT/$name/cache"
	check "make secure-world: a lock with $name stops before any fetch" nonzero "$want"
	expect "make secure-world with $name makes no work directory and publishes nothing" \
		test ! -e "$TMP_ROOT/$name/work" -a ! -e "$TMP_ROOT/$name/out"
done

finish
