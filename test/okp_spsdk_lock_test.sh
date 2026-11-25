#!/usr/bin/env bash
# The SPSDK lock file (scripts/ahab/requirements.txt) is fully pinned and hashed, and the documents
# agree with it. Reads text only: never installs, never runs pip, no network, no SPSDK or device tool.
#
# Overrides: OKP_REQ_FILE (the lock file), OKP_DOCS_DIR (architecture.md, provisioning-host-survey.md).
# Rerun the scratch fixtures: bash test/okp_spsdk_lock_test.sh (they are built in a temp dir each
# run and never written to the tree).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
req=${OKP_REQ_FILE:-$here/scripts/ahab/requirements.txt}
docs=${OKP_DOCS_DIR:-$here/docs/oem-key-provisioning}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# shellcheck disable=SC2016  # the Python program is meant to be unexpanded
PY='
import re, sys

req, docs = sys.argv[1], sys.argv[2]
errs = []


def err(path, line, token, msg):
    errs.append("%s:%s: %s: %s" % (path, line, token, msg))


NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*"
REQ_RE = re.compile(r"(%s)==([A-Za-z0-9][A-Za-z0-9.!+_-]*)( \\)?" % NAME)
HASH_RE = re.compile(r"    --hash=sha256:([0-9a-f]{64})( \\)?")

pins, names, current, cont = {}, {}, None, False
for n, text in enumerate(open(req, encoding="utf-8").read().split("\n"), 1):
    if text.strip() == "" or text.lstrip().startswith("#"):
        continue
    if cont:
        m = HASH_RE.fullmatch(text)
        if not m:
            err(req, n, text.strip().split()[0], "a continuation must be one --hash=sha256: line of exactly 64 hex characters")
            cont = False
            current = None
            # fall through: the line may start a new requirement
        else:
            current["hashes"] += 1
            cont = m.group(2) is not None
            continue
    m = REQ_RE.fullmatch(text)
    if not m:
        tok = text.strip().split()[0]
        if re.match(r"(-e|-r|--index-url|--extra-index-url|--find-links|-f|-i)$", tok) or re.match(r"--", tok):
            why = "option line"
        elif "://" in text or "@" in tok:
            why = "URL requirement"
        elif re.search(r"[<>~!]=?|,", tok):
            why = "version range"
        elif HASH_RE.fullmatch(text) or tok.startswith("--hash"):
            why = "hash line outside a requirement or malformed"
        else:
            why = "not name==version"
        err(req, n, tok, "%s; every line must be name==version with hashes" % why)
        current = None
        continue
    name = re.sub(r"[-_.]+", "-", m.group(1)).lower()
    if name in names:
        err(req, n, m.group(1), "name appears twice (first at line %d)" % names[name])
    names[name] = n
    pins.setdefault(name, []).append((m.group(2), n))
    current = {"name": m.group(1), "line": n, "hashes": 0}
    cont = m.group(3) is not None
    if not cont:
        err(req, n, m.group(1), "requirement has no --hash=sha256: line")
        current = None
        continue

# every requirement line that ends with a backslash must be followed by a hash line (checked above);
# the last line of the file may not end with one
last = [t for t in open(req, encoding="utf-8").read().split("\n") if t.strip()][-1]
if last.endswith("\\"):
    err(req, "end", last.strip().split()[0], "the file ends in a continuation")

spsdk = pins.get("spsdk", [])
if len(spsdk) != 1:
    err(req, 1, "spsdk", "spsdk== must appear exactly once, found %d" % len(spsdk))
libuuu = pins.get("libuuu", [])
if len(libuuu) != 1:
    err(req, 1, "libuuu", "libuuu== must be pinned exactly once, found %d" % len(libuuu))
want_spsdk = spsdk[0][0] if len(spsdk) == 1 else None
want_uuu = libuuu[0][0] if len(libuuu) == 1 else None


def section(path, heading_re):
    """(first line number, text) of the section under the matching "## " heading."""
    out, inside, first = [], False, 0
    for n, text in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if text.startswith("## "):
            if inside:
                break
            inside = re.match(heading_re, text) is not None
            if inside:
                first = n
            continue
        if inside:
            out.append(text)
    return first, "\n".join(out)


def versions(path, heading_re, label, name_re, want):
    first, text = section(path, heading_re)
    if not first:
        err(path, 1, label, "section not found")
        return
    found = list(re.finditer(name_re, text))
    if not found:
        err(path, first, label, "the section names no %s version" % label)
    for m in found:
        line = first + text.count("\n", 0, m.start()) + 1
        if want is not None and m.group(1) != want:
            err(path, line, m.group(1), "%s version disagrees with the lock file (%s)" % (label, want))


ARCH = docs + "/architecture.md"
HOST = docs + "/provisioning-host-survey.md"
SP = r"SPSDK[,\s]+(?:pinned at\s+)?v?(\d+\.\d+\.\d+)"
versions(ARCH, r"## Open questions", "SPSDK", SP, want_spsdk)
versions(HOST, r"## 6\.", "SPSDK", SP, want_spsdk)
versions(HOST, r"## 6\.", "libuuu", r"libuuu`?\s+(\d+\.\d+\.\d+)", want_uuu)

for e in errs:
    print(e)
sys.exit(1 if errs else 0)
'
lock() { out=$(python3 -I -c "$PY" "$1" "$2" 2>&1); rc=$?; }

# expect_fail NAME WANT...: the last run failed and its output names every WANT
expect_fail() {
  local name=$1 w
  shift
  if [ "$rc" != 1 ]; then bad "$name: rc=$rc want 1: $out"; return; fi
  for w in "$@"; do
    if [[ $out != *"$w"* ]]; then bad "$name: output lacks '$w': $out"; return; fi
  done
  ok "$name"
}

lock "$req" "$docs"
if [ "$rc" = 0 ]; then ok "the lock file is fully pinned and hashed and agrees with the documents"
else bad "the tree:"; echo "$out"; fi

# scratch copies, in a temp dir, never in the tree
scratch() { # scratch NAME 'python statements on s' [FILE]: a changed copy of the lock file or a document
  local file=${3:-req}
  mkdir -p "$work/$1/docs"
  cp "$req" "$work/$1/req.txt"
  cp "$docs/architecture.md" "$docs/provisioning-host-survey.md" "$work/$1/docs/"
  local target="$work/$1/req.txt"
  [ "$file" = req ] || target="$work/$1/docs/$file"
  python3 -I -c '
import sys
s = open(sys.argv[1]).read()
orig = s
exec(sys.argv[2])
assert s != orig, "scratch edit changed nothing"
open(sys.argv[1], "w").write(s)
' "$target" "$2"
}
run_scratch() { lock "$work/$1/req.txt" "$work/$1/docs"; }

scratch nohash 'import re
s = re.sub(r"(asn1crypto==1\.5\.1) \\\n    --hash=sha256:[0-9a-f]{64}\n", r"\1\n", s, count=1)'
run_scratch nohash
expect_fail "a requirement without a hash line fails and is named" "asn1crypto" "req.txt:"

scratch range 's = s.replace("asn1crypto==1.5.1", "asn1crypto>=1.5.1", 1)'
run_scratch range
expect_fail "an unpinned >= line fails and is named" "asn1crypto>=1.5.1" "version range"

scratch extra 's = s.replace("argparse-addons==", "--extra-index-url https://example.invalid/simple\nargparse-addons==", 1)'
run_scratch extra
expect_fail "an --extra-index-url line fails and is named" "--extra-index-url" "req.txt:"

scratch dup 'i = s.index("zipp==")
s = s + s[i:]'
run_scratch dup
expect_fail "a duplicated name fails and is named" "zipp" "appears twice"

scratch otherver 's = s.replace("requirements file for SPSDK 3.13.0", "requirements file for SPSDK 3.12.9", 1)' provisioning-host-survey.md
run_scratch otherver
expect_fail "a document with another SPSDK version fails and names document and version" "provisioning-host-survey.md" "3.12.9"

scratch archver 's = s.replace("pinned at 3.13.0", "pinned at 3.14.0", 1)' architecture.md
run_scratch archver
expect_fail "architecture.md with another SPSDK version fails and names it" "architecture.md" "3.14.0"

scratch nouuu 'import re
s = re.sub(r"libuuu==1\.5\.243 \\\n(    --hash=\S+ \\\n)*    --hash=\S+\n", "", s, count=1)'
run_scratch nouuu
expect_fail "a lock file without libuuu fails and is named" "libuuu"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
