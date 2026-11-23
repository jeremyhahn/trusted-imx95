#!/usr/bin/env bash
# The template's helper scripts (ci-template v1.54, #159), run by the
# template's own tests, copied unchanged to test/testdata/. The tests find the
# scripts and ci.yml beside their own testdata/ directory, so they run on a
# copy laid out that way. ci-image-history-tests.py is the template's except
# its publish fixtures, adapted to the retained ci-image-cache.sh (#159).
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lay="$TMP_ROOT/ci-helpers"
mkdir -p "$lay/testdata"
cp "$ROOT/.github/workflows/ci.yml" "$lay/ci.yml"
cp "$ROOT/scripts/ci-mask-lan.sh" "$ROOT/scripts/ci-image-history.sh" \
  "$ROOT/scripts/ci-image-cache.sh" "$lay/"
cp "$ROOT/test/testdata/ci-mask-lan-tests.py" \
  "$ROOT/test/testdata/ci-image-history-tests.py" "$lay/testdata/"

run python3 -I "$lay/testdata/ci-mask-lan-tests.py"
check "ci-mask-lan: the template's tests pass" 0
# The ci-image-history wiring cases parse ci.yml with PyYAML (py3-yaml in the
# toolchain image). In CI (CI or GITHUB_ACTIONS is true) a missing PyYAML
# fails; elsewhere, outside the toolchain image, the suite is skipped with a
# named line. With PyYAML present the suite always runs and must pass.
if python3 -I -c 'import yaml' 2>/dev/null; then
  run python3 -I "$lay/testdata/ci-image-history-tests.py"
  check "ci-image-history: the tests pass" 0 "0 failure(s)"
elif [ "${CI:-}" = true ] || [ "${GITHUB_ACTIONS:-}" = true ]; then
  run python3 -I -c 'import yaml'
  check "ci-image-history: PyYAML is installed" 0
else
  echo "skip ci-image-history: PyYAML is not installed (required when CI is true)"
fi

# The scripts themselves, run through bash and sh on PATH (check-script-tests
# counts a script tested only so). docker and go are stubs.
stubs="$TMP_ROOT/stubs"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'EOF'
#!/bin/sh
case $1 in
history) printf '%s\n' "${STUB_HISTORY:-/bin/sh -c apk add curl}" ;;
image) printf '%s\n' "${STUB_CONFIG:-{\"Env\":[\"PATH=/usr/bin\"]\}}" ;;
esac
EOF
cat >"$stubs/go" <<'EOF'
#!/bin/sh
echo p/a.go
if [ "${STUB_GO_SAME:-}" = 1 ]; then exit 0; fi
case "$*" in
*"-tags a b"*) echo p/ab.go ;;
esac
EOF
chmod +x "$stubs/docker" "$stubs/go"

# ci-mask-lan.sh
run env -i PATH="$PATH" bash "$ROOT/scripts/ci-mask-lan.sh"
check "ci-mask-lan.sh: no registry or cache variable masks nothing" 0
if [ -z "$OUT" ]; then
	pass "ci-mask-lan.sh: prints nothing for an empty environment"
else
	fail "ci-mask-lan.sh: prints nothing for an empty environment" "$OUT"
fi
run env -i PATH="$PATH" DEVCACHE_GOPROXY=http://10.11.12.13:8080/go \
	CI_IMAGE_REGISTRY=registry.internal:5000 GOPROXY="https://proxy.golang.org,direct" \
	bash "$ROOT/scripts/ci-mask-lan.sh"
check "ci-mask-lan.sh: an internal address and host name are masked" 0 \
	"::add-mask::http://10.11.12.13:8080/go" "::add-mask::10.11.12.13:8080" \
	"::add-mask::10.11.12.13" "::add-mask::registry.internal"
if [[ "$OUT" != *proxy.golang.org* ]]; then
	pass "ci-mask-lan.sh: a public host is left"
else
	fail "ci-mask-lan.sh: a public host is left" "$OUT"
fi

# ci-mask-lan.sh classifies the canonical host name (lower case, one trailing root
# dot), and fails closed on a host it cannot classify (Codex security P1 at verify 15;
# a local change to the template file). Each case masks the spelling that appears later.
masklan() { run env -i PATH="$PATH" "$@" bash "$ROOT/scripts/ci-mask-lan.sh"; }
masklan GITHUB_SERVER_URL=https://FORGE.CORP:3000
check "ci-mask-lan.sh: an upper-case internal host is masked as written and canonically" 0 \
	"::add-mask::https://FORGE.CORP:3000" "::add-mask::FORGE.CORP:3000" \
	"::add-mask::FORGE.CORP" "::add-mask::forge.corp" "::add-mask::forge.corp:3000"
masklan GITHUB_SERVER_URL=https://forge.corp.:3000
check "ci-mask-lan.sh: a trailing-dot internal host is masked as written and canonically" 0 \
	"::add-mask::https://forge.corp.:3000" "::add-mask::forge.corp.:3000" \
	"::add-mask::forge.corp." "::add-mask::forge.corp" "::add-mask::forge.corp:3000"
masklan GITHUB_SERVER_URL=https://Forge.Corp.
check "ci-mask-lan.sh: a mixed-case trailing-dot host with no port is masked" 0 \
	"::add-mask::https://Forge.Corp." "::add-mask::Forge.Corp." "::add-mask::forge.corp"
masklan CI_REGISTRY=https://user:secret@Registry.Example.
check "ci-mask-lan.sh: a userinfo URL fails closed, userinfo included" 0 \
	"::add-mask::https://user:secret@Registry.Example." "::add-mask::user:secret" \
	"::add-mask::Registry.Example." "::add-mask::registry.example"
masklan GITHUB_SERVER_URL='https://[fd00::1]:3000'
check "ci-mask-lan.sh: a bracketed IPv6 host fails closed" 0 \
	"::add-mask::https://[fd00::1]:3000" "::add-mask::[fd00::1]:3000" "::add-mask::[fd00::1]"
masklan GITHUB_SERVER_URL='https://'
check "ci-mask-lan.sh: an empty host fails closed" 0 "::add-mask::https://"
masklan GITHUB_SERVER_URL='https://bad_host!x.example'
check "ci-mask-lan.sh: an unparseable host fails closed" 0 "::add-mask::https://bad_host!x.example"
masklan GITHUB_SERVER_URL=https://GitHub.Com.
if [ -z "$OUT" ]; then
	pass "ci-mask-lan.sh: a public host in any case, with a trailing dot, is left"
else
	fail "ci-mask-lan.sh: a public host in any case, with a trailing dot, is left" "$OUT"
fi

# ci-image-history.sh
run env PATH="$stubs:$PATH" bash "$ROOT/scripts/ci-image-history.sh"
check "ci-image-history.sh: no image is a usage error" 2 "usage:"
run env PATH="$stubs:$PATH" bash "$ROOT/scripts/ci-image-history.sh" img:1
check "ci-image-history.sh: a clean image passes" 0
run env PATH="$stubs:$PATH" STUB_HISTORY="ARG X=http://10.1.2.3:8080" \
	bash "$ROOT/scripts/ci-image-history.sh" img:1
check "ci-image-history.sh: a private address in the history fails" 1 \
	"history entry 1 carries a private address"
if [[ "$OUT" != *10.1.2.3* ]]; then
	pass "ci-image-history.sh: the address is never printed"
else
	fail "ci-image-history.sh: the address is never printed" "$OUT"
fi
run env PATH="$stubs:$PATH" STUB_CONFIG='{"Env":["P=192.168.0.5"]}' \
	bash "$ROOT/scripts/ci-image-history.sh" img:1
check "ci-image-history.sh: a private address in the config fails" 1 "its config"

# assert-build-tags.sh
run env PATH="$stubs:$PATH" GO_BUILD_TAGS= sh "$ROOT/scripts/assert-build-tags.sh"
check "assert-build-tags.sh: no tags asserts nothing" 0 "nothing to assert"
run env PATH="$stubs:$PATH" GO_BUILD_TAGS="a b" sh "$ROOT/scripts/assert-build-tags.sh"
check "assert-build-tags.sh: tags that select code pass" 0 "every declared tag selects code"
run env PATH="$stubs:$PATH" GO_BUILD_TAGS="a b" STUB_GO_SAME=1 \
	sh "$ROOT/scripts/assert-build-tags.sh"
check "assert-build-tags.sh: tags that change nothing fail" 1 "changed nothing"

finish
