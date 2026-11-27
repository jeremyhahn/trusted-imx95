#!/usr/bin/env bash
# test/deps_check_test.sh: scripts/deps-check.sh reads the latest release of every
# pin class (tools, Alpine, Python requirements, workflow actions) through a stub
# curl that serves canned JSON per URL and records its arguments. Offline.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK=$ROOT/scripts/deps-check.sh
STUB_DIR=$TMP_ROOT/stub
mkdir -p "$STUB_DIR/bin" "$STUB_DIR/answers"
TOKEN="t$RANDOM$RANDOM$$"

# The stub answers a URL from answers/<url with every non-alphanumeric byte as _>:
# 200 and the file, or 404 with curl -f's exit 22. It refuses --opt=value for
# --write-out as curl does, keeps one line of arguments per call and the stdin of
# --config -.
cat >"$STUB_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/args.log"
out='' url='' cfg=0 wo=0
while [ $# -gt 0 ]; do
	case $1 in
	--write-out=*)
		echo "curl: option $1: is unknown" >&2
		exit 2
		;;
	-o) out=$2; shift ;;
	--config) cfg=1; shift ;;
	--write-out) wo=1; shift ;;
	http*) url=$1 ;;
	esac
	shift
done
[ "$cfg" -eq 0 ] || cat >>"$STUB_DIR/stdin.log"
file=$STUB_DIR/answers/$(printf '%s' "$url" | tr -c 'A-Za-z0-9.' '_')
# answers/any_github_release, when present, answers every releases/latest URL that has no answer of its own.
if [ ! -f "$file" ] && [[ $url == https://api.github.com/repos/*/releases/latest ]]; then
	file=$STUB_DIR/answers/any_github_release
fi
if [ -f "$file" ]; then
	if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
	[ "$wo" -eq 0 ] || printf 200
	exit 0
fi
[ "$wo" -eq 0 ] || printf 404
exit 22
EOF
chmod +x "$STUB_DIR/bin/curl"

# answer <url> <body>
answer() {
	printf '%s' "$2" >"$STUB_DIR/answers/$(printf '%s' "$1" | tr -c 'A-Za-z0-9.' '_')"
}
gh() { answer "https://api.github.com/repos/$1/releases/latest" "{\"tag_name\":\"$2\",\"published_at\":\"$3\"}"; }
pypi() { answer "https://pypi.org/pypi/$1/json" "{\"info\":{\"version\":\"$2\"},\"urls\":[{\"upload_time_iso_8601\":\"$3.123456Z\"}]}"; }
dc() { env PATH="$STUB_DIR/bin:$PATH" STUB_DIR="$STUB_DIR" GITHUB_TOKEN="$TOKEN" "$@"; }

old=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%S)
sha=0123456789abcdef0123456789abcdef01234567

answer "https://registry.hub.docker.com/v2/repositories/library/alpine/tags?page_size=100" \
	"{\"results\":[{\"name\":\"3.24.4\",\"tag_last_pushed\":\"${old}Z\"},{\"name\":\"edge\",\"last_updated\":\"${old}Z\"}]}"
gh example/aaa v1.0.0 "${old}Z"
gh example/bbb v2.1.0 "${old}Z"
pypi fresh-pkg 1.0.0 "$old"
pypi stale-pkg 1.2.0 "$old"
gh example/uptodate v1.0.0 "${old}Z"
gh example/stale v1.2.0 "${old}Z"
gh example/coarse v6.2.0 "${old}Z"

pins=$TMP_ROOT/pins.sh
cat >"$pins" <<'EOF'
ALPINE_VERSION=3.24.4
AAA_REPO=example/aaa
AAA_VERSION=1.0.0
BBB_REPO=example/bbb
BBB_VERSION=2.0.0
CCC_REPO=example/ccc
CCC_VERSION=3.0.0
PINNED_TOOLS=AAA,BBB,CCC
EOF
reqs=$TMP_ROOT/requirements.txt
cat >"$reqs" <<'EOF'
# a comment
fresh-pkg==1.0.0 \
    --hash=sha256:aa
stale-pkg==1.0.0 \
    --hash=sha256:bb
gone-pkg==1.0.0 \
    --hash=sha256:cc
EOF
wf=$TMP_ROOT/wf
mkdir -p "$wf"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/uptodate@%s # v1.0.0\n      - uses: example/stale@%s # v1.0.0\n      - uses: example/coarse@%s # v6\n      - uses: ./local\n      - uses: example/loose@v1\n' \
	"$sha" "$sha" "$sha" >"$wf/x.yml"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/stale@%s # v1.0.0\n      - uses: example/missing@%s # v1.0.0\n' \
	"$sha" "$sha" >"$wf/y.yml"

# Every class, one outdated or unreadable item in each; none hides another.
run dc env DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "mixed run fails" 1 \
	"OK     AAA 1.0.0 (latest)" \
	"FAIL   BBB 2.0.0 is behind 2.1.0" \
	"FAIL   CCC: the latest release of example/ccc cannot be read (HTTP 404)" \
	"OK     ALPINE 3.24.4 (latest)" \
	"OK     PYPI:fresh-pkg 1.0.0 (latest)" \
	"FAIL   PYPI:stale-pkg 1.0.0 is behind 1.2.0" \
	"FAIL   PYPI:gone-pkg: the latest release cannot be read (HTTP 404)" \
	"OK     ACTION:example/uptodate 1.0.0 (latest)" \
	"FAIL   ACTION:example/stale 1.0.0 is behind 1.2.0" \
	"FAIL   ACTION:example/coarse: the comment 'v6' on the SHA pin must name the exact release" \
	"FAIL   ACTION:example/coarse 6 is behind 6.2.0" \
	"FAIL   ACTION:example/missing: the latest release of example/missing cannot be read (HTTP 404)"
if [[ "$OUT" == *"./local"* || "$OUT" == *"example/loose"* ]]; then fail "local and unpinned actions are not listed"; else pass "local and unpinned actions are not listed"; fi
stale_lines=0 stale_calls=0
while IFS= read -r l; do [[ $l != *"ACTION:example/stale"* ]] || stale_lines=$((stale_lines + 1)); done <<<"$OUT"
while IFS= read -r l; do [[ $l != *"repos/example/stale/"* ]] || stale_calls=$((stale_calls + 1)); done <"$STUB_DIR/args.log"
if [ "$stale_lines" = 1 ] && [ "$stale_calls" = 1 ]; then pass "an action used twice is looked up and reported once"; else fail "an action used twice is looked up and reported once" "lines $stale_lines, lookups $stale_calls"; fi

# curl takes no --opt=value; the token is on stdin only.
args=$(<"$STUB_DIR/args.log")
stdin=$(<"$STUB_DIR/stdin.log")
if [[ "$args" == *"--write-out="* ]]; then fail "no argument starts with --write-out="; else pass "no argument starts with --write-out="; fi
if [[ "$args" == *"$TOKEN"* ]]; then fail "no token on a curl command line"; else pass "no token on a curl command line"; fi
if [[ "$stdin" == *"header = \"Authorization: Bearer $TOKEN\""* ]]; then pass "the token reaches curl on stdin"; else fail "the token reaches curl on stdin"; fi
if [[ "$OUT" == *"$TOKEN"* ]]; then fail "no token in the output"; else pass "no token in the output"; fi

# Everything current: exit 0.
cat >"$pins" <<'EOF'
ALPINE_VERSION=3.24.4
AAA_REPO=example/aaa
AAA_VERSION=1.0.0
PINNED_TOOLS=AAA
EOF
printf 'fresh-pkg==1.0.0 \\\n    --hash=sha256:aa\n' >"$reqs"
rm "$wf/y.yml"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/uptodate@%s # v1.0.0\n' "$sha" >"$wf/x.yml"
run dc env DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "everything at its latest release passes" 0 "OK     PYPI:fresh-pkg" "OK     ACTION:example/uptodate"

# A SHA pin never moves: a major-only comment is not current while the latest is v6.2.0; the exact version is.
printf 'jobs:\n  j:\n    steps:\n      - uses: example/coarse@%s # v6\n' "$sha" >"$wf/x.yml"
run dc env DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "a SHA pin commented with a major only is not OK" 1 "FAIL   ACTION:example/coarse: the comment 'v6' on the SHA pin must name the exact release"
if [[ "$OUT" == *"OK     ACTION:example/coarse"* ]]; then fail "a major-only SHA pin is not judged current"; else pass "a major-only SHA pin is not judged current"; fi
printf 'jobs:\n  j:\n    steps:\n      - uses: example/coarse@%s # v6.2.0\n' "$sha" >"$wf/x.yml"
run dc env DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "a SHA pin commented with the exact latest version is OK" 0 "OK     ACTION:example/coarse 6.2.0 (latest)"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/uptodate@%s # v1.0.0\n' "$sha" >"$wf/x.yml"

# An outdated pin under 7 days old is reported, not failed.
new=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S)
pypi stale-pkg 1.2.0 "$new"
printf 'stale-pkg==1.0.0 \\\n    --hash=sha256:bb\n' >"$reqs"
run dc env DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "a Python release under 7 days old is reported" 0 "REPORT PYPI:stale-pkg 1.0.0, latest 1.2.0"

# Without the file variables, and with DEPS_RELEASES_DIR, the new sections stay out.
: >"$STUB_DIR/args.log"
run dc "$CHECK" "$pins"
check "no Python or Actions section without the variables" 0 "OK     AAA"
args=$(<"$STUB_DIR/args.log")
if [[ "$args" == *pypi.org* ]]; then fail "PyPI is not read without DEPS_REQUIREMENTS"; else pass "PyPI is not read without DEPS_REQUIREMENTS"; fi
mkdir -p "$TMP_ROOT/rel"
printf 'v1.0.0 %sZ\n' "$old" >"$TMP_ROOT/rel/AAA"
# --fetch writes the tools' and the pinned actions' latest releases; a check with DEPS_RELEASES_DIR judges the
# actions from those files with no GitHub call, reads PyPI live, and fails an action with no file.
printf 'jobs:\n  j:\n    steps:\n      - uses: example/uptodate@%s # v1.0.0\n      - uses: example/stale@%s # v1.0.0\n' "$sha" "$sha" >"$wf/x.yml"
run dc env DEPS_WORKFLOWS="$wf" "$CHECK" --fetch "$TMP_ROOT/rel" "$pins"
check "--fetch writes the pinned actions' releases" 0 "FETCH  AAA v1.0.0" "FETCH  ACTION:example/uptodate v1.0.0" "FETCH  ACTION:example/stale v1.2.0"
if [ -s "$TMP_ROOT/rel/ACTION@example@stale" ]; then pass "--fetch writes one file per action"; else fail "--fetch writes one file per action"; fi
: >"$STUB_DIR/args.log"
run dc env DEPS_RELEASES_DIR="$TMP_ROOT/rel" DEPS_REQUIREMENTS="$reqs" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "DEPS_RELEASES_DIR still judges the Python and Actions pins" 1 \
	"OK     AAA 1.0.0 (latest)" \
	"REPORT PYPI:stale-pkg 1.0.0, latest 1.2.0" \
	"OK     ACTION:example/uptodate 1.0.0 (latest)" \
	"FAIL   ACTION:example/stale 1.0.0 is behind 1.2.0"
args=$(<"$STUB_DIR/args.log")
if [[ "$args" == *api.github.com* ]]; then fail "DEPS_RELEASES_DIR makes no GitHub call"; else pass "DEPS_RELEASES_DIR makes no GitHub call"; fi
if [[ "$OUT" == *SKIP* ]]; then fail "DEPS_RELEASES_DIR skips nothing"; else pass "DEPS_RELEASES_DIR skips nothing"; fi
printf 'jobs:\n  j:\n    steps:\n      - uses: example/unfetched@%s # v1.0.0\n' "$sha" >"$wf/z.yml"
run dc env DEPS_RELEASES_DIR="$TMP_ROOT/rel" DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "an action --fetch did not write fails with DEPS_RELEASES_DIR" 1 \
	"FAIL   ACTION:example/unfetched: the latest release of example/unfetched cannot be read ($TMP_ROOT/rel/ACTION@example@unfetched holds no release tag and date)"
rm "$wf/z.yml"

# .yaml workflows are read beside .yml ones, by the check and by --fetch.
printf 'jobs:\n  j:\n    steps:\n      - uses: example/uptodate@%s # v1.0.0\n' "$sha" >"$wf/x.yml"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/coarse@%s # v6\n' "$sha" >"$wf/w.yaml"
run dc env DEPS_WORKFLOWS="$wf" "$CHECK" "$pins"
check "a pin in a .yaml workflow is checked beside the .yml ones" 1 \
	"OK     ACTION:example/uptodate 1.0.0 (latest)" \
	"FAIL   ACTION:example/coarse: the comment 'v6' on the SHA pin must name the exact release"
run dc env DEPS_WORKFLOWS="$wf" "$CHECK" --fetch "$TMP_ROOT/rel" "$pins"
check "--fetch reads .yaml workflows" 0 "FETCH  ACTION:example/coarse v6.2.0"
rm "$wf/w.yaml"
mkdir -p "$TMP_ROOT/wf-yaml"
printf 'jobs:\n  j:\n    steps:\n      - uses: example/stale@%s # v1.0.0\n' "$sha" >"$TMP_ROOT/wf-yaml/only.yaml"
run dc env DEPS_WORKFLOWS="$TMP_ROOT/wf-yaml" "$CHECK" "$pins"
check "a directory of .yaml workflows alone is checked" 1 "FAIL   ACTION:example/stale 1.0.0 is behind 1.2.0"

# The repository's own workflows: every SHA pin's comment names an exact release, and --fetch with its default
# directory reads them. Every action's latest release is served as the same canned answer.
answer any-github-release "{\"tag_name\":\"v1.0.0\",\"published_at\":\"${old}Z\"}"
rm -rf "$TMP_ROOT/rel-repo"
run dc "$CHECK" --fetch "$TMP_ROOT/rel-repo" "$pins"
check "--fetch reads the repository's workflows by default" 0 "FETCH  ACTION:actions/checkout"
run dc env DEPS_RELEASES_DIR="$TMP_ROOT/rel-repo" DEPS_WORKFLOWS="$ROOT/.github/workflows" "$CHECK" "$pins"
if [[ "$OUT" == *"ACTION:actions/checkout 6.1.0 is behind 1.0.0"* && "$OUT" != *"must name the exact release"* && "$OUT" != *"cannot be read"* ]]; then
	pass "every SHA pin in .github/workflows names an exact release"
else
	fail "every SHA pin in .github/workflows names an exact release" "$(printf '%s\n' "$OUT" | while IFS= read -r l; do [[ $l != *"must name the exact release"* ]] || printf '%s\n' "$l"; done)"
fi

finish
