#!/usr/bin/env bash
# The recipe text holds literal ${...} expressions; the single quotes are meant.
# shellcheck disable=SC2016
# Static check of the xkmsd recipe (docs/SPEC.md, `platform-image`: "It runs
# xkmsd from go-xkms on its Linux side") and of the production image that
# installs it. No bitbake, no network.
set -u
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

recipe_rel=platform-image/recipes-security/xkmsd/xkmsd_git.bb
image_rel=platform-image/recipes-core/images/trusted-imx95-image.bb

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "$TMP_ROOT"' EXIT

# val FILE NAME: the value of the first active `NAME = "value"` line.
val() {
	local f=$1 name=$2 l v
	while IFS= read -r l; do
		case $l in "$name = \""*'"')
			v=${l#"$name = \""}
			printf '%s' "${v%\"}"
			return 0
			;;
		esac
	done <"$f"
	return 1
}

# has FILE TEXT: an active (not comment) line holds TEXT.
has() {
	local l s
	while IFS= read -r l; do
		s=${l#"${l%%[![:space:]]*}"}
		case $s in '#'*) continue ;; esac
		case $l in *"$2"*) return 0 ;; esac
	done <"$1"
	return 1
}

# recipe_ok FILE: a tagged go-xkms release, its commit, the PV of the tag,
# AGPL-3.0-only, a sha256-checked Go archive, the pinned toolchain only,
# modules verified against go.sum, aarch64 only, the binary packaged.
recipe_ok() {
	local f=$1 tag pv rev sha
	tag=$(val "$f" XKMS_TAG) || { echo "no XKMS_TAG"; return 1; }
	[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "XKMS_TAG '$tag' is not a release tag"; return 1; }
	pv=$(val "$f" PV) || { echo "no PV"; return 1; }
	[ "$pv" = "${tag#v}" ] || { echo "PV '$pv' is not the tag '$tag' without its v"; return 1; }
	rev=$(val "$f" SRCREV) || { echo "no SRCREV"; return 1; }
	[[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo "SRCREV '$rev' is not a full commit"; return 1; }
	[ "$(val "$f" LICENSE)" = AGPL-3.0-only ] || { echo "LICENSE is not AGPL-3.0-only"; return 1; }
	has "$f" 'git://github.com/jeremyhahn/go-xkms;' || { echo "SRC_URI is not go-xkms"; return 1; }
	has "$f" 'nobranch=1;tag=${XKMS_TAG}' || { echo "SRC_URI does not pin the tag"; return 1; }
	if has "$f" 'branch=' && ! has "$f" 'nobranch=1'; then echo "SRC_URI follows a branch"; return 1; fi
	sha=$(val "$f" 'SRC_URI[go.sha256sum]') || { echo "no Go archive sha256"; return 1; }
	[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "Go archive sha256 '$sha' is malformed"; return 1; }
	has "$f" 'export GOTOOLCHAIN=local' || { echo "go may fetch another toolchain"; return 1; }
	has "$f" 'go mod verify' || { echo "modules are not verified"; return 1; }
	has "$f" '-mod=readonly' || { echo "go.mod may be rewritten"; return 1; }
	[ "$(val "$f" COMPATIBLE_HOST)" = 'aarch64.*-linux' ] || { echo "COMPATIBLE_HOST is not aarch64 Linux"; return 1; }
	[ "$(val "$f" 'FILES:${PN}')" = '${bindir}/xkmsd' ] || { echo "the package does not hold \${bindir}/xkmsd"; return 1; }
	return 0
}

# image_ok FILE: an active IMAGE_INSTALL line installs xkmsd (a word, not a
# substring of another package name).
image_ok() {
	local l v w
	while IFS= read -r l; do
		case $l in '#'*) continue ;; esac
		[[ $l =~ ^IMAGE_INSTALL(:append)?\ *[+]?=\ *\"([^\"]*)\" ]] || continue
		v=${BASH_REMATCH[2]}
		for w in $v; do [ "$w" != xkmsd ] || return 0; done
	done <"$1"
	echo "$1 does not install xkmsd"
	return 1
}

t() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
}
neg() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then fail "$name" "expected a failure"; else pass "$name ($out)"; fi
}

t "the xkmsd recipe" recipe_ok "$ROOT/$recipe_rel"
t "the production image installs xkmsd" image_ok "$ROOT/$image_rel"

r0=$(<"$ROOT/$recipe_rel")
rcopy() { # FROM TO NAME: a copy of the recipe with FROM replaced by TO
	printf '%s\n' "${r0//"$1"/"$2"}" >"$scratch/$3.bb"
	printf '%s' "$scratch/$3.bb"
}
neg "negative: PV is not the tag" recipe_ok "$(rcopy 'PV = "0.64.2-alpha"' 'PV = "0.64.1"' pv)"
neg "negative: short SRCREV" recipe_ok "$(rcopy 'SRCREV = "9f040cea0e06a2afd3233d0e669885249f49c4c2"' 'SRCREV = "9f040cea"' rev)"
neg "negative: branch tag" recipe_ok "$(rcopy 'XKMS_TAG = "v0.64.2-alpha"' 'XKMS_TAG = "main"' tag)"
neg "negative: other license" recipe_ok "$(rcopy 'LICENSE = "AGPL-3.0-only"' 'LICENSE = "MIT"' lic)"
neg "negative: no tag in SRC_URI" recipe_ok "$(rcopy 'nobranch=1;tag=${XKMS_TAG}' 'branch=main' src)"
neg "negative: malformed Go sha256" recipe_ok "$(rcopy '65efbc80' 'zz' sha)"
neg "negative: GOTOOLCHAIN not local" recipe_ok "$(rcopy 'export GOTOOLCHAIN=local' 'export GOTOOLCHAIN=auto' tc)"
neg "negative: no go mod verify" recipe_ok "$(rcopy 'go mod verify' 'true' verify)"
neg "negative: any host" recipe_ok "$(rcopy 'COMPATIBLE_HOST = "aarch64.*-linux"' 'COMPATIBLE_HOST = ".*-linux"' host)"
neg "negative: verify only in a comment" recipe_ok "$(rcopy '    go mod verify' '    # go mod verify' cverify)"

printf '%s\n' 'IMAGE_INSTALL = "packagegroup-core-boot ${CORE_IMAGE_EXTRA_INSTALL}"' >"$scratch/noxkmsd.bb"
neg "negative: image without xkmsd" image_ok "$scratch/noxkmsd.bb"
printf '%s\n' '# IMAGE_INSTALL = "packagegroup-core-boot xkmsd"' 'IMAGE_INSTALL = "packagegroup-core-boot"' >"$scratch/comment.bb"
neg "negative: xkmsd only in a comment" image_ok "$scratch/comment.bb"
printf '%s\n' 'IMAGE_INSTALL = "packagegroup-core-boot xkmsd-tools"' >"$scratch/prefix.bb"
neg "negative: another package named xkmsd-*" image_ok "$scratch/prefix.bb"
printf '%s\n' 'IMAGE_INSTALL:append = " xkmsd"' >"$scratch/append.bb"
t "an IMAGE_INSTALL:append installs xkmsd" image_ok "$scratch/append.bb"

finish
