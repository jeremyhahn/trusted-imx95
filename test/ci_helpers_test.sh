#!/usr/bin/env bash
# The template's helper scripts (ci-template v1.54, #159), run by the
# template's own tests, copied unchanged to test/testdata/. The tests find the
# scripts and ci.yml beside their own testdata/ directory, so they run on a
# copy laid out that way.
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
# The ci-image-history wiring cases parse ci.yml with PyYAML, which the
# toolchain image does not carry; without it they are skipped, named here.
if python3 -I -c 'import yaml' 2>/dev/null; then
  run python3 -I "$lay/testdata/ci-image-history-tests.py"
  check "ci-image-history: the template's tests pass" 0
else
  echo "SKIP ci-image-history: PyYAML is not installed"
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
[ -z "$OUT" ] && pass "ci-mask-lan.sh: prints nothing for an empty environment" ||
	fail "ci-mask-lan.sh: prints nothing for an empty environment" "$OUT"
run env -i PATH="$PATH" DEVCACHE_GOPROXY=http://10.9.8.7:3000/go \
	CI_IMAGE_REGISTRY=registry.corp:5000 GOPROXY="https://proxy.golang.org,direct" \
	bash "$ROOT/scripts/ci-mask-lan.sh"
check "ci-mask-lan.sh: an internal address and host name are masked" 0 \
	"::add-mask::http://10.9.8.7:3000/go" "::add-mask::10.9.8.7:3000" \
	"::add-mask::10.9.8.7" "::add-mask::registry.corp"
[[ "$OUT" != *proxy.golang.org* ]] && pass "ci-mask-lan.sh: a public host is left" ||
	fail "ci-mask-lan.sh: a public host is left" "$OUT"

# ci-image-history.sh
run env PATH="$stubs:$PATH" bash "$ROOT/scripts/ci-image-history.sh"
check "ci-image-history.sh: no image is a usage error" 2 "usage:"
run env PATH="$stubs:$PATH" bash "$ROOT/scripts/ci-image-history.sh" img:1
check "ci-image-history.sh: a clean image passes" 0
run env PATH="$stubs:$PATH" STUB_HISTORY="ARG X=http://10.1.2.3:8080" \
	bash "$ROOT/scripts/ci-image-history.sh" img:1
check "ci-image-history.sh: a private address in the history fails" 1 \
	"history entry 1 carries a private address"
[[ "$OUT" != *10.1.2.3* ]] && pass "ci-image-history.sh: the address is never printed" ||
	fail "ci-image-history.sh: the address is never printed" "$OUT"
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
