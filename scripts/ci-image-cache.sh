#!/usr/bin/env bash
# ci-image-cache.sh v4 (2026-11-12, Codex security P1 on trusted-imx95 #19):
# checking the tag once left a race, because later steps resolved it again.
# The Makefile now records the image ID a trusted build settles on (the
# verified pull's, or its own build's) and `make -s toolchain-ref` prints it;
# publish tags and pushes that ID, never the local tag.
# ci-image-cache.sh v3 (2026-11-12, Codex security P1 on trusted-imx95 #19):
# pull request jobs share the runners' persistent Docker daemon and run their
# own Makefile with Docker access, so a pull request can tag any image with
# main's toolchain tag. A trusted run (GITHUB_EVENT_NAME set and not
# pull_request or pull_request_target) therefore never trusts a tag the
# daemon holds: pull always pulls from the registry, takes the registry's
# digest from the image's RepoDigests, pulls that digest, tags it, and
# exports its image ID to the job as TOOLCHAIN_VERIFIED_ID (GITHUB_ENV). The
# Makefile's docker-build-toolchain uses that ID on a trusted run while the
# daemon holds it, and otherwise rebuilds from source with no cache.
# test/ci_scripts_test.sh holds this. A pull request run, and a run outside
# CI, keep v2's behaviour.
# ci-image-cache.sh v2 (2026-11-08, Company Agent m2101 item 2): the
# namespace comes only from CI_IMAGE_NAMESPACE, the repository Actions
# variable; unset, the script stops.
# ci-image-cache.sh v1 (ci-template v1.30, fix 1 of the 72-hour CI evaluation):
# the toolchain image's registry cache. It ships beside ci.yml as
# scripts/ci-image-cache.sh.
#
#   ci-image-cache.sh pull                 before `make docker-build`: when the
#                                          daemon lacks the toolchain tag, pull it
#                                          from the forge registry and tag it locally
#   ci-image-cache.sh publish [make args]  on the release runner, on a push to main
#                                          only: build and push the toolchain image
#                                          when the registry lacks its tag
#
# The toolchain tag is `make -s toolchain-image`, <repo>-toolchain:<hash>, the
# hash of the Dockerfile, the tool pin file and every devcontainer module's
# go.mod and go.sum (ci-standard.md §9). The published name is
# <registry>/<namespace>/<repo>-toolchain:<hash>-main, so the image is built
# once per change to those files, by the release runner, and every other job
# and runner pulls it instead of building it. The registry is the forge's own,
# host[:port] from GITHUB_SERVER_URL, as in go-qrdb's scripts/ci-registry.sh;
# no address is written here. The namespace is CI_IMAGE_NAMESPACE, the
# repository Actions variable (v2: no default here), public for anonymous
# pull (ruling 217(4)); only the release
# runner writes there (rulings 169 and 173). On github.com both commands do
# nothing.
#
# pull exits 0 when the daemon holds the tag after it, and 1 otherwise; the
# caller runs `scripts/ci-image-cache.sh pull || true`, so a miss, an
# unreachable registry or a failed pull falls back to the local build, never to
# a red job. A pulled image keeps its digest in the log.
#
# publish reads the release runner's credential contract (ruling 173):
# RELEASE_REGISTRY, which must be this forge's registry, RELEASE_REGISTRY_USER
# and RELEASE_REGISTRY_TOKEN. No credential value is printed or put on a
# command line: docker reads the token on stdin, into a private DOCKER_CONFIG
# that is removed on exit. A pull logs in with nothing, through an empty
# DOCKER_CONFIG.
set -euo pipefail

die() { echo "ci-image-cache: $*" >&2; exit 1; }

case ${GITHUB_SERVER_URL:-} in
  '' | https://github.com) echo "ci-image-cache: no forge registry on this host; nothing to do"; exit 0 ;;
esac
host=${GITHUB_SERVER_URL#*://}
host=${host%%/*}
ns=${CI_IMAGE_NAMESPACE:-}
[ -n "$ns" ] || die "CI_IMAGE_NAMESPACE is not set (the repository Actions variable)"

# A trusted run is CI on any event but a pull request (v3, above).
case ${GITHUB_EVENT_NAME:-} in
  '' | pull_request | pull_request_target) trusted=0 ;;
  *) trusted=1 ;;
esac

local_tag=$(make -s toolchain-image) || die "make -s toolchain-image failed"
case $local_tag in
  *:*) ;;
  *) die "make -s toolchain-image printed '$local_tag', not <name>:<tag>" ;;
esac
remote="$host/$ns/$local_tag-main"

cfg=$(mktemp -d)
cleanup() { rm -f "$cfg/config.json"; rmdir "$cfg" 2>/dev/null || true; }
trap cleanup EXIT

case ${1:-} in
  pull)
    # A pull request may use a tag the daemon holds. A trusted run never does
    # (v3, above): the shared daemon lets a pull request's job tag any image.
    if [ "$trusted" = 0 ] && docker image inspect "$local_tag" >/dev/null 2>&1; then
      echo "ci-image-cache: the daemon holds $local_tag; no pull"
      exit 0
    fi
    [ "$trusted" = 0 ] || echo "ci-image-cache: a trusted run ($GITHUB_EVENT_NAME) never uses the daemon's $local_tag; pulling it by digest"
    if ! DOCKER_CONFIG=$cfg docker pull -q "$remote" >/dev/null 2>&1; then
      echo "ci-image-cache: $remote is not in the registry (or the pull failed); the job builds it"
      exit 1
    fi
    # The registry's digest for the tag: the RepoDigests entry of this
    # repository, which only a pull from (or a push to) the registry sets.
    repo=${remote%:*}
    digest=
    while IFS= read -r d; do
      case $d in "$repo"@sha256:*) digest=${d#"$repo"@}; break ;; esac
    done < <(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$remote" 2>/dev/null || true)
    if [ -z "$digest" ]; then
      [ "$trusted" = 0 ] || { echo "ci-image-cache: $remote has no registry digest; the job builds it"; exit 1; }
      digest=unknown
    fi
    if [ "$trusted" = 1 ]; then
      # Pull by digest, then tag that content and nothing else.
      DOCKER_CONFIG=$cfg docker pull -q "$repo@$digest" >/dev/null 2>&1 \
        || { echo "ci-image-cache: the pull of $repo@$digest failed; the job builds it"; exit 1; }
      id=$(docker image inspect --format '{{.Id}}' "$repo@$digest") \
        || { echo "ci-image-cache: $repo@$digest is not in the daemon after its pull; the job builds it"; exit 1; }
      docker tag "$repo@$digest" "$local_tag"
      [ "$(docker image inspect --format '{{.Id}}' "$local_tag")" = "$id" ] \
        || { echo "ci-image-cache: $local_tag does not name $repo@$digest after the tag; the job builds it"; exit 1; }
      # The Makefile's docker-build-toolchain records this ID for the job's
      # containers (v4, above).
      if [ -n "${GITHUB_ENV:-}" ]; then echo "TOOLCHAIN_VERIFIED_ID=$id" >> "$GITHUB_ENV"; fi
    else
      docker tag "$remote" "$local_tag"
    fi
    docker image rm "$remote" >/dev/null 2>&1 || true   # untags only; $local_tag keeps the image
    echo "ci-image-cache: pulled $repo@$digest as $local_tag"
    ;;
  publish)
    shift
    [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF:-}" = refs/heads/main ] \
      || die "publish runs on a push to main only"
    [ -n "${RELEASE_REGISTRY_USER:-}" ] || die "RELEASE_REGISTRY_USER is not set (the release runner's env file exports it)"
    [ -n "${RELEASE_REGISTRY_TOKEN:-}" ] || die "RELEASE_REGISTRY_TOKEN is not set (the release runner's env file exports it)"
    [ "${RELEASE_REGISTRY:-$host}" = "$host" ] || die "RELEASE_REGISTRY is not this forge's registry; refusing the push"
    if DOCKER_CONFIG=$cfg docker manifest inspect "$remote" >/dev/null 2>&1; then
      echo "ci-image-cache: the registry holds $remote; nothing to publish"
      exit 0
    fi
    make docker-build-toolchain "$@"
    # The ID the build recorded, never $local_tag, which the shared daemon's
    # other jobs can move (v4, above).
    id=$(make -s toolchain-ref "$@") || die "make -s toolchain-ref failed"
    printf '%s' "$RELEASE_REGISTRY_TOKEN" | DOCKER_CONFIG=$cfg docker login "$host" -u "$RELEASE_REGISTRY_USER" --password-stdin >/dev/null
    docker tag "$id" "$remote"
    DOCKER_CONFIG=$cfg docker push -q "$remote" >/dev/null
    digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$remote" 2>/dev/null || echo unknown)
    docker image rm "$remote" >/dev/null 2>&1 || true
    echo "ci-image-cache: published $local_tag as $digest"
    ;;
  *)
    die "usage: ci-image-cache.sh pull | publish [make args]"
    ;;
esac
