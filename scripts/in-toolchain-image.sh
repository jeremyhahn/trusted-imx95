#!/usr/bin/env bash
# Run a command in the toolchain image against a copy of the checkout: scripts/in-toolchain-image.sh <image> <command...>.
# The container drops every capability, has no network unless IN_IMAGE_NETWORK=bridge, and gets the job's CPU and memory bounds; caches live in named volumes per trust class (CI_CACHE=off mounts none).
# A trusted run accepts <image> only as an image ID (sha256:<64 hex>). The container is named <CI_STACK_PREFIX>tc-<pid>-<random> and runs as IN_IMAGE_UID (default 10001).
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <image> <command...>" >&2
  exit 2
fi
image=$1
shift
# A trusted run starts its containers by image ID (above).
case ${GITHUB_EVENT_NAME:-} in
  '' | pull_request | pull_request_target) ;;
  *)
    if ! [[ $image =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "in-toolchain-image: a trusted run ($GITHUB_EVENT_NAME) starts containers by image ID (sha256:...), never by a tag: $image" >&2
      exit 2
    fi
    ;;
esac
network=${IN_IMAGE_NETWORK:-none}
case $network in
  none | bridge) ;;
  *) echo "IN_IMAGE_NETWORK must be none or bridge: $network" >&2; exit 2 ;;
esac

uid=${IN_IMAGE_UID:-10001}
case $uid in
  "" | 0 | *[!0-9]*) echo "IN_IMAGE_UID must be a non-root numeric uid: $uid" >&2; exit 2 ;;
esac
prefix=${CI_STACK_PREFIX:-$(basename "$PWD")-ci-}
name="${prefix}tc-$$-${RANDOM}"
cache=${CI_CACHE:-on}
case $cache in
  on | off) ;;
  *) echo "CI_CACHE must be on or off: $cache" >&2; exit 2 ;;
esac
class=${CI_CACHE_CLASS:-pr}
case $class in
  pr | main) ;;
  *) echo "CI_CACHE_CLASS must be pr or main: $class" >&2; exit 2 ;;
esac
cpus=${IN_IMAGE_CPUS:-}
if [ -z "$cpus" ]; then
  quota=max period=100000
  if [ -r /sys/fs/cgroup/cpu.max ]; then read -r quota period < /sys/fs/cgroup/cpu.max; fi
  case $quota in
    max | "" | *[!0-9]*) cpus=$(nproc) ;;
    *) cpus=$(((quota + period - 1) / period)) ;;
  esac
fi
case $cpus in
  "" | 0 | *[!0-9]*) echo "IN_IMAGE_CPUS must be a positive integer: $cpus" >&2; exit 2 ;;
esac
memory=${IN_IMAGE_MEMORY:-}
if [ -z "$memory" ]; then
  limit=max
  if [ -r /sys/fs/cgroup/memory.max ]; then read -r limit < /sys/fs/cgroup/memory.max; fi
  case $limit in
    max | "" | *[!0-9]*) memory=8g ;;
    *) memory=$limit ;;
  esac
fi
if ! [[ $memory =~ ^[1-9][0-9]*[mg]?$ ]]; then
  echo "IN_IMAGE_MEMORY must be a size in bytes, m or g, e.g. 16g: $memory" >&2
  exit 2
fi
scratch=${IN_IMAGE_SCRATCH:-/var/tmp}
case $scratch in
  /*) ;;
  *) echo "IN_IMAGE_SCRATCH must be an absolute path: $scratch" >&2; exit 2 ;;
esac
args=(
  --name "$name"
  --cpus "$cpus"
  --env GOMAXPROCS="$cpus"
  --env GOFLAGS="-p=$cpus"
  --init
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --pids-limit 4096
  --memory "$memory"
  --memory-swap "$memory"
  --ulimit memlock=67108864:67108864
  --ulimit core=1048576:1048576
  --ulimit nofile=65536:65536
  --tmpfs "/tmp:rw,exec,nosuid,nodev,size=3g,mode=1777"
  # Go's build and link scratch on disk, not the tmpfs (v4, above).
  -v "$scratch"
  --env TMPDIR="$scratch"
  --env GOTMPDIR="$scratch"
  --network "$network"
  --user "$uid:$uid"
  --workdir /src
  --env HOME=/tmp
  --env CI="${CI:-}"
)
modcache=/tmp/gomodcache
if [ "$cache" = on ]; then
  vols="${prefix}cache-${class}"
  docker run --rm --network none --cap-drop ALL --cap-add CHOWN \
    --security-opt no-new-privileges:true --user 0:0 \
    -v "$vols-gobuild:/c/gobuild" -v "$vols-golangci:/c/golangci" -v "$vols-gomod:/c/gomod" \
    "$image" sh -c "for d in /c/*; do [ \"\$(stat -c %u:%g \"\$d\")\" = $uid:$uid ] || chown $uid:$uid \"\$d\"; done" >/dev/null
  args+=(
    -v "$vols-gobuild:/cache/gobuild" --env GOCACHE=/cache/gobuild
    -v "$vols-golangci:/cache/golangci" --env GOLANGCI_LINT_CACHE=/cache/golangci
  )
  if [ "$network" = bridge ]; then
    args+=(-v "$vols-gomod:/cache/gomod")
    modcache=/cache/gomod
  fi
fi
if [ "$network" = bridge ]; then
  # The baked module cache is read-only to the run's user and holds only the
  # root module's build list; the nested modules deps-check walks fetch more.
  # Athens first when the runner sets DEVCACHE_GOPROXY (v4, above).
  args+=(--env "GOPROXY=${DEVCACHE_GOPROXY:+$DEVCACHE_GOPROXY|}https://proxy.golang.org" --env "GOMODCACHE=$modcache")
  # GOPRIVATE only: no forge credential enters the container (above).
  if [ -n "${GOPRIVATE:-}" ]; then args+=(--env GOPRIVATE); fi
fi

cleanup() { docker rm -f -v "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A scratch directory the image lacks, or the run's user cannot write, fails
# the stage here by name, not later as a tool's ENOSPC or EACCES.
# shellcheck disable=SC2016 # expands in the container, not here
guard='[ -d "$TMPDIR" ] && [ -w "$TMPDIR" ] || { echo "in-toolchain-image: scratch directory $TMPDIR is missing or not writable" >&2; exit 2; }'
docker create "${args[@]}" "$image" sh -c "$guard; $*" >/dev/null
tree_tar() {
  case $(tar --version 2>/dev/null) in
    *"GNU tar"*) tar -C "$PWD" --owner="$uid" --group="$uid" --numeric-owner -cf - . ;;
    *)
      python3 -c '
import os, sys, tarfile
uid = int(sys.argv[1])
def own(t):
    t.uid = t.gid = uid
    t.uname = t.gname = ""
    return t
os.chdir(sys.argv[2])
with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as tf:
    tf.add(".", filter=own)
' "$uid" "$PWD" ;;
  esac
}
tree_tar | docker cp -a - "$name:/src"
docker start -a "$name"
