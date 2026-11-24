#!/usr/bin/env bash
# Remove this repo's stale CI leftovers on the runner host: scripts/reap-stale-ci-stacks.sh <prefix> [min-age-seconds] (default 11100).
# Removes compose projects and containers under <prefix> whose containers are all exited or never started for min-age, then unused <prefix>it images, dangling labelled images and old <repo>-toolchain tags older than REAP_IMAGE_MIN_AGE (7200), under the image lock.
# An image any container uses is kept; a failed removal is reported and skipped; REAP_DRY_RUN=1 only prints.
set -u

prefix=${1:-}
min_age=${2:-11100}
case $prefix in
  '' | *[!A-Za-z0-9_.-]*) echo "usage: $0 <prefix [A-Za-z0-9_.-]> [min-age-seconds]" >&2; exit 2 ;;
esac
case $min_age in
  '' | *[!0-9]*) echo "min-age-seconds must be a number: $min_age" >&2; exit 2 ;;
esac
image_min_age=${REAP_IMAGE_MIN_AGE:-7200}
case $image_min_age in
  '' | *[!0-9]*) echo "REAP_IMAGE_MIN_AGE must be a number: $image_min_age" >&2; exit 2 ;;
esac

lock_wait=${REAP_LOCK_WAIT:-60}
case $lock_wait in
  '' | *[!0-9]*) echo "REAP_LOCK_WAIT must be a number: $lock_wait" >&2; exit 2 ;;
esac

now=$(date +%s)

# run <command...>: the command, or only its echo under REAP_DRY_RUN=1.
run() {
  if [ "${REAP_DRY_RUN:-0}" = 1 ]; then echo "dry   $*"; else "$@" >/dev/null; fi
}

# stale <container>: 0 when the container is stale (as above), 1 otherwise.
stale() {
  local state finished created t
  read -r state finished created < <(docker inspect -f '{{.State.Status}} {{.State.FinishedAt}} {{.Created}}' "$1" 2>/dev/null) || return 1
  case $state in
    exited | dead) t=$finished ;;
    created) t=$created ;;
    *) return 1 ;;
  esac
  t=$(date -d "$t" +%s 2>/dev/null) || return 1
  [ $((now - t)) -ge "$min_age" ]
}

# image_lock: take the daemon's image lock (v5, above), waiting up to
# REAP_LOCK_WAIT seconds; 1 when it is not taken. image_unlock drops it.
lock="${prefix}image-lock"
lock_id=
image_lock() {
  local base="$lock:base" held at t i
  for ((i = 0; i < lock_wait; i++)); do
    docker image inspect "$base" >/dev/null 2>&1 ||
      head -c 1024 /dev/zero | docker import - "$base" >/dev/null 2>&1
    lock_id=$(docker create --pull never --name "$lock" "$base" true 2>/dev/null) && return 0
    lock_id=
    if read -r held at < <(docker inspect -f '{{.Id}} {{.Created}}' "$lock" 2>/dev/null) &&
      t=$(date -d "$at" +%s 2>/dev/null) && [ $(($(date +%s) - t)) -ge 600 ]; then
      echo "lock  removing the stale $lock (created $at)"
      docker rm "$held" >/dev/null 2>&1
      continue
    fi
    sleep 1
  done
  return 1
}
image_unlock() {
  [ -z "$lock_id" ] || docker rm "$lock_id" >/dev/null 2>&1
  lock_id=
}
trap image_unlock EXIT

reaped=0

# Compose projects.
for project in $(docker ps -a --filter label=com.docker.compose.project \
    --format '{{.Label "com.docker.compose.project"}}' | sort -u); do
  case $project in "$prefix"*) ;; *) continue ;; esac
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
  keep=0
  for id in $ids; do stale "$id" || { keep=1; break; }; done
  if [ "$keep" = 1 ]; then
    echo "keep  $project (a container is live or stopped within ${min_age}s)"
    continue
  fi
  # shellcheck disable=SC2086 # one id per word
  set -- $ids
  echo "reap  $project: $# container(s)"
  run docker rm -v "$@" || echo "warn  $project: container removal failed"
  for net in $(docker network ls -q --filter "label=com.docker.compose.project=$project"); do
    run docker network rm "$net" || echo "warn  $project: network $net not removed"
  done
  for vol in $(docker volume ls -q --filter "label=com.docker.compose.project=$project"); do
    run docker volume rm "$vol" || echo "warn  $project: volume $vol not removed"
  done
  reaped=$((reaped + 1))
done

# Containers outside compose.
docker ps -a --filter "name=^$prefix" \
    --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}' |
  while read -r id name project; do
    [ -z "$project" ] || continue
    case $name in "$prefix"*) ;; *) continue ;; esac
    if stale "$id"; then
      echo "reap  container $name"
      run docker rm -v "$id" || echo "warn  container $name not removed"
    fi
  done

# Content-addressed integration images (v2, above) and toolchain images (v7),
# under the image lock (v5).
images=0
refs=
dangling=
it_repo="${prefix}it"
tc_repo=
tc_current=
sw_repo=
sw_current=
case $prefix in
  ?*-ci-)
    tc_repo="${prefix%-ci-}-toolchain"
    tc_current=$("$(dirname "$0")/image-tag.sh" toolchain "${prefix%-ci-}" 2>/dev/null) || tc_current=
    # v8: the secure-world image family (Makefile docker-build-sw) is reaped
    # the same way: dangling ids by label, old tags but the current tree's.
    sw_repo="${prefix%-ci-}-secure-world"
    sw_current=$("$(dirname "$0")/image-tag.sh" secure-world "${prefix%-ci-}" 2>/dev/null) || sw_current=
    ;;
esac
if [ "${REAP_DRY_RUN:-0}" = 1 ] || image_lock; then
  for repo in $it_repo $tc_repo $sw_repo; do
    refs="$refs $(docker images --filter "reference=$repo" --format '{{.Repository}}:{{.Tag}}')"
    dangling="$dangling $(docker images -q --no-trunc --filter dangling=true --filter "label=ci.reap.repository=$repo")"
  done
else
  echo "keep  every $it_repo${tc_repo:+, $tc_repo}${sw_repo:+ and $sw_repo} image (the image lock was not free within ${lock_wait}s)"
fi
for ref in $refs; do
  case $ref in
    "$it_repo:"*) ;;
    "$tc_repo:"*)
      [ -n "$tc_repo" ] || continue
      if [ -z "$tc_current" ]; then
        echo "keep  image $ref (the current toolchain tag could not be computed)"
        continue
      fi
      if [ "$ref" = "$tc_current" ]; then
        echo "keep  image $ref (the current toolchain tag)"
        continue
      fi
      ;;
    "$sw_repo:"*)
      [ -n "$sw_repo" ] || continue
      if [ -z "$sw_current" ]; then
        echo "keep  image $ref (the current secure-world tag could not be computed)"
        continue
      fi
      if [ "$ref" = "$sw_current" ]; then
        echo "keep  image $ref (the current secure-world tag)"
        continue
      fi
      ;;
    *) continue ;;
  esac
  id='' created=''
  read -r id created < <(docker image inspect -f '{{.Id}} {{.Created}}' "$ref" 2>/dev/null)
  if [ -z "$id" ] || [ -z "$created" ]; then
    echo "keep  image $ref (docker image inspect gave no id)"
    continue
  fi
  t=$(date -d "$created" +%s 2>/dev/null) || continue
  # date -d takes the tag time without its fraction and zone name; a never-tagged image reports a large negative time.
  tagged=$(docker image inspect -f '{{.Metadata.LastTagTime}}' "$ref" 2>/dev/null | sed -E 's/\.[0-9]+//; s/ [A-Z]+$//')
  tagged=$(date -d "$tagged" +%s 2>/dev/null) || tagged=
  case $tagged in ''|*[!0-9]*) ;; *) [ "$tagged" -le "$t" ] || t=$tagged ;; esac
  if [ $((now - t)) -lt "$image_min_age" ]; then
    echo "keep  image $ref (created or tagged within ${image_min_age}s)"
    continue
  fi
  # v4: a container on the id (a lease or a stack) keeps every tag of it.
  if ! users=$(docker ps -a -q --filter "ancestor=$id" 2>/dev/null); then
    echo "keep  image $ref (could not list the containers on $id)"
    continue
  fi
  if [ -n "$users" ]; then
    echo "keep  image $ref (in use: $(echo "$users" | wc -l) container(s) on $id)"
    continue
  fi
  echo "reap  image $ref"
  if run docker image rm "$ref"; then images=$((images + 1)); else echo "warn  image $ref not removed (in use?)"; fi
done
# v6, v7: the dangling images a rebuild left behind, by id, under the same lock.
for id in $dangling; do
  case $id in sha256:*) ;; *) continue ;; esac
  created=$(docker image inspect -f '{{.Created}}' "$id" 2>/dev/null) || created=
  t=$(date -d "$created" +%s 2>/dev/null) || {
    echo "keep  dangling image $id (docker image inspect gave no creation time)"
    continue
  }
  if [ $((now - t)) -lt "$image_min_age" ]; then
    echo "keep  dangling image $id (created within ${image_min_age}s)"
    continue
  fi
  if ! users=$(docker ps -a -q --filter "ancestor=$id" 2>/dev/null); then
    echo "keep  dangling image $id (could not list the containers on it)"
    continue
  fi
  if [ -n "$users" ]; then
    echo "keep  dangling image $id (in use: $(echo "$users" | wc -l) container(s))"
    continue
  fi
  echo "reap  dangling image $id (labelled ci.reap.repository=$it_repo${tc_repo:+ or $tc_repo}${sw_repo:+ or $sw_repo})"
  if run docker image rm "$id"; then images=$((images + 1)); else echo "warn  dangling image $id not removed (in use?)"; fi
done
image_unlock

if [ "${REAP_DRY_RUN:-0}" = 1 ]; then done_as="would be removed"; else done_as=removed; fi
echo "reaper: $reaped compose project(s) and $images image(s) $done_as for prefix '$prefix'"
exit 0
