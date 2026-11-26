#!/usr/bin/env bash
# xkmsd-upgrade.sh: is the board on the latest go-xkms, and bring it there in
# one step. The owner's 2026-11-24 directive is that the board runs the latest
# go-xkms at all times. This script reads the board's running version over
# ssh, compares it with the commit a go-xkms ref resolves to, and with --apply
# builds that commit and deploys it (with xkmsd-deploy.sh's backup and
# rollback). The ssh target is always an argument.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: xkmsd-upgrade.sh [--help] [--dry-run] [--apply] [--ref <go-xkms ref>] <ssh target>

Resolve a go-xkms ref (default refs/heads/main, in XKMS_REPO, the same
default as xkmsd-build.sh) to one commit, read the board's running version
(<ssh target> /usr/local/bin/xkmsd --version) and print one line:

  current <commit>                     the version names the commit
  behind: board <reported>, latest <commit>
  unknown: <reason>                    no go-xkms commit in the answer, or no answer

Exit codes: 0 current, 10 behind (no --apply), 1 any error or an unknown
version, 2 usage; with --apply and behind, the exit status of the deploy.

  --apply     when behind: xkmsd-build.sh <commit>, then xkmsd-deploy.sh
              <ssh target> <that build dir>. The deploy backs up the board
              first and restores it on any failure, so every upgrade is
              covered. Never run when the build failed; refused when the
              version is unknown (install by hand with xkmsd-deploy.sh).
  --ref <r>   the go-xkms branch or tag to follow (an annotated tag is
              peeled to its commit)
  --dry-run   print the plan; contact nothing
EOF
}

usage_err() {
	echo "xkmsd-upgrade: $1 (see --help)" >&2
	exit 2
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=${XKMS_REPO:-https://github.com/jeremyhahn/go-xkms}
# XKMSD_BUILD and XKMSD_DEPLOY replace the two scripts, for tests only.
build=${XKMSD_BUILD:-$here/xkmsd-build.sh}
deploy=${XKMSD_DEPLOY:-$here/xkmsd-deploy.sh}
BIN=/usr/local/bin/xkmsd
# shellcheck disable=SC2206 # word splitting of the option string is intended
ssh_opts=(${XKMS_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10})

dry=0
apply=0
ref=refs/heads/main
target=""
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	--dry-run) dry=1 ;;
	--apply) apply=1 ;;
	--ref)
		[ $# -ge 2 ] || usage_err "--ref needs a value"
		ref=$2
		shift
		;;
	-*) usage_err "unknown option $1" ;;
	*)
		[ -z "$target" ] || usage_err "more than one ssh target"
		target=$1
		;;
	esac
	shift
done
[ -n "$target" ] || usage_err "no ssh target"
case $ref in
"" | -*) usage_err "bad --ref '$ref'" ;;
esac

if [ "$dry" = 1 ]; then
	echo "plan: git ls-remote $repo $ref; refuse unless that is exactly one 40-hex commit"
	echo "plan: ssh $target $BIN --version; the version names the commit: current (exit 0), another commit: behind (exit 10), neither: unknown (exit 1)"
	if [ "$apply" = 1 ]; then
		echo "plan: when behind: $build <commit>, then $deploy $target <the build dir it printed>; exit with the deploy's status"
		echo "plan: when unknown: refuse (exit 1)"
	else
		echo "plan: without --apply nothing is built or installed"
	fi
	exit 0
fi

# resolve: the commit of $ref in $repo, or an error. An annotated tag lists
# the tag object and, peeled (^{}), its commit: the peeled one is the commit.
resolve() {
	local out l n=0 p=0 c="" pc=""
	out=$(git ls-remote "$repo" "$ref" "$ref^{}") || {
		echo "xkmsd-upgrade: git ls-remote $repo $ref failed" >&2
		return 1
	}
	while IFS= read -r l; do
		[ -n "$l" ] || continue
		case $l in
		*'^{}')
			p=$((p + 1))
			pc=${l%%[[:space:]]*}
			;;
		*)
			n=$((n + 1))
			c=${l%%[[:space:]]*}
			;;
		esac
	done <<<"$out"
	if [ "$n" = 1 ] && [ "$p" = 1 ]; then
		c=$pc
	elif [ "$n" != 1 ] || [ "$p" != 0 ]; then
		echo "xkmsd-upgrade: $ref names $n refs in $repo, need exactly one" >&2
		return 1
	fi
	[[ $c =~ ^[0-9a-f]{40}$ ]] || {
		echo "xkmsd-upgrade: $ref does not resolve to a 40-hex commit: '$c'" >&2
		return 1
	}
	commit=$c
}

commit=""
resolve || exit 1

rc=0
ver=$(ssh "${ssh_opts[@]}" "$target" "$BIN" --version 2>&1) || rc=$?
if [ "$rc" != 0 ]; then
	echo "unknown: ssh to the board failed (exit $rc), its version is not known"
	exit 1
fi

# The answer on one line, for the report.
one=$(printf '%s' "$ver" | tr '\n\r\t' '   ' | tr -s ' ')
one=${one# }
one=${one% }
one=${one:0:200}

re_sha='[0-9a-f]{40}'
re_short='\+g[0-9a-f]{7,}'
case $ver in
*"$commit"*)
	echo "current $commit"
	exit 0
	;;
esac
if ! [[ $ver =~ $re_sha || $ver =~ $re_short ]]; then
	echo "unknown: board reported '$one', which names no go-xkms commit"
	[ "$apply" = 0 ] || echo "xkmsd-upgrade: refusing to --apply over an unknown version; install by hand with xkmsd-deploy.sh" >&2
	exit 1
fi

echo "behind: board $one, latest $commit"
[ "$apply" = 1 ] || exit 10

# Build the commit; the deploy follows only when the build succeeded and
# printed a build directory holding exactly that commit.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
rc=0
"$build" "$commit" 2>&1 | tee "$log" || rc=$?
if [ "$rc" != 0 ]; then
	echo "xkmsd-upgrade: the build failed (exit $rc); nothing is deployed" >&2
	exit "$rc"
fi
builddir=""
while IFS= read -r l; do
	case $l in
	"xkmsd-build: output "*) builddir=${l#xkmsd-build: output } ;;
	esac
done <"$log"
[ -n "$builddir" ] && [ -f "$builddir/manifest.txt" ] || {
	echo "xkmsd-upgrade: the build printed no build directory with a manifest; nothing is deployed" >&2
	exit 1
}
built=""
while IFS= read -r l; do
	case $l in
	"go-xkms-commit: "*) built=${l#go-xkms-commit: } ;;
	esac
done <"$builddir/manifest.txt"
[ "$built" = "$commit" ] || {
	echo "xkmsd-upgrade: $builddir/manifest.txt names '$built', not $commit; nothing is deployed" >&2
	exit 1
}

rc=0
"$deploy" "$target" "$builddir" || rc=$?
exit "$rc"
