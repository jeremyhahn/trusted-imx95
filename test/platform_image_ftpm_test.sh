#!/usr/bin/env bash
# Offline checks of the firmware TPM image configuration (proposed, pending owner
# approval, SPEC row ftpm, issue #140): the revision pins match
# docs/secure-world/build.md, NV is on REE FS with RPMB off, and the debug image
# alone carries tpm2-tools.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

odir=$ROOT/platform-image/recipes-security/optee
ftpm_bb=$odir/optee-ftpm_4.10.0.bb
os_app=$odir/optee-os_%.bbappend
kit_app=$odir/optee-os-tadevkit_%.bbappend
flags=$odir/optee-ftpm-flags.inc
bsp=$ROOT/secure-world/bsp.lock
swdoc=$ROOT/docs/secure-world/build.md
img=$ROOT/platform-image/recipes-core/images/trusted-imx95-image.bb
dbg=$ROOT/platform-image/recipes-core/images/trusted-imx95-image-debug.bb
doc=$ROOT/docs/ftpm/build.md

# has FILE STRING: FILE contains STRING (fixed text, comments included).
has() {
	local t
	t=$(<"$1")
	[[ $t == *"$2"* ]]
}
# nc FILE REGEX: a non-comment line of FILE matches REGEX (extended).
nc() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '' | '#'*) continue ;; esac
		[[ $l =~ $2 ]] && return 0
	done <"$1"
	return 1
}
# ncstr FILE STRING: a non-comment line of FILE contains STRING.
ncstr() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '' | '#'*) continue ;; esac
		[[ $l == *"$2"* ]] && return 0
	done <"$1"
	return 1
}
# lockval NAME: the value of NAME in secure-world/bsp.lock.
lockval() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in "$1="*) printf '%s\n' "${l#*=}"; return 0 ;; esac
	done <"$bsp"
	return 1
}
# none STRING FILE...: no FILE contains STRING.
none() {
	local s=$1 f
	shift
	for f in "$@"; do
		! has "$f" "$s" || return 1
	done
}
# tree_none STRING DIR: no tracked file under DIR contains STRING.
tree_none() {
	local f
	while IFS= read -r f; do
		! has "$ROOT/$f" "$1" || return 1
	done < <(git -C "$ROOT" ls-files -co --exclude-standard "$2")
}

for f in "$ftpm_bb" "$os_app" "$kit_app" "$flags"; do
	expect "exists: ${f#"$ROOT"/}" test -s "$f"
done

ftpm_rev=$(lockval FTPM_COMMIT)
mstpm_rev=$(lockval MSTPM_COMMIT)
expect "optee-ftpm pins optee_ftpm at the bsp.lock commit" nc "$ftpm_bb" "^SRCREV_ftpm = \"$ftpm_rev\""
expect "optee-ftpm pins ms-tpm-20-ref at the bsp.lock commit" nc "$ftpm_bb" "^SRCREV_mstpm = \"$mstpm_rev\""
expect "docs/secure-world/build.md names the same optee_ftpm commit" has "$swdoc" "$ftpm_rev"
expect "docs/secure-world/build.md names the same ms-tpm-20-ref commit" has "$swdoc" "$mstpm_rev"
expect "no floating revision (no AUTOREV)" none AUTOREV "$ftpm_bb"

expect "optee-os: early TAs on" ncstr "$os_app" 'CFG_EARLY_TA=y'
expect "optee-os: EARLY_TA_PATHS names the fTPM TA UUID" nc "$os_app" 'EARLY_TA_PATHS=.*\$\{FTPM_TA_UUID\}'
expect "the fTPM TA UUID is the one the secure-world doc gives" ncstr "$os_app" 'FTPM_TA_UUID = "bc50d971-d4c9-42c4-82cb-343fb7f37896"'
expect "REE FS on" ncstr "$flags" 'CFG_REE_FS=y'
expect "RPMB FS off" ncstr "$flags" 'CFG_RPMB_FS=n'
expect "optee-os takes the shared flags" ncstr "$os_app" 'optee-ftpm-flags.inc'
expect "the TA dev kit takes the shared flags" ncstr "$kit_app" 'optee-ftpm-flags.inc'
expect "the TA stores its NV in REE FS explicitly" ncstr "$ftpm_bb" 'CFG_FTPM_TA_TEE_STORAGE_ID=TEE_STORAGE_PRIVATE_REE'
expect "measured boot stays off" none CFG_TA_MEASURED_BOOT=y "$ftpm_bb" "$os_app" "$flags"

# The RPMB key is never programmed or enabled by this layer or its docs. The
# option name is assembled so this file does not itself carry it.
opt="RPMB_WRITE""_KEY"
expect "no RPMB key option in platform-image" tree_none "$opt" platform-image
expect "no RPMB key option in docs/ftpm" tree_none "$opt" docs/ftpm
expect "CFG_RPMB_FS=y appears nowhere in platform-image" tree_none 'CFG_RPMB_FS=y' platform-image

# tpm2-tools: the debug image only.
expect "the debug image installs tpm2-tools" nc "$dbg" 'IMAGE_INSTALL.*tpm2-tools'
expect "the production image does not name tpm2-tools" none tpm2-tools "$img"

# The documentation: exists, marks its defaults provisional, no internal detail.
expect "docs/ftpm/build.md exists" test -s "$doc"
expect "docs/ftpm/build.md says provisional" has "$doc" 'rovisional'
expect "docs/ftpm/build.md links to the fTPM design" has "$doc" 'README.md'
expect "docs/ftpm/README.md points to build.md" has "$ROOT/docs/ftpm/README.md" '(build.md)'
expect "docs/platform-image/build.md points to docs/ftpm/build.md" has "$ROOT/docs/platform-image/build.md" 'ftpm/build.md'
expect "docs/ftpm/build.md names no /home path" none '/home/' "$doc"

finish
