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
	return 0
}

problems=$(check_recipe "$PI")
if [ -z "$problems" ]; then pass "collector recipe passes every check"; else fail "collector recipe checks" "$problems"; fi

# the installed file is the repository's script
expect "the script the recipe installs exists in the repository" test -f "$ROOT/scripts/device-lifecycle/collect-evidence.sh"
expect "FILESEXTRAPATHS reaches scripts/device-lifecycle from the recipe directory" \
	test -f "$PI/recipes-core/device-lifecycle/../../../scripts/device-lifecycle/collect-evidence.sh"

# negatives: each broken copy must be reported
neg() { # name file-relative-to-layer sed-expression
	local d out
	d=$(mktemp -d "$TMP_ROOT/pi.XXXXXX")
	cp -R "$PI/." "$d/"
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

finish
