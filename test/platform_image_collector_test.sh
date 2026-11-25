#!/usr/bin/env bash
# test/platform_image_collector_test.sh: static checks (no bitbake) of the opt-in
# collector recipe platform-image/recipes-core/device-lifecycle/. Negatives run
# on copies under mktemp; nothing is written under the repo.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PI="$ROOT/platform-image"
REL=recipes-core/device-lifecycle/trusted-imx95-collect-evidence_1.0.bb
NAME=trusted-imx95-collect-evidence

# check_recipe LAYERDIR: prints the problems found, one per line; empty is clean.
check_recipe() {
	local pi=$1 rec=$1/$REL f
	[ -f "$rec" ] || { echo "recipe missing"; return; }
	# the layer's BBFILES pattern: recipes-*/*/*.bb
	case "$REL" in recipes-*/*/*.bb) ;; *) echo "recipe not matched by the BBFILES pattern" ;; esac
	grep -qE '^BBFILES[[:space:]]*\+=.*recipes-\*/\*/\*\.bb"' "$pi/conf/layer.conf" || echo "layer.conf lacks the BBFILES line"
	# SRC_URI: file:// only
	grep -E '^SRC_URI' "$rec" | grep -qE '[a-z]+://' || echo "no SRC_URI entry"
	if grep -E '^SRC_URI' "$rec" | grep -oE '[A-Za-z][A-Za-z0-9+.-]*://' | grep -vqx 'file://'; then
		echo "SRC_URI has a scheme other than file"
	fi
	grep -qE 'install -m 0755 .*collect-evidence\.sh .*\$\{D\}\$\{sbindir\}' "$rec" || echo "script not installed at 0755 in sbindir"
	grep -E '^RDEPENDS:\$\{PN\}' "$rec" | grep -qE '"([^"]* )?bash( [^"]*)?"' || echo "RDEPENDS lacks bash"
	grep -E '^RDEPENDS:\$\{PN\}' "$rec" | grep -qE '"([^"]* )?coreutils( [^"]*)?"' || echo "RDEPENDS lacks coreutils"
	if grep -E '^ELE_ATTEST_CMD|^ACCEPT_FSL_EULA' "$rec" >/dev/null; then echo "recipe sets ELE_ATTEST_CMD or the EULA"; fi
	# no image installs it
	for f in "$pi"/recipes-core/images/*.bb; do
		if grep -qF "$NAME" "$f"; then echo "no image installs it: $(basename "$f") names it"; fi
	done
	grep -rqF "$NAME" "$pi/conf" && echo "no image installs it: conf names it"
	# every file:// entry of SRC_URI must be found through the recipe's own FILESEXTRAPATHS,
	# with ${THISDIR} taken as the recipe directory
	local fx dirs d uri found
	fx=$(grep -m1 -E '^FILESEXTRAPATHS' "$rec" || true)
	if [ -z "$fx" ]; then
		echo "recipe has no FILESEXTRAPATHS line"
	else
		fx=${fx#*\"}
		fx=${fx%\"*}
		IFS=: read -ra dirs <<<"$fx"
		while IFS= read -r uri; do
			uri=${uri#file://}
			found=0
			for d in "${dirs[@]}"; do
				[ -n "$d" ] || continue
				# shellcheck disable=SC2016  # the text is a literal ${THISDIR}
				d=${d//'${THISDIR}'/$(dirname "$rec")}
				if [ -f "$d/$uri" ]; then found=1; fi
			done
			if [ "$found" -eq 0 ]; then echo "FILESEXTRAPATHS does not reach file://$uri"; fi
		done < <(grep -E '^SRC_URI' "$rec" | grep -oE 'file://[^ "]+' || true)
	fi
	# wrynose OE-Core: file:// sources unpack into UNPACKDIR, and S = WORKDIR is rejected at parse
	while IFS= read -r f; do
		bad_workdir "$f"
	done < <(find "$pi" -name '*.bb' -o -name '*.bbappend' -o -name '*.bbclass' | sort)
	return 0
}

# bad_workdir FILE: prints a problem for each obsolete WORKDIR form in a recipe.
bad_workdir() {
	local f=$1
	if grep -qE '^[[:space:]]*S[[:space:]]*(:=|\?=|=)[[:space:]]*"\$\{WORKDIR\}"' "$f"; then
		echo "S = \"\${WORKDIR}\" is rejected at parse time ($(basename "$f")); use \${UNPACKDIR}"
	fi
	if grep -qE '\$\{WORKDIR\}/[A-Za-z0-9_.-]+\.(sh|conf|service|patch|txt)' "$f"; then
		echo "task reads a fetched file from \${WORKDIR}/ ($(basename "$f")); use \${UNPACKDIR} or \${S}"
	fi
}

problems=$(check_recipe "$PI")
if [ -z "$problems" ]; then pass "collector recipe passes every check"; else fail "collector recipe checks" "$problems"; fi

# the installed file is the repository's script
expect "the script the recipe installs exists in the repository" test -f "$ROOT/scripts/device-lifecycle/collect-evidence.sh"

# negatives: each broken copy must be reported
neg() { # name file-relative-to-layer sed-expression
	local b d out
	# the copy sits beside a copy of scripts/, so ${THISDIR}/../../../scripts resolves as in the repository
	b=$(mktemp -d "$TMP_ROOT/pi.XXXXXX")
	d=$b/platform-image
	mkdir -p "$d" "$b/scripts"
	cp -R "$PI/." "$d/"
	cp -R "$ROOT/scripts/device-lifecycle" "$b/scripts/"
	sed -E -i "$3" "$d/$2"
	out=$(check_recipe "$d")
	if [ -n "$out" ]; then pass "negative: $1"; else fail "negative: $1 was not caught"; fi
}
neg "an image installs it (IMAGE_INSTALL)" recipes-core/images/trusted-imx95-image.bb "s/^(IMAGE_INSTALL = \"[^\"]*)\"/\1 $NAME\"/"
neg "the debug image names it" recipes-core/images/trusted-imx95-image-debug.bb "\$a CORE_IMAGE_EXTRA_INSTALL += \"$NAME\""
neg "install mode 0644" "$REL" 's/install -m 0755/install -m 0644/'
neg "https SRC_URI" "$REL" 's|^SRC_URI = .*|SRC_URI = "https://example.invalid/collect-evidence.sh"|'
neg "RDEPENDS drops bash" "$REL" 's/^(RDEPENDS:\$\{PN\} = ")bash /\1/'
neg "RDEPENDS drops coreutils" "$REL" 's/ coreutils//'
neg "BBFILES line removed" conf/layer.conf '/^BBFILES \+= .*\*\.bb"$/d'
# shellcheck disable=SC2016  # the sed text carries a literal ${WORKDIR}
neg "S = WORKDIR" "$REL" 's|^S = .*|S = "${WORKDIR}"|'
# shellcheck disable=SC2016
neg "install reads from WORKDIR" "$REL" 's|\$\{S\}/collect-evidence|${WORKDIR}/collect-evidence|'
neg "FILESEXTRAPATHS line deleted" "$REL" '/^FILESEXTRAPATHS/d'
neg "FILESEXTRAPATHS points at a wrong directory" "$REL" 's|/scripts/device-lifecycle:|/scripts/nowhere:|'

finish
