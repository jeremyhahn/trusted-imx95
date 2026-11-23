#!/usr/bin/env bash
# The "Runner labels (ruling 633)" step of ci.yml (ci-template v1.54, #159),
# run on fixture workflows. The step is a python script inside ci.yml; it is
# extracted here and run in a directory holding the fixtures.
#
# This repository departs from the template at handbook 1ad68ab8 in one place:
# an `||` whose left operand is unknown (vars.*, inputs.*, ...) is unknown, not
# the literal fallback on its right, because the variable may hold any label.
# `vars.RUNNER || 'ubuntu-latest'` therefore does not count as hosted
# (Codex security P1 at verify 5).
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$TMP_ROOT/runner-labels"
mkdir -p "$work/.github/workflows"
python3 -I - "$ROOT/.github/workflows/ci.yml" "$work/step.py" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, s in enumerate(lines) if "- name: Runner labels (ruling 633)" in s)
a = next(i for i in range(start, len(lines)) if lines[i].strip().endswith("python3 -I - <<'PY'")) + 1
b = next(i for i in range(a, len(lines)) if lines[i].strip() == "PY")
ind = len(lines[a]) - len(lines[a].lstrip())
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(s[ind:] for s in lines[a:b]) + "\n")
PY
check "the runner-labels step is extracted" 0
# The step reads workflows with PyYAML; the step installs it when missing (never a skip).
if ! python3 -I -c 'import yaml' 2>/dev/null; then
	YAML_DIR="$TMP_ROOT/pyyaml"
	python3 -m pip install --quiet --disable-pip-version-check --target "$YAML_DIR" pyyaml
	export YAML_DIR
fi
check "PyYAML is importable by the step" 0

# stepcmd: the step, from the fixture directory. The step refuses a tree with no
# ci.yml, so one fixture workflow runs beside a copy of the real ci.yml unless
# the case wrote its own ci.yml or sets NOSEED.
stepcmd() {
	if [ ! -f "$work/.github/workflows/ci.yml" ] && [ -z "${NOSEED:-}" ]; then
		cp "$ROOT/.github/workflows/ci.yml" "$work/.github/workflows/ci.yml"
	fi
	run bash -c "cd '$work' && python3 -I step.py"
}

# fixture <runs-on text> [if text] [on text]: a one-job workflow, run through
# the step. The default triggers include pull_request, so an untrusted event.
fixture() {
	local cond=${2:+"    if: $2"} on=${3:-[push, pull_request]}
	rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
	cat >"$work/.github/workflows/${FIXNAME:-t.yml}" <<EOF
name: t
on: $on
jobs:
  build:
    runs-on: $1
$cond
    steps:
      - run: true
EOF
	stepcmd
}

fixture "ubuntu-latest"
check "a standard image passes" 0 "OK:"
# Any `${{` in a runs-on is refused unless it is exactly one of the template's
# selection expressions, in every workflow whatever its triggers (verify 8).
T="[push, workflow_dispatch]"
for ro in "\${{ 'ubuntu-latest' }}" "\${{ 'ubuntu-latest' || vars.RUNNER }}" "\${{ vars.RUNNER }}" \
	"\${{ vars.RUNNER || 'ubuntu-latest' }}" "\${{ inputs.runner || 'ubuntu-latest' }}" \
	"\${{ vars.RUNNER || vars.OTHER || 'ubuntu-latest' }}"; do
	fixture "$ro" "" "$T"
	check "an expression is refused in a trusted-only workflow: $ro" 1 "(a) its runs-on holds an expression"
	fixture "$ro"
	check "an expression is refused under a pull_request: $ro" 1 "(a) its runs-on holds an expression"
done

# Evaluated labels count for the release restriction (Codex security P1 at
# verify 6): a waiver comment relaxes the hosted/self-hosted class rule only.
fixture "\${{ format('re{0}', 'lease') }} # self-hosted: hardware: dedicated host"
check "a format()-built release label with a waiver is refused" 1 "(a) its runs-on holds an expression"
fixture "\${{ format('re{0}', 'lease') }}"
check "a format()-built release label without a waiver is refused" 1 "(a) its runs-on holds an expression"
fixture "\${{ join(fromJSON('[\"re\",\"lease\"]'), '') }} # self-hosted: oversize: big job"
check "a join() of an unknown with a waiver is refused" 1 "(a) its runs-on holds an expression"
fixture "release # self-hosted: hardware: dedicated host"
check "a literal release with a waiver is refused" 1 "(a) names \`release\`"
# Local fix on top of v1.54 (#159, verify 8): a self-hosted waiver never admits a
# fork head under pull_request or pull_request_target.
fixture "[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason"
check "a waived self-hosted list under default pull_request triggers is refused" 1 "(f) its \`# self-hosted:\` waiver does not cover a fork head"
fixture "[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason" "" "[pull_request_target]"
check "a waived self-hosted list under pull_request_target is refused" 1 "(f) its \`# self-hosted:\` waiver does not cover a fork head"
fixture "[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason" "" "[push, workflow_dispatch]"
check "a waived self-hosted list whose triggers exclude fork heads passes" 0 "OK:"

# Verify 9 (security P1): the fork guard is per job, never file-wide, and a local
# reusable workflow inherits its callers' triggers.
G='github.event.pull_request.head.repo.full_name == github.repository'
W='[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason'
resetwf() { rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml; }
wfwrite() { cat >"$work/.github/workflows/$1"; }
# shellcheck disable=SC2016  # the backticks are the finding's literal text
FORKMSG='(f) its `# self-hosted:` waiver does not cover a fork head'

resetwf
wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  a:
    if: "$G"
    runs-on: ubuntu-latest
    steps:
      - run: true
  b:
    runs-on: $W
    steps:
      - run: true
EOF
stepcmd
check "an unrelated job's guard does not exempt an unconditional waived job" 1 "$FORKMSG"

for c in "$G || true" "$G || github.event_name == 'push'" "(\${{ $G }}) || always()" "!($G)"; do
	resetwf
	wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  b:
    if: "$c"
    runs-on: $W
    steps:
      - run: true
EOF
	stepcmd
	check "a guard that a top-level || or a negation bypasses is refused: $c" 1 "$FORKMSG"
done

for c in "$G" "github.event.pull_request.state == 'open' && $G" "always() && $G"; do
	resetwf
	wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  b:
    if: "$c"
    runs-on: $W
    steps:
      - run: true
EOF
	stepcmd
	check "a job requiring the same-repository head passes: $c" 0 "OK:"
done

for dep in "" "    if: github.event.pull_request.state == 'open'"; do
	resetwf
	wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  a:
    if: "$G"
    runs-on: ubuntu-latest
    steps:
      - run: true
  b:
    needs: a
$dep
    runs-on: $W
    steps:
      - run: true
EOF
	stepcmd
	check "a job needing a guarded job passes ($dep)" 0 "OK:"
done

for dep in "always()" "failure()" "cancelled() || needs.a.result == 'success'"; do
	resetwf
	wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  a:
    if: "$G"
    runs-on: ubuntu-latest
    steps:
      - run: true
  b:
    needs: [a]
    if: "$dep"
    runs-on: $W
    steps:
      - run: true
EOF
	stepcmd
	check "a dependent that runs whatever its need did is refused: $dep" 1 "$FORKMSG"
done

# Local reusable workflows: the callee inherits the callers' triggers.
callee() { # <runs-on line> [if]
	wfwrite callee.yml <<EOF
name: callee
on: workflow_call
jobs:
  c:
${2:+    if: "$2"}
    runs-on: $1
    steps:
      - run: true
EOF
}
caller() { # <on>
	wfwrite caller.yml <<EOF
name: caller
on: $1
jobs:
  call:
    uses: ./.github/workflows/callee.yml
EOF
}
resetwf; caller "[pull_request]"; callee "$W"; stepcmd
check "a pull_request caller of a waived self-hosted callee is refused" 1 "$FORKMSG"
resetwf; caller "[pull_request_target]"; callee "$W"; stepcmd
check "a pull_request_target caller of a waived self-hosted callee is refused" 1 "$FORKMSG"
resetwf; caller "[push, workflow_dispatch]"; callee "$W"; stepcmd
check "a push-only caller of the same callee passes" 0 "OK:"
resetwf; caller "[pull_request]"; callee "$W" "$G"; stepcmd
check "a callee guarded per job passes under a pull_request caller" 0 "OK:"
resetwf; callee "$W"; stepcmd
check "a callee no local workflow calls is held to the fork rule" 1 "$FORKMSG"

# Verify 10: triggers propagate through nested local callees; expression names are
# case-insensitive.
chain() { # <a's on> <condition on the a->b calling job, or empty>
	resetwf
	wfwrite a.yml <<EOF
name: a
on: $1
jobs:
  call:
${2:+    if: "$2"}
    uses: ./.github/workflows/b.yml
EOF
	wfwrite b.yml <<EOF
name: b
on: workflow_call
jobs:
  call:
    uses: ./.github/workflows/c.yml
EOF
	wfwrite c.yml <<EOF
name: c
on: workflow_call
jobs:
  c:
    runs-on: $W
    steps:
      - run: true
EOF
}
chain "[pull_request]"; stepcmd
check "a pull_request a -> b -> c chain refuses the waived job in c" 1 "$FORKMSG"
chain "[push]"; stepcmd
check "the same chain from a push-only a passes" 0 "OK:"
chain "[pull_request]" "$G"; stepcmd
check "a guarded a -> b edge carries no pull_request" 0 "OK:"
resetwf
wfwrite a.yml <<EOF
name: a
on: [pull_request]
jobs:
  call:
    uses: ./.github/workflows/b.yml
EOF
for pair in b:c c:b; do
	wfwrite "${pair%%:*}.yml" <<EOF
name: n
on: workflow_call
jobs:
  call:
    uses: ./.github/workflows/${pair##*:}.yml
  w:
    runs-on: $W
    steps:
      - run: true
EOF
done
stepcmd
check "a b <-> c cycle reached from a pull_request caller is refused" 1 "$FORKMSG"

for fn in "ALWAYS()" "Always()" "Failure()" "Cancelled()" "aLwAyS ()"; do
	resetwf
	wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  a:
    if: "$G"
    runs-on: ubuntu-latest
    steps:
      - run: true
  b:
    needs: a
    if: "$fn"
    runs-on: $W
    steps:
      - run: true
EOF
	stepcmd
	check "a dependent using $fn is refused" 1 "$FORKMSG"
done
resetwf
wfwrite t.yml <<EOF
name: t
on: [pull_request]
jobs:
  b:
    if: "GitHub.Event.Pull_Request.Head.Repo.Full_Name == GITHUB.repository"
    runs-on: $W
    steps:
      - run: true
EOF
stepcmd
check "a mixed-case but correct guard is still recognised" 0 "OK:"

# Codex security P1s at verify 7: the release decision is an allowlist.
# (1) head_ref is an arbitrary branch name, never simulated.
fixture "release" "github.event_name == 'pull_request' && github.head_ref == 'topic'"
check "a release job on a head_ref condition is refused" 1 "(a) names \`release\`"
fixture "release" "github.ref_name == 'x'"
check "a release job on a ref_name condition is refused" 1 "(a) names \`release\`"
fixture "release" ""
check "a release job with no if is refused" 1 "(a) names \`release\`"
fixture "release" "github.event_name == 'push' && github.ref == 'refs/heads/main'"
check "a release job on exactly the push-to-main condition passes" 0 "OK:"
fixture "release" "\${{ github.event_name == 'push'  &&  github.ref == 'refs/heads/main' }}"
check "the allowlisted condition is read whitespace-normalized" 0 "OK:"
# (2) a list element's expression is never evaluated.
fixture "[self-hosted, linux, x64, \"\${{ format('re{0}', 'lease') }}\"] # self-hosted: hardware: dedicated host"
check "an expression inside a list element with a waiver is refused" 1 "(a) its runs-on holds an expression"
fixture "[self-hosted, linux, x64, \"\${{ vars.X }}\"]"
check "an expression inside a list element without a waiver is refused" 1 "(a) its runs-on holds an expression"
# (3) github.server_url is not always github.com.
fixture "\${{ github.server_url == 'https://github.com' && 'ubuntu-latest' || format('re{0}', 'lease') }}"
check "a server_url selection that falls to release is refused" 1 "(a) its runs-on holds an expression"
FIXNAME=ci.yml fixture "\${{ github.server_url == 'https://github.com' && fromJSON(needs.preflight.outputs.runner_docker) || 'bigdisk' }}"
check "the selection expression with no pinned producer is refused" 1 "(a) its runs-on holds an expression"

# Codex security P1 at verify 9: a selection expression is exempt only where its
# producer is the template's own preflight job (pinned by digest).
rm -f "$work"/.github/workflows/*.yml
cat >"$work/.github/workflows/ci.yaml" <<'EOF'
name: t
on: [pull_request]
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      runner_docker: '"release"'
    steps:
      - run: true
  build:
    needs: [preflight]
    runs-on: ${{ github.server_url == 'https://github.com' && fromJSON(needs.preflight.outputs.runner_docker) || 'bigdisk' }}
    steps:
      - run: true
EOF
stepcmd
check "a new workflow with its own preflight exporting release is refused" 1 "(a) its runs-on holds an expression"
rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
sed 's/Preflight \[changed files/Preflight [altered files/' "$ROOT/.github/workflows/ci.yml" >"$work/.github/workflows/ci.yml"
stepcmd
check "an altered ci.yml preflight job loses the exemption" 1 "(a) its runs-on holds an expression"
# One `run` line of a non-guard preflight step changed (the Runner labels
# step's own run is replaced by a marker in the pin, so it is not the target).
sed 's/not a schedule run: no check"/not a schedule run: no checks"/' "$ROOT/.github/workflows/ci.yml" >"$work/.github/workflows/ci.yml"
if cmp -s "$ROOT/.github/workflows/ci.yml" "$work/.github/workflows/ci.yml"; then
	echo "FAIL fixture is identical to ci.yml: the run-line edit did not apply"
	exit 1
fi
stepcmd
check "a changed run line in a non-guard preflight step loses the exemption" 1 "(a) its runs-on holds an expression"
# Codex security P1 at verify 11: what preflight inherits from the workflow
# level is pinned too. Only a workflow-level defaults.run.shell wrapper, or only
# a workflow-level env entry, is added to the real ci.yml.
sed '0,/^env:$/s//defaults:\n  run:\n    shell: "bash {0}"\nenv:/' "$ROOT/.github/workflows/ci.yml" >"$work/.github/workflows/ci.yml"
if cmp -s "$ROOT/.github/workflows/ci.yml" "$work/.github/workflows/ci.yml"; then
	echo "FAIL fixture is identical to ci.yml: the defaults edit did not apply"
	exit 1
fi
stepcmd
check "a workflow-level defaults.run.shell wrapper loses the exemption" 1 "(a) its runs-on holds an expression"
sed '0,/^env:$/s//env:\n  BASH_ENV: \/tmp\/wrapper.sh/' "$ROOT/.github/workflows/ci.yml" >"$work/.github/workflows/ci.yml"
if cmp -s "$ROOT/.github/workflows/ci.yml" "$work/.github/workflows/ci.yml"; then
	echo "FAIL fixture is identical to ci.yml: the env edit did not apply"
	exit 1
fi
stepcmd
check "a workflow-level env entry loses the exemption" 1 "(a) its runs-on holds an expression"

# Codex security P1s at verify 8: the workflow is parsed as YAML, and every
# release job meets the allowlist whatever the triggers.
rawfile() { # rawfile <content>: one workflow, run through the step
	rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
	printf '%s\n' "$1" >"$work/.github/workflows/t.yml"
	stepcmd
}
rawfile "name: t
on: [push, pull_request]
'jobs':
  a:
    runs-on: [self-hosted, linux, x64, release]
    steps:
      - run: true"
check "a quoted jobs key with a release job in a PR workflow is refused" 1 "(a) names \`release\`"
rawfile "name: t
on: [pull_request]
jobs: {a: {runs-on: release, steps: [{run: true}]}}"
check "a flow-map jobs with a release job in a PR workflow is refused" 1 "(a) names \`release\`"
rawfile "name: t
on: [pull_request]
\"jobs\": {a: {runs-on: [self-hosted, linux, x64, release], steps: [{run: true}]}}"
check "a quoted jobs key in flow form is refused" 1 "(a) names \`release\`"
rawfile "name: t
'on': [push]
jobs:
  a:
    runs-on: release
    if: github.ref == 'refs/heads/topic'
    steps:
      - run: true"
check "a release job on a push-only workflow with a topic-branch if is refused" 1 "(a) names \`release\`"
fixture "release" "github.ref == 'refs/heads/topic'" "[push, workflow_dispatch]"
check "a release job on a push and dispatch workflow with a topic-branch if is refused" 1 "(a) names \`release\`"
fixture "release" "github.event_name == 'push' && github.ref == 'refs/heads/main'" "[push]"
check "the allowlisted condition passes in a push-only workflow" 0 "OK:"
rawfile "name: t
on: [push
jobs: [a"
check "unparseable YAML is refused" 1 "not parseable YAML"
rawfile "name: t
on: [push]"
check "a workflow with no jobs is refused" 1 "no \`jobs\` mapping"
# Reusable-workflow callers (#159, Codex security P1 at verify 20): a job-level
# `uses:` has no runs-on. Only a local ./.github/workflows/<file>.yml of this
# checkout is accepted; every file of the directory is scanned, so a local
# callee and a nested one are held to the same rules.
callfile() { # callfile <name> <content>: add one workflow file beside t.yml
	printf '%s\n' "$2" >"$work/.github/workflows/$1"
}
rl_callee_ok='name: c
on: workflow_call
jobs:
  c:
    runs-on: ubuntu-latest
    steps:
      - run: true'
rl_callee_rel='name: c
on: workflow_call
jobs:
  c:
    runs-on: [self-hosted, linux, x64, release]
    steps:
      - run: true'
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: owner/trusted-imx95/.github/workflows/other.yml@refs/heads/other"
check "a remote reusable-workflow callee at another ref is refused" 1 "calls reusable workflow owner/trusted-imx95"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/c.yml@refs/heads/other"
check "a local callee with a ref is refused" 1 "calls reusable workflow"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/c.yml"
callfile c.yml "$rl_callee_rel"
stepcmd
check "a local callee selecting a release runner is refused" 1 "names \`release\`"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/c.yml"
callfile c.yml "$rl_callee_ok"
stepcmd
check "a local callee on allowed runners is accepted" 0 "OK:"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/c.yml"
callfile c.yml "name: c
on: workflow_call
jobs:
  c:
    uses: ./.github/workflows/d.yml"
callfile d.yml "$rl_callee_rel"
stepcmd
check "a nested local call is scanned" 1 "d.yml:c: (a) names \`release\`"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/missing.yml"
check "a local callee that is not a file of the checkout is refused" 1 "calls reusable workflow"
rawfile "name: t
on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/t.yml"
check "a local workflow calling itself is read once, not looped" 0 "OK:"
rawfile "name: t
on: [push]
jobs:
  a:
    runs-on: {group: g, labels: release}
    steps:
      - run: true"
check "a runs-on mapping is refused" 1 "neither a string nor a list of strings"

# This repository's own workflows still pass under the stricter evaluator.
rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
cp "$ROOT"/.github/workflows/*.yml "$work/.github/workflows/"
stepcmd
check "this repository's workflows pass the runner-label check" 0 "OK:"

# Codex security P1 at verify 12: the guard fails closed on its input.
# (a) only a preflight `defaults.run.working-directory` added to the real ci.yml.
rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
sed '0,/^        shell: bash$/s//        shell: bash\n        working-directory: \/tmp/' "$ROOT/.github/workflows/ci.yml" >"$work/.github/workflows/ci.yml"
if cmp -s "$ROOT/.github/workflows/ci.yml" "$work/.github/workflows/ci.yml"; then
	echo "FAIL fixture is identical to ci.yml: the working-directory edit did not apply"
	exit 1
fi
stepcmd
check "a preflight defaults.run.working-directory loses the exemption" 1 "(a) its runs-on holds an expression"
# (b) the step run from another current directory still checks the real tree.
rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
cp "$ROOT"/.github/workflows/*.yml "$work/.github/workflows/"
run bash -c "cd /tmp && RL_ROOT='$work' python3 -I '$work/step.py'"
check "the step run from another directory still checks every workflow of the tree" 0 "OK:"
run bash -c "cd /tmp && RL_ROOT='$work' python3 -I '$work/step.py'"
check "the other-directory run names the workflows it read" 0 "workflow file(s)"
# (c) an empty workflows directory, and a tree without ci.yml, are refused.
rm -f "$work"/.github/workflows/*.yml "$work"/.github/workflows/*.yaml
NOSEED=1 stepcmd
check "an empty workflows directory is refused" 1 "no workflow file"
fixture "ubuntu-latest" "" "[push]" >/dev/null 2>&1 || true
rm -f "$work"/.github/workflows/ci.yml
NOSEED=1 stepcmd
check "a tree without ci.yml is refused" 1 "ci.yml is not among the workflow files"
rm -rf "$work/.github"
NOSEED=1 stepcmd
check "a missing workflows directory is refused" 1 "is not a directory"
mkdir -p "$work/.github/workflows"

# The step executes and imports nothing from the checkout (Codex security P1 at
# verify 13). The complete step body, bootstrap included, runs with PyYAML hidden
# from the "is it installed" probe, against a tree carrying a root-level pip.py and
# yaml/__init__.py that each write a marker file. No network: pip installs a wheel
# built here from the PyYAML this test already has, through a python3 shim that only
# hides the probe and points pip at that wheel; the real `python3 -I -m pip` runs.
rl="$TMP_ROOT/rl13"
rm -rf "$rl"
mkdir -p "$rl/tree/.github/workflows" "$rl/tree/yaml" "$rl/shim" "$rl/wheels" "$rl/rt"
cp "$ROOT"/.github/workflows/*.yml "$rl/tree/.github/workflows/"
printf 'open(%s, "w").write("pip")\n' "'$rl/marker-pip'" >"$rl/tree/pip.py"
printf 'open(%s, "w").write("yaml")\n' "'$rl/marker-yaml'" >"$rl/tree/yaml/__init__.py"
python3 -I - "$rl/wheels" "$ROOT/.github/workflows/ci.yml" "$rl/body.sh" <<'PY'
import os, shutil, sys, zipfile
wheels, ci, body = sys.argv[1:4]
if os.environ.get("YAML_DIR"):
    sys.path.insert(0, os.environ["YAML_DIR"])
import yaml
src = os.path.dirname(yaml.__file__)
with zipfile.ZipFile(os.path.join(wheels, "PyYAML-6.0-py3-none-any.whl"), "w") as z:
    for d, _, fs in os.walk(src):
        for f in fs:
            if f.endswith(".py"):
                p = os.path.join(d, f)
                z.write(p, os.path.join("yaml", os.path.relpath(p, src)))
    di = "PyYAML-6.0.dist-info/"
    z.writestr(di + "METADATA", "Metadata-Version: 2.1\nName: PyYAML\nVersion: 6.0\n")
    z.writestr(di + "WHEEL", "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
    z.writestr(di + "RECORD", "")
lines = open(ci, encoding="utf-8").read().splitlines()
s = next(i for i, l in enumerate(lines) if "- name: Runner labels (ruling 633)" in l)
r = next(i for i in range(s, len(lines)) if lines[i].strip() == "run: |") + 1
ind = len(lines[r]) - len(lines[r].lstrip())
e = r
while e < len(lines) and (not lines[e].strip() or len(lines[e]) - len(lines[e].lstrip()) >= ind):
    e += 1
open(body, "w", encoding="utf-8").write("\n".join(l[ind:] for l in lines[r:e]) + "\n")
PY
run bash -c "[ -s '$rl/body.sh' ] && [ -f '$rl/wheels/PyYAML-6.0-py3-none-any.whl' ]"
check "the whole step body and a local wheel are built" 0
real_py=$(command -v python3)
cat >"$rl/shim/python3" <<SH
#!/bin/bash
if [ "\$*" = "-I -c import yaml" ]; then exit 1; fi
case " \$* " in *" -m pip "*) exec "$real_py" "\$@" --no-index --find-links "$rl/wheels" ;; esac
exec "$real_py" "\$@"
SH
chmod +x "$rl/shim/python3"
bodycmd() {
	run env -u YAML_DIR PATH="$rl/shim:$PATH" RL_ROOT="$rl/tree" RUNNER_TEMP="$rl/rt" \
		bash -c "cd '$rl/tree' && bash -e '$rl/body.sh'"
}
bodycmd
check "the whole step, bootstrap included, installs PyYAML and checks the real workflows" 0 "OK:"
run bash -c "[ ! -e '$rl/marker-pip' ]"
check "a root-level pip.py in the checkout is not run by the bootstrap" 0
run bash -c "[ ! -e '$rl/marker-yaml' ]"
check "a root-level yaml package in the checkout is not imported" 0
# A PyYAML install target inside the checkout is refused before anything is imported.
mkdir -p "$rl/tree/evil"
cp -r "$rl/tree/yaml" "$rl/tree/evil/yaml"
run env YAML_DIR="$rl/tree/evil" RL_ROOT="$rl/tree" bash -c "cd '$rl' && python3 -I '$work/step.py'"
check "a PyYAML that would load from inside the checkout is refused" 1 "imports nothing from the checkout"
run bash -c "[ ! -e '$rl/marker-yaml' ]"
check "the refused checkout PyYAML was not imported" 0

# v1.54 local change (#159, verify 16): a workflow_dispatch on ci/deps-bump is
# refused, as on main's v1.35.2 file, so no full-tier run waits on a
# Releasability (push) status the producer never makes for that branch. The
# test evaluates the preflight's own dispatch condition.
ciy="$ROOT/.github/workflows/ci.yml"
# shellcheck disable=SC2016 # the pattern is ci.yml's text, $EVENT is not ours
dl=$(grep -m1 -F 'if [ "$EVENT" = workflow_dispatch ]' "$ciy")
dl=${dl#"${dl%%[![:space:]]*}"}
dispatch() { EVENT=workflow_dispatch REF=$1 bash -c "verdict=run; $dl verdict=refused; fi; echo verdict=\$verdict" 2>/dev/null; }
run dispatch refs/heads/ci/deps-bump
check "preflight: a dispatch on ci/deps-bump is refused" 0 "verdict=refused"
run dispatch refs/heads/topic
check "preflight: a dispatch on another branch is refused" 0 "verdict=refused"
run dispatch refs/heads/main
check "preflight: a dispatch on main still runs" 0 "verdict=run"
if grep -qE "github\.ref == 'refs/heads/ci/deps-bump'" "$ciy"; then
	fail "ci.yml: no full-tier expression admits ci/deps-bump" "$(grep -nE "github\.ref == 'refs/heads/ci/deps-bump'" "$ciy")"
else
	pass "ci.yml: no full-tier expression admits ci/deps-bump"
fi

finish
