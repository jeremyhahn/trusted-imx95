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

finish
