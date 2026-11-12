#!/usr/bin/env python3
"""docs-check.py [repo-dir]

`make docs-check`: an offline check of the published documentation, every
Markdown file under docs/ (recursively), ROADMAP.md and README.md. It reads
the files on disk, so an untracked file is checked as well, and it fetches
nothing. It checks:

  links    every relative link resolves inside the repository, and a
           `#anchor` names a heading of the target Markdown file (the parser
           and the anchor rule of scripts/check-doc-links.py)
  hosts    no internal host name: a URL whose host is a single label (other
           than localhost), or any name under .internal, .local, .lan, .corp,
           .intranet, .localdomain or .home.arpa
  IPs      no IPv4 address literal, except the documentation ranges of
           RFC 5737 (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). A
           number after a section sign (§3.2.6.3) is a section, not an
           address.
  paths    no /home/ path

The host, IP and path rules read every line, fenced code included. A finding
prints the path, the line and the rule, never the matched text, and the
script exits 1. ROADMAP.md and README.md must exist.
"""

import importlib.util
import ipaddress
import os
import re
import sys

sys.dont_write_bytecode = True  # the import below leaves no __pycache__ in the tree
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("check_doc_links", os.path.join(HERE, "check-doc-links.py"))
links = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(links)

URL_HOST = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/\s@]*@)?([^/\s:?#)\]>\"']+)")
INTERNAL_SUFFIX = re.compile(
    r"(?<![\w.-])(?:[A-Za-z0-9-]+\.)+(?:internal|local|lan|corp|intranet|localdomain|home\.arpa)(?![\w-])",
    re.IGNORECASE)
IPV4 = re.compile(r"(?<![\w.§])(?<!§ )(\d{1,3}(?:\.\d{1,3}){3})(?![\w.]*\d)")
HOME = re.compile(r"(?<![\w.~-])/home/")
DOC_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]


def files(root):
    found = []
    for name in ("README.md", "ROADMAP.md"):
        found.append(name)
    docs = os.path.join(root, "docs")
    for dirpath, dirnames, filenames in os.walk(docs):
        dirnames.sort()
        for f in sorted(filenames):
            if f.endswith(".md"):
                found.append(os.path.relpath(os.path.join(dirpath, f), root))
    return found


def hygiene(line):
    """The rules a line breaks: internal host, IP literal, /home path."""
    rules = []
    for m in URL_HOST.finditer(line):
        host = m.group(1).rstrip(".").lower()
        if "." not in host and host != "localhost" and not host.startswith("["):
            rules.append("a URL names an internal (single-label) host")
            break
    if INTERNAL_SUFFIX.search(line):
        rules.append("an internal host name")
    for m in IPV4.finditer(line):
        try:
            addr = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue  # not an address (an octet over 255): a version or a number
        if not any(addr in n for n in DOC_NETS):
            rules.append("an IP address (use RFC 5737's documentation ranges)")
            break
    if HOME.search(line):
        rules.append("a /home path")
    return rules


def check_links(root, rel, lineno, line):
    out = []
    path = os.path.join(root, rel)
    for m in links.LINK.finditer(line):
        target = m.group(1)
        if links.SCHEME.match(target):
            continue
        file_part, _, frag = target.partition("#")
        dest = path if not file_part else os.path.normpath(os.path.join(os.path.dirname(path), file_part))
        if not dest.startswith(root + os.sep) and dest != root:
            out.append("link leaves the repository")
        elif not os.path.exists(dest):
            out.append("link target does not exist")
        elif frag and dest.endswith(".md") and frag not in links.anchors(dest):
            out.append("anchor not found in the link target")
    return out


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = 0
    checked = files(root)
    for rel in checked:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            print(f"{rel}: missing")
            bad = 1
            continue
        fenced = False
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                found = hygiene(line)
                if links.FENCE.match(line):
                    fenced = not fenced
                elif not fenced:
                    found += check_links(root, rel, lineno, line)
                for rule in found:
                    print(f"{rel}:{lineno}: {rule}")
                    bad = 1
    if bad:
        return 1
    print(f"docs-check: OK ({len(checked)} Markdown files: docs/, ROADMAP.md, README.md)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
