#!/usr/bin/env bash
# Unit tests of scripts/hdp-boundary-check.py: the repository keeps the
# hsm-device-protocol row, and fixture trees that break each check (B1 to B5)
# fail with the check named. Offline; writes only under $TMP_ROOT.
# The recipe fixtures hold ${VAR} text that must reach the .bb file unexpanded.
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHK="$ROOT/scripts/hdp-boundary-check.py"

# A tree holding the files the check reads, copied from the repository.
tree() {
	mkdir -p "$1/docs/references"
	cp "$ROOT/docs/SPEC.md" "$1/docs/"
	cp "$ROOT/docs/references/README.md" "$1/docs/references/"
	cp -R "$ROOT/docs/hsm-device-protocol" "$1/docs/"
}

run python3 "$CHK" "$ROOT"
check "the repository keeps the hsm-device-protocol row" 0 \
	"ok B1 row" "ok B2 missing" "ok B3 no-protocol" "ok B4 owner" "ok B5 release" "hdp-boundary-check: OK (5 checks"

t="$TMP_ROOT/good"
tree "$t"
run python3 "$CHK" "$t"
check "a copy of the row's files keeps the row; with no recipe B5 says xkmsd is missing" 0 \
	"no xkmsd recipe yet: missing"

t="$TMP_ROOT/b1"
tree "$t"
python3 - "$t/docs/SPEC.md" <<'EOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read().replace("go-xkms #1521", "go-xkms #1")
open(p, "w", encoding="utf-8").write(s)
EOF
run python3 "$CHK" "$t"
check "B1: a row that drops go-xkms #1521 fails" 1 "FAIL B1 row" "go-xkms #1521 owns the open questions"

t="$TMP_ROOT/b1-gone"
tree "$t"
printf '# spec\n' >"$t/docs/SPEC.md"
run python3 "$CHK" "$t"
check "B1: a SPEC without the row fails" 1 "docs/SPEC.md has no hsm-device-protocol row"

t="$TMP_ROOT/b2"
tree "$t"
printf '# references\n\n| UM12527 | x |\n' >"$t/docs/references/README.md"
run python3 "$CHK" "$t"
check "B2: references that do not list the 10 GbE card documentation as missing fail" 1 \
	"FAIL B2 missing" "10 GbE expansion card documentation as missing"

for f in wire.proto api/openapi.yaml cmd/xkmsd/README go.mod; do
	t="$TMP_ROOT/b3-${f//\//-}"
	tree "$t"
	mkdir -p "$t/$(dirname "$f")"
	: >"$t/$f"
	run python3 "$CHK" "$t"
	check "B3: $f in the tree fails" 1 "FAIL B3 no-protocol" "go-xkms owns"
done

t="$TMP_ROOT/b4"
tree "$t"
printf '# A new trace\n\nNo owner named.\n' >"$t/docs/hsm-device-protocol/new.md"
run python3 "$CHK" "$t"
check "B4: a device-side document that does not name go-xkms #1521 fails" 1 \
	"FAIL B4 owner" "new.md does not name go-xkms #1521"

t="$TMP_ROOT/b5-tag"
tree "$t"
mkdir -p "$t/platform-image/recipes-xkms/xkmsd"
printf 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;tag=v1.2.3;nobranch=1"\nSRCREV = "0123"\n' \
	>"$t/platform-image/recipes-xkms/xkmsd/xkmsd_1.2.3.bb"
run python3 "$CHK" "$t"
check "B5: an xkmsd recipe on a tagged go-xkms release passes" 0 "ok B5 release: xkmsd recipes fetch a tagged go-xkms release"

t="$TMP_ROOT/b5-branch"
tree "$t"
mkdir -p "$t/platform-image/recipes-xkms/xkmsd"
printf '%s\n' 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;branch=main"' "SRCREV = \"\${AUTOREV}\"" \
	>"$t/platform-image/recipes-xkms/xkmsd/xkmsd_git.bb"
run python3 "$CHK" "$t"
check "B5: an xkmsd recipe that follows a branch is a notice, exit 0" 0 \
	"NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry" "follows a branch" \
	"B5 is a notice"

# b5_recipe <name> <recipe text, printf format>: a tree whose xkmsd recipe is that text.
b5_recipe() {
	t="$TMP_ROOT/b5-$1"
	tree "$t"
	mkdir -p "$t/platform-image/recipes-xkms/xkmsd"
	printf '%b' "$2" >"$t/platform-image/recipes-xkms/xkmsd/xkmsd_git.bb"
	run python3 "$CHK" "$t"
}

b5_recipe comment-only 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;branch=main"\n# tag=v1.2.3 is planned\nSRCREV = "0123"\n'
check "B5: tag= only in a comment is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry"

b5_recipe trailing-comment 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;nobranch=1" # tag=v1.2.3\nSRCREV = "0123"\n'
check "B5: tag= only in a trailing comment is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry"

b5_recipe other-var 'XKMS_NOTE = "tag=v1.2.3"\nSRC_URI = "git://example.invalid/go-xkms;protocol=https;nobranch=1"\nSRCREV = "0123"\n'
check "B5: tag= only in another variable is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry"

b5_recipe other-entry 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;nobranch=1 file://x.patch;tag=1"\nSRCREV = "0123"\n'
check "B5: tag= on another SRC_URI entry is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry"

b5_recipe untagged-nobranch 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;nobranch=1"\nSRCREV = "0123456789abcdef"\n'
check "B5: an untagged SRCREV with nobranch=1 is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no tag= in the go-xkms SRC_URI entry"

b5_recipe indirection 'XKMS_URI = "git://example.invalid/go-xkms;tag=v1.2.3;nobranch=1"\nSRC_URI = "${XKMS_URI}"\nSRCREV = "0123"\n'
check "B5: a variable indirection in SRC_URI is a notice, exit 0 as unresolvable" 0 "NOTICE B5 (proposed, pending owner approval)" "variable indirection"

b5_recipe indirection-in-uri 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;tag=${XKMS_TAG};nobranch=1"\nSRCREV = "0123"\n'
check "B5: a variable inside the go-xkms entry is a notice, exit 0 as unresolvable" 0 "NOTICE B5 (proposed, pending owner approval)" "cannot be resolved"

b5_recipe no-fetch 'SRC_URI = "file://x.patch"\nSRCREV = "0123"\n'
check "B5: a recipe with no go-xkms fetch entry is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "no go-xkms fetch entry"

b5_recipe autorev-tagged 'SRC_URI = "git://example.invalid/go-xkms;tag=v1.2.3;nobranch=1"\nSRCREV = "${AUTOREV}"\n'
check "B5: a tag with SRCREV AUTOREV is a notice, exit 0" 0 "NOTICE B5 (proposed, pending owner approval)" "SRCREV is AUTOREV"

b5_recipe continued 'SRC_URI = "file://x.patch \\\\\n    git://example.invalid/go-xkms;protocol=https;tag=v1.2.3;nobranch=1 \\\\\n    file://y.patch"\n# SRCREV = "${AUTOREV}"\nSRCREV = "0123"\n'
check "B5: a tag on a continued SRC_URI line passes; a commented AUTOREV is ignored" 0 "ok B5 release: xkmsd recipes fetch a tagged go-xkms release"

# A B5 violation with B1, B3 and B4 also broken still fails closed.
t="$TMP_ROOT/b5-and-others"
b5_recipe and-others 'SRC_URI = "git://example.invalid/go-xkms;protocol=https;branch=main"\nSRCREV = "0123"\n'
printf '# A new trace\n\nNo owner named.\n' >"$t/docs/hsm-device-protocol/new.md"
: >"$t/wire.proto"
printf '# spec\n' >"$t/docs/SPEC.md"
run python3 "$CHK" "$t"
check "B5 together with B1, B3 and B4 violations exits non-zero" 1 \
	"FAIL B1 row" "FAIL B3 no-protocol" "FAIL B4 owner" "NOTICE B5 (proposed, pending owner approval)" \
	"3 of 4 enforced checks break"

t="$TMP_ROOT/b4-nested"
tree "$t"
mkdir -p "$t/docs/hsm-device-protocol/design"
printf '# A nested trace\n\nNo owner named.\n' >"$t/docs/hsm-device-protocol/design/new.md"
run python3 "$CHK" "$t"
check "B4: a nested document that does not name go-xkms #1521 fails" 1 \
	"FAIL B4 owner" "docs/hsm-device-protocol/design/new.md does not name go-xkms #1521"

t="$TMP_ROOT/b4-nested-ok"
tree "$t"
mkdir -p "$t/docs/hsm-device-protocol/design"
printf '# A nested trace\n\nOwned by go-xkms #1521.\n' >"$t/docs/hsm-device-protocol/design/new.md"
run python3 "$CHK" "$t"
check "B4: a nested document that names go-xkms #1521 passes" 0 "ok B4 owner"

# The go-xkms build cache scripts/xkms/xkmsd-build.sh keeps under build/go-xkms
# (src checkout, module cache, work dirs) is not this repository's code.
t="$TMP_ROOT/b3-cache"
tree "$t"
mkdir -p "$t/build/go-xkms/src/cmd/xkmsd" "$t/build/go-xkms/gopath/pkg/mod/example.invalid/dep@v1" \
	"$t/build/go-xkms/build.abc123/api" "$t/build/xkms/0123"
: >"$t/build/go-xkms/src/go.mod"
: >"$t/build/go-xkms/src/main.go"
: >"$t/build/go-xkms/src/cmd/xkmsd/main.go"
: >"$t/build/go-xkms/gopath/pkg/mod/example.invalid/dep@v1/go.mod"
: >"$t/build/go-xkms/build.abc123/api/wire.proto"
: >"$t/build/xkms/0123/xkmsd"
run python3 "$CHK" "$t"
check "B3: a populated build/go-xkms cache passes" 0 "ok B3 no-protocol" "no xkmsd recipe yet: missing"

for f in stray.go build/stray.go build/xkms/go.mod build/go-xkms-other/go.mod go-xkms/go.mod scripts/build/go-xkms/main.go; do
	t="$TMP_ROOT/b3-stray-${f//\//-}"
	tree "$t"
	mkdir -p "$t/build/go-xkms/src" "$t/$(dirname "$f")"
	: >"$t/build/go-xkms/src/go.mod"
	: >"$t/$f"
	run python3 "$CHK" "$t"
	check "B3: $f outside the go-xkms cache still fails beside a populated cache" 1 \
		"FAIL B3 no-protocol" "$f implements xkmsd"
done

# The artefact exclusions are paths from the tree root, never directory names:
# the same names deeper in the tree are tracked content and are inspected.
t="$TMP_ROOT/b3-root-artefacts"
tree "$t"
mkdir -p "$t/out/sm" "$t/.tools/bin"
: >"$t/out/sm/wire.proto"
: >"$t/out/sm/main.go"
: >"$t/.tools/bin/go.mod"
run python3 "$CHK" "$t"
check "B3: the root out/ and .tools/ artefact directories are not inspected" 0 "ok B3 no-protocol"

for f in scripts/out/wire.proto scripts/out/main.go system-manager/out/go.mod scripts/.tools/main.go node_modules/x/main.go; do
	t="$TMP_ROOT/b3-nested-${f//\//-}"
	tree "$t"
	mkdir -p "$t/$(dirname "$f")"
	: >"$t/$f"
	run python3 "$CHK" "$t"
	check "B3: $f, an artefact directory name below the root, is inspected and fails" 1 \
		"FAIL B3 no-protocol" "$f"
done

# A directory symlink is not followed by the walk: the check refuses it (exit 2)
# and does not report success over a subtree it did not inspect.
t="$TMP_ROOT/b3-symlink"
tree "$t"
mkdir -p "$t/real"
: >"$t/real/wire.proto"
mkdir -p "$t/scripts"
ln -s ../real "$t/scripts/linked"
run python3 "$CHK" "$t"
check "B3: a directory symlink to a tree holding a protocol schema exits 2" 2 \
	"hdp-boundary-check:" "scripts/linked is a directory symlink"

t="$TMP_ROOT/b4-symlink"
tree "$t"
mkdir -p "$t/elsewhere"
printf '# A linked trace\n\nNo owner named.\n' >"$t/elsewhere/new.md"
ln -s ../../elsewhere "$t/docs/hsm-device-protocol/design"
run python3 "$CHK" "$t"
check "B4: a directory symlink under docs/hsm-device-protocol exits 2" 2 \
	"hdp-boundary-check:" "docs/hsm-device-protocol/design is a directory symlink"

t="$TMP_ROOT/b4-folder-symlink"
tree "$t"
mv "$t/docs/hsm-device-protocol" "$t/elsewhere"
ln -s ../elsewhere "$t/docs/hsm-device-protocol"
run python3 "$CHK" "$t"
check "B4: docs/hsm-device-protocol itself a directory symlink exits 2" 2 \
	"hdp-boundary-check:" "docs/hsm-device-protocol is a directory symlink"

# An unreadable subtree must fail closed (exit 2), not read as "no protocol here".
# chmod 000 does not deny reads to root, so the case is skipped there.
if [ "$(id -u)" = 0 ]; then
	echo "note: running as root, chmod 000 does not deny reads: the unreadable-subtree cases are skipped"
else
	t="$TMP_ROOT/b3-unreadable"
	tree "$t"
	mkdir -p "$t/vendor/deep"
	: >"$t/vendor/deep/wire.proto"
	chmod 000 "$t/vendor/deep"
	run python3 "$CHK" "$t"
	check "B3: an unreadable subtree exits 2 and does not report success" 2 \
		"hdp-boundary-check:" "Permission denied"
	chmod 755 "$t/vendor/deep"

	t="$TMP_ROOT/b4-unreadable"
	tree "$t"
	mkdir -p "$t/docs/hsm-device-protocol/design"
	chmod 000 "$t/docs/hsm-device-protocol/design"
	run python3 "$CHK" "$t"
	check "B4: an unreadable document subtree exits 2 and does not report success" 2 \
		"hdp-boundary-check:" "Permission denied"
	chmod 755 "$t/docs/hsm-device-protocol/design"
fi

run python3 "$CHK" "$TMP_ROOT/absent"
check "an unreadable tree exits 2" 2 "hdp-boundary-check:"

run python3 "$CHK"
check "no tree prints the usage" 2 "usage: hdp-boundary-check.py <tree>"

finish
