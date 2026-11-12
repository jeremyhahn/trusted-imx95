#!/usr/bin/env python3
"""ci-proven-sim.py <ci.yml> <repo-dir> <gate-script-out>

Simulates ci.yml on a proven push to main: the event is a push to
refs/heads/main on the forge, and preflight succeeded with the verdict
`proven` (proof 42), docs_only false and lint_gates true. For each job it
evaluates the job's `if:` (with GitHub's implicit success() when the
expression has no status function) and, in a job that runs, each step's
`if:`. A running step whose command scans the history (make
secret-scan-history, make security or secret-scan.sh history) runs
scripts/secret-scan.sh history on <repo-dir>, through a full-depth clone
when the job's checkout has fetch-depth 0 and a depth-1 clone otherwise;
its job's result is success or failure by the scan. Every other running job
succeeds. Prints `job <name> <result>` per job and `scan <job> <result>` per
job that scanned, then writes CI Gate's run script to <gate-script-out>, its
`${{ needs.<job>.result }}` set from shell variables R_<job> assigned at the
top. The gate's own env (SCHEDULE_GUARD, PROOF, ...) is the caller's.

ci.yml is read line by line (no YAML library on the host): job headers at two
spaces under `jobs:`, a job's `if:` and `needs:` at four, steps at six.
"""

import os
import re
import subprocess
import sys
import tempfile

TOKEN = re.compile(r"\s*(&&|\|\||==|!=|!|\(|\)|,|'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_.*-]*|\d+)")
STATUS = re.compile(r"\b(always|cancelled|failure|success)\(")
SCANS = re.compile(r"secret-scan-history|secret-scan\.sh history|make security\b")


def tokens(expr):
    expr = expr.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2]
    out, pos = [], 0
    while pos < len(expr):
        m = TOKEN.match(expr, pos)
        if not m:
            if expr[pos:].strip():
                raise ValueError("cannot read expression: " + expr)
            break
        out.append(m.group(1))
        pos = m.end()
    return out


def truthy(v):
    return v not in (None, False, "", 0, [])


def text(v):
    if v is None:
        return ""
    if v is True or v is False:
        return "true" if v else "false"
    return str(v).lower()


class Eval:
    """GitHub expressions: || && ! == != ( ), strings, contexts, calls."""

    def __init__(self, ctx, status):
        self.ctx, self.status = ctx, status

    def __call__(self, expr):
        self.t, self.i = tokens(expr), 0
        v = self.or_()
        if self.i != len(self.t):
            raise ValueError("trailing tokens in: " + expr)
        return v

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self):
        self.i += 1
        return self.t[self.i - 1]

    def or_(self):
        v = self.and_()
        while self.peek() == "||":
            self.take()
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.unary()
        while self.peek() == "&&":
            self.take()
            r = self.unary()
            v = r if truthy(v) else v
        return v

    def unary(self):
        if self.peek() == "!":
            self.take()
            return not truthy(self.unary())
        v = self.primary()
        if self.peek() in ("==", "!="):
            op, r = self.take(), self.primary()
            same = text(v) == text(r)
            return same if op == "==" else not same
        return v

    def primary(self):
        t = self.take()
        if t == "(":
            v = self.or_()
            self.take()
            return v
        if t.startswith("'"):
            return t[1:-1].replace("''", "'")
        if t in ("true", "false"):
            return t == "true"
        if t == "null":
            return None
        if t.isdigit():
            return int(t)
        if self.peek() == "(":
            self.take()
            args = []
            while self.peek() != ")":
                args.append(self.or_())
                if self.peek() == ",":
                    self.take()
            self.take()
            return self.call(t, args)
        return self.ctx(t)

    def call(self, name, args):
        if name in self.status:
            return self.status[name]
        if name == "contains":
            hay, needle = args
            if isinstance(hay, list):
                return any(text(h) == text(needle) for h in hay)
            return text(needle) in text(hay)
        if name == "startsWith":
            return text(args[0]).startswith(text(args[1]))
        raise ValueError("unknown function " + name)


def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    env, jobs, order = {}, {}, []
    section, job, step = None, None, None
    run_indent = None
    for line in lines:
        if run_indent is not None:
            if not line.strip() or len(line) - len(line.lstrip()) >= run_indent:
                step["run"] += line + "\n"
                continue
            run_indent = None
        if re.match(r"^\S", line):
            section = line.split(":")[0]
            continue
        if section == "env":
            m = re.match(r"^  ([A-Z_][A-Z0-9_]*): (.*)$", line)
            if m:
                env[m.group(1)] = m.group(2)
            continue
        if section != "jobs":
            continue
        m = re.match(r"^  ([a-z][a-z0-9-]*):\s*(#.*)?$", line)
        if m:
            job = {"if": None, "needs": [], "steps": []}
            jobs[m.group(1)] = job
            order.append(m.group(1))
            step = None
            continue
        if job is None:
            continue
        m = re.match(r"^    (if|needs): (.*)$", line)
        if m:
            val = m.group(2)
            if m.group(1) == "if":
                job["if"] = val
            else:
                val = re.sub(r"\s+#.*$", "", val).strip("[] ")
                job["needs"] = [n.strip() for n in val.split(",") if n.strip()]
            continue
        m = re.match(r"^      - (.*)$", line)
        if m:
            step = {"if": None, "run": "", "uses": "", "depth": None}
            job["steps"].append(step)
            line = "        " + m.group(1)
        if step is None:
            continue
        m = re.match(r"^        (if|run|uses): ?(.*)$", line)
        if m:
            if m.group(1) == "run" and m.group(2).strip() in ("|", ">"):
                run_indent = 10
            else:
                step[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^          fetch-depth: (.*)$", line)
        if m:
            step["depth"] = m.group(1).strip()
    return env, jobs, order


def scan(root, repo, full):
    with tempfile.TemporaryDirectory() as tmp:
        clone = os.path.join(tmp, "c")
        cmd = ["git", "clone", "-q"] + ([] if full else ["--depth", "1"]) + ["file://" + repo, clone]
        subprocess.run(cmd, check=True)
        return subprocess.run([os.path.join(root, "scripts", "secret-scan.sh"), "history", clone],
                              capture_output=True).returncode


def main():
    path, repo, gate_out = sys.argv[1:4]
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(path))))
    env, jobs, order = parse(path)
    flat = {
        "github.event_name": "push",
        "github.ref": "refs/heads/main",
        "github.server_url": "https://forge.example",
        "github.head_ref": "",
        "github.event.pull_request.labels.*.name": [],
        "needs.preflight.outputs.verdict": "proven",
        "needs.preflight.outputs.proof": "42",
        "needs.preflight.outputs.docs_only": "false",
        "needs.preflight.outputs.lint_gates": "true",
    }
    step_env = {"TOOLCHAIN_IMAGE": "sha256:" + "0" * 64}

    def ctx(name):
        if name in flat:
            return flat[name]
        if name.startswith("env."):
            key = name[4:]
            if key in step_env:
                return step_env[key]
            raw = env.get(key)
            if raw is None:
                return None
            raw = raw.strip()
            if raw.startswith("${{"):
                return Eval(ctx, {"always": True, "cancelled": False, "success": True, "failure": False})(raw)
            raw = re.sub(r"\s+#.*$", "", raw)
            return raw[1:-1] if raw[:1] in "'\"" and raw[-1:] == raw[:1] else raw
        return None

    results = {"preflight": "success"}
    for name in order:
        if name in ("preflight", "ci-gate"):
            continue
        j = jobs[name]
        ok = all(results.get(n) == "success" for n in j["needs"])
        status = {"always": True, "cancelled": False, "success": ok, "failure": not ok}
        cond = j["if"]
        if cond is None:
            runs = ok
        elif STATUS.search(cond):
            runs = truthy(Eval(ctx, status)(cond))
        else:
            runs = ok and truthy(Eval(ctx, status)(cond))
        if not runs:
            results[name] = "skipped"
            continue
        full = any("actions/checkout" in s["uses"] and s["depth"] == "0" for s in j["steps"])
        result = "success"
        for s in j["steps"]:
            sc = s["if"]
            st = {"always": True, "cancelled": False, "success": True, "failure": False}
            if sc is not None and not truthy(Eval(ctx, st)(sc)):
                continue
            if SCANS.search(s["run"]):
                rc = scan(root, os.path.abspath(repo), full)
                r = "success" if rc == 0 else "failure"
                print(f"scan {name} {r}")
                if r == "failure":
                    result = "failure"
        results[name] = result
    for name in order:
        if name in results:
            print(f"job {name} {results[name]}")
    gate = jobs.get("ci-gate")
    if gate is None or not gate["steps"]:
        print("ci-gate: no job", file=sys.stderr)
        return 1
    script = gate["steps"][0]["run"]
    head = "".join(f"R_{n.replace('-', '_')}={results.get(n, '')}\n" for n in gate["needs"])
    script = re.sub(r"\$\{\{\s*needs\.([A-Za-z0-9_-]+)\.result\s*\}\}",
                    lambda m: "${R_" + m.group(1).replace("-", "_") + "}", script)
    with open(gate_out, "w", encoding="utf-8") as fh:
        fh.write(head + script)
    return 0


if __name__ == "__main__":
    sys.exit(main())
