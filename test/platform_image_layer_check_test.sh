#!/usr/bin/env bash
# Offline checks of scripts/platform-image-layer-check.sh (provisional default,
# pending the owner's answer on #14): a stub layer tree in a mktemp dir outside
# the clone and a stub template. No network, no Yocto.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

script=$ROOT/scripts/platform-image-layer-check.sh
tmp=$TMP_ROOT
d=$tmp/d
repo=$tmp/repo

cat >"$tmp/template" <<'EOF'
# comment with ##FETCH_DIR##/sources/ignored in it
BBLAYERS ?= " \
  ##FETCH_DIR##/sources/openembedded-core/meta \
  ##FETCH_DIR##/sources/meta-a \
  ##FETCH_DIR##/sources/meta-b \
  ##REPO_DIR##/platform-image \
"
EOF

# mklayer PATH COLLECTION [DEPENDS] [COMPAT]
mklayer() {
	mkdir -p "$1/conf"
	{
		echo "BBPATH .= \":\${LAYERDIR}\""
		echo "BBFILE_COLLECTIONS += \"$2\""
		echo "LAYERDEPENDS_$2 = \"${3:-core}\""
		echo "LAYERSERIES_COMPAT_$2 = \"${4:-testseries}\""
	} >"$1/conf/layer.conf"
}

build_tree() {
	rm -rf "$d" "$repo"
	mkdir -p "$d/sources/openembedded-core/meta/conf"
	cat >"$d/sources/openembedded-core/meta/conf/layer.conf" <<'EOF'
BBFILE_COLLECTIONS += "core"
LAYERSERIES_CORENAMES = "testseries"
LAYERSERIES_COMPAT_core = "testseries"
EOF
	mklayer "$d/sources/meta-a" a "core (>= 3)"
	mklayer "$d/sources/meta-b" b "core a:2" "oldseries \\
  testseries"
	mklayer "$repo/platform-image" repo "core b"
}

runc() {
	run env PLATFORM_IMAGE_BBLAYERS_TEMPLATE="$tmp/template" PLATFORM_IMAGE_REPO_DIR="$repo" bash "$script" "${1:-$d}"
}

build_tree
runc
check "a consistent tree passes" 0 "layer-check: OK (4 layers, 4 collections, series testseries)"
expect_out "a version constraint is reported as a note" "version constraint is not enforced" || true
expect_out "the (>= N) spelling is read as a constraint on core, not a collection" "depends on core:3" || true

rm "$d/sources/meta-a/conf/layer.conf"
runc
check "a listed layer without conf/layer.conf fails and names it" 1 "layer sources/meta-a has no conf/layer.conf"

build_tree
mklayer "$d/sources/meta-b" b "core nothere"
runc
check "an unmet LAYERDEPENDS fails and names layer and collection" 1 "layer sources/meta-b (collection b)" "collection nothere"

build_tree
mklayer "$d/sources/meta-a" a core "oldseries"
runc
check "a series outside LAYERSERIES_COMPAT fails and names layer and series" 1 "layer sources/meta-a (collection a)" "does not include series testseries"

build_tree
mklayer "$repo/platform-image" repo core "oldseries"
runc
check "the repository's own layer is checked too" 1 "layer platform-image (collection repo)"

build_tree
: >"$d/sources/openembedded-core/meta/conf/layer.conf"
runc
check "no LAYERSERIES_CORENAMES fails" 1 "no LAYERSERIES_CORENAMES"

runc "$tmp/no-such-dir"
check "no fetched tree fails and says to fetch" 1 "run make platform-image-fetch first"

finish
