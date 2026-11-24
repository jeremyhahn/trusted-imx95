#!/usr/bin/env python3
"""hdp-boundary-check.py <tree>

The hsm-device-protocol row of docs/SPEC.md as a fail-closed check of a
repository tree. The row is the device side of go-xkms's hsm-device-protocol:
go-xkms defines the wire protocol and implements xkmsd, and this repository
never does (SPEC Boundaries; owner rulings 1243 and 1244, #24). The check
decides whether a tree keeps that boundary and states the row's facts; it
talks to no board and to no xkmsd.

Checks, each one line of output:

- B1 row: the SPEC row `hsm-device-protocol` exists and states its facts: go-xkms
  defines the protocol, the two 1 GbE ports and the 10 GbE card on the
  Slim-SAS connector (UM12527 section 1.2 Table 1, section 2.18), the card is
  not in the kit and its documentation is missing, go-xkms #1521 owns the open
  questions, and the HSM is an xkmsd node (rulings 1243 and 1244).
- B2 missing: docs/references/README.md lists UM12527 and lists the 10 GbE
  expansion card documentation as missing, for the hsm-device-protocol row.
- B3 no-protocol: no file in the tree defines a wire protocol (protocol schema
  files: .proto, .thrift, .capnp, .fbs, .avsc, .asn1, OpenAPI or AsyncAPI
  documents) or implements xkmsd (Go sources, go.mod, a cmd/xkmsd directory).
- B4 owner: every document under docs/hsm-device-protocol/ names go-xkms
  #1521, the issue where go-xkms owns the protocol.
- B5 release: every image recipe of xkmsd or go-xkms fetches a tagged go-xkms
  release (a `tag=` in SRC_URI, no `branch=` and no AUTOREV), as
  docs/hsm-device-protocol/xkmsd-node.md section 2 proposes. With no recipe
  the check holds and says the recipe is missing.

Exit status: 0 when every check holds, 1 when one does not, 2 when the tree
cannot be read.
"""

import os
import re
import sys

SKIP_DIRS = {".git", ".tools", "out", "node_modules", "__pycache__"}
PROTOCOL_SUFFIXES = (".proto", ".thrift", ".capnp", ".fbs", ".avsc", ".asn1")
PROTOCOL_NAME = re.compile(r"^(openapi|asyncapi|swagger)[^/]*\.(ya?ml|json)$", re.IGNORECASE)
RECIPE_NAME = re.compile(r"^(xkmsd|go-xkms)[^/]*\.bb(append)?$")

ROW_FACTS = (
    ("go-xkms defines the protocol", "which go-xkms defines"),
    ("the two 1 GbE ports", "two 1 GbE ports"),
    ("the 10 GbE card on the Slim-SAS connector", "10 GbE expansion card on the Slim-SAS connector"),
    ("the UM12527 citation", "UM12527 §1.2 Table 1, §2.18"),
    ("the card is not in the kit", "not in the board kit"),
    ("the card's documentation is missing", "documentation is missing"),
    ("go-xkms #1521 owns the open questions", "go-xkms #1521"),
    ("the HSM is an xkmsd node", "rulings 1243 and 1244"),
    ("the protocol is never defined here", "never defines"),
)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def spec_row(text, name):
    """The cells of the Features table row named name, or None."""
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and cells[0] == name:
            return cells
    return None


def b1_row(tree):
    row = spec_row(read(os.path.join(tree, "docs", "SPEC.md")), "hsm-device-protocol")
    if row is None or len(row) < 3:
        return ["docs/SPEC.md has no hsm-device-protocol row"]
    requirements = row[2]
    return [f"the row does not state {what} ({needle!r})" for what, needle in ROW_FACTS if needle not in requirements]


def b2_missing(tree):
    text = read(os.path.join(tree, "docs", "references", "README.md"))
    faults = []
    if "UM12527" not in text:
        faults.append("docs/references/README.md does not list UM12527")
    listed = [ln for ln in text.splitlines() if ln.startswith("| 10 GbE expansion card documentation |")]
    if not listed:
        faults.append("docs/references/README.md does not list the 10 GbE expansion card documentation as missing")
    elif "hsm-device-protocol" not in listed[0]:
        faults.append("the 10 GbE card documentation entry does not name the hsm-device-protocol row")
    return faults


def walk(tree):
    for top, dirs, files in os.walk(tree):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            yield os.path.relpath(os.path.join(top, name), tree), name
        for d in dirs:
            rel = os.path.relpath(os.path.join(top, d), tree)
            if rel.replace(os.sep, "/").endswith("cmd/xkmsd"):
                yield rel + "/", d


def b3_no_protocol(tree):
    faults = []
    for rel, name in walk(tree):
        lower = name.lower()
        if lower.endswith(PROTOCOL_SUFFIXES) or PROTOCOL_NAME.match(name):
            faults.append(f"{rel} defines a wire protocol: go-xkms owns it (go-xkms #1521)")
        elif lower.endswith(".go") or name == "go.mod" or rel.endswith("/"):
            faults.append(f"{rel} implements xkmsd: go-xkms owns xkmsd")
    return faults


def b4_owner(tree):
    folder = os.path.join(tree, "docs", "hsm-device-protocol")
    docs = sorted(n for n in os.listdir(folder) if n.endswith(".md"))
    if not docs:
        return ["docs/hsm-device-protocol/ holds no document"]
    return [f"docs/hsm-device-protocol/{n} does not name go-xkms #1521"
            for n in docs if "go-xkms #1521" not in read(os.path.join(folder, n))]


def b5_release(tree):
    faults, recipes = [], []
    for rel, name in walk(tree):
        if RECIPE_NAME.match(name):
            recipes.append(rel)
            text = read(os.path.join(tree, rel))
            src = " ".join(ln for ln in text.splitlines() if "go-xkms" in ln or "SRC_URI" in ln or "SRCREV" in ln)
            if "tag=" not in src:
                faults.append(f"{rel} does not fetch a tagged go-xkms release (no tag= in SRC_URI)")
            if re.search(r"(^|[;\s\"])branch=", src) or "AUTOREV" in src:
                faults.append(f"{rel} follows a branch, not a tagged go-xkms release")
    return faults, recipes


def main(argv):
    if len(argv) != 2:
        print("usage: hdp-boundary-check.py <tree>", file=sys.stderr)
        return 2
    tree = argv[1]
    failed = 0
    try:
        results = [
            ("B1 row: the SPEC row states its facts", b1_row(tree)),
            ("B2 missing: UM12527 listed, the 10 GbE card documentation listed as missing", b2_missing(tree)),
            ("B3 no-protocol: no wire protocol or xkmsd in the tree", b3_no_protocol(tree)),
            ("B4 owner: every device-side document names go-xkms #1521", b4_owner(tree)),
        ]
        b5, recipes = b5_release(tree)
    except OSError as err:
        print(f"hdp-boundary-check: {err}", file=sys.stderr)
        return 2
    note = "" if recipes else " (no xkmsd recipe yet: missing, go-xkms has no tagged release to pin)"
    results.append(("B5 release: xkmsd recipes fetch a tagged go-xkms release" + note, b5))
    for title, faults in results:
        if faults:
            failed += 1
            print(f"FAIL {title}")
            for fault in faults:
                print(f"  - {fault}")
        else:
            print(f"ok {title}")
    if failed:
        print(f"hdp-boundary-check: {failed} of {len(results)} checks break the hsm-device-protocol row")
        return 1
    print(f"hdp-boundary-check: OK ({len(results)} checks keep the hsm-device-protocol row)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
