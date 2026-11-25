#!/usr/bin/env bash
# Unit tests of scripts/hdp-boundary-check.py: the repository keeps the
# hsm-device-protocol row, and fixture trees that break each check (B1 to B5)
# fail with the check named. Offline; writes only under $TMP_ROOT.
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
check "B5: an xkmsd recipe that follows a branch fails" 1 \
	"FAIL B5 release" "no tag= in SRC_URI" "follows a branch"

run python3 "$CHK" "$TMP_ROOT/absent"
check "an unreadable tree exits 2" 2 "hdp-boundary-check:"

run python3 "$CHK"
check "no tree prints the usage" 2 "usage: hdp-boundary-check.py <tree>"

finish
