#!/usr/bin/env bash
# ci-image-cache.sh v5 (2026-11-12, Codex security P1s on trusted-imx95 #19):
# v4 still resolved the shared daemon's tags at two points. The trusted pull
# read the registry digest from the RepoDigests of the tag it had just
# pulled, and another job could retag that in between. Publish tagged the
# built ID and then pushed the tag, which could be retagged before the push.
# Now a trusted run reads the tag's digest from the registry itself
# (`docker buildx imagetools inspect`, which asks the registry, not the
# daemon), pulls that digest and takes TOOLCHAIN_VERIFIED_ID from the
# by-digest reference. A digest reference cannot be retagged. Publish builds
# with `docker buildx build --output type=registry`, which pushes the build's
# own result. It then reads the registry's digest for the tag and fails
# unless that digest is the build's (its --metadata-file).
# Both need the runner's docker buildx CLI plugin; this runs on the runner
# host, not in the toolchain image. Without buildx a trusted pull falls back
# to the local build, and publish fails.
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
cleanup() { rm -rf "$cfg"; }
trap cleanup EXIT
# The private DOCKER_CONFIG still finds the user's CLI plugins (buildx),
# which the CLI looks up under it first.
plugins=${DOCKER_CONFIG:-${HOME:-/nonexistent}/.docker}/cli-plugins
if [ -d "$plugins" ]; then ln -s "$plugins" "$cfg/cli-plugins"; fi
repo=${remote%:*}

# registry_digest <ref>: the manifest digest the registry holds for <ref>,
# asked of the registry and never of the shared daemon (v5, above). Prints
# nothing and fails when it cannot be read.
registry_digest() {
  DOCKER_CONFIG=$cfg docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null \
    | jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' 2>/dev/null
}

case ${1:-} in
  pull)
    # A pull request may use a tag the daemon holds. A trusted run never does
    # (v3, above): the shared daemon lets a pull request's job tag any image.
    if [ "$trusted" = 0 ] && docker image inspect "$local_tag" >/dev/null 2>&1; then
      echo "ci-image-cache: the daemon holds $local_tag; no pull"
      exit 0
    fi
    if [ "$trusted" = 1 ]; then
      echo "ci-image-cache: a trusted run ($GITHUB_EVENT_NAME) never uses the daemon's $local_tag; pulling it by the registry's digest"
      # The digest from the registry (v5), then the pull of that digest. The
      # ID is the by-digest reference's, which no other job can retag.
      digest=$(registry_digest "$remote") \
        || { echo "ci-image-cache: the registry gave no digest for $remote (not there, unreachable, or no docker buildx); the job builds it"; exit 1; }
      DOCKER_CONFIG=$cfg docker pull -q "$repo@$digest" >/dev/null 2>&1 \
        || { echo "ci-image-cache: the pull of $repo@$digest failed; the job builds it"; exit 1; }
      id=$(docker image inspect --format '{{.Id}}' "$repo@$digest" 2>/dev/null) && [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || { echo "ci-image-cache: $repo@$digest is not in the daemon after its pull; the job builds it"; exit 1; }
      # The tag is for people only. Nothing in a trusted job reads it, because
      # the Makefile's docker-build-toolchain records this ID for the job's
      # containers (v4, above).
      docker tag "$repo@$digest" "$local_tag" || true
      if [ -n "${GITHUB_ENV:-}" ]; then echo "TOOLCHAIN_VERIFIED_ID=$id" >> "$GITHUB_ENV"; fi
      echo "ci-image-cache: pulled $repo@$digest as $id"
      exit 0
    fi
    if ! DOCKER_CONFIG=$cfg docker pull -q "$remote" >/dev/null 2>&1; then
      echo "ci-image-cache: $remote is not in the registry (or the pull failed); the job builds it"
      exit 1
    fi
    # For the log only: the RepoDigests entry of this repository.
    digest=unknown
    while IFS= read -r d; do
      case $d in "$repo"@sha256:*) digest=${d#"$repo"@}; break ;; esac
    done < <(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$remote" 2>/dev/null || true)
    docker tag "$remote" "$local_tag"
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
    DOCKER_CONFIG=$cfg docker buildx version >/dev/null 2>&1 \
      || die "publish needs the runner's docker buildx CLI plugin (v5, above)"
    if registry_digest "$remote" >/dev/null; then
      echo "ci-image-cache: the registry holds $remote; nothing to publish"
      exit 0
    fi
    # The Makefile names the Dockerfile; the make args reach it as they did.
    # shellcheck disable=SC2016 # $(DOCKERFILE) is make's, expanded by make
    dockerfile=$(make -s --no-print-directory --eval 'ci-image-cache-dockerfile: ; @echo $(DOCKERFILE)' \
      ci-image-cache-dockerfile "$@") || die "make could not name the Dockerfile"
    [ -f "$dockerfile" ] || die "the Makefile's Dockerfile '$dockerfile' is not a file"
    printf '%s' "$RELEASE_REGISTRY_TOKEN" | DOCKER_CONFIG=$cfg docker login "$host" -u "$RELEASE_REGISTRY_USER" --password-stdin >/dev/null
    # The build pushes its own result: no local tag is resolved between the
    # build and the push (v5, above).
    DOCKER_CONFIG=$cfg docker buildx build --no-cache --provenance=false --sbom=false \
      --target toolchain -f "$dockerfile" --metadata-file "$cfg/build.json" \
      --output "type=registry,name=$remote" . \
      || die "the build and push of $remote failed"
    built=$(jq -er '."containerimage.digest" | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' "$cfg/build.json" 2>/dev/null) \
      || die "the build recorded no image digest for $remote"
    got=$(registry_digest "$remote") || die "the registry gave no digest for $remote after the push"
    [ "$got" = "$built" ] \
      || die "the registry's $remote is $got, not the image this run built ($built)"
    docker image rm "$remote" >/dev/null 2>&1 || true   # the build's local name, if its driver kept one
    echo "ci-image-cache: published $local_tag as $repo@$built"
    ;;
  *)
    die "usage: ci-image-cache.sh pull | publish [make args]"
    ;;
esac
