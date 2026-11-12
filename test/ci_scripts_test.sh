#!/usr/bin/env bash
# The CI scripts behind the make targets: scripts/check-doc-links.py,
# scripts/secret-scan.sh, scripts/deps-check.sh, scripts/fetch-tools.sh,
# scripts/image-tag.sh and scripts/check-script-tests.sh. Network calls are
# answered by a stub curl on PATH, so the suite runs offline.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- scripts/check-doc-links.py --------------------------------------------

run python3 "$ROOT/scripts/check-doc-links.py" "$ROOT"
check "check-doc-links: this repository's links resolve" 0 "OK"

repo="$TMP_ROOT/docs"
mkdir -p "$repo/docs"
printf '# Title\n\n## A section\n\nSee [b](docs/b.md#a-section), [web](https://example.com).\n' >"$repo/a.md"
printf '# B\n\n## A section\n' >"$repo/docs/b.md"
git -C "$repo" init -q && git -C "$repo" add -A
run python3 "$ROOT/scripts/check-doc-links.py" "$repo"
check "check-doc-links: a good link and anchor pass" 0 "OK (2 Markdown files)"

printf 'A [missing](docs/none.md) link.\n' >"$repo/c.md"
printf 'A [bad anchor](docs/b.md#nowhere) link.\n' >"$repo/d.md"
fence='```'
printf '%s\n[in a fence](nowhere.md)\n%s\n' "$fence" "$fence" >"$repo/e.md"
git -C "$repo" add -A
run python3 "$ROOT/scripts/check-doc-links.py" "$repo"
check "check-doc-links: a missing target and a bad anchor fail, by path and line" 1 \
	"c.md:1: link target does not exist" "d.md:1: anchor not found"
if [[ "$OUT" == *e.md* ]]; then fail "check-doc-links: a fenced link is not checked" "$OUT"; else pass "check-doc-links: a fenced link is not checked"; fi

# --- scripts/secret-scan.sh ------------------------------------------------

# The pinned tools: the image's, or those `make tools` put in .tools/bin.
PATH="$ROOT/.tools/bin:$PATH"
if ! command -v gitleaks >/dev/null 2>&1; then
	fail "secret-scan: gitleaks is on PATH or in .tools/bin (run make tools)"
else
	repo="$TMP_ROOT/secrets"
	mkdir -p "$repo"
	printf 'nothing here\n' >"$repo/ok.txt"
	git -C "$repo" init -q && git -C "$repo" add -A
	run "$ROOT/scripts/secret-scan.sh" tree "$repo"
	check "secret-scan: a clean tree passes" 0 "OK"

	# A planted AWS-style key, built at run time so this file holds none.
	key="AKIA$(printf 'Q%.0s' 1 2 3 4)RSTUVWXYZ234"
	secret="aws_secret_access_key = $(printf 'wJalrXUtnFEMI/K7MDENG/bPxRfiCY%s' 7EXAMPLEKEY1)"
	printf 'aws_access_key_id = %s\n%s\n' "$key" "$secret" >"$repo/creds.ini"
	run "$ROOT/scripts/secret-scan.sh" tree "$repo"
	check "secret-scan: a planted key fails with path, line and rule" 1 "creds.ini:1:"
	if [[ "$OUT" == *"$key"* ]]; then fail "secret-scan: the matched text is never printed" "$OUT"; else pass "secret-scan: the matched text is never printed"; fi

	run "$ROOT/scripts/secret-scan.sh" sideways "$repo"
	check "secret-scan: an unknown mode is refused" 2 "unknown mode"
fi

# --- a stub curl for deps-check and fetch-tools ----------------------------

stub="$TMP_ROOT/stub"
mkdir -p "$stub"
# shellcheck disable=SC2016 # the stub's own variables expand when it runs
cat >"$stub/curl" <<'EOF'
#!/usr/bin/env bash
# Answers from $STUB_DIR: the last argument is the URL; -o <file> writes it.
out= url=
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift 2 ;;
	-H) shift 2 ;;
	-*) shift ;;
	*) url=$1; shift ;;
	esac
done
key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9.\n' '_')
[ -f "$STUB_DIR/$key" ] || { echo "stub curl: no answer for $url" >&2; exit 22; }
if [ -n "$out" ]; then cp "$STUB_DIR/$key" "$out"; else cat "$STUB_DIR/$key"; fi
EOF
chmod +x "$stub/curl"
export STUB_DIR="$TMP_ROOT/answers"
mkdir -p "$STUB_DIR"
answer() { printf '%s' "$2" >"$STUB_DIR/$(printf '%s' "$1" | tr -c 'A-Za-z0-9.\n' '_')"; }

# --- scripts/deps-check.sh -------------------------------------------------

old=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
new=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
pins="$TMP_ROOT/pins.sh"
cat >"$pins" <<'EOF'
ALPINE_VERSION=3.24.4
AAA_VERSION=1.0.0
AAA_REPO=example/aaa
AAA_HOLD=
BBB_VERSION=2.0.0
BBB_REPO=example/bbb
BBB_HOLD=
PINNED_TOOLS=AAA,BBB
EOF
answer "https://registry.hub.docker.com/v2/repositories/library/alpine/tags?page_size=100" \
	"{\"results\":[{\"name\":\"3.24.4\",\"tag_last_pushed\":\"$old\"},{\"name\":\"3.24\",\"tag_last_pushed\":\"$old\"},{\"name\":\"3.9.9\",\"tag_last_pushed\":\"$old\"}]}"
answer https://api.github.com/repos/example/aaa/releases/latest "{\"tag_name\":\"v1.0.0\",\"published_at\":\"$old\"}"
answer https://api.github.com/repos/example/bbb/releases/latest "{\"tag_name\":\"v2.0.0\",\"published_at\":\"$old\"}"
run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$pins"
check "deps-check: every pin at its latest release passes" 0 "OK     AAA 1.0.0" "OK     ALPINE 3.24.4"

answer https://api.github.com/repos/example/bbb/releases/latest "{\"tag_name\":\"v2.1.0\",\"published_at\":\"$new\"}"
run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$pins"
check "deps-check: a release under 7 days old is reported, not failed" 0 "REPORT BBB 2.0.0, latest 2.1.0"

answer https://api.github.com/repos/example/bbb/releases/latest "{\"tag_name\":\"v2.1.0\",\"published_at\":\"$old\"}"
run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$pins"
check "deps-check: a pin behind a release over 7 days old fails" 1 "FAIL   BBB 2.0.0 is behind 2.1.0"

printf "BBB_HOLD='waiting on a fix'\n" >>"$pins"
run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$pins"
check "deps-check: a held pin with its reason is reported" 0 "HELD   BBB 2.0.0, latest 2.1.0: waiting on a fix"

rm "$STUB_DIR/$(printf '%s' https://api.github.com/repos/example/aaa/releases/latest | tr -c 'A-Za-z0-9.\n' '_')"
run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$pins"
check "deps-check: an unreadable release fails, never passes" 1 "AAA: the latest release of example/aaa cannot be read"

run env PATH="$stub:$PATH" "$ROOT/scripts/deps-check.sh" "$ROOT/scripts/tool-pins.sh"
check "deps-check: the real pin file names a repository for every tool" 1 "cannot be read"
if [[ "$OUT" == *"has no"* ]]; then fail "deps-check: the real pin file is complete" "$OUT"; else pass "deps-check: the real pin file is complete"; fi

# --- scripts/fetch-tools.sh ------------------------------------------------

src="$TMP_ROOT/fetch-src"
mkdir -p "$src/shellcheck-v9.9.9"
for b in shellcheck-v9.9.9/shellcheck actionlint gitleaks trivy; do printf '#!/bin/sh\n' >"$src/$b"; done
fpins="$TMP_ROOT/fetch-pins.sh"
: >"$fpins"
printf 'SHELLCHECK_VERSION=9.9.9\n' >>"$fpins"
for t in SHELLCHECK:shellcheck-v9.9.9/shellcheck ACTIONLINT:actionlint GITLEAKS:gitleaks TRIVY:trivy; do
	name=${t%%:*} path=${t#*:}
	tar -C "$src" -czf "$TMP_ROOT/$name.tgz" "$path"
	url="https://downloads.example/$name.tgz"
	cp "$TMP_ROOT/$name.tgz" "$STUB_DIR/$(printf '%s' "$url" | tr -c 'A-Za-z0-9.\n' '_')"
	sum=$(sha256sum "$TMP_ROOT/$name.tgz")
	printf '%s_URL=%s\n%s_SHA256=%s\n' "$name" "$url" "$name" "${sum%% *}" >>"$fpins"
done
run env PATH="$stub:$PATH" sh "$ROOT/scripts/fetch-tools.sh" "$fpins" "$TMP_ROOT/bin"
check "fetch-tools: every pinned archive is checked and installed" 0
for b in shellcheck actionlint gitleaks trivy; do
	[ -x "$TMP_ROOT/bin/$b" ] || fail "fetch-tools: $b installed"
done

printf 'TRIVY_SHA256=%064d\n' 0 >>"$fpins"
run env PATH="$stub:$PATH" sh "$ROOT/scripts/fetch-tools.sh" "$fpins" "$TMP_ROOT/bin2"
check "fetch-tools: a digest mismatch fails naming the tool" 1 "TRIVY: SHA-256 mismatch"

# --- scripts/image-tag.sh --------------------------------------------------

run "$ROOT/scripts/image-tag.sh" toolchain trusted-imx95
check "image-tag: the toolchain tag is named by content" 0 "trusted-imx95-toolchain:"
first=$OUT
run "$ROOT/scripts/image-tag.sh" toolchain trusted-imx95
expect "image-tag: the toolchain tag is stable" [ "$OUT" = "$first" ]

repo="$TMP_ROOT/tags"
fixture_repo "$repo"
git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm fixture
run "$repo/scripts/image-tag.sh" integration trusted-imx95
check "image-tag: the integration tag is named by content" 0 "trusted-imx95-ci-it:"
clean=$OUT
run env APK_INDEX_SUM=abc "$repo/scripts/image-tag.sh" integration trusted-imx95
expect "image-tag: APK_INDEX_SUM changes the integration tag" [ "$OUT" != "$clean" ]
printf 'new\n' >"$repo/untracked.txt"
run "$repo/scripts/image-tag.sh" integration trusted-imx95
expect "image-tag: an untracked file changes the integration tag" [ "$OUT" != "$clean" ]
run "$ROOT/scripts/image-tag.sh" other trusted-imx95
check "image-tag: an unknown family is refused" 2 "unknown family"

# --- scripts/check-script-tests.sh -----------------------------------------

run "$ROOT/scripts/check-script-tests.sh" 100
check "check-script-tests: every project script has a test" 0 "threshold 100%"

repo="$TMP_ROOT/untested"
fixture_repo "$repo"
name="fixture-$$.sh" # built at run time, so no test names it
printf '#!/bin/sh\n' >"$repo/scripts/$name"
run "$repo/scripts/check-script-tests.sh" 100
check "check-script-tests: an untested script fails naming it" 1 "scripts/$name: no test"

finish
