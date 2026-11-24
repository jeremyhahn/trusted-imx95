#!/usr/bin/env python3
"""hsm-self-defence-check.py <root>: the hsm-self-defence row holds as written.

The row is blocked (owner rulings 1243 and 1244, #26). This check proves the
tree keeps it that way: docs/SPEC.md states the row as written and leaves it
planned, ROADMAP.md marks it blocked on the owner, docs/references/README.md
lists it under the missing documents, and nothing in the tree builds it.
Prints one "ok"/"FAIL" line per check; exits 0 when all hold, 1 when one
fails, 2 on a usage error.
"""
import os
import re
import sys

TARGET = re.compile(r"^([A-Za-z0-9_.%/-]+)\s*:(?!=)")

ROW = "hsm-self-defence"
OPENING = "Later (owner rulings 1243 and 1244, #26): it stays blocked."
# What the row says, phrase by phrase (docs/SPEC.md, Features).
PHRASES = [
    "The HSM device side of the tamper response",
    "trusted-firmware's `hsm-self-defence` row enforces on the Cortex-M7",
    "go-xkms's `hsm-self-defence` row names",
    "NXP's System Manager, whose configuration is this repository's (`system-manager-config`)",
    "the EdgeLock secure enclave: power domains, PHYs, key zeroisation and shutdown",
    "Whether the Cortex-A55 tamper detector, the NPU model and the IMA log are built in this repository is not decided, and is an open question for the owner",
    "gives the EdgeLock tamper pins; the one that does is missing",
]
# The only make targets and scripts a blocked row may carry: this check.
ALLOWED_TARGETS = {"hsm-self-defence-check", "integration-test-hsm-self-defence"}
ALLOWED_SCRIPTS = {"hsm-self-defence-check.py"}


class Report:
    def __init__(self):
        self.n = 0
        self.failed = 0

    def check(self, ok, what, why=""):
        self.n += 1
        if ok:
            print(f"ok {self.n} {what}")
        else:
            self.failed += 1
            print(f"FAIL {self.n} {what}: {why}")


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read().splitlines()
    except OSError as e:
        return e


def table_rows(lines, name):
    out = []
    for line in lines:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.lstrip().startswith("|") and cells and cells[0] == name:
            out.append(cells)
    return out


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: hsm-self-defence-check.py <root>", file=sys.stderr)
        return 2
    root = argv[1]
    r = Report()

    spec = read(root, "docs/SPEC.md")
    if isinstance(spec, OSError):
        r.check(False, "docs/SPEC.md", f"unreadable ({spec.strerror})")
        rows = []
    else:
        rows = table_rows(spec, ROW)
        r.check(len(rows) == 1, "SPEC.md: one hsm-self-defence row", f"found {len(rows)}")
    if len(rows) == 1:
        cells = rows[0]
        if len(cells) != 4:
            r.check(False, "SPEC.md: the row has four cells", f"found {len(cells)}")
        else:
            _, status, req, folder = cells
            r.check(status == "planned", "SPEC.md: the row stays planned", f"status is '{status}'")
            r.check(req.startswith(OPENING), "SPEC.md: the row stays blocked (rulings 1243 and 1244)",
                    f"requirements do not open with '{OPENING}'")
            for p in PHRASES:
                r.check(p in req, f"SPEC.md: the row says '{p}'", "phrase missing")
            r.check(folder == "none", "SPEC.md: the row has no feature folder", f"folder is '{folder}'")

    roadmap = read(root, "ROADMAP.md")
    if isinstance(roadmap, OSError):
        r.check(False, "ROADMAP.md", f"unreadable ({roadmap.strerror})")
    else:
        lines = [l for l in roadmap if l.startswith(f"- **{ROW}**")]
        line = lines[0] if len(lines) == 1 else ""
        r.check(len(lines) == 1, "ROADMAP.md: one hsm-self-defence line", f"found {len(lines)}")
        r.check("blocked: owner approval" in line, "ROADMAP.md: blocked on owner approval", "not marked blocked")
        r.check("A55 side open" in line, "ROADMAP.md: the A55 side is open", "not marked open")

    refs = read(root, "docs/references/README.md")
    if isinstance(refs, OSError):
        r.check(False, "docs/references/README.md", f"unreadable ({refs.strerror})")
    else:
        for doc in ("IMX95RM, i.MX 95 Applications Processor Reference Manual",
                    "i.MX 95 Security Reference Manual"):
            rows = table_rows(refs, doc)
            ok = len(rows) == 1 and len(rows[0]) > 1 and ROW in rows[0][1]
            r.check(ok, f"references: '{doc}' is missing for hsm-self-defence", "row absent or does not name it")

    mk = read(root, "Makefile")
    if isinstance(mk, OSError):
        r.check(False, "Makefile", f"unreadable ({mk.strerror})")
    else:
        targets = sorted({m.group(1) for m in map(TARGET.match, mk) if m and ROW in m.group(1)})
        extra = [t for t in targets if t not in ALLOWED_TARGETS]
        r.check(not extra, "Makefile: no target builds hsm-self-defence", "targets " + ", ".join(extra))
    scripts = os.path.join(root, "scripts")
    extra = sorted(f for f in (os.listdir(scripts) if os.path.isdir(scripts) else [])
                   if f.startswith(ROW) and f not in ALLOWED_SCRIPTS)
    r.check(not extra, "scripts/: no hsm-self-defence build script", "found " + ", ".join(extra))
    r.check(not os.path.exists(os.path.join(root, ROW)), "no top-level hsm-self-defence/ source tree",
            f"{ROW}/ exists")

    if r.failed:
        print(f"hsm-self-defence-check: FAIL ({r.failed} of {r.n} checks)")
        return 1
    print(f"hsm-self-defence-check: OK (blocked as written, {r.n} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
