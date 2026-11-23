#!/usr/bin/env bash
# ci-image-cache.sh publish: an image reaches the registry only after
# ci-image-history.sh and trivy passed on its ID, and the pushed manifest's
# config digest must be that ID (#159, Codex security P1 from verify 16).
# docker, make, ci-image-history.sh and in-toolchain-image.sh (which runs
# trivy) are stubs that log each call to $d/log.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ID=sha256:$(printf 'c%.0s' $(seq 64))
OTHER=sha256:$(printf 'd%.0s' $(seq 64))

d="$TMP_ROOT/pub"
mkdir -p "$d/repo/scripts" "$d/bin"
cp "$ROOT/scripts/ci-image-cache.sh" "$d/repo/scripts/"
echo 'FROM scratch' > "$d/repo/Dockerfile"

cat > "$d/bin/make" <<'EOF'
#!/bin/sh
case "$*" in
*ci-image-cache-dockerfile*) echo Dockerfile ;;
*toolchain-image*) echo repo-toolchain:abc ;;
esac
EOF
cat > "$d/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$STUB_DIR/log"
case "$1 $2 $3" in
"buildx version "*) exit 0 ;;
"buildx imagetools inspect")
  [ -f "$STUB_DIR/pushed" ] || exit 1
  case "$*" in
  *--raw*) printf '{"config":{"digest":"%s"}}\n' "$PUSHED_CONFIG" ;;
  *) printf '{"digest":"sha256:%064d"}\n' 1 ;;
  esac
  exit 0 ;;
"buildx imagetools create") exit "${CREATE_RC:-0}" ;;
esac
case $1 in
login) cat > /dev/null; exit "${LOGIN_RC:-0}" ;;
buildx)
  while [ $# -gt 1 ]; do
    [ "$1" = --iidfile ] && printf '%s' "$BUILT_ID" > "$2"
    shift
  done ;;
save) while [ $# -gt 1 ]; do [ "$1" = -o ] && : > "$2"; shift; done ;;
push) [ "${PUSH_RC:-0}" = 0 ] || exit 1; : > "$STUB_DIR/pushed" ;;
esac
exit 0
EOF
cat > "$d/repo/scripts/ci-image-history.sh" <<'EOF'
#!/bin/sh
echo "history $*" >> "$STUB_DIR/log"
exit "${HIST_RC:-0}"
EOF
cat > "$d/repo/scripts/in-toolchain-image.sh" <<'EOF'
#!/bin/sh
echo "trivy-in-image $*" >> "$STUB_DIR/log"
exit "${TRIVY_RC:-0}"
EOF
chmod +x "$d/bin/"* "$d/repo/scripts/"*

pub() { # pub [VAR=value...]: one publish run in a clean stub state
	rm -f "$d/log" "$d/pushed"
	: > "$d/log"
	(cd "$d/repo" && env "PATH=$d/bin:$PATH" STUB_DIR="$d" BUILT_ID="$ID" PUSHED_CONFIG="$ID" \
		GITHUB_SERVER_URL=https://forge.example CI_IMAGE_NAMESPACE=ns GITHUB_EVENT_NAME=push \
		GITHUB_REF=refs/heads/main RELEASE_REGISTRY_USER=u RELEASE_REGISTRY_TOKEN=fake-token \
		HOME="$d" "$@" bash scripts/ci-image-cache.sh publish)
}
logged() { grep -qE "$1" "$d/log"; }
nolog() { ! grep -qE "$1" "$d/log"; }

run pub HIST_RC=1
check "publish: a history finding fails" 1 "history check refused"
expect "publish: a history finding makes no push call" nolog '^docker (push|tag|login)'
expect "publish: a history finding does not reach trivy" nolog '^trivy-in-image'

run pub TRIVY_RC=1
check "publish: a trivy finding fails" 1 "trivy refused"
expect "publish: a trivy finding makes no push call" nolog '^docker (push|tag|login)'
expect "publish: trivy ran after the history check" logged '^history '

run pub
check "publish: a clean image is pushed" 0 "checked before the push"
expect "publish: the push happened, under a staging tag" logged '^docker push forge.example/ns/repo-toolchain:stage-[0-9]+-[0-9a-f]{16}$'
expect "publish: no docker tag or push names the trusted tag" nolog '^docker (tag|push) .*:abc-main'
expect "publish: the trusted tag is promoted by the staging manifest digest" \
	logged '^docker buildx imagetools create --tag forge.example/ns/repo-toolchain:abc-main forge.example/ns/repo-toolchain@sha256:0{63}1$'
expect "publish: the checks name the built image ID" logged "^history $ID"
if [[ "$OUT" == *fake-token* ]]; then fail "publish: prints no credential" "$OUT"; else pass "publish: prints no credential"; fi

run pub PUSHED_CONFIG="$OTHER"
check "publish: a pushed config digest that is not the checked ID fails" 1 \
	"not the checked image $ID" "nothing was published under forge.example/ns/repo-toolchain:abc-main"
expect "publish: a swapped staging image never reaches the trusted tag (no create call)" nolog 'imagetools create'

run pub CREATE_RC=1
check "publish: a failed promotion fails, saying nothing was published" 1 "nothing was published under"

run pub
if grep -qE 'type=registry|--push' "$d/log"; then
	fail "publish: no build call carries type=registry or --push" "$(cat "$d/log")"
else
	pass "publish: no build call carries type=registry or --push"
fi
expect "publish: the build loads the image" logged '^docker buildx build .*--load '
# Order: the build, history and trivy all come before login, tag and push.
order=$(grep -nE '^(docker buildx build|history|trivy-in-image|docker login|docker tag|docker push)' "$d/log" | cut -d' ' -f1-2 | sed 's/^[0-9]*://' | tr '\n' ',')
expect "publish: build, history, trivy, then login, tag, push" \
	test "$order" = "docker buildx,history $ID,trivy-in-image $ID,docker login,docker tag,docker push,"

run pub IMG_NO_BUILDX=1 BUILT_ID=garbage
check "publish: a build with no image ID pushes nothing" 1 "recorded no image ID"
expect "publish: a build with no image ID makes no push call" nolog '^docker (push|tag|login)'

# The job removes the image it loaded, on every exit path (Codex finding on
# verify 17), and only when the build gave it an ID.
rmid='^docker image rm -f '"$ID"'$'
run pub HIST_RC=1
expect "publish: removes the built image after a history rejection" logged "$rmid"
run pub TRIVY_RC=1
expect "publish: removes the built image after a trivy rejection" logged "$rmid"
run pub LOGIN_RC=1
check "publish: a login failure fails" 1 "login for"
expect "publish: removes the built image after a login failure" logged "$rmid"
run pub PUSH_RC=1
check "publish: a push failure fails" 1 "the push of"
expect "publish: removes the built image after a push failure" logged "$rmid"
run pub PUSHED_CONFIG="$OTHER"
expect "publish: removes the built image after a config-digest mismatch" logged "$rmid"
run pub
expect "publish: removes the built image after success" logged "$rmid"
expect "publish: removes the staging tag after success" logged '^docker image rm -f forge.example/ns/repo-toolchain:stage-'
expect "publish: never removes the trusted tag from the daemon" nolog '^docker image rm .*:abc-main'
run pub IMG_NO_BUILDX=1 BUILT_ID=garbage
expect "publish: no image rm when the build gave no ID" nolog '^docker image rm'

finish
