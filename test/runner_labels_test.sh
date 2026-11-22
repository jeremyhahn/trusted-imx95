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

# fixture <runs-on text> [if text] [on text]: a one-job workflow, run through
# the step. The default triggers include pull_request, so an untrusted event.
fixture() {
	local cond=${2:+"    if: $2"} on=${3:-[push, pull_request]}
	rm -f "$work"/.github/workflows/*.yml
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
	run bash -c "cd '$work' && python3 -I step.py"
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
fixture "[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason"
check "a literal self-hosted list with a waiver still passes" 0 "OK:"

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
check "the template's own selection expression is accepted" 0 "OK:"

# Codex security P1s at verify 8: the workflow is parsed as YAML, and every
# release job meets the allowlist whatever the triggers.
rawfile() { # rawfile <content>: one workflow, run through the step
	rm -f "$work"/.github/workflows/*.yml
	printf '%s\n' "$1" >"$work/.github/workflows/t.yml"
	run bash -c "cd '$work' && python3 -I step.py"
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
rawfile "name: t
on: [push]
jobs:
  a:
    runs-on: {group: g, labels: release}
    steps:
      - run: true"
check "a runs-on mapping is refused" 1 "neither a string nor a list of strings"

# This repository's own workflows still pass under the stricter evaluator.
rm -f "$work"/.github/workflows/*.yml
cp "$ROOT"/.github/workflows/*.yml "$work/.github/workflows/"
run bash -c "cd '$work' && python3 -I step.py"
check "this repository's workflows pass the runner-label check" 0 "OK:"

finish
