#!/usr/bin/env bash
# The secure-world row end to end through make, in a fixture copy of the
# repository (make integration-test-secure-world): the committed
# secure-world/bsp.lock checks, and make refuses, before anything is fetched,
# a lock that breaks owner rulings 771 and 1234 (docs/SPEC.md, secure-world
# row): a BL31 source that is neither upstream Arm TF-A nor NXP's imx-atf, a
# TF-A pin whose tag is not that source's release tag, or an OP-TEE OS that is
# not NXP's BSP OP-TEE. Offline; runs as uid 10001 on a
# read-only root in the integration image.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

repo="$TMP_ROOT/repo"
fixture_repo "$repo"
cp -R "$ROOT/secure-world" "$repo/"
# The lock check also reads the System Manager's DDR EXEC grant.
mkdir -p "$repo/system-manager"
cp "$ROOT/system-manager/ap-s-grants.txt" "$repo/system-manager/"
git -C "$repo" add -A secure-world system-manager

run make -s -C "$repo" secure-world-check-lock
check "make secure-world-check-lock: the committed lock holds rulings 771 and 1234" 0 \
	"bsp.lock OK" "lf-6.18.37-2.1.0" "TF-A lf-6.18.37-2.1.0 af9eb2c1748e"

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
tfa_repo=TFA_REPO=https://github.com/nxp-imx/imx-atf.git
tfa_tag=TFA_TAG=lf-6.18.37-2.1.0
optee_repo=OPTEE_REPO=https://github.com/nxp-imx/imx-optee-os.git

for c in \
	"forkrepo|$tfa_repo|TFA_REPO=https://github.com/example/atf.git|is neither upstream Arm TF-A nor NXP's imx-atf" \
	"rctag|$tfa_tag|TFA_TAG=lf-6.18.37-rc0|is not an imx-atf release tag" \
	"uptag|$tfa_tag|TFA_TAG=v2.15.0|is not an imx-atf release tag" \
	"upoptee|$optee_repo|OPTEE_REPO=https://github.com/OP-TEE/optee_os.git|is not NXP's BSP OP-TEE"; do
	IFS='|' read -r name from to want <<<"$c"
	lock=$(badlock "$name" "$from" "$to")
	run make -s -C "$repo" secure-world-check-lock SW_LOCK="$lock"
	check "make secure-world-check-lock: a lock with $name is refused" nonzero "$want" "owner ruling"
	# make secure-world stops at the lock: no work directory, nothing published.
	run make -s -C "$repo" secure-world SW_LOCK="$lock" \
		SW_WORK="$TMP_ROOT/$name/work" SW_OUT="$TMP_ROOT/$name/out" SW_CACHE="$TMP_ROOT/$name/cache"
	check "make secure-world: a lock with $name stops before any fetch" nonzero "$want"
	expect "make secure-world with $name makes no work directory and publishes nothing" \
		test ! -e "$TMP_ROOT/$name/work" -a ! -e "$TMP_ROOT/$name/out"
done

finish
