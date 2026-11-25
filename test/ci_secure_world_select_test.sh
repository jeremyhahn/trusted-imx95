#!/usr/bin/env bash
# test/ci_secure_world_select_test.sh: offline checks of ci.yml's secure-world
# selection (the preflight diff step's `secure_world` output) and of CI Gate's
# `sw` skip mode. Both steps' scripts are extracted from the workflow as
# written and run, the diff step in a git fixture, the gate step with stubbed
# job results. CI_YML overrides the workflow under test (a mutation check).
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YML=${CI_YML:-$ROOT/.github/workflows/ci.yml}

# helper <mode> ...: python over the workflow text.
#   step <step name> <out>     a step's run script, as written
#   env <NAME>                 a top-level env value, unquoted
#   gate <script> <out> <job=result,...>   the gate script with its
#                              ${{ needs.<job>.result }} expressions filled in
helper() {
	python3 -I - "$YML" "$@" <<'EOF'
import re, sys
yml, mode = sys.argv[1], sys.argv[2]
lines = open(yml).read().split("\n")
if mode == "step":
    i = next(n for n, l in enumerate(lines) if l.strip() == "- name: " + sys.argv[3])
    i = next(n for n in range(i, len(lines)) if lines[n].strip() == "run: |")
    ind = len(lines[i]) - len(lines[i].lstrip()) + 2
    out = []
    for l in lines[i + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) < ind:
            break
        out.append(l[ind:])
    open(sys.argv[4], "w").write("\n".join(out) + "\n")
elif mode == "env":
    l = next(l for l in lines if re.match(r"  " + sys.argv[3] + r": ", l))
    v = l.split(": ", 1)[1].strip()
    if v.startswith("'") and v.endswith("'"):
        v = v[1:-1].replace("''", "'")
    print(v)
elif mode == "gate":
    res = dict(kv.split("=", 1) for kv in sys.argv[5].split(",") if kv)
    s = open(sys.argv[3]).read()
    s = re.sub(r"\$\{\{ needs\.([a-z-]+)\.result \}\}", lambda m: res.get(m.group(1), "success"), s)
    open(sys.argv[4], "w").write(s)
EOF
}

SW_PATTERN=$(helper env SECURE_WORLD_PATTERN)
DOCS_PATTERN=$(helper env DOCS_ONLY_PATTERN)
LINT_PATTERN=$(helper env LINT_GATES_PATTERN)
expect "ci.yml: SECURE_WORLD_PATTERN is read" test -n "$SW_PATTERN"

helper step "Is every changed file docs or markdown?" "$TMP_ROOT/diff.sh"
helper step "Fail closed on any non-success" "$TMP_ROOT/gate.sh"
expect "ci.yml: the preflight diff script is extracted" test -s "$TMP_ROOT/diff.sh"
expect "ci.yml: the CI Gate script is extracted" test -s "$TMP_ROOT/gate.sh"

# The job's own `if:` runs on anything but a false selection.
# shellcheck disable=SC2016 # the workflow's own ${{ }} text, matched literally
expect "ci.yml: preflight exports the secure_world output" \
	grep -qF 'secure_world: ${{ steps.diff.outputs.secure_world }}' "$YML"
expect "ci.yml: secure-world-build runs unless secure_world is 'false'" \
	grep -qF "needs.preflight.outputs.secure_world != 'false' }}" "$YML"

# --- selection: the diff step in a fixture repo -----------------------------
fx=$TMP_ROOT/fx
mkdir -p "$fx"
fxg() { git -C "$fx" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
fxg init -q -b main
printf 'base\n' >"$fx/seed"
fxg add -A
fxg commit -q -m base
BASE=$(fxg rev-parse HEAD)

# select <event> <full tier> <path...>: runs the diff step on a PR (or other
# event) that changes the paths; prints the secure_world output.
select_sw() {
	local event=$1 full=$2 p head
	shift 2
	fxg checkout -q -B work "$BASE"
	for p in "$@"; do
		mkdir -p "$fx/$(dirname "$p")"
		printf 'change\n' >"$fx/$p"
	done
	fxg add -A
	fxg commit -q -m change
	head=$(fxg rev-parse HEAD)
	: >"$TMP_ROOT/out"
	(cd "$fx" && env BASE="$BASE" HEAD="$head" EVENT="$event" CI_FULL_LABEL="$full" \
		DOCS_ONLY_PATTERN="$DOCS_PATTERN" LINT_GATES_PATTERN="$LINT_PATTERN" \
		SECURE_WORLD_PATTERN="$SW_PATTERN" GITHUB_OUTPUT="$TMP_ROOT/out" \
		bash "$TMP_ROOT/diff.sh") >"$TMP_ROOT/diff.log" 2>&1
	python3 -I -c 'import sys
for l in open(sys.argv[1]):
    if l.startswith("secure_world="): print(l.split("=",1)[1].strip())' "$TMP_ROOT/out"
}

want_sw() { # <name> <want> <event> <full> <path...>
	local name=$1 want=$2 got
	shift 2
	got=$(select_sw "$@")
	if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "secure_world=$got, want $want"; fi
}

want_sw "select: a README-only PR selects no secure-world build" false pull_request false README.md
want_sw "select: a docs-only PR selects no secure-world build" false pull_request false docs/threat-model.md docs/secure-world/build.md
want_sw "select: an unrelated script selects no secure-world build" false pull_request false scripts/other.sh
want_sw "select: a lookalike path selects none (scripts/secure-world-build.sh.bak)" false pull_request false scripts/secure-world-build.sh.bak
want_sw "select: a README plus a watched file selects it" true pull_request false README.md secure-world/bsp.lock

# Every watched input path, named. Keep in step with SECURE_WORLD_PATTERN.
for p in \
	secure-world/bsp.lock \
	secure-world/sub/dir/file \
	scripts/secure-world-build.sh \
	scripts/tool-pins.sh \
	scripts/in-toolchain-image.sh \
	scripts/image-tag.sh \
	build/docker/devcontainer/Dockerfile \
	test/secure_world_build_test.sh \
	Makefile \
	.github/workflows/ci.yml; do
	want_sw "select: a PR changing $p selects the build" true pull_request false "$p"
done

want_sw "select: a push selects the build (README only)" true push false README.md
want_sw "select: a schedule run selects the build (README only)" true schedule true README.md
want_sw "select: a workflow_dispatch run selects the build (README only)" true workflow_dispatch true README.md
want_sw "select: a PR with the full tier selects the build (README only)" true pull_request true README.md

# An empty diff is a doubt: it runs the job.
fxg checkout -q -B empty "$BASE"
: >"$TMP_ROOT/out"
(cd "$fx" && env BASE="$BASE" HEAD="$BASE" EVENT=pull_request CI_FULL_LABEL=false \
	DOCS_ONLY_PATTERN="$DOCS_PATTERN" LINT_GATES_PATTERN="$LINT_PATTERN" \
	SECURE_WORLD_PATTERN="$SW_PATTERN" GITHUB_OUTPUT="$TMP_ROOT/out" \
	bash "$TMP_ROOT/diff.sh") >/dev/null 2>&1
if [ "$(python3 -I -c 'import sys
print([l for l in open(sys.argv[1]) if l.startswith("secure_world=")][0].strip())' "$TMP_ROOT/out")" = secure_world=true ]; then
	pass "select: an empty PR diff selects the build"
else
	fail "select: an empty PR diff selects the build"
fi

# --- CI Gate: the `sw` skip mode --------------------------------------------
# gate <secure_world output> <secure-world-build result> [job=result,...]
gate() {
	local sel=$1 res=$2 extra=${3:-}
	helper gate "$TMP_ROOT/gate.sh" "$TMP_ROOT/gate-run.sh" "secure-world-build=$res${extra:+,$extra}"
	run env FULL_TIER=false NIGHTLY=false DRAFT=false SCHEDULE=false SCHEDULE_GUARD=run PROOF= \
		DOCS_ONLY=false LINT_GATES_SEL=true SECURE_WORLD_SEL="$([ "$sel" != false ] && echo true || echo false)" \
		bash "$TMP_ROOT/gate-run.sh"
}

gate true success
check "gate: selected and succeeded passes" 0 "OK   secure-world-build"
gate true failure
check "gate: selected and failed fails" 1 "FAIL secure-world-build (failure)"
gate true skipped
check "gate: selected and skipped unexpectedly fails" 1 "FAIL secure-world-build (skipped)"
gate true cancelled
check "gate: selected and cancelled fails" 1 "FAIL secure-world-build (cancelled)"
gate false skipped
check "gate: not selected and correctly skipped passes" 0 "SKIP secure-world-build (no changed file matches SECURE_WORLD_PATTERN)"
gate false success
check "gate: not selected but ran and succeeded passes" 0 "OK   secure-world-build"
gate false failure
check "gate: not selected but failed fails" 1 "FAIL secure-world-build (failure)"
# An sw skip never hides another job's failure.
gate false skipped lint=failure
check "gate: a correct sw skip does not mask another failure" 1 "FAIL lint (failure)"
# A proven tree accepts the selected build skipped; a refused guard fails.
gate true skipped
run env FULL_TIER=true NIGHTLY=false DRAFT=false SCHEDULE=false SCHEDULE_GUARD=proven PROOF=123 \
	DOCS_ONLY=false LINT_GATES_SEL=true SECURE_WORLD_SEL=true bash "$TMP_ROOT/gate-run.sh"
check "gate: a proven tree accepts the build skipped" 0 "SKIP secure-world-build (tree proven by run 123)"
gate false skipped
run env FULL_TIER=false NIGHTLY=false DRAFT=false SCHEDULE=false SCHEDULE_GUARD=refused PROOF= \
	DOCS_ONLY=false LINT_GATES_SEL=true SECURE_WORLD_SEL=false bash "$TMP_ROOT/gate-run.sh"
check "gate: a refused guard fails even with a correct sw skip" 1 "FAIL schedule-guard"
run env FULL_TIER=false NIGHTLY=false DRAFT=true SCHEDULE=false SCHEDULE_GUARD=run PROOF= \
	DOCS_ONLY=false LINT_GATES_SEL=true SECURE_WORLD_SEL=false bash "$TMP_ROOT/gate-run.sh"
check "gate: a draft PR fails" 1 "FAIL draft pull request"

# --- selection feeds the gate (the two steps joined) -------------------------
sel=$(select_sw pull_request false README.md)
gate "$sel" skipped
check "joined: a README-only PR with the build skipped passes the gate" 0 "SKIP secure-world-build"
sel=$(select_sw pull_request false secure-world/bsp.lock)
gate "$sel" skipped
check "joined: a secure-world PR with the build skipped fails the gate" 1 "FAIL secure-world-build (skipped)"
gate "$sel" success
check "joined: a secure-world PR with the build green passes the gate" 0 "OK   secure-world-build"

finish
