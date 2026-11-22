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
a = next(i for i in range(start, len(lines)) if lines[i].strip() == "python3 -I - <<'PY'") + 1
b = next(i for i in range(a, len(lines)) if lines[i].strip() == "PY")
ind = len(lines[a]) - len(lines[a].lstrip())
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(s[ind:] for s in lines[a:b]) + "\n")
PY
check "the runner-labels step is extracted" 0

# fixture <runs-on text>: a one-job workflow, run through the step.
fixture() {
	rm -f "$work"/.github/workflows/*.yml
	cat >"$work/.github/workflows/t.yml" <<EOF
name: t
on: [push, pull_request]
jobs:
  build:
    runs-on: $1
    steps:
      - run: true
EOF
	run bash -c "cd '$work' && python3 -I step.py"
}

fixture "ubuntu-latest"
check "a standard image passes" 0 "OK:"
fixture "\${{ 'ubuntu-latest' }}"
check "a literal expression passes" 0 "OK:"
fixture "\${{ vars.RUNNER }}"
check "a bare unknown variable fails as an unknown label" 1 "an unknown label"
fixture "\${{ vars.RUNNER || 'ubuntu-latest' }}"
check "a variable with a hosted fallback is not hosted" 1 "an unknown label"
fixture "\${{ inputs.runner || 'ubuntu-latest' }}"
check "an input with a hosted fallback is not hosted" 1 "an unknown label"
fixture "\${{ vars.RUNNER || vars.OTHER || 'ubuntu-latest' }}"
check "two variables with a hosted fallback are not hosted" 1 "an unknown label"
fixture "\${{ 'ubuntu-latest' || vars.RUNNER }}"
check "a known hosted label ahead of a variable stays hosted" 0 "OK:"

# Evaluated labels count for the release restriction (Codex security P1 at
# verify 6): a waiver comment relaxes the hosted/self-hosted class rule only.
fixture "\${{ format('re{0}', 'lease') }} # self-hosted: hardware: dedicated host"
check "a format()-built release label with a waiver is refused" 1 "(a) names \`release\`"
fixture "\${{ format('re{0}', 'lease') }}"
check "a format()-built release label without a waiver is refused" 1 "(a) names \`release\`"
fixture "\${{ join(fromJSON('[\"re\",\"lease\"]'), '') }} # self-hosted: oversize: big job"
check "a join() of an unknown with a waiver is refused" 1 "(a) names \`release\`"
fixture "release # self-hosted: hardware: dedicated host"
check "a literal release with a waiver is refused" 1 "(a) names \`release\`"
fixture "[self-hosted, linux, x64, bigdisk] # self-hosted: hardware: a named reason"
check "a literal self-hosted list with a waiver still passes" 0 "OK:"

# This repository's own workflows still pass under the stricter evaluator.
rm -f "$work"/.github/workflows/*.yml
cp "$ROOT"/.github/workflows/*.yml "$work/.github/workflows/"
run bash -c "cd '$work' && python3 -I step.py"
check "this repository's workflows pass the runner-label check" 0 "OK:"

finish
