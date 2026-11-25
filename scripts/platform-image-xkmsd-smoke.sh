#!/usr/bin/env bash
# Build-and-start smoke test of the xkmsd recipe (docs/SPEC.md, `platform-image`).
# What the static checks of test/platform_image_xkmsd_test.sh cannot show:
#   1. the pinned go-xkms commit the recipe names builds with the recipe's own
#      build script (files/xkmsd-build.sh, the one do_compile runs);
#   2. the daemon starts on the development config (dev/xkmsd-dev.yaml, software
#      key custody, never installed; state and socket paths redirected into a
#      temp dir), reaches its ready state (the local socket is served; the node
#      is sealed until an operator unseals it) and stops on SIGTERM;
#   3. it refuses the packaged production config (files/xkmsd.yaml), which
#      configures no key custody: no enclave backend exists at the pin;
#   4. it refuses to start when its state directory is read-only.
# It fails, never skips: a source that cannot be fetched, a build that fails or
# a missing tool is a failure. It needs network (the pinned commit and its Go
# modules), git, a C compiler, libusb headers and a Go toolchain that meets the
# go-xkms go.mod (GOTOOLCHAIN=local: it fetches no other), and a non-root user
# (a read-only directory does not stop root).
#
# The checkout and the Go caches live in XKMSD_SMOKE_CACHE (default
# ${TMPDIR:-/tmp}/trusted-imx95-xkmsd-smoke-<uid>), outside the clone, and are
# reused by the next run. XKMSD_SMOKE_REPO overrides the go-xkms URL (the
# recipe's SRC_URI by default); the pin is always the recipe's SRCREV.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
recipe=$root/platform-image/recipes-security/xkmsd/xkmsd_git.bb
build=$root/platform-image/recipes-security/xkmsd/files/xkmsd-build.sh
conf=$root/platform-image/recipes-security/xkmsd/files/xkmsd.yaml
devconf=$root/platform-image/recipes-security/xkmsd/dev/xkmsd-dev.yaml
unit=$root/platform-image/recipes-security/xkmsd/files/xkmsd.service
mountu=$root/platform-image/recipes-security/xkmsd/files/var-lib-xkms.mount

die() { echo "xkmsd-smoke: FAIL: $*" >&2; exit 1; }
ok() { echo "xkmsd-smoke: ok   $*"; }

# val NAME: the value of the recipe's first `NAME = "value"` line.
val() {
	local l v
	while IFS= read -r l; do
		case $l in "$1 = \""*'"')
			v=${l#"$1 = \""}
			printf '%s' "${v%\"}"
			return 0
			;;
		esac
	done <"$recipe"
	return 1
}

pv=$(val PV) || die "the recipe has no PV"
rev=$(val SRCREV) || die "the recipe has no SRCREV"
[[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the recipe's SRCREV '$rev' is not a full commit"
repo=${XKMSD_SMOKE_REPO:-}
if [ -z "$repo" ]; then
	repo=$(grep -o 'git://github.com/[^;" ]*' "$recipe" | head -n 1) || true
	[ -n "$repo" ] || die "the recipe's SRC_URI names no git:// source"
	repo=https://${repo#git://}
fi
[ "$(id -u)" != 0 ] || die "run as a non-root user: a read-only directory does not stop root"
for tool in git go gcc pkg-config; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

cache=${XKMSD_SMOKE_CACHE:-${TMPDIR:-/tmp}/trusted-imx95-xkmsd-smoke-$(id -u)}
work=$(mktemp -d)
pid=
cleanup() {
	[ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
	chmod -R u+rwX "$work" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$cache"
src=$cache/src-$rev

# The cache holds code the build runs, so it is reused only while it is ours and
# private: owned by the invoking user, mode 0700. A cache of another owner is
# not touched (fail); a cache of another mode is emptied and fetched afresh.
read -r cache_uid cache_mode < <(stat -c '%u %a' "$cache") || die "cannot stat the cache directory $cache"
[ "$cache_uid" = "$(id -u)" ] || die "the cache directory $cache is not owned by the invoking user"
if [ "$cache_mode" != 700 ]; then
	echo "xkmsd-smoke: the cache directory $cache is mode $cache_mode, not 0700: emptied" >&2
	chmod -R u+rwX "$cache"
	rm -rf "$cache"
	mkdir -m 0700 "$cache"
fi

# 1. The pinned commit, fetched by its hash. A cached checkout is reused only at
# that commit with nothing modified, added or ignored-but-present in it.
cached_ok() {
	[ -d "$src/.git" ] || return 1
	[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" = "$rev" ] || return 1
	local dirty
	dirty=$(git -C "$src" status --porcelain --ignored 2>&1) || return 1
	[ -z "$dirty" ]
}
if ! cached_ok; then
	chmod -R u+rwX "$src" 2>/dev/null || true
	rm -rf "$src"
	mkdir -p "$src"
	git -C "$src" init -q
	git -C "$src" fetch -q --depth 1 "$repo" "$rev" || die "cannot fetch go-xkms $rev from $repo"
	git -C "$src" checkout -q --detach FETCH_HEAD || die "cannot check out $rev"
	[ "$(git -C "$src" rev-parse HEAD)" = "$rev" ] || die "the fetched commit is not $rev"
fi
ok "go-xkms $rev is checked out"

# 2. The build: the recipe's own script, for this host.
export GOPATH=$cache/gopath GOCACHE=$cache/gocache GOMODCACHE=$cache/gomodcache
bin=$work/xkmsd
sh "$build" "$src" "$bin" "$pv" "$rev" || die "the recipe's build script failed"
[ -x "$bin" ] || die "the build left no xkmsd binary"
ok "the recipe's build script builds ./cmd/xkmsd"
vout=$("$bin" -version 2>&1) || die "xkmsd -version failed"
case $vout in *"$pv"*"$rev"* | *"$pv"*) ;; *) die "xkmsd -version does not report $pv: $vout" ;; esac
ok "xkmsd -version reports $pv"

# 2b. The unit and the state mount: they load, and the unit refuses to start
# without the state mount. Not a boot of the unit (that needs a built image,
# the image-build row's): systemd-analyze verifies both files and evaluates the
# unit's mount-point assertion against a directory that is no mount point (it
# must fail) and against a mount point (it must pass). Without systemd-analyze,
# or with XKMSD_SMOKE_OFFLINE_UNITS=1, the offline check reads the same lines.
[ -f "$unit" ] || die "the xkmsd unit $unit is missing"
[ -f "$mountu" ] || die "the state mount unit $mountu is missing: nothing mounts /var/lib/xkms"
mp='' rw='' l=''
while IFS= read -r l; do
	case $l in
	AssertPathIsMountPoint=/var/lib/xkms) mp=$l ;;
	AssertPathIsReadWrite=/var/lib/xkms) rw=$l ;;
	esac
done <"$unit"
[ -n "$mp" ] || die "xkmsd.service does not assert that /var/lib/xkms is a mount point: it would start without the state mount"
[ -n "$rw" ] || die "xkmsd.service does not assert that /var/lib/xkms is writable: it would start on a read-only state"
mkdir -p "$work/units" "$work/nomount"
c=$(<"$unit")
printf '%s\n' "${c//\/usr\/bin\/xkmsd/$bin}" >"$work/units/xkmsd.service"
cp "$mountu" "$work/units/var-lib-xkms.mount"
if [ -z "${XKMSD_SMOKE_OFFLINE_UNITS:-}" ] && command -v systemd-analyze >/dev/null 2>&1; then
	systemd-analyze verify "$work/units/xkmsd.service" "$work/units/var-lib-xkms.mount" || die "systemd-analyze verify rejects xkmsd.service or var-lib-xkms.mount"
	ok "systemd-analyze verifies xkmsd.service and var-lib-xkms.mount"
	cond() { systemd-analyze condition "$1" >/dev/null 2>&1; }
	cond "${mp//\/var\/lib\/xkms//}" || die "the mount-point assertion fails on a mount point: the check proves nothing"
	cond "${rw//\/var\/lib\/xkms/$work}" || die "the writable assertion fails on a writable directory: the check proves nothing"
	if cond "${mp//\/var\/lib\/xkms/$work/nomount}"; then die "xkmsd.service starts when /var/lib/xkms is no mount point"; fi
	ok "xkmsd.service refuses to start when /var/lib/xkms is no mount point"
	# AssertPathIsReadWrite tests the mount's read-only flag, not a directory's
	# mode: it is read from the unit above and its positive control run, and a
	# read-only mount needs a real mount, which only the built image has.
else
	echo "xkmsd-smoke: systemd-analyze is not used: the offline unit check" >&2
	has_line() {
		local ln
		while IFS= read -r ln; do [ "$ln" = "$2" ] && return 0; done <"$1"
		return 1
	}
	for l in 'RequiresMountsFor=/var/lib/xkms' 'After=var-lib-xkms.mount' "$mp" "$rw"; do
		has_line "$unit" "$l" || die "xkmsd.service lacks '$l'"
	done
	for l in 'What=/dev/disk/by-label/xkms-state' 'Where=/var/lib/xkms'; do
		has_line "$mountu" "$l" || die "var-lib-xkms.mount lacks '$l'"
	done
	ok "the offline unit check: xkmsd.service asserts the state mount, var-lib-xkms.mount names it"
fi

# The development config (software key custody, never installed in the image: it
# is what lets the real daemon run at all, since it refuses a config with no
# enabled key backend) with its state and socket paths in the temp dir.
c=$(<"$devconf")
c=${c//\/var\/lib\/xkms/$work/state}
c=${c//\/run\/xkms/$work/run}
mkdir -p "$work/state" "$work/run"
printf '%s\n' "$c" >"$work/xkmsd.yaml"

# wait_for FILE REGEX SECONDS: the pattern shows in FILE while the daemon runs.
wait_for() {
	local i
	for ((i = 0; i < $3 * 10; i++)); do
		grep -q -E "$2" "$1" 2>/dev/null && return 0
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 0.1
	done
	return 1
}

# 3. Start on the packaged config, reach ready, stop on SIGTERM.
"$bin" --config "$work/xkmsd.yaml" >"$work/run.log" 2>&1 &
pid=$!
if ! wait_for "$work/run.log" 'Unix socket server started' 120; then
	tail -n 20 "$work/run.log" >&2
	die "xkmsd did not reach its ready state (the local socket served) on the packaged config"
fi
[ -S "$work/run/xkms.sock" ] || die "the ready state is logged but $work/run/xkms.sock is no socket"
kill -0 "$pid" 2>/dev/null || die "xkmsd exited after it was ready"
ok "xkmsd reaches its ready state on the packaged config (socket served, node sealed)"
kill -TERM "$pid"
for ((i = 0; i < 300; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then die "xkmsd did not stop within 30 s of SIGTERM"; fi
rc=0
wait "$pid" || rc=$?
pid=
case $rc in 0 | 143) ;; *) tail -n 20 "$work/run.log" >&2; die "xkmsd stopped on SIGTERM with status $rc" ;; esac
if grep -q -E 'panic:|^goroutine ' "$work/run.log"; then die "xkmsd panicked on SIGTERM"; fi
ok "xkmsd stops on SIGTERM (status $rc)"

# 3b. The packaged (production) config configures no key custody, and go-xkms at
# the pin has no enclave backend to configure: the daemon must refuse it, exit
# non-zero and serve nothing, so key operations stay unavailable (fail closed).
mkdir -p "$work/prod/state" "$work/prod/run"
c=$(<"$conf")
c=${c//\/var\/lib\/xkms/$work/prod/state}
c=${c//\/run\/xkms/$work/prod/run}
printf '%s\n' "$c" >"$work/prod/xkmsd.yaml"
"$bin" --config "$work/prod/xkmsd.yaml" >"$work/prod/run.log" 2>&1 &
pid=$!
for ((i = 0; i < 300; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then die "xkmsd keeps running on the production config, which configures no key custody"; fi
rc=0
wait "$pid" || rc=$?
pid=
[ "$rc" -ne 0 ] || die "xkmsd exited 0 on the production config, which configures no key custody"
if grep -q 'Unix socket server started' "$work/prod/run.log" || [ -S "$work/prod/run/xkms.sock" ]; then die "xkmsd served its socket on the production config, which configures no key custody"; fi
ok "xkmsd refuses the production config, which configures no key custody (status $rc)"

# 4. Fails closed on a read-only state directory (development config).
mkdir -p "$work/ro/state" "$work/ro/run"
c=$(<"$devconf")
c=${c//\/var\/lib\/xkms/$work/ro/state}
c=${c//\/run\/xkms/$work/ro/run}
printf '%s\n' "$c" >"$work/ro/xkmsd.yaml"
chmod 0555 "$work/ro/state"
if (: >"$work/ro/state/probe") 2>/dev/null; then die "a 0555 directory is still writable here: the read-only check proves nothing"; fi
"$bin" --config "$work/ro/xkmsd.yaml" >"$work/ro/run.log" 2>&1 &
pid=$!
for ((i = 0; i < 300; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then die "xkmsd keeps running on a read-only state directory"; fi
rc=0
wait "$pid" || rc=$?
pid=
[ "$rc" -ne 0 ] || die "xkmsd exited 0 on a read-only state directory"
if grep -q 'Unix socket server started' "$work/ro/run.log"; then die "xkmsd served its socket on a read-only state directory"; fi
ok "xkmsd refuses to start on a read-only state directory (status $rc)"

echo "xkmsd-smoke: all passed"
