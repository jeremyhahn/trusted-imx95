#!/usr/bin/env python3
"""check-doc-links.py [repo-dir]

Checks every relative link in the tracked Markdown files: the target file or
directory exists in the tree, and a `#anchor` names a heading of the target
Markdown file. External links (a scheme such as https:, or mailto:) are not
fetched. A finding prints path, line and the rule only. Exit 1 on a finding.
"""

import os
import re
import subprocess
import sys

LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
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
        path = os.path.join(root, rel)
        fenced = False
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                if FENCE.match(line):
                    fenced = not fenced
                    continue
                if fenced:
                    continue
                for m in LINK.finditer(line):
                    target = m.group(1)
                    if SCHEME.match(target):
                        continue
                    file_part, _, frag = target.partition("#")
                    dest = path if not file_part else os.path.normpath(
                        os.path.join(os.path.dirname(path), file_part))
                    if not dest.startswith(root + os.sep) and dest != root:
                        print(f"{rel}:{lineno}: link leaves the repository")
                        bad = 1
                    elif not os.path.exists(dest):
                        print(f"{rel}:{lineno}: link target does not exist")
                        bad = 1
                    elif frag and dest.endswith(".md") and frag not in anchors(dest):
                        print(f"{rel}:{lineno}: anchor not found in the link target")
                        bad = 1
    if bad:
        return 1
    print(f"check-doc-links: OK ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
