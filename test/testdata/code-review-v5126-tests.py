#!/usr/bin/env python3
# Copied unchanged from the handbook: software/templates/github-actions/testdata/code-review-v5126-tests.py at commit 824e4979.
"""code-review-v5126-tests.py -- the regression tests for code-review.yml
v5.12.6 (Tenant Agent ruling 1046: the gate held a hosted runner up to
4500 s while a twin run's Codex review queued for the one codex runner).

The gate's step is read out of the workflow file, not copied, and run under
bash and jq against a fake forge (a `curl` on PATH that answers from canned
bodies and logs every request) and a `sleep` on PATH that fails the test.
Nothing reaches the network.

  T. THE GATE JOB: timeout-minutes is 10 (ruling 580); no 4500 and no
     sleep is left in it.
  Q. A TWIN REVIEWS THE HEAD (its `Codex review` queued or in progress) and
     the head has no approval, or a REQUEST_CHANGES: the gate fails with
     exit 3 at once, naming the twin run, and never sleeps.
  A. A TWIN REVIEWS THE HEAD but the head is already APPROVED: it passes.
  N. NO TWIN (none listed, or a twin whose review has ended): the verdict
     decides as before (APPROVED passes, REQUEST_CHANGES and none fail).
  E. AN API ERROR listing the runs or a twin's jobs fails closed (exit 3),
     even with an approval of the head.

Run: python3 -I software/templates/github-actions/testdata/code-review-v5126-tests.py [workflow]
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
WORKFLOW = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "code-review.yml"
_ENV = WORKFLOW.read_text()
NON_CODE = re.search(r"\n  NON_CODE_PATHS: '([^']*)'\n", _ENV).group(1)
ROW_BRANCH = re.search(r"\n  ROW_BRANCH: '([^']*)'\n", _ENV).group(1)
TRUSTED_AUTHORS = re.search(r"\n  TRUSTED_AUTHORS: '([^']*)'\n", _ENV).group(1)
TRUSTED_PR = re.search(r"\n  TRUSTED_PR: '([^']*)'\n", _ENV).group(1)
FAILS = []
HEAD = "a" * 40
BASE = "b" * 40
REVIEWER = "codex-reviewer[bot]"
API = "https://api.github.test/repos/o/r"
TITLE = f"Code Review: PR #7 into main at {HEAD}"


def fatal(msg):
    print(f"FATAL: {msg}")
    sys.exit(9)


def once(pattern, text, what):
    found = re.findall(pattern, text, re.S)
    if len(found) != 1:
        fatal(f"{what}: found {len(found)} times in {WORKFLOW.name}, want 1")
    return found[0]


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


def job(src, name):
    return once(r"\n  " + re.escape(name) + r":\n(.*?)(?=\n  [a-z][a-z0-9-]*:\n|\Z)", src, f"the job '{name}'")


def step(text, name):
    return once(r"\n      - name: " + re.escape(name) + r"\n(.*?)(?=\n      - (?:name|uses): |\Z)",
                text, f"the step '{name}'")


def run_script(text):
    body = once(r"\n        run: \|\n(.*)", "\n" + text, "a run block")
    lines = []
    for line in body.split("\n"):
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines) + "\n"


FAKE_CURL = r'''#!/usr/bin/env python3
import fnmatch, json, os, sys
args = sys.argv[1:]
out = fmt = None
url = None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "-w", "-X", "-H", "--proto", "--max-time", "--retry", "--data-binary"):
        if a == "-o": out = args[i + 1]
        elif a == "-w": fmt = args[i + 1]
        i += 2
        continue
    if not a.startswith("-"):
        url = a
    i += 1
base = os.environ["FAKE_BASE"]
path = url[len(base):] if url.startswith(base) else url
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(path + "\n")
code, body = 404, '{"message":"no route"}'
for glob, c, b in json.loads(os.environ["FAKE_ROUTES"]):
    if fnmatch.fnmatchcase(path, glob):
        code, body = c, b
        break
if out:
    open(out, "w").write(body)
else:
    sys.stdout.write(body)
if fmt:
    sys.stdout.write(str(code))
'''

FAKE_SLEEP = "#!/bin/sh\necho \"sleep $*\" >> \"$FAKE_LOG\"\necho 'the gate slept' >&2\nexit 99\n"


def runs_body(ids):
    return json.dumps({"workflow_runs": [{"id": i, "display_title": TITLE} for i in ids]})


def jobs_body(status):
    return json.dumps({"jobs": [{"name": "scope", "status": "completed"},
                                {"name": "Codex review", "status": status}]})


def run_gate(script, verdict, queued=(), in_progress=(), twin_jobs="in_progress",
             runs_code=200, jobs_code=200):
    """verdict: APPROVED, REQUEST_CHANGES or None (no review of the head).
    Returns (exit code, output, requests, seconds)."""
    reviews = [] if verdict is None else [
        {"id": 1, "state": verdict, "commit_id": HEAD, "user": {"login": REVIEWER},
         "submitted_at": "2026-11-20T00:00:00Z"}]
    routes = [
        [f"/compare/{BASE}...{HEAD}", 200, json.dumps({"files": [{"filename": "pkg/x.go"}]})],
        ["/actions/runs/77", 200, json.dumps({"workflow_id": 5})],
        ["/actions/workflows/5/runs?*status=queued*", runs_code, runs_body([77] + list(queued))],
        ["/actions/workflows/5/runs?*status=in_progress*", runs_code, runs_body(list(in_progress))],
        ["/actions/runs/*/jobs?*", jobs_code, jobs_body(twin_jobs)],
        ["/pulls/7", 200, json.dumps({"head": {"sha": HEAD}, "labels": [{"name": "code-review"}]})],
        ["/pulls/7/reviews?*page=1", 200, json.dumps(reviews)],
        ["/pulls/7/reviews?*", 200, "[]"],
    ]
    with tempfile.TemporaryDirectory() as d:
        tmp = pathlib.Path(d)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("curl", FAKE_CURL), ("sleep", FAKE_SLEEP)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        log = tmp / "requests.log"
        log.write_text("")
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp), "FAKE_LOG": str(log),
               "FAKE_ROUTES": json.dumps(routes), "FAKE_BASE": API,
               "FORGE": "github", "REVIEWER": REVIEWER, "REPO_API": API, "PR_NUM": "7",
               "EVENT_SHA": HEAD, "BASE_SHA": BASE, "BASE_REF": "main", "GITHUB_RUN_ID": "77",
               "GH_API_TOKEN": "<REDACTED>",
               "NON_CODE_PATHS": NON_CODE, "ROW_BRANCH": ROW_BRANCH, "HEAD_REF": "row/1-x", "TRUSTED_AUTHORS": TRUSTED_AUTHORS, "TRUSTED_PR": TRUSTED_PR,
               "SCOPE_SKIP": "false", "SCOPE_RESULT": "success", "REVIEW_RESULT": "skipped"}
        t0 = time.monotonic()
        out = subprocess.run(["bash", "-c", script], cwd=tmp, env=env,
                             capture_output=True, text=True, check=False, timeout=60)
        secs = time.monotonic() - t0
        return out.returncode, out.stdout + out.stderr, log.read_text().splitlines(), secs


def main():
    global NO_REVIEW, DOCS
    for tool in ("jq", "bash", "grep"):
        if shutil.which(tool) is None:
            fatal(f"{tool} is not on PATH")
    src = WORKFLOW.read_text()
    gate = job(src, "gate")
    script = run_script(step(gate, "Require a Codex approval of the head, or a no-review change"))
    NO_REVIEW = NON_CODE
    DOCS = NON_CODE

    # T
    check(re.search(r"\n    timeout-minutes: 10\n", gate) is not None, "T1 the gate's timeout-minutes is 10")
    check("4500" not in gate, "T2 no 4500 is left in the gate")
    check(re.search(r"\bsleep\b", script) is None, "T3 the gate's step never sleeps")
    check("v5.12.6" in src.splitlines()[0], "T4 the header names v5.12.6")

    # Q
    for where, kw in (("queued", {"queued": [91]}), ("in progress", {"in_progress": [91]})):
        for verdict in (None, "REQUEST_CHANGES"):
            rc, out, reqs, secs = run_gate(script, verdict, twin_jobs="queued" if where == "queued" else "in_progress", **kw)
            what = f"Q twin run {where}, verdict {verdict or 'none'}"
            check(rc == 3, f"{what}: exit 3 (got {rc})")
            check("runs in run 91" in out and "ruling 1046" in out, f"{what}: names the twin run")
            check(not any(r.startswith("sleep") for r in reqs) and secs < 20, f"{what}: no sleep ({secs:.1f} s)")
            check(any(r.startswith("/pulls/7/reviews") for r in reqs), f"{what}: read the verdict first")

    # A
    for status in ("queued", "in_progress"):
        rc, out, reqs, _ = run_gate(script, "APPROVED", in_progress=[91], twin_jobs=status)
        check(rc == 0 and "approved" in out, f"A twin review {status}, head APPROVED: passes (got {rc})")

    # N
    for label, kw in (("no twin", {}), ("twin review ended", {"in_progress": [91], "twin_jobs": "completed"})):
        rc, _, _, _ = run_gate(script, "APPROVED", **kw)
        check(rc == 0, f"N {label}, APPROVED: passes (got {rc})")
        rc, out, _, _ = run_gate(script, "REQUEST_CHANGES", **kw)
        check(rc == 3 and "requested changes" in out, f"N {label}, REQUEST_CHANGES: fails (got {rc})")
        rc, out, _, _ = run_gate(script, None, **kw)
        check(rc == 3 and "no codex-reviewer[bot] approval" in out, f"N {label}, none: fails (got {rc})")

    # E
    rc, out, _, _ = run_gate(script, "APPROVED", runs_code=500)
    check(rc == 3 and "HTTP 500" in out, f"E runs list HTTP 500, APPROVED: fails closed (got {rc})")
    rc, out, _, _ = run_gate(script, "APPROVED", in_progress=[91], jobs_code=502)
    check(rc == 3 and "HTTP 502" in out, f"E twin jobs HTTP 502, APPROVED: fails closed (got {rc})")

    print(f"\n{'FAILED' if FAILS else 'PASSED'}: {len(FAILS)} failure(s)")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
