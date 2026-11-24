#!/usr/bin/env bash
# `make ele-client-test`: fetch the pinned source outside the checkout, then run
# the backend test against it with REQUIRE_ELE_SRC=1. Runs the Makefile's own
# recipe in a scratch copy, with stub scripts: no network, no vendor source.
# To see the REQUIRE_ELE_SRC case fail, copy the Makefile to a scratch path,
# remove REQUIRE_ELE_SRC=1 from the copy's recipe, and run this test with
# ELE_MAKEFILE=<that copy>. The checked-in Makefile is never touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fails=0
check() { # check DESCRIPTION CONDITION-COMMAND...
	local d=$1
	shift
	if "$@"; then echo "ok: $d"; else echo "FAIL $d"; fails=1; fi
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# make_scratch DIR FETCH_RC: a copy of the Makefile with stub fetch and test.
make_scratch() {
	local d=$1 rc=$2
	mkdir -p "$d/scripts" "$d/test"
	cp "${ELE_MAKEFILE:-$here/Makefile}" "$d/Makefile"
	cat >"$d/scripts/ele-lib-build.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$d/fetch.args"
exit $rc
EOF
	chmod +x "$d/scripts/ele-lib-build.sh"
	cp "$here/scripts/tool-pins.sh" "$d/scripts/tool-pins.sh"
	cat >"$d/test/ele_client_test.sh" <<EOF
#!/usr/bin/env bash
printf 'ELE_SRC=%s REQUIRE_ELE_SRC=%s\n' "\${ELE_SRC-}" "\${REQUIRE_ELE_SRC-}" >"$d/test.env"
exit 0
EOF
}

ok=$tmp/ok
make_scratch "$ok" 0
base=$tmp/base
make -C "$ok" ele-client-test ELE_BASE="$base" >"$tmp/ok.log" 2>&1
check "target succeeds when fetch and test succeed" test $? -eq 0
check "fetch gets --src-only" grep -q -e '--src-only' "$ok/fetch.args"
check "fetch work dir is under ELE_BASE" grep -q -e "--work $base/src-work" "$ok/fetch.args"
check "test gets REQUIRE_ELE_SRC=1" grep -q 'REQUIRE_ELE_SRC=1$' "$ok/test.env"
check "test gets ELE_SRC=<work>/src" grep -q "^ELE_SRC=$base/src-work/src " "$ok/test.env"

bad=$tmp/bad
make_scratch "$bad" 3
make -C "$bad" ele-client-test ELE_BASE="$tmp/base2" >"$tmp/bad.log" 2>&1
rc=$?
check "target fails when the fetch fails" test "$rc" -ne 0
check "the test does not run after a failed fetch" test ! -e "$bad/test.env"

exit $fails
