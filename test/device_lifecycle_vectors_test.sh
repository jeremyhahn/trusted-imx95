#!/usr/bin/env bash
# device_lifecycle_vectors_test.sh: bundle_fixture.py vectors (test-only). Generates the
# vector set into a temp dir, runs `check` for every manifest entry, and
# compares exit code and failed-check name. No key is committed or kept.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=test/lib.sh
source "$here/lib.sh"

before=$(cd "$ROOT" && git status --porcelain --ignored)
PY="$("$ROOT/scripts/ahab/spsdk-venv.sh")/bin/python"
TOOL="$ROOT/test/device_lifecycle/bundle_fixture.py"
W="$TMP_ROOT/w"
mkdir -p "$W"

run "$PY" -I "$TOOL" vectors "$W/a"
check "vectors run a" 0 "vectors written"
run "$PY" -I "$TOOL" vectors "$W/b"
check "vectors run b" 0 "vectors written"

# Every manifest entry: run check from the manifest directory.
RC=0
"$PY" -I - "$W/a" "$TOOL" "$PY" >"$W/each.log" 2>&1 <<'EOF' || RC=$?
import json, subprocess, sys

d, tool, py = sys.argv[1:4]
m = json.load(open(f"{d}/manifest.json"))
assert m["synthetic"] and m["proposed"], "manifest must say synthetic and proposed"
bad = 0
for v in m["vectors"]:
    p = subprocess.run([py, "-I", tool, "check", *v["check_args"]], cwd=d,
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    ok = p.returncode == v["expect_exit"] and v["expect_check"] in out
    print(("ok   " if ok else "FAIL ") + v["name"] + ("" if ok else f" rc={p.returncode} out={out!r}"))
    bad += not ok
print(f"{len(m['vectors'])} vectors")
sys.exit(1 if bad else 0)
EOF
if [ "$RC" -eq 0 ]; then pass "every manifest entry gives its exit code and check name"; else fail "manifest entries" "$(<"$W/each.log")"; fi

# Coverage: positives and negatives of both exit codes are present.
run "$PY" -I -c '
import json, sys
v = json.load(open(sys.argv[1] + "/manifest.json"))["vectors"]
print({x["expect_exit"] for x in v} == {0, 1, 2}, len(v) >= 25)' "$W/a"
check "the set holds exit 0, 1 and 2 vectors" 0 "True True"

# No private key anywhere in the output.
leak=0
"$PY" -I -c '
import glob, sys
sys.exit(any(b"PRIVATE KEY" in open(f, "rb").read() for d in sys.argv[1:] for f in glob.glob(d + "/*")))' \
	"$W/a" "$W/b" || leak=1
if [ "$leak" -eq 0 ]; then pass "no PRIVATE KEY PEM in OUTDIR"; else fail "a PRIVATE KEY PEM was written"; fi

# Fresh key per run, same case list.
if cmp -s "$W/a/ele-pub.pem" "$W/b/ele-pub.pem"; then
	fail "two runs generate different keys"
else
	pass "two runs generate different keys"
fi
run "$PY" -I -c '
import json, sys
n = [[x["name"] for x in json.load(open(d + "/manifest.json"))["vectors"]] for d in sys.argv[1:3]]
print(n[0] == n[1])' "$W/a" "$W/b"
check "two runs give the same case list" 0 "True"

after=$(cd "$ROOT" && git status --porcelain --ignored)
if [ "$before" = "$after" ]; then pass "the clone is unchanged"; else fail "the clone is unchanged" "$after"; fi
finish
