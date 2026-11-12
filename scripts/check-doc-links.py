#!/usr/bin/env python3
"""check-doc-links.py [repo-dir]

Checks every relative link in the tracked Markdown files: the target file or
directory exists in the tree, and a `#anchor` names a heading of the target
Markdown file. Inline links (`[text](target)`) and reference-style links
(`[text][ref]`, `[ref][]`, with a `[ref]: target` definition) are both
checked: a definition's target like an inline link's, and a full or
collapsed reference with no definition in its file is a finding. External
links (a scheme such as https:, or mailto:) are not fetched. A finding prints
path, line and the rule only. Exit 1 on a finding.
"""

import os
import re
import subprocess
import sys

LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
# A link reference definition (CommonMark §4.7): up to three spaces of
# indent, [label]: destination, an optional title after it.
# A footnote ([^1]: text) is not a link.
REF_DEF = re.compile(r"^ {0,3}\[(?!\^)((?:[^\]\\]|\\.)+)\]:\s*(?:<([^>\s]*)>|(\S+))")
# A full ([text][label]) or collapsed ([label][]) reference link.
REF_USE = re.compile(r"!?\[((?:[^\]\\]|\\.)*)\]\[((?:[^\]\\]|\\.)*)\]")
# Inline code: `a[i][j]` is not a reference link.
CODE_SPAN = re.compile(r"(`+).*?\1")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def slug(text):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to -."""
    text = re.sub(r"`|\*|_(?=\w)|(?<=\w)_", "", text.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path):
    found, seen = set(), {}
    with open(path, encoding="utf-8") as fh:
        fenced = False
        for line in fh:
            if FENCE.match(line):
                fenced = not fenced
                continue
            m = None if fenced else HEADING.match(line)
            if m:
                s = slug(m.group(1))
                n = seen.get(s, 0)
                seen[s] = n + 1
                found.add(s if n == 0 else f"{s}-{n}")
    return found


def label(text):
    """A reference label as CommonMark matches it: case and spacing folded."""
    return " ".join(text.lower().split())


def scan(path):
    """The links of a Markdown file, outside fenced code, in line order.

    Yields (lineno, target, None) for each inline link and each reference
    definition, and (lineno, None, rule) for a reference with no definition.
    """
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    outside, fenced = [], False
    for lineno, line in enumerate(lines, 1):
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced:
            outside.append((lineno, line))
    defined = set()
    for _, line in outside:
        m = REF_DEF.match(line)
        if m:
            defined.add(label(m.group(1)))
    for lineno, line in outside:
        d = REF_DEF.match(line)
        if d:
            yield lineno, d.group(2) if d.group(2) is not None else d.group(3), None
            continue
        for m in LINK.finditer(line):
            yield lineno, m.group(1), None
        for m in REF_USE.finditer(CODE_SPAN.sub("", line)):
            ref = label(m.group(2) or m.group(1))
            if ref and ref not in defined:
                yield lineno, None, "reference link has no definition"


def check_target(root, path, target):
    """The rule a relative link target breaks, or None."""
    if not target or SCHEME.match(target):
        return None
    file_part, _, frag = target.partition("#")
    dest = path if not file_part else os.path.normpath(os.path.join(os.path.dirname(path), file_part))
    if not dest.startswith(root + os.sep) and dest != root:
        return "link leaves the repository"
    if not os.path.exists(dest):
        return "link target does not exist"
    if frag and dest.endswith(".md") and frag not in anchors(dest):
        return "anchor not found in the link target"
    return None


def findings(root, path):
    """(lineno, rule) for each broken link of a Markdown file."""
    out = []
    for lineno, target, rule in scan(path):
        rule = rule or check_target(root, path, target)
        if rule:
            out.append((lineno, rule))
    return out


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--", "*.md"],
            check=True, capture_output=True,
        ).stdout.decode()
    except (OSError, subprocess.CalledProcessError):
        print("check-doc-links: cannot list the tracked Markdown files", file=sys.stderr)
        return 1
    files = [f for f in out.split("\0") if f]
    if not files:
        print("check-doc-links: no tracked Markdown file found", file=sys.stderr)
        return 1
    bad = 0
    for rel in files:
        for lineno, rule in findings(root, os.path.join(root, rel)):
            print(f"{rel}:{lineno}: {rule}")
            bad = 1
    if bad:
        return 1
    print(f"check-doc-links: OK ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
