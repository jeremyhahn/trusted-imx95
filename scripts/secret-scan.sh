#!/usr/bin/env bash
# secret-scan.sh <tree|history> [repo-dir]: runs pinned gitleaks, redacted, printing path, line and rule only; exit 1 on a finding or a failed scan.
set -euo pipefail

mode=${1:?usage: secret-scan.sh <tree|history> [repo-dir]}
dir=${2:-.}

if ! command -v gitleaks >/dev/null 2>&1; then
	echo "secret-scan: gitleaks is not on PATH; run in the devcontainer image (make docker-run CMD='make security')" >&2
	exit 1
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT

case "$mode" in
tree) sub=(dir "$dir") ;;
history)
	# A shallow clone hides every commit before its depth: scanning it would
	# pass a secret committed and removed earlier. Refuse, never pass.
	if [ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
		echo "secret-scan (history): $dir is a shallow clone or not a git repository; the history scan needs the full history (actions/checkout fetch-depth: 0, or git fetch --unshallow)" >&2
		exit 1
	fi
	# -m diffs merges against each parent so merge resolutions are scanned; --log-opts replaces the defaults, so they are restated.
	sub=(git "$dir" --log-opts="--all --full-history --diff-filter=tuxdb -m")
	;;
*)
	echo "secret-scan: unknown mode '$mode' (tree or history)" >&2
	exit 2
	;;
esac

rc=0
gitleaks "${sub[@]}" --redact --no-banner --log-level error \
	--report-format json --report-path "$report" --exit-code 3 >/dev/null 2>&1 || rc=$?

case "$rc" in
0)
	echo "secret-scan ($mode): OK"
	;;
3)
	python3 -c '
import json, sys
for f in json.load(open(sys.argv[1])):
    where = f.get("File", "?")
    if f.get("Commit"):
        where = f.get("Commit")[:12] + ":" + where
    print("secret-scan: %s:%s: %s" % (where, f.get("StartLine", "?"), f.get("RuleID", "?")))
' "$report"
	echo "secret-scan ($mode): FAIL" >&2
	exit 1
	;;
*)
	echo "secret-scan ($mode): gitleaks could not run (exit $rc)" >&2
	exit 1
	;;
esac
