#!/usr/bin/env bash
# Unit tests of scripts/secure-world-build.sh: the committed lock file checks,
# a bad lock file or argument fails naming the fault, and the work directory
# rule holds. Offline: no source, toolchain or wheel is fetched; a stub curl
# fails the first fetch, after the work directory is set up.
set -euo pipefail
# shellcheck source=test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sw=$ROOT/scripts/secure-world-build.sh
good=$ROOT/secure-world/bsp.lock

run bash "$sw" --help
check "help prints the usage" 0 "usage: secure-world-build.sh"

run bash "$sw" --check-lock
check "the committed bsp.lock checks" 0 "bsp.lock OK" "lf-6.18.37-2.1.0" "toolchain 15.2.rel1"

run bash "$sw" --frobnicate
check "an unknown argument fails" nonzero "unknown argument: --frobnicate"

run bash "$sw" --jobs 0 --check-lock
check "--jobs 0 fails" nonzero "--jobs must be a positive number"

run bash "$sw" --lock "$TMP_ROOT/absent.lock" --check-lock
check "a missing lock file fails" nonzero "no such lock file"

# lockcopy <name> <edit>: prints the path of a copy of the good lock with
# each line passed through the function <edit>, which changes one pin.
lockcopy() {
	local f=$TMP_ROOT/$1.lock line
	: >"$f"
	while IFS= read -r line || [ -n "$line" ]; do
		"$2" "$line" >>"$f"
	done <"$good"
	printf '%s\n' "$f"
}
edit_unread() { [[ "$1" == TFA_COMMIT=* ]] && echo TFA_COMMIT=UNREAD || printf '%s\n' "$1"; }
edit_short() { [[ "$1" == OPTEE_COMMIT=* ]] && echo OPTEE_COMMIT=99f40897 || printf '%s\n' "$1"; }
edit_digest() { [[ "$1" == TOOLCHAIN_SHA256=* ]] && echo TOOLCHAIN_SHA256=abc || printf '%s\n' "$1"; }
edit_url() { [[ "$1" == FTPM_REPO=* ]] && echo FTPM_REPO=http://example.org/x.git || printf '%s\n' "$1"; }
edit_chars() { [[ "$1" == TFA_PLAT=* ]] && echo 'TFA_PLAT=imx95;true' || printf '%s\n' "$1"; }
edit_unknown() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nEXTRA_FLAG=y\n' "$1" || printf '%s\n' "$1"; }
edit_twice() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\n%s\n' "$1" "$1" || printf '%s\n' "$1"; }
edit_missing() { [[ "$1" == MSTPM_COMMIT=* ]] || printf '%s\n' "$1"; }
edit_nowheel() { [[ "$1" == PYWHEEL=* ]] || printf '%s\n' "$1"; }
edit_badwheel() { [[ "$1" == PYWHEEL=cffi* ]] && echo PYWHEEL=cffi==2.1.1 || printf '%s\n' "$1"; }
edit_shape() { [[ "$1" == TFA_PLAT=* ]] && printf '%s\nnot a pin\n' "$1" || printf '%s\n' "$1"; }

for c in \
	"unread|is marked UNREAD" \
	"short|must be a 40-hex commit" \
	"digest|must be a 64-hex SHA-256" \
	"url|must be an https URL" \
	"chars|has characters outside" \
	"unknown|unknown name EXTRA_FLAG" \
	"twice|TFA_PLAT is set twice" \
	"missing|MSTPM_COMMIT is missing" \
	"nowheel|no PYWHEEL line" \
	"badwheel|PYWHEEL must be" \
	"shape|not NAME=value"; do
	name=${c%%|*} want=${c#*|}
	f=$(lockcopy "$name" "edit_$name")
	run bash "$sw" --lock "$f" --check-lock
	check "a lock with $name fails" nonzero "$want"
done

# The host and the work directory: stubs make the host look like x86_64
# Linux with every tool, and curl fail, so a run stops at the first fetch.
stubs=$TMP_ROOT/stubs
mkdir -p "$stubs"
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo "${STUB_ARCH:-x86_64}" ;; esac
EOF
cat >"$stubs/curl" <<'EOF'
#!/bin/sh
echo "curl: stub, offline" >&2
exit 7
EOF
for t in git make tar xz sha256sum uv; do
	command -v "$t" >/dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' >"$stubs/$t"
done
chmod +x "$stubs"/*
sp=$stubs:$PATH

w=$TMP_ROOT/w
mkdir -p "$w/work"
: >"$w/work/foreign"
run env PATH="$sp" bash "$sw" --work "$w/work" --out "$w/out" --cache "$w/cache"
check "a non-empty work directory not made by the script is refused" nonzero "is not empty and was not made by this script"
expect "the refused work directory keeps its file" test -f "$w/work/foreign"

: >"$w/afile"
run env PATH="$sp" bash "$sw" --work "$w/afile" --out "$w/out" --cache "$w/cache"
check "a work path that is a file is refused" nonzero "is not a directory"

run env PATH="$sp" STUB_ARCH=aarch64 bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a host other than x86_64 Linux is refused" nonzero "this host is Linux-aarch64"

run env PATH="$sp" bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a new work directory is made, then the offline fetch fails" nonzero "toolchain failed"
expect "the new work directory holds the marker" test -f "$w/new/.secure-world-build-work"

: >"$w/new/stale"
run env PATH="$sp" bash "$sw" --work "$w/new" --out "$w/out" --cache "$w/cache"
check "a work directory the script made is recreated" nonzero "toolchain failed"
expect "the recreated work directory lost its stale file" test ! -e "$w/new/stale"

finish
