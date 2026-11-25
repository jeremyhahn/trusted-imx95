"""ci-gate-cancel-tests.py -- evaluates the real `if:` of ci.yml's ci-gate job
(ci-template v1.53/v1.54, #159) under GitHub's status-function semantics.

It reads ci.yml from the parent of its own directory (test/ci_gate_cancel_test.sh
runs it on a copy laid out that way) and takes the job-level `if:` straight from
the file; no copy of the expression lives here.

Semantics: always() is true; cancelled() is true when the run was cancelled;
success() is true when no needed job failed or was cancelled; failure() is true
when one failed. A job `if:` with a status function replaces the implicit
success() check, so the gate's condition alone decides whether it runs.

Cases:
  G1 pull_request, run cancelled        -> gate runs (always()), then fails
  G2 pull_request_target, cancelled     -> gate runs
  G3 push to main, run cancelled        -> gate skipped (!cancelled())
  G4 push, a need failed, not cancelled -> gate runs (and fails closed)
  G5 push, everything green             -> gate runs
  G6 schedule, verdict busy             -> gate skipped
  G7 schedule, verdict proven / empty   -> gate runs
  G8 schedule, busy, cancelled          -> gate skipped
  G9 pull_request, verdict busy         -> gate runs (busy only skips schedule)
  G10 pull_request, need failed         -> gate runs

Run: python3 -I test/testdata/ci-gate-cancel-tests.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOW = os.path.join(os.path.dirname(HERE), "ci.yml")

TOKEN = re.compile(r"\s*(&&|\|\||==|!=|!|\(|\)|,|'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_.*-]*)")


def gate_if(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    in_gate = False
    for line in lines:
        if re.match(r"^  ci-gate:\s*(#.*)?$", line):
            in_gate = True
            continue
        if in_gate and re.match(r"^  [a-z][a-z0-9-]*:\s*(#.*)?$", line):
            break
        if in_gate:
            m = re.match(r"^    if: (.*)$", line)
            if m:
                expr = m.group(1).strip()
                if expr.startswith("${{") and expr.endswith("}}"):
                    expr = expr[3:-2]
                return expr.strip()
    raise SystemExit("ci-gate: no job-level if: in " + path)


def tokens(expr):
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
    return v not in (None, False, "", 0)


def text(v):
    if v is None:
        return ""
    if v is True or v is False:
        return "true" if v else "false"
    return str(v).lower()


class Eval:
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
        if name == "startsWith":
            return text(args[0]).startswith(text(args[1]))
        raise ValueError("unknown function " + name)


def runs(expr, event, verdict="proven", cancelled=False, need_failed=False):
    flat = {
        "github.event_name": event,
        "needs.preflight.outputs.verdict": verdict,
    }
    status = {
        "always": True,
        "cancelled": cancelled,
        "failure": need_failed and not cancelled,
        "success": not cancelled and not need_failed,
    }
    return truthy(Eval(lambda n: flat.get(n), status)(expr))


def main():
    expr = gate_if(WORKFLOW)
    cases = [
        ("G1 pull_request cancelled runs the gate", dict(event="pull_request", cancelled=True), True),
        ("G2 pull_request_target cancelled runs the gate", dict(event="pull_request_target", cancelled=True), True),
        ("G3 push cancelled skips the gate", dict(event="push", cancelled=True), False),
        ("G4 push with a failed need runs the gate", dict(event="push", need_failed=True), True),
        ("G5 push all green runs the gate", dict(event="push"), True),
        ("G6 schedule busy skips the gate", dict(event="schedule", verdict="busy"), False),
        ("G7a schedule proven runs the gate", dict(event="schedule", verdict="proven"), True),
        ("G7b schedule empty verdict runs the gate", dict(event="schedule", verdict=""), True),
        ("G8 schedule busy cancelled skips the gate", dict(event="schedule", verdict="busy", cancelled=True), False),
        ("G9 pull_request busy verdict still runs the gate", dict(event="pull_request", verdict="busy"), True),
        ("G10 pull_request with a failed need runs the gate", dict(event="pull_request", need_failed=True), True),
    ]
    bad = 0
    for name, kw, want in cases:
        got = runs(expr, **kw)
        ok = got == want
        bad += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f" (want {want}, got {got})"))
    # Mutation self-check (M1): without the pull_request always() branch the
    # same cases must fail, so G1/G2 are proven to bite. The mutant is built
    # in memory from the real expression; nothing is written.
    branch = "startsWith(github.event_name, 'pull_request') && always() ||"
    if branch not in expr:
        print("FAIL M1 the pull_request always() branch is not in the gate if:")
        return 1
    mutant = expr.replace(branch, "")
    for name, kw, want in cases[:2]:
        if runs(mutant, **kw) == want:
            bad += 1
            print("FAIL M1 mutant without the PR always() branch still passes: " + name)
        else:
            print("ok   M1 mutant without the PR always() branch fails: " + name)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
