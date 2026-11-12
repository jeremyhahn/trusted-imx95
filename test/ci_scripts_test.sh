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
# The stub docker keeps each reference's image ID, and its RepoDigests, as
# files under $IMG_STATE; an image ID is a reference to itself. A pull
# succeeds while $IMG_STATE/registry exists and gives the registry's image,
# $IMG_GOOD, digest sha256:dgood. A build gives sha256:<sha256 of its target>
# and writes it to its --iidfile. Every container start (create, run) is
# logged to $IMG_STARTS.
mkdir -p "$TMP_ROOT/imgbin"
cat >"$TMP_ROOT/imgbin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$IMG_LOG"
key() { printf '%s' "$1" | tr '/:@' '___'; }
s=$IMG_STATE
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
	[ -f "$s/registry" ] || exit 1
	ref=$3
	repo=${ref%@*}
	[ "$repo" != "$ref" ] || repo=${ref%:*}
	echo "$IMG_GOOD" >"$s/$(key "$ref")"
	echo "$IMG_GOOD" >"$s/$(key "$IMG_GOOD")"
	if [ -z "${IMG_NODIGEST:-}" ]; then echo "$repo@sha256:dgood" >"$s/$(key "$ref").digests"; fi ;;
"tag "*)
	cp "$s/$(key "$2")" "$s/$(key "$3")"
	if [ -f "$s/$(key "$2").digests" ]; then cp "$s/$(key "$2").digests" "$s/$(key "$3").digests"; else rm -f "$s/$(key "$3").digests"; fi ;;
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
	id=sha256:$(printf '%s' "$target" | sha256sum | cut -c1-64)
	echo "$id" >"$s/$(key "$id")"
	if [ -n "$tag" ]; then echo "$id" >"$s/$(key "$tag")"; rm -f "$s/$(key "$tag").digests"; fi
	if [ -n "$iid" ]; then printf '%s' "$id" >"$iid"; fi ;;
"create "* | "run "*)
	echo "$*" >>"$IMG_STARTS"
	case " $* " in *" --entrypoint du "*) printf '4\t/c\n' ;; esac ;;
"cp "*) cat >/dev/null ;;
"start "* | "rm "* | "ps "* | "push "*) ;;
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
IMG_EVIL=sha256:$(printf 'e%.0s' {1..64})
export IMG_LOG IMG_STATE IMG_STARTS IMG_GOOD
ltag=trusted-imx95-toolchain:abc
itag=trusted-imx95-integration:abc
tc_built=sha256:$(printf '%s' toolchain | sha256sum | cut -c1-64)
it_built=sha256:$(printf '%s' integration | sha256sum | cut -c1-64)
skey() { printf '%s' "$1" | tr '/:@' '___'; }
lkey=$(skey "$ltag")
rt=$TMP_ROOT/rt # the job's RUNNER_TEMP
# seed <registry up: yes|no>: a fresh daemon whose $ltag and $itag a pull
# request tagged with its own image ($IMG_EVIL, no registry digest).
seed() {
	rm -rf "$IMG_STATE" "$rt"
	mkdir -p "$IMG_STATE" "$rt"
	: >"$IMG_LOG"
	: >"$IMG_STARTS"
	: >"$TMP_ROOT/github_env"
	echo "$IMG_EVIL" >"$IMG_STATE/$lkey"
	echo "$IMG_EVIL" >"$IMG_STATE/$(skey "$itag")"
	echo "$IMG_EVIL" >"$IMG_STATE/$(skey "$IMG_EVIL")"
	[ "$1" = no ] || : >"$IMG_STATE/registry"
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
check "ci-image-cache: a push run pulls by digest over a tag the daemon already holds" 0 \
	"pulled forge.example/ns/trusted-imx95-toolchain@sha256:dgood as $ltag"
expect "ci-image-cache: the push run's tag names the registry's image, not the seeded one" \
	grep -qx "$IMG_GOOD" "$IMG_STATE/$lkey"
expect "ci-image-cache: the push run pulls the digest itself" \
	grep -qx "pull -q forge.example/ns/trusted-imx95-toolchain@sha256:dgood" "$IMG_LOG"
expect "ci-image-cache: the push run exports the verified image ID" \
	grep -qx "TOOLCHAIN_VERIFIED_ID=$IMG_GOOD" "$TMP_ROOT/github_env"
seed no
run cache schedule
check "ci-image-cache: a scheduled run with the registry down falls back to the build, not the seeded tag" 1 \
	"is not in the registry"
if [ -s "$TMP_ROOT/github_env" ]; then
	fail "ci-image-cache: a failed trusted pull exports no verified ID" "$(cat "$TMP_ROOT/github_env")"
else
	pass "ci-image-cache: a failed trusted pull exports no verified ID"
fi
seed yes
IMG_NODIGEST=1 run cache push
check "ci-image-cache: a trusted pull with no registry digest falls back to the build" 1 "has no registry digest"
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
# publish tags the ID its build recorded, not the tag another job moved.
seed yes
rm -f "$IMG_STATE/registry"
GITHUB_REF=refs/heads/main RELEASE_REGISTRY_USER=u RELEASE_REGISTRY_TOKEN=fake-token run cache push publish
check "ci-image-cache: publish pushes the image its build recorded" 0 "published $ltag"
expect "ci-image-cache: publish tags the recorded ID, never the local tag" \
	grep -qx "tag $tc_built forge.example/ns/$ltag-main" "$IMG_LOG"
if [[ "$OUT" == *fake-token* ]]; then fail "ci-image-cache: publish prints no credential" "$OUT"; else pass "ci-image-cache: publish prints no credential"; fi
cd "$here" || exit 1

# ci.yml exports TOOLCHAIN_IMAGE only from toolchain-ref, and hands the
# integration test the leased ID.
ci=$(<"$ROOT/.github/workflows/ci.yml")
# shellcheck disable=SC2016 # the patterns match ci.yml's literal shell text
n_ref=$(grep -c 'ref=$(make -s toolchain-ref)' <<<"$ci" || true)
# shellcheck disable=SC2016
n_tag=$(grep -c 'TOOLCHAIN_IMAGE=$(make -s toolchain-image)' <<<"$ci" || true)
# shellcheck disable=SC2016
n_it=$(grep -cE 'make (integration-test|"\$SOAK_TARGET") .*IT_IMAGE_ID="\$IT_LEASE_ID"' <<<"$ci" || true)
if [ "$n_ref" = 3 ] && [ "$n_tag" = 0 ] && [ "$n_it" = 2 ]; then
	pass "ci.yml: every job exports the toolchain-ref reference and runs the integration image by its leased ID"
else
	fail "ci.yml: every job exports the toolchain-ref reference and runs the integration image by its leased ID" "toolchain-ref $n_ref, tag $n_tag, IT_IMAGE_ID $n_it"
fi

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
