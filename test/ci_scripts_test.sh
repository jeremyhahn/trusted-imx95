#!/usr/bin/env bash
# The CI scripts behind the make targets: scripts/check-doc-links.py,
# scripts/secret-scan.sh, scripts/deps-check.sh, scripts/fetch-tools.sh,
# scripts/image-tag.sh and scripts/check-script-tests.sh. Network calls are
# answered by a stub curl on PATH, so the suite runs offline.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The suite's outcome must not depend on the job that runs it: a check that
# needs a trusted run sets GITHUB_EVENT_NAME (and RUNNER_TEMP) itself.
unset GITHUB_EVENT_NAME RUNNER_TEMP TOOLCHAIN_VERIFIED_ID TOOLCHAIN_ID_FILE IT_ID_FILE IT_IMAGE_ID

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

	# A key committed, then removed in the next commit: the tree is clean, the
	# history is not. (The CI checkout of the history scan is full depth.)
	hist="$TMP_ROOT/history"
	mkdir -p "$hist"
	g() { git -C "$hist" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
	g init -q
	printf 'aws_access_key_id = %s\n%s\n' "$key" "$secret" >"$hist/creds.ini"
	g add -A && g commit -qm "add creds"
	rm "$hist/creds.ini"
	printf 'nothing here\n' >"$hist/ok.txt"
	g add -A && g commit -qm "remove creds"
	run "$ROOT/scripts/secret-scan.sh" tree "$hist"
	check "secret-scan: the tree without the removed key passes" 0 "OK"
	run "$ROOT/scripts/secret-scan.sh" history "$hist"
	check "secret-scan: a key committed and removed later fails the history scan" 1 "creds.ini:1:"
	if [[ "$OUT" == *"$key"* ]]; then fail "secret-scan: the history scan never prints the matched text" "$OUT"; else pass "secret-scan: the history scan never prints the matched text"; fi
	git clone -q --depth 1 "file://$hist" "$TMP_ROOT/shallow"
	run "$ROOT/scripts/secret-scan.sh" history "$TMP_ROOT/shallow"
	check "secret-scan: a shallow clone, which hides the removed key, is refused" 1 "shallow clone"

	# A key that only a merge resolution adds (neither parent has it), deleted
	# in the next commit: gitleaks' default git log emits no merge patch.
	mrg="$TMP_ROOT/merge"
	mkdir -p "$mrg"
	m() { git -C "$mrg" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
	m init -q -b main
	printf 'a\n' >"$mrg/a.txt" && m add -A && m commit -qm base
	m checkout -qb side
	printf 'b\n' >"$mrg/b.txt" && m add -A && m commit -qm side
	m checkout -q main
	printf 'c\n' >"$mrg/c.txt" && m add -A && m commit -qm main
	m merge -q --no-ff --no-commit side >/dev/null
	printf 'aws_access_key_id = %s\n%s\n' "$key" "$secret" >"$mrg/merged.ini"
	m add -A && m commit -qm merge
	m rm -q merged.ini && m commit -qm "remove merged creds"
	run "$ROOT/scripts/secret-scan.sh" history "$mrg"
	check "secret-scan: a key added only by a merge resolution and removed later fails the history scan" 1 "merged.ini:1:"

	# A proven main push (Codex security P1, the tree proof): after a green
	# run, two commits add a credential and remove it, so the tree is the
	# proven one. test/ci-proven-sim.py evaluates ci.yml's job and step `if:`
	# for that push, runs the history scan where a running step scans the
	# history, and writes CI Gate's script with the job results; the gate
	# must fail. On a clean history it passes.
	pv="$TMP_ROOT/proven"
	mkdir -p "$pv"
	pg() { git -C "$pv" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
	pg init -q
	printf 'nothing here\n' >"$pv/ok.txt"
	pg add -A && pg commit -qm "proven green"
	green=$(pg rev-parse 'HEAD^{tree}')
	run python3 "$ROOT/test/ci-proven-sim.py" "$ROOT/.github/workflows/ci.yml" "$pv" "$TMP_ROOT/gate-clean.sh"
	check "tree proof: a proven push with a clean history runs the history scan" 0 "scan history-scan"
	run env SCHEDULE_GUARD=proven PROOF=42 DRAFT=false FULL_TIER=true NIGHTLY=false SCHEDULE=false DOCS_ONLY=false LINT_GATES_SEL=true bash "$TMP_ROOT/gate-clean.sh"
	check "tree proof: CI Gate passes a proven push whose history is clean" 0 "OK   history-scan"
	printf 'aws_access_key_id = %s\n%s\n' "$key" "$secret" >"$pv/creds.ini"
	pg add -A && pg commit -qm "add creds"
	pg rm -q creds.ini && pg commit -qm "remove creds"
	expect "tree proof: adding and removing a credential leaves the proven tree" test "$(pg rev-parse 'HEAD^{tree}')" = "$green"
	run python3 "$ROOT/test/ci-proven-sim.py" "$ROOT/.github/workflows/ci.yml" "$pv" "$TMP_ROOT/gate.sh"
	check "tree proof: the history scan runs on the proven push and finds the removed credential" 0 "scan history-scan failure"
	run env SCHEDULE_GUARD=proven PROOF=42 DRAFT=false FULL_TIER=true NIGHTLY=false SCHEDULE=false DOCS_ONLY=false LINT_GATES_SEL=true bash "$TMP_ROOT/gate.sh"
	check "tree proof: CI Gate fails the proven push of a credential added and removed" 1 "FAIL history-scan (failure)"
	# A history scan skipped on a proven tree never passes the gate.
	sed 's/^R_history_scan=.*/R_history_scan=skipped/' "$TMP_ROOT/gate-clean.sh" >"$TMP_ROOT/gate-skip.sh"
	run env SCHEDULE_GUARD=proven PROOF=42 DRAFT=false FULL_TIER=true NIGHTLY=false SCHEDULE=false DOCS_ONLY=false LINT_GATES_SEL=true bash "$TMP_ROOT/gate-skip.sh"
	check "tree proof: CI Gate fails a skipped history scan on a proven tree" 1 "FAIL history-scan (skipped"
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

# A mini repository: one script a test runs, one its test names only in a
# comment. (This repository's own count is make coverage; running it here
# would run this suite inside itself.)
mini="$TMP_ROOT/mini"
mkdir -p "$mini/scripts" "$mini/test"
cp "$ROOT/scripts/check-script-tests.sh" "$mini/scripts/"
printf '#!/usr/bin/env bash\ntrue\n' >"$mini/scripts/mini-run.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$mini/scripts/mini-comment.sh"
printf '#!/bin/sh\ntrue\n' >"$mini/scripts/mini-sh.sh"
printf 'print("ok")\n' >"$mini/scripts/mini-py.py"
chmod +x "$mini/scripts/"*
cat >"$mini/test/mini_test.sh" <<'EOF'
#!/usr/bin/env bash
# Mentions scripts/mini-comment.sh and runs nothing of it.
root="$(dirname "${BASH_SOURCE[0]}")/.."
"$root/scripts/mini-run.sh"
sh "$root/scripts/mini-sh.sh"
python3 "$root/scripts/mini-py.py" >/dev/null
bash -n "$root/scripts/mini-comment.sh"
echo "scripts/mini-comment.sh"
EOF
run "$mini/scripts/check-script-tests.sh" 100
check "check-script-tests: a script named only in a comment, a string or bash -n is untested" 1 \
	"scripts/mini-comment.sh: no test" "3 of 5 scripts tested"
for s in mini-run.sh mini-sh.sh mini-py.py; do
	if [[ "$OUT" == *"scripts/$s: no test"* ]]; then fail "check-script-tests: $s, executed, is tested" "$OUT"; else pass "check-script-tests: $s, executed, is tested"; fi
done

# shellcheck disable=SC2016 # a literal line of the mini test
printf '"$(dirname "${BASH_SOURCE[0]}")/../scripts/mini-comment.sh"\n' >>"$mini/test/mini_test.sh"
run "$mini/scripts/check-script-tests.sh" 80
check "check-script-tests: a script once executed counts" 0 "4 of 5 scripts tested (80%"

printf 'exit 1\n' >>"$mini/test/mini_test.sh"
run "$mini/scripts/check-script-tests.sh" 100
check "check-script-tests: a failing test fails the count" 1 "test/mini_test.sh failed"

# --- make coverage runs the suite once; make docs-check ----------------------
# A second mini repository with this Makefile and the scripts its coverage
# and docs-check targets run. Its one test counts its runs.
mk2="$TMP_ROOT/mk2"
mkdir -p "$mk2/scripts" "$mk2/test" "$mk2/docs"
for s in tool-pins.sh check-script-tests.sh check-tracked-cst.sh docs-check.py check-doc-links.py; do
	cp "$ROOT/scripts/$s" "$mk2/scripts/"
done
cp "$ROOT/Makefile" "$mk2/"
cat >"$mk2/test/count_test.sh" <<'EOF'
#!/usr/bin/env bash
echo run >>"$COUNT_FILE"
echo "ok   counted"
[ -z "${COUNT_FAIL:-}" ]
EOF
printf '# Readme\n\nSee [the roadmap](ROADMAP.md#roadmap) and [a doc](docs/a.md).\n' >"$mk2/README.md"
printf '# Roadmap\n\nRM00284 §3.2.6.3; an example host at 192.0.2.10.\n' >"$mk2/ROADMAP.md"
printf '# A\n\n## Part one\n\nBack to [the readme](../README.md) and [part one](#part-one).\n' >"$mk2/docs/a.md"
git -C "$mk2" init -q && git -C "$mk2" add -A
export COUNT_FILE="$TMP_ROOT/count"
: >"$COUNT_FILE"
run make --no-print-directory -C "$mk2" coverage COVERAGE_THRESHOLD=0
check "make coverage: passes with its tests" 0 "--- test/count_test.sh" "ok   counted" "check-script-tests:"
expect "make coverage: runs the suite once" test "$(grep -c . "$COUNT_FILE")" = 1
: >"$COUNT_FILE"
COUNT_FAIL=1 run make --no-print-directory -C "$mk2" coverage COVERAGE_THRESHOLD=0
check "make coverage: a failing test fails it" nonzero "FAIL test/count_test.sh"
expect "make coverage: a failing suite also runs once" test "$(grep -c . "$COUNT_FILE")" = 1

run make --no-print-directory -C "$mk2" docs-check
check "make docs-check: links, anchors, a § section and an RFC 5737 address pass" 0 "docs-check: OK (3 Markdown files"
printf 'A [broken link](docs/none.md).\n' >>"$mk2/README.md"
run make --no-print-directory -C "$mk2" docs-check
check "make docs-check: a broken relative link fails it" nonzero "README.md:4: link target does not exist"
printf '# Readme\n\nSee [the roadmap](ROADMAP.md#nowhere).\n' >"$mk2/README.md"
run python3 "$ROOT/scripts/docs-check.py" "$mk2"
check "docs-check: an anchor the target lacks fails" 1 "README.md:3: anchor not found in the link target"
# Reference-style links: a definition's target and anchor are checked like an
# inline link's, and a reference with no definition fails. A good reference,
# a footnote and `a[i][j]` in inline code pass.
{
	printf '# Readme\n\nSee [good][ok], [missing][gone], [anchor][bad-anchor], [undefined][nodef] and [ok][].\n'
	printf 'Code %sa[i][j]%s and a note[^1].\n\n' '`' '`'
	printf '[ok]: ROADMAP.md#roadmap\n[gone]: docs/none.md\n[Bad-Anchor]: ROADMAP.md#nowhere "a title"\n[^1]: a footnote, not a link\n'
} >"$mk2/README.md"
run python3 "$ROOT/scripts/docs-check.py" "$mk2"
check "docs-check: a broken reference-style link, a broken reference anchor and an undefined reference fail" 1 \
	"README.md:3: reference link has no definition" "README.md:7: link target does not exist" \
	"README.md:8: anchor not found in the link target"
for n in 4 6 9; do
	if [[ "$OUT" == *"README.md:$n:"* ]]; then fail "docs-check: line $n (inline code, a good reference, a footnote) passes" "$OUT"; else pass "docs-check: line $n (inline code, a good reference, a footnote) passes"; fi
done
git -C "$mk2" add README.md
run python3 "$ROOT/scripts/check-doc-links.py" "$mk2"
check "check-doc-links: the same reference-style links fail lint-docs" 1 \
	"README.md:3: reference link has no definition" "README.md:7: link target does not exist" \
	"README.md:8: anchor not found in the link target"
# An inline-code link example renders as code, not a link, and passes; a
# broken inline link beside it still fails.
{
	printf '# Readme\n\nCode %s[label](missing.md)%s and %s[x](none.md#a)%s.\n' '`' '`' '``' '``'
	printf 'A [broken link](docs/none.md).\n'
} >"$mk2/README.md"
for chk in docs-check check-doc-links; do
	run python3 "$ROOT/scripts/$chk.py" "$mk2"
	check "$chk: a broken inline link beside inline-code link examples fails" 1 "README.md:4: link target does not exist"
	if [[ "$OUT" == *"README.md:3:"* ]]; then fail "$chk: an inline-code link example passes" "$OUT"; else pass "$chk: an inline-code link example passes"; fi
done
printf '# Readme\n' >"$mk2/README.md"
mkdir -p "$mk2/docs/sub"
{
	printf 'Clone http://gitbox:3000/x and see build1.corp.\n'
	# Built here, so this file holds no address or home path itself.
	printf '%s\nssh admin@%s\ncd /%s/dev/tree\n%s\n' '~~~' "10.20.$((15 * 2)).40" "ho""me" '~~~'
	printf 'Not an address: v1.35.2.1 or 1.2.3.4.5; an address: 300.1.1.1 is not one.\n'
	printf 'The local registry at https://localhost:5000 is fine.\n'
} >"$mk2/docs/sub/b.md"
run python3 "$ROOT/scripts/docs-check.py" "$mk2"
check "docs-check: an internal host, an IP and a /home path fail, fenced or not, in a nested docs/ file" 1 \
	"docs/sub/b.md:1: a URL names an internal (single-label) host" "docs/sub/b.md:1: an internal host name" \
	"docs/sub/b.md:3: an IP address" "docs/sub/b.md:4: a /home path"
for n in 5 6 7; do
	if [[ "$OUT" == *"docs/sub/b.md:$n:"* ]]; then fail "docs-check: line $n of b.md (a version, a fence, localhost) passes" "$OUT"; else pass "docs-check: line $n of b.md (a version, a fence, localhost) passes"; fi
done
if [[ "$OUT" == *admin@* || "$OUT" == *"10.20."* || "$OUT" == *gitbox* || "$OUT" == *dev/tree* ]]; then
	fail "docs-check: a finding prints the rule, not the matched text" "$OUT"
else
	pass "docs-check: a finding prints the rule, not the matched text"
fi
rm -rf "$mk2/docs/sub"
rm "$mk2/ROADMAP.md"
run python3 "$ROOT/scripts/docs-check.py" "$mk2"
check "docs-check: a missing ROADMAP.md fails" 1 "ROADMAP.md: missing"
run python3 "$ROOT/scripts/docs-check.py" "$ROOT"
check "docs-check: this repository's docs/, ROADMAP.md and README.md pass" 0 "docs-check: OK"
expect "make lint runs docs-check (so ci.yml's make lint enforces it)" \
	grep -qE '^lint:.* docs-check( |$)' "$ROOT/Makefile"

# --- ci.yml: marking a draft ready starts the Gate (handbook v1.35.3, DS-8551)
run python3 - "$ROOT/.github/workflows/ci.yml" <<'EOF'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
on = lines.index("on:")
pr = next(n for n in range(on, len(lines)) if lines[n] == "  pull_request:")
for l in lines[pr + 1:]:
    if l.strip() and not l.startswith("    "):
        sys.exit("pull_request has no types")
    m = re.match(r"^    types: \[(.*)\]\s*(#.*)?$", l)
    if m:
        print("types:", " ".join(t.strip() for t in m.group(1).split(",")))
        break
EOF
check "ci.yml: the pull_request types include ready_for_review beside the others" 0 \
	"types: opened synchronize reopened ready_for_review"

# --- ci.yml: every event runs the tree secret scan ---------------------------
#
# The tree secret scan runs in the lint job's `make gosec` step or in the
# image job's `make security` step. This evaluates their `if:` conditions
# (and their jobs') for each tier and for a docs-only change, so a condition
# that leaves an event with neither fails here.
sel="$TMP_ROOT/scan-selection.py"
cat >"$sel" <<'EOF'
import re, sys
lines = open(sys.argv[1]).read().splitlines()

def cond(found, what):
    if found is None:
        sys.exit("scan-selection: no single-line if: for " + what)
    return found

def step_if(name):
    for i, l in enumerate(lines):
        if l.strip() == "- name: " + name:
            for m in lines[i + 1:i + 4]:
                if m.strip().startswith("if: ${{"):
                    return m.split("if:", 1)[1].strip()
    return cond(None, "step " + name)

def job_if(job):
    for i, l in enumerate(lines):
        if l == "  %s:" % job:
            for m in lines[i + 1:]:
                if re.match(r"  \S", m):
                    break
                if m.startswith("    if: ${{"):
                    return m.split("if:", 1)[1].strip()
    return cond(None, "job " + job)

def ev(expr, ctx):
    e = expr[3:-2] if expr.startswith("${{") and expr.endswith("}}") else sys.exit("scan-selection: not an expression: " + expr)
    e = e.replace("!cancelled()", "True").replace("!=", " NE ").replace("!", " not ").replace(" NE ", " != ")
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"\b(?:env|needs|github)\.[A-Za-z_.]+", lambda m: repr(ctx.get(m.group(0), "")), e)
    return bool(eval(e, {"__builtins__": {}}, {}))

gosec = (job_if("lint"), step_if("make gosec (PR tier)"))
security = (job_if("image"), step_if("make security"))
bad = 0
for docs in ("true", "false"):
    for full in ("true", ""):
        ctx = {"env.TOOLCHAIN_IMAGE": "toolchain", "env.CI_FULL_TIER": full,
               "needs.preflight.outputs.verdict": "run", "needs.preflight.outputs.docs_only": docs}
        ran = all(ev(c, ctx) for c in gosec) or all(ev(c, ctx) for c in security)
        tier = "full" if full else "PR"
        if ran:
            print("scan-selection: ok   %s tier, docs_only=%s: the tree secret scan runs" % (tier, docs))
        else:
            print("scan-selection: FAIL %s tier, docs_only=%s: no tree secret scan" % (tier, docs))
            bad = 1
sys.exit(bad)
EOF
run python3 "$sel" "$ROOT/.github/workflows/ci.yml"
check "ci.yml: the tree secret scan runs on every tier, a docs-only PR included" 0 \
	"PR tier, docs_only=true: the tree secret scan runs" "full tier, docs_only=true: the tree secret scan runs"
# The condition before this fix, which skipped a docs-only PR, is caught.
old_if="env.CI_FULL_TIER != 'true' && needs.preflight.outputs.docs_only != 'true' }}"
yml=$(<"$ROOT/.github/workflows/ci.yml")
yml=${yml//"(env.CI_FULL_TIER != 'true' || needs.preflight.outputs.docs_only == 'true') }}"/"$old_if"}
printf '%s\n' "$yml" >"$TMP_ROOT/ci-old.yml"
run python3 "$sel" "$TMP_ROOT/ci-old.yml"
check "ci.yml: a gosec condition that skips docs-only PRs fails the selection" 1 \
	"FAIL PR tier, docs_only=true: no tree secret scan"

# --- make docker-run: CST_PATH outside the checkout ---------------------------
#
# A stub docker records each invocation; `image inspect` succeeds, so no
# image is built. The run must mount a set CST_PATH read-only and name it
# inside the container, and must not forward an unset one.
dstub="$TMP_ROOT/dstub"
mkdir -p "$dstub"
cat >"$dstub/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] && printf '%s\n' "$@" >"$DOCKER_LOG"
exit 0
EOF
chmod +x "$dstub/docker"
export DOCKER_LOG="$TMP_ROOT/docker.log"
cst_host="$TMP_ROOT/host extract/cst-3.1.0"
mkdir -p "$cst_host/release/docs"
: >"$cst_host/release/docs/CST_UG.pdf"
run env PATH="$dstub:$PATH" CST_PATH="$cst_host" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: runs with CST_PATH set" 0
expect "docker-run: a set CST_PATH is bind-mounted read-only at /cst" grep -qxF -- "$cst_host:/cst:ro" "$DOCKER_LOG"
expect "docker-run: CST_PATH names the mount inside the container" grep -qxF -- "CST_PATH=/cst" "$DOCKER_LOG"
expect "docker-run: the command runs in the image" grep -qxF -- "make cst-check" "$DOCKER_LOG"
: >"$DOCKER_LOG"
run env -u CST_PATH PATH="$dstub:$PATH" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: runs with CST_PATH unset" 0
log=$(<"$DOCKER_LOG")
if [[ "$log" == *CST_PATH* || "$log" == *"/cst:ro"* ]]; then fail "docker-run: an unset CST_PATH is neither forwarded nor mounted" "$log"; else pass "docker-run: an unset CST_PATH is neither forwarded nor mounted"; fi
run env PATH="$dstub:$PATH" CST_PATH="$TMP_ROOT/absent" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: a CST_PATH that is not a directory is refused" nonzero "is not a directory"
# Inside the container cst-check compares /cst with /src and would pass, so
# docker-run refuses an in-checkout CST_PATH, canonically, before the remap.
# An existing directory of the checkout stands in; nothing is written there.
: >"$DOCKER_LOG"
run env PATH="$dstub:$PATH" CST_PATH="$ROOT/scripts" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: a CST_PATH inside the checkout is refused" nonzero "is inside this checkout"
expect "docker-run: an in-checkout CST_PATH never reaches docker" test ! -s "$DOCKER_LOG"
ln -s "$ROOT/scripts" "$TMP_ROOT/cst-link"
run env PATH="$dstub:$PATH" CST_PATH="$TMP_ROOT/cst-link" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: a symlink to a directory of the checkout is refused" nonzero "is inside this checkout"
expect "docker-run: a symlinked in-checkout CST_PATH never reaches docker" test ! -s "$DOCKER_LOG"
run env PATH="$dstub:$PATH" CST_PATH="$ROOT" make -s -C "$ROOT" docker-run CMD='make cst-check'
check "docker-run: the checkout itself is refused as CST_PATH" nonzero "is inside this checkout"

# --- .dockerignore: the vendor paths .gitignore excludes ----------------------
#
# The integration Dockerfile copies the whole context, and scripts/image-tag.sh
# hashes only what git tracks, so every resources/ rule of .gitignore must also
# keep the path out of the Docker context.
missing=""
while IFS= read -r rule; do
	case "$rule" in resources/*) grep -qxF -- "$rule" "$ROOT/.dockerignore" || missing="$missing $rule" ;; esac
done <"$ROOT/.gitignore"
if [ -z "$missing" ]; then pass ".dockerignore: every resources/ rule of .gitignore is excluded from the Docker context"; else fail ".dockerignore: every resources/ rule of .gitignore is excluded from the Docker context" "missing:$missing"; fi
expect ".gitignore: the resources/ vendor rules the check above reads exist" grep -q '^resources/' "$ROOT/.gitignore"

# --- .dockerignore: the Docker context, by Docker's matching rules -------------
#
# No Docker here, so ctx.py applies .dockerignore the way Docker's pattern
# matcher does (each pattern filepath.Clean'd; `**` any number of components,
# `*` and `?` within one; a path is out when it or a parent directory
# matches, the last matching pattern deciding) and prints what stays in.
cat >"$TMP_ROOT/ctx.py" <<'EOF'
import os, re, sys
def rx(p):
    p = os.path.normpath(p)
    r, i = "^", 0
    while i < len(p):
        c = p[i]
        if c == "*" and p[i + 1:i + 2] == "*":
            i += 2
            while p[i:i + 1] == "/":
                i += 1
            r += ".*" if i >= len(p) else "(.*/)?"
            continue
        if c == "*":
            r += "[^/]*"
        elif c == "?":
            r += "[^/]"
        elif c == "[":
            j = p.index("]", i)
            r += p[i:j + 1]
            i = j + 1
            continue
        else:
            r += re.escape(c)
        i += 1
    return re.compile(r + "$")
rules = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line and not line.startswith("#"):
        neg = line.startswith("!")
        rules.append((neg, rx(line[1:] if neg else line)))
def out(path):
    parts = path.split("/")
    for n in range(1, len(parts) + 1):
        sub, verdict = "/".join(parts[:n]), False
        for neg, r in rules:
            if r.match(sub):
                verdict = not neg
        if verdict:
            return True
    return False
for path in sys.stdin.read().split("\n"):
    if path and not out(path):
        print(path)
EOF
ctx_in() { python3 "$TMP_ROOT/ctx.py" "$1"; }
kept=$(printf '%s\n' \
	tools/cst-local/release/docs/CST_UG.pdf \
	a/b/cst-mine/linux64/bin/cst \
	cst-3.1.0/release/docs/CST_UG.pdf \
	dist/cst-3.1.0.tgz \
	resources/imx95-yocto-6.6.zip \
	resources/ucm-imx95:yocto-linux/image.wic \
	.tools/bin/gitleaks \
	scripts/cst-check.sh test/cst_guard_test.sh resources/README.md Makefile | ctx_in "$ROOT/.dockerignore")
want="scripts/cst-check.sh
test/cst_guard_test.sh
resources/README.md
Makefile"
if [ "$kept" = "$want" ]; then pass ".dockerignore: no cst-* extraction (tools/cst-local, a nested one), CST archive, vendor image or .tools reaches the Docker context"; else fail ".dockerignore: no cst-* extraction (tools/cst-local, a nested one), CST archive, vendor image or .tools reaches the Docker context" "kept: $(printf '%s' "$kept" | tr '\n' ' ')"; fi
tracked=$(git -C "$ROOT" ls-files)
if [ "$(printf '%s\n' "$tracked" | ctx_in "$ROOT/.dockerignore")" = "$tracked" ]; then pass ".dockerignore: every tracked file, scripts/cst-check.sh among them, stays in the Docker context"; else fail ".dockerignore: every tracked file, scripts/cst-check.sh among them, stays in the Docker context"; fi
printf '**/cst-*/\n' >"$TMP_ROOT/slash.dockerignore"
expect "ctx.py: Docker's cleaning makes **/cst-*/ drop scripts/cst-check.sh" test -z "$(echo scripts/cst-check.sh | ctx_in "$TMP_ROOT/slash.dockerignore")"

# --- forge credentials: never into a container, never in a PR job's env -------
#
# The runner injects GIT_CONFIG_COUNT/KEY_0/VALUE_0 (dependency-resolution.md
# §6). in-toolchain-image.sh, with a network, runs a pull request's scripts:
# a stub docker records what `docker create` is given.
tstub="$TMP_ROOT/tcstub"
mkdir -p "$tstub" "$TMP_ROOT/tcsrc"
cat >"$tstub/docker" <<'EOF'
#!/usr/bin/env bash
case $1 in
create) printf '%s\n' "$@" >"$TC_LOG" ;;
cp) cat >/dev/null ;;
esac
exit 0
EOF
chmod +x "$tstub/docker"
export TC_LOG="$TMP_ROOT/tc.log"
here=$PWD
cd "$TMP_ROOT/tcsrc" || exit 1
run env -u GITHUB_EVENT_NAME PATH="$tstub:$PATH" IN_IMAGE_NETWORK=bridge CI_CACHE=off IN_IMAGE_CPUS=1 IN_IMAGE_MEMORY=1g \
	GOPRIVATE=example.invalid GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://u:fake@example.invalid/.insteadOf GIT_CONFIG_VALUE_0=https://example.invalid/ \
	FORGE_TOKEN=fake GITHUB_TOKEN=fake GITEA_TOKEN=fake "$ROOT/scripts/in-toolchain-image.sh" img:test true
cd "$here" || exit 1
check "in-toolchain-image: a bridge run with the forge credentials set succeeds" 0
expect "in-toolchain-image: a bridge run passes GOPRIVATE in" grep -qxF GOPRIVATE "$TC_LOG"
if grep -qE 'GIT_CONFIG|TOKEN|fake' "$TC_LOG"; then fail "in-toolchain-image: no GIT_CONFIG_* or token variable reaches the container" "$(grep -E 'GIT_CONFIG|TOKEN|fake' "$TC_LOG")"; else pass "in-toolchain-image: no GIT_CONFIG_* or token variable reaches the container"; fi

# ci.yml, read as text: no loop copies a credential into an env file, a
# container's --env or GITHUB_ENV; no --env names one; the workflow env blanks
# the runner's GIT_CONFIG_*; and a *TOKEN secret is read only on an event that
# is not a pull request.
cat >"$TMP_ROOT/creds.py" <<'EOF'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
cred = re.compile(r"GIT_CONFIG|TOKEN")
bad = []
for n, l in enumerate(lines):
    m = re.search(r"for v in ([^;]*); do", l)
    if m and cred.search(m.group(1)) and re.search(r"gomodauth|--env|GITHUB_ENV|>>", "\n".join(lines[n + 1:n + 4])):
        bad.append("%d: a loop copies %s" % (n + 1, m.group(1)))
    if re.search(r"(--env|\s-e)\s+\"?\$?\{?\w*(GIT_CONFIG|TOKEN)", l):
        bad.append("%d: --env passes a credential" % (n + 1))
    m = re.match(r"\s+(GIT_CONFIG_\w+):\s*(\S*)", l)
    if m and m.group(2) not in ('""', '"0"'):
        bad.append("%d: %s is set to %s" % (n + 1, m.group(1), m.group(2)))
    if re.search(r"secrets\.\w*TOKEN", l) and not re.search(r"github\.event_name == '(schedule|push)'", l):
        bad.append("%d: a *TOKEN secret reaches a pull_request run" % (n + 1))
top, inside = {}, False
for l in lines:
    if re.match(r"\S", l):
        inside = l.startswith("env:")
        continue
    m = re.match(r"  (GIT_CONFIG_\w+):\s*(\S*)", l) if inside else None
    if m:
        top[m.group(1)] = m.group(2)
want = {"GIT_CONFIG_COUNT": '"0"', "GIT_CONFIG_KEY_0": '""', "GIT_CONFIG_VALUE_0": '""'}
if top != want:
    bad.append("the workflow env does not blank the runner's GIT_CONFIG_*: %s" % top)
print("\n".join(bad) if bad else "OK")
sys.exit(1 if bad else 0)
EOF
run python3 "$TMP_ROOT/creds.py" "$ROOT/.github/workflows/ci.yml"
check "ci.yml: no job hands the forge credentials or a token to a pull request's code" 0 "OK"
# The template's form before this fix fails the same check.
sed -e 's/for v in GOPRIVATE; do/for v in GOPRIVATE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; do/' \
	"$ROOT/.github/workflows/ci.yml" >"$TMP_ROOT/creds-old.yml"
run python3 "$TMP_ROOT/creds.py" "$TMP_ROOT/creds-old.yml"
check "ci.yml: an env-file loop that copies GIT_CONFIG_* fails the check" 1 "a loop copies GOPRIVATE GIT_CONFIG_COUNT"

# --- A trusted run never uses a toolchain tag the shared daemon holds ---
# (Codex security P1: a pull request's job can tag any image with main's tag.)
# The stub docker keeps each local reference's image ID, and its RepoDigests,
# as files under $IMG_STATE; an image ID is a reference to itself. The
# registry is $IMG_STATE/registry/, present while it is up: a tag's file
# holds its manifest digest, a digest's file its image ID. A build gives
# sha256:<sha256 of its target> and writes it to its --iidfile; a buildx
# build pushes its result as sha256:<sha256 of manifest:<target>>. Every
# container start (create, run) is logged to $IMG_STARTS. The races another
# job on the shared daemon can run:
#   IMG_RACE_PULL   after any pull, the toolchain's remote tag is moved to an
#                   older image the registry still holds ($IMG_OLD, $DOLD)
#   IMG_RACE_PUSH   a push first finds the tag moved to $IMG_EVIL
#   IMG_REG_OVERWRITE  after a buildx push, the registry's tag names $DOLD
#   IMG_NOBUILDX    the runner has no buildx plugin
mkdir -p "$TMP_ROOT/imgbin"
cat >"$TMP_ROOT/imgbin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$IMG_LOG"
key() { printf '%s' "$1" | tr '/:@' '___'; }
s=$IMG_STATE
r=$s/registry
h() { printf '%s' "$1" | sha256sum | cut -c1-64; }
case "$1 ${2:-}" in
"image inspect")
	ref=${*: -1}
	k=$(key "$ref")
	[ -f "$s/$k" ] || exit 1
	case "${3:-} ${4:-}" in
	"--format "*RepoDigests*) cat "$s/$k.digests" 2>/dev/null || true ;;
	"--format "* | "-f "*) cat "$s/$k" ;;
	*) echo '[]' ;;
	esac ;;
"image rm") rm -f "$s/$(key "$3")" "$s/$(key "$3").digests" ;;
"pull -q")
	[ -d "$r" ] || exit 1
	ref=$3
	case $ref in
	*@*) repo=${ref%@*} d=${ref#*@} ;;
	*) repo=${ref%:*}; d=$(cat "$r/$(key "$ref")" 2>/dev/null) || exit 1 ;;
	esac
	id=$(cat "$r/$(key "$d")" 2>/dev/null) || exit 1
	echo "$id" >"$s/$(key "$ref")"
	echo "$id" >"$s/$(key "$id")"
	echo "$repo@$d" >"$s/$(key "$ref").digests"
	if [ -n "${IMG_RACE_PULL:-}" ]; then
		echo "$IMG_OLD" >"$s/$(key "$IMG_REMOTE")"
		echo "$IMG_OLD" >"$s/$(key "$IMG_OLD")"
		echo "${IMG_REMOTE%:*}@$DOLD" >"$s/$(key "$IMG_REMOTE").digests"
	fi ;;
"tag "*)
	case $3 in *@*) echo "refusing to create a tag with a digest reference" >&2; exit 1 ;; esac
	cp "$s/$(key "$2")" "$s/$(key "$3")"
	if [ -f "$s/$(key "$2").digests" ]; then cp "$s/$(key "$2").digests" "$s/$(key "$3").digests"; else rm -f "$s/$(key "$3").digests"; fi ;;
"push "*)
	ref=${*: -1}
	if [ -n "${IMG_RACE_PUSH:-}" ]; then echo "$IMG_EVIL" >"$s/$(key "$ref")"; fi
	id=$(cat "$s/$(key "$ref")")
	d=sha256:$(h "pushed:$id")
	echo "$d" >"$r/$(key "$ref")"
	echo "$id" >"$r/$(key "$d")"
	echo "${ref%:*}@$d" >"$s/$(key "$ref").digests" ;;
"build "*)
	iid= tag= target=
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--iidfile) iid=$2; shift 2 ;;
		-t) tag=$2; shift 2 ;;
		--target) target=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	id=sha256:$(h "$target")
	echo "$id" >"$s/$(key "$id")"
	if [ -n "$tag" ]; then echo "$id" >"$s/$(key "$tag")"; rm -f "$s/$(key "$tag").digests"; fi
	if [ -n "$iid" ]; then printf '%s' "$id" >"$iid"; fi ;;
"buildx "*)
	[ -z "${IMG_NOBUILDX:-}" ] || { echo "docker: unknown command: docker buildx" >&2; exit 1; }
	case $2 in
	version) echo "github.com/docker/buildx v0 stub" ;;
	imagetools)
		[ "${3:-}" = inspect ] && [ -d "$r" ] || exit 1
		d=$(cat "$r/$(key "$4")" 2>/dev/null) || exit 1
		printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1}\n' "$d" ;;
	build)
		meta= out= target=
		shift 2
		while [ $# -gt 0 ]; do
			case $1 in
			--metadata-file) meta=$2; shift 2 ;;
			--output) out=$2; shift 2 ;;
			--target) target=$2; shift 2 ;;
			*) shift ;;
			esac
		done
		case $out in type=registry,name=*) name=${out#type=registry,name=} ;; *) exit 4 ;; esac
		[ -d "$r" ] || exit 1
		id=sha256:$(h "$target")
		d=sha256:$(h "manifest:$target")
		echo "$d" >"$r/$(key "$name")"
		echo "$id" >"$r/$(key "$d")"
		echo "$id" >"$s/$(key "$name")"
		printf '{"containerimage.digest":"%s"}\n' "$d" >"$meta"
		if [ -n "${IMG_REG_OVERWRITE:-}" ]; then echo "$DOLD" >"$r/$(key "$name")"; fi ;;
	*) exit 3 ;;
	esac ;;
"create "* | "run "*)
	echo "$*" >>"$IMG_STARTS"
	case " $* " in *" --entrypoint du "*) printf '4\t/c\n' ;; esac ;;
"cp "*) cat >/dev/null ;;
"start "* | "rm "* | "ps "*) ;;
"volume ls") echo "${IMG_VOLS:-}" ;;
"login "*) cat >/dev/null ;;
"manifest inspect") exit 1 ;;
*) echo "stub docker: unexpected $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP_ROOT/imgbin/docker"
IMG_LOG=$TMP_ROOT/img.log
IMG_STATE=$TMP_ROOT/img
IMG_STARTS=$TMP_ROOT/img-starts.log
IMG_GOOD=sha256:$(printf 'a%.0s' {1..64})
IMG_OLD=sha256:$(printf 'b%.0s' {1..64})
IMG_EVIL=sha256:$(printf 'e%.0s' {1..64})
DGOOD=sha256:$(printf 'd%.0s' {1..64})
DOLD=sha256:$(printf 'c%.0s' {1..64})
ltag=trusted-imx95-toolchain:abc
itag=trusted-imx95-integration:abc
rrepo=forge.example/ns/trusted-imx95-toolchain
IMG_REMOTE=$rrepo:abc-main
export IMG_LOG IMG_STATE IMG_STARTS IMG_GOOD IMG_OLD IMG_EVIL DGOOD DOLD IMG_REMOTE
tc_built=sha256:$(printf '%s' toolchain | sha256sum | cut -c1-64)
tc_pushed=sha256:$(printf '%s' manifest:toolchain | sha256sum | cut -c1-64)
it_built=sha256:$(printf '%s' integration | sha256sum | cut -c1-64)
skey() { printf '%s' "$1" | tr '/:@' '___'; }
lkey=$(skey "$ltag")
rkey=$(skey "$IMG_REMOTE")
rt=$TMP_ROOT/rt # the job's RUNNER_TEMP
# seed yes|empty|no: a fresh daemon whose $ltag and $itag a pull request
# tagged with its own image ($IMG_EVIL), and a registry that holds the
# toolchain's remote tag (yes), only an older image (empty), or is down (no).
seed() {
	rm -rf "$IMG_STATE" "$rt"
	mkdir -p "$IMG_STATE" "$rt"
	: >"$IMG_LOG"
	: >"$IMG_STARTS"
	: >"$TMP_ROOT/github_env"
	echo "$IMG_EVIL" >"$IMG_STATE/$lkey"
	echo "$IMG_EVIL" >"$IMG_STATE/$(skey "$itag")"
	echo "$IMG_EVIL" >"$IMG_STATE/$(skey "$IMG_EVIL")"
	[ "$1" != no ] || return 0
	mkdir -p "$IMG_STATE/registry"
	echo "$IMG_OLD" >"$IMG_STATE/registry/$(skey "$DOLD")"
	[ "$1" = yes ] || return 0
	echo "$DGOOD" >"$IMG_STATE/registry/$rkey"
	echo "$IMG_GOOD" >"$IMG_STATE/registry/$(skey "$DGOOD")"
}
# move: a pull request's job moves both tags back to its image.
move() { echo "$IMG_EVIL" >"$IMG_STATE/$lkey"; echo "$IMG_EVIL" >"$IMG_STATE/$(skey "$itag")"; }
cache() { # cache <event> [pull|publish]: ci-image-cache.sh on the forge, for <event>
	env PATH="$TMP_ROOT/imgbin:$PATH" GITHUB_EVENT_NAME="$1" GITHUB_SERVER_URL=https://forge.example \
		CI_IMAGE_NAMESPACE=ns TOOLCHAIN_IMAGE="$ltag" GITHUB_ENV="$TMP_ROOT/github_env" RUNNER_TEMP="$rt" \
		"$ROOT/scripts/ci-image-cache.sh" "${2:-pull}"
}
here=$PWD
cd "$ROOT" || exit 1
seed yes
run cache push
check "ci-image-cache: a push run pulls by the registry's digest over a tag the daemon already holds" 0 \
	"pulled $rrepo@$DGOOD as $IMG_GOOD"
expect "ci-image-cache: the push run reads the tag's digest from the registry" \
	grep -qx "buildx imagetools inspect $IMG_REMOTE --format {{json .Manifest}}" "$IMG_LOG"
expect "ci-image-cache: the push run pulls the digest itself" grep -qx "pull -q $rrepo@$DGOOD" "$IMG_LOG"
if grep -qx "pull -q $IMG_REMOTE" "$IMG_LOG"; then
	fail "ci-image-cache: the push run never pulls the mutable tag" "$(cat "$IMG_LOG")"
else
	pass "ci-image-cache: the push run never pulls the mutable tag"
fi
expect "ci-image-cache: the push run exports the verified image ID" \
	grep -qx "TOOLCHAIN_VERIFIED_ID=$IMG_GOOD" "$TMP_ROOT/github_env"
# Finding 3: another job retags the remote tag between the pull and the
# digest's read, to an older image the registry still holds.
seed yes
IMG_RACE_PULL=1 run cache push
if { [ "$RC" = 0 ] && grep -qx "TOOLCHAIN_VERIFIED_ID=$IMG_GOOD" "$TMP_ROOT/github_env"; } ||
	{ [ "$RC" != 0 ] && [ ! -s "$TMP_ROOT/github_env" ]; }; then
	pass "ci-image-cache: a retag between the pull and the digest's read never exports another image"
else
	fail "ci-image-cache: a retag between the pull and the digest's read never exports another image" \
		"rc $RC; $(cat "$TMP_ROOT/github_env"); $OUT"
fi
seed no
run cache schedule
check "ci-image-cache: a scheduled run with the registry down falls back to the build, not the seeded tag" 1 \
	"the registry gave no digest for $IMG_REMOTE"
if [ -s "$TMP_ROOT/github_env" ]; then
	fail "ci-image-cache: a failed trusted pull exports no verified ID" "$(cat "$TMP_ROOT/github_env")"
else
	pass "ci-image-cache: a failed trusted pull exports no verified ID"
fi
seed yes
IMG_NOBUILDX=1 run cache push
check "ci-image-cache: a trusted pull on a runner without buildx falls back to the build" 1 "no docker buildx"
if [ -s "$TMP_ROOT/github_env" ]; then
	fail "ci-image-cache: a trusted pull without buildx exports no verified ID" "$(cat "$TMP_ROOT/github_env")"
else
	pass "ci-image-cache: a trusted pull without buildx exports no verified ID"
fi
seed yes
run cache pull_request
check "ci-image-cache: a pull request still uses the tag its daemon holds" 0 "the daemon holds $ltag; no pull"

# The Makefile's builds (docker-build-toolchain, docker-build) and the
# references they record.
mk() { # mk <event> <target> [VAR=value...]
	local ev=$1
	shift
	env PATH="$TMP_ROOT/imgbin:$PATH" GITHUB_EVENT_NAME="$ev" RUNNER_TEMP="$rt" \
		make --no-print-directory -C "$ROOT" "$@" TOOLCHAIN_IMAGE="$ltag" IT_IMAGE="$itag"
}
seed yes
run mk push docker-build-toolchain
check "make docker-build-toolchain: a push run rebuilds over a seeded tag" 0 "rebuilds $ltag from source"
expect "make docker-build-toolchain: the trusted rebuild uses no cache and records its ID" \
	grep -q "^build --no-cache --iidfile $rt/toolchain-image.id --target toolchain -t $ltag " "$IMG_LOG"
run mk push -s toolchain-ref
check "make toolchain-ref: a push run prints the ID its rebuild recorded" 0 "$tc_built"
seed yes
echo "$IMG_GOOD" >"$IMG_STATE/$(skey "$IMG_GOOD")"
TOOLCHAIN_VERIFIED_ID=$IMG_GOOD run mk push docker-build-toolchain
check "make docker-build-toolchain: a push run uses the verified pull, by its ID" 0 \
	"uses the image pulled by digest, by its ID ($IMG_GOOD)"
if grep -q '^build' "$IMG_LOG"; then fail "make docker-build-toolchain: a verified pull is not rebuilt" "$(cat "$IMG_LOG")"; else pass "make docker-build-toolchain: a verified pull is not rebuilt"; fi
run mk push -s toolchain-ref
check "make toolchain-ref: a push run prints the verified ID, not the seeded tag's" 0 "$IMG_GOOD"
seed yes
TOOLCHAIN_VERIFIED_ID=$IMG_GOOD run mk push docker-build-toolchain
expect "make docker-build-toolchain: a verified ID the daemon lacks is rebuilt" \
	grep -q "^build --no-cache --iidfile .* --target toolchain" "$IMG_LOG"
seed yes
run env -u RUNNER_TEMP PATH="$TMP_ROOT/imgbin:$PATH" GITHUB_EVENT_NAME=push \
	make --no-print-directory -C "$ROOT" docker-build-toolchain TOOLCHAIN_IMAGE="$ltag"
check "make docker-build-toolchain: a trusted run with nowhere to record the ID fails" nonzero "records its image ID"
seed yes
run mk push -s it-ref
check "make it-ref: a trusted run with no recorded ID fails, never prints the tag" nonzero "holds no image ID"
seed yes
run mk push docker-build
expect "make docker-build: a push run rebuilds the integration image with no cache, recording its ID" \
	grep -q "^build --no-cache --iidfile $rt/it-image.id --target integration" "$IMG_LOG"
expect "make docker-build: the trusted rebuild labels the image with its repository, for the reaper" \
	grep -q "^build .*--target integration --label ci.reap.repository=${itag%:*} " "$IMG_LOG"
seed yes
rm -f "$IMG_STATE/$(skey "$itag")"
run mk pull_request docker-build
expect "make docker-build: a local build labels the image with its repository, for the reaper" \
	grep -q "^build --target integration --label ci.reap.repository=${itag%:*} " "$IMG_LOG"
seed yes
run mk pull_request docker-build
if [ "$RC" = 0 ] && ! grep -q '^build' "$IMG_LOG"; then
	pass "make docker-build: a pull request keeps the tags its daemon holds"
else
	fail "make docker-build: a pull request keeps the tags its daemon holds" "rc $RC; $(cat "$IMG_LOG"); $OUT"
fi
run mk pull_request -s toolchain-ref
check "make toolchain-ref: a pull request prints the tag" 0 "$ltag"

# A trusted job end to end, as ci.yml runs it: the pull, the build, the
# exported reference; then a pull request's job moves both tags, and every
# container the job starts (the cache trim, each stage, the integration
# test, docker-run) must still name an image ID.
mkdir -p "$TMP_ROOT/tcsrc"
seed yes
cache push >/dev/null
ver=$(sed -n 's/^TOOLCHAIN_VERIFIED_ID=//p' "$TMP_ROOT/github_env")
TOOLCHAIN_VERIFIED_ID=$ver mk push docker-build-toolchain >/dev/null
tref=$(mk push -s toolchain-ref)
mk push docker-build >/dev/null
iref=$(mk push -s it-ref)
move
: >"$IMG_STARTS"
tc() { (cd "$TMP_ROOT/tcsrc" && env PATH="$TMP_ROOT/imgbin:$PATH" GITHUB_EVENT_NAME=push \
	IN_IMAGE_CPUS=1 IN_IMAGE_MEMORY=1g CI_STACK_PREFIX=t-ci- "$@"); }
run tc env IMG_VOLS=t-ci-cache-main-gobuild "$ROOT/scripts/trim-ci-caches.sh" t-ci- "$tref"
check "trim-ci-caches: a push run measures with the image ID" 0 "caches:"
run tc "$ROOT/scripts/in-toolchain-image.sh" "$tref" true
check "in-toolchain-image: a push run starts its stage by the image ID" 0
run mk push integration-test IT_IMAGE_ID="$iref" IT_PROJECT=t-it
check "make integration-test: a push run starts the leased image ID" 0
run mk push integration-test IT_PROJECT=t-it2
check "make integration-test: a push run without IT_IMAGE_ID starts the ID its build recorded" 0
TOOLCHAIN_VERIFIED_ID=$ver run mk push docker-run CMD=true
check "make docker-run: a push run starts the image ID" 0
starts=$(grep -c . "$IMG_STARTS" || true)
untagged=$(grep -cvE " sha256:[0-9a-f]{64}( |$)" "$IMG_STARTS" || true)
if [ "$starts" -ge 6 ] && [ "$untagged" = 0 ] && ! grep -qE "$ltag|$itag" "$IMG_STARTS"; then
	pass "a trusted job: no container start receives a tag ($starts starts, after the tags moved)"
else
	fail "a trusted job: no container start receives a tag ($starts starts, after the tags moved)" "$(cat "$IMG_STARTS")"
fi
expect "a trusted job: the stages run the verified toolchain ID" grep -q " $IMG_GOOD " "$IMG_STARTS"
expect "a trusted job: the integration test runs the integration build's ID" grep -q " $it_built make -C /src" "$IMG_STARTS"
: >"$IMG_STARTS"
run tc "$ROOT/scripts/in-toolchain-image.sh" "$ltag" true
check "in-toolchain-image: a push run refuses a tag" 2 "never by a tag: $ltag"
run tc "$ROOT/scripts/trim-ci-caches.sh" t-ci- "$ltag"
check "trim-ci-caches: a push run refuses a tag" 2 "never by a tag: $ltag"
run mk push integration-test IT_IMAGE_ID="$itag" IT_PROJECT=t-it3
check "make integration-test: an IT_IMAGE_ID that is a tag is refused" nonzero "must be an image ID"
expect "a trusted job: a refused tag starts no container" test ! -s "$IMG_STARTS"
run tc env GITHUB_EVENT_NAME=pull_request "$ROOT/scripts/in-toolchain-image.sh" "$ltag" true
check "in-toolchain-image: a pull request may still name a tag" 0
# Finding 2: publish pushes the build's own result, never a local tag
# another job can move, and checks the registry's digest after the push.
pub() { GITHUB_REF=refs/heads/main RELEASE_REGISTRY_USER=u RELEASE_REGISTRY_TOKEN=fake-token cache push publish; }
reg_image() { cat "$IMG_STATE/registry/$(skey "$(cat "$IMG_STATE/registry/$rkey")")"; }
seed empty
run pub
check "ci-image-cache: publish pushes the image its build made" 0 "published $ltag as $rrepo@$tc_pushed"
expect "ci-image-cache: the registry's tag names the built image" test "$(reg_image)" = "$tc_built"
expect "ci-image-cache: publish builds straight to the registry" \
	grep -q "^buildx build .*--output type=registry,name=$IMG_REMOTE " "$IMG_LOG"
if grep -qE '^(push|tag) ' "$IMG_LOG"; then
	fail "ci-image-cache: publish resolves no local tag (no docker tag or push)" "$(cat "$IMG_LOG")"
else
	pass "ci-image-cache: publish resolves no local tag (no docker tag or push)"
fi
if [[ "$OUT" == *fake-token* ]]; then fail "ci-image-cache: publish prints no credential" "$OUT"; else pass "ci-image-cache: publish prints no credential"; fi
seed empty
IMG_RACE_PUSH=1 run pub
if [ "$RC" != 0 ] || [ "$(reg_image)" = "$tc_built" ]; then
	pass "ci-image-cache: a retag between the tag and the push never publishes another image as done"
else
	fail "ci-image-cache: a retag between the tag and the push never publishes another image as done" "registry $(reg_image); $OUT"
fi
seed empty
IMG_REG_OVERWRITE=1 run pub
check "ci-image-cache: publish fails when the registry's digest is not the build's" 1 \
	"the registry's $IMG_REMOTE is $DOLD, not the image this run built ($tc_pushed)"
seed empty
IMG_NOBUILDX=1 run pub
check "ci-image-cache: publish without buildx fails" 1 "publish needs the runner's docker buildx"
seed yes
run pub
check "ci-image-cache: publish leaves a tag the registry holds" 0 "the registry holds $IMG_REMOTE; nothing to publish"
cd "$here" || exit 1

# ci.yml exports TOOLCHAIN_IMAGE only from toolchain-ref (lint, history-scan,
# image, lint-gates), and hands the integration test the leased ID.
ci=$(<"$ROOT/.github/workflows/ci.yml")
# shellcheck disable=SC2016 # the patterns match ci.yml's literal shell text
n_ref=$(grep -c 'ref=$(make -s toolchain-ref)' <<<"$ci" || true)
# shellcheck disable=SC2016
n_tag=$(grep -c 'TOOLCHAIN_IMAGE=$(make -s toolchain-image)' <<<"$ci" || true)
# shellcheck disable=SC2016
n_it=$(grep -cE 'make (integration-test|"\$SOAK_TARGET") .*IT_IMAGE_ID="\$IT_LEASE_ID"' <<<"$ci" || true)
if [ "$n_ref" = 4 ] && [ "$n_tag" = 0 ] && [ "$n_it" = 2 ]; then
	pass "ci.yml: every job exports the toolchain-ref reference and runs the integration image by its leased ID"
else
	fail "ci.yml: every job exports the toolchain-ref reference and runs the integration image by its leased ID" "toolchain-ref $n_ref, tag $n_tag, IT_IMAGE_ID $n_it"
fi

# --- reap-stale-ci-stacks.sh v6: the dangling images a rebuild leaves --------
# (Codex reliability P1: each trusted rebuild moves the content tag to a new
# ID and leaves the old ID dangling, which the tag loop never sees.) A stub
# docker holds images as lines "<id> <created> <label> <tag or ->" in
# $RP/images and containers as "<id> <image id>" in $RP/containers; `docker
# image rm` refuses an image a container uses, as Docker does.
mkdir -p "$TMP_ROOT/reapbin"
cat >"$TMP_ROOT/reapbin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$RP/log"
case "$1 ${2:-}" in
"ps -a")
	case " $* " in
	*" -q --filter ancestor="*)
		img=${!#}
		img=${img#ancestor=}
		while read -r cid on; do [ "$on" != "$img" ] || echo "$cid"; done <"$RP/containers" ;;
	esac ;;
"images "*)
	case " $* " in
	*" --filter dangling=true "*)
		want=${!#}
		want=${want#label=}
		while read -r id _ lab tag; do [ "$tag" = - ] && [ "ci.reap.repository=$lab" = "$want" ] && echo "$id"; done <"$RP/images" ;;
	*) while read -r _ _ _ tag; do [ "$tag" = - ] || echo "$tag"; done <"$RP/images" ;;
	esac ;;
"image inspect")
	ref=${*: -1}
	while read -r id created _ tag; do
		if [ "$ref" = "$id" ] || [ "$ref" = "$tag" ]; then
			case $3 in -f) case $4 in *Id*) echo "$id $created" ;; *LastTagTime*) echo "0001-01-01 00:00:00 +0000 UTC" ;; *) echo "$created" ;; esac ;; esac
			exit 0
		fi
	done <"$RP/images"
	[ "$ref" = "${REAP_PREFIX}image-lock:base" ] || exit 1 ;;
"image rm")
	ref=$3
	id=$ref
	while read -r i _ _ tag; do [ "$ref" != "$tag" ] || id=$i; done <"$RP/images"
	while read -r _ on; do [ "$on" != "$id" ] || { echo "conflict: image is being used" >&2; exit 1; }; done <"$RP/containers"
	grep -v "^$id " "$RP/images" >"$RP/images.new"
	mv "$RP/images.new" "$RP/images"
	echo "$id" >>"$RP/removed" ;;
"create --pull") echo lock-id ;;
"rm "*) ;;
*) echo "stub docker: unexpected $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP_ROOT/reapbin/docker"
RP=$TMP_ROOT/reap
REAP_PREFIX=trusted-imx95-ci-
export RP REAP_PREFIX
mkdir -p "$RP"
rid() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
old=$(date -u -d '-5 hours' +%Y-%m-%dT%H:%M:%SZ)
new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lab="${REAP_PREFIX}it"
cat >"$RP/images" <<EOF
$(rid current) $new $lab ${REAP_PREFIX}it:abc
$(rid dangling) $old $lab -
$(rid leased) $old $lab -
$(rid fresh) $new $lab -
$(rid other) $old other-ci-it -
EOF
echo "lease-container $(rid leased)" >"$RP/containers"
: >"$RP/removed"
: >"$RP/log"
run env PATH="$TMP_ROOT/reapbin:$PATH" "$ROOT/scripts/reap-stale-ci-stacks.sh" "$REAP_PREFIX"
check "reap-stale-ci-stacks: a dangling repository image no lease uses is removed" 0 "reap  dangling image $(rid dangling)" \
	"keep  dangling image $(rid leased) (in use: 1 container(s))" "keep  dangling image $(rid fresh) (created within"
expect "reap-stale-ci-stacks: the dangling image is gone from the daemon" grep -qx "$(rid dangling)" "$RP/removed"
expect "reap-stale-ci-stacks: a dangling image a live lease holds is kept" grep -q "^$(rid leased) " "$RP/images"
if grep -qx "$(rid leased)" "$RP/removed" || grep -q "image rm $(rid leased)" "$RP/log"; then
	fail "reap-stale-ci-stacks: the leased image is never asked to go" "$(cat "$RP/log")"
else
	pass "reap-stale-ci-stacks: the leased image is never asked to go"
fi
expect "reap-stale-ci-stacks: a just-built dangling image is kept" grep -q "^$(rid fresh) " "$RP/images"
expect "reap-stale-ci-stacks: another repository's dangling image is not touched" grep -q "^$(rid other) " "$RP/images"
expect "reap-stale-ci-stacks: the current tagged image is kept" grep -q "^$(rid current) " "$RP/images"
expect "reap-stale-ci-stacks: dangling images are found by the label the Makefile sets" \
	grep -qx "images -q --no-trunc --filter dangling=true --filter label=ci.reap.repository=$lab" "$RP/log"
echo "$(rid dangling) $old $lab -" >>"$RP/images"
cp "$RP/images" "$RP/images.before"
run env PATH="$TMP_ROOT/reapbin:$PATH" REAP_DRY_RUN=1 "$ROOT/scripts/reap-stale-ci-stacks.sh" "$REAP_PREFIX"
check "reap-stale-ci-stacks: a dry run names what it would remove and removes nothing" 0 "dry   docker image rm $(rid dangling)"
expect "reap-stale-ci-stacks: the dry run left every image" cmp -s "$RP/images" "$RP/images.before"
expect "Makefile: the label the reaper reads is the one every integration build sets" \
	grep -q 'IT_REAP_LABEL *= ci.reap.repository=' "$ROOT/Makefile"

# --- the toolchain image carries ssh-keygen ------------------------------------
# (Codex P1: git's SSH signature checks below run ssh-keygen -Y; Alpine's
# git package does not supply it.)
expect "Dockerfile: the toolchain stage installs openssh-keygen" \
	python3 -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"FROM base AS toolchain\n(.*?)\n(?:FROM|\Z)", t, re.S); sys.exit(0 if m and re.search(r"apk add [^\n]*\bopenssh-keygen\b", m.group(1)) else 1)' \
	"$ROOT/build/docker/devcontainer/Dockerfile"

# --- signatures.yml: the adoption push, against real SSH-signed git fixtures ---
# (Codex P1: the adoption merge's push has a before with no registry.) The
# step's script is taken from the workflow and run as written; it fetches
# from no origin here, so it reads only the fixture's objects.
python3 - "$ROOT/.github/workflows/signatures.yml" >"$TMP_ROOT/sigstep.sh" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(lines) if "- name: Verify commit signatures" in l)
i = next(n for n in range(i, len(lines)) if lines[n].strip() == "run: |")
ind = len(lines[i]) - len(lines[i].lstrip()) + 2
out = []
for l in lines[i + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) < ind:
        break
    out.append(l[ind:])
print("\n".join(out))
EOF
if [ -s "$TMP_ROOT/sigstep.sh" ]; then pass "signatures.yml: the verify step's script is extracted"; else fail "signatures.yml: the verify step's script is extracted"; fi
sr=$TMP_ROOT/sigrepo
mkdir -p "$sr"
# No skip: without ssh-keygen the fixtures cannot be made, and that fails.
if ! command -v ssh-keygen >/dev/null 2>&1; then
	fail "signatures.yml fixtures: ssh-keygen is not on PATH (the toolchain image installs openssh-keygen; outside it, install OpenSSH's ssh-keygen)"
else
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$TMP_ROOT/sigkey" # a throwaway key for the fixture only
ssh-keygen -q -t ed25519 -N '' -C other -f "$TMP_ROOT/otherkey"
g() { git -C "$sr" -c user.name=Dev -c user.email=dev@example.com -c gpg.format=ssh \
	-c user.signingkey="$TMP_ROOT/${KEY:-sigkey}" -c commit.gpgsign=true "$@"; }
g init -q -b main
echo a >"$sr/README"
g add README && g commit -q -m "main before the adoption"
A=$(g rev-parse HEAD)
g checkout -q -b adopt
mkdir -p "$sr/.github"
echo "dev@example.com $(cut -d' ' -f1-2 "$TMP_ROOT/sigkey.pub")" >"$sr/.github/allowed_signers"
g add .github && g commit -q -m "ci: the signer registry"
B=$(g rev-parse HEAD)
g checkout -q main
g merge -q --no-ff -m "Merge the adoption" adopt
M=$(g rev-parse HEAD)
echo b >>"$sr/README"
g commit -q -am "after the adoption"
M2=$(g rev-parse HEAD)
# A second adoption whose registry commit the registered key did not sign.
g checkout -q -b adopt2 "$A"
mkdir -p "$sr/.github"
echo "dev@example.com $(cut -d' ' -f1-2 "$TMP_ROOT/sigkey.pub")" >"$sr/.github/allowed_signers"
g add .github && KEY=otherkey g commit -q -m "ci: the registry, signed by another key"
g checkout -q -b main2 "$A"
g merge -q --no-ff -m "Merge the second adoption" adopt2
M3=$(g rev-parse HEAD)
sig() { # sig <event> <before> <head> [base]: the step, in the fixture
	(cd "$sr" && env EVENT="$1" BEFORE="$2" HEAD_SHA="$3" BASE_SHA="${4:-}" PR="${4:+1}" REPO=o/r \
		API=http://127.0.0.1:9 GH_TOKEN= RUNNER_TEMP="$TMP_ROOT" bash "$TMP_ROOT/sigstep.sh")
}
run sig push "$A" "$M"
check "signatures.yml: the adoption push verifies against the registry its merge adds" 0 \
	"the adoption push: it adds the registry" "OK   ${B:0:12} signed by dev@example.com" "OK   ${M:0:12} signed by dev@example.com"
run sig push "$A" "$M2"
check "signatures.yml: a push whose last commit does not add the registry still fails" 1 \
	"FAIL no .github/allowed_signers at the base ${A:0:12}"
run sig push "$M" "$M2"
check "signatures.yml: a later push reads the registry at its before" 0 "registry: .github/allowed_signers at ${M:0:12}"
run sig push "$A" "$M3"
check "signatures.yml: the adoption push still fails a commit the registered key did not sign" 1 \
	"the adoption push" "FAIL $(g rev-parse adopt2 | cut -c1-12) signed by a key not in the registry"
run sig pull_request_target "" "$B" "$A"
check "signatures.yml: a pull request that adds the registry is still judged by its base's" 1 \
	"FAIL no .github/allowed_signers at the base ${A:0:12}"
fi

finish
