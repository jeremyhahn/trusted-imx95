#!/usr/bin/env bash
# ci-image-cache.sh publish: an image reaches the registry only after
# ci-image-history.sh and trivy passed on its ID, and the pushed manifest's
# config digest must be that ID (#159, Codex security P1 from verify 16).
# docker, make, ci-image-history.sh and in-toolchain-image.sh (which runs
# trivy) are stubs that log each call to $d/log.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CFG='{"architecture":"amd64","os":"linux"}'
ID=sha256:$(printf '%s' "$CFG" | sha256sum | cut -c1-64)
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
save)
  while [ $# -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done
  t=$(mktemp -d); mkdir -p "$t/blobs/sha256"
  printf '%s' "${SAVE_CFG:-$CFG}" > "$t/blobs/sha256/cfg"
  printf '[{"Config":"blobs/sha256/cfg"}]' > "$t/manifest.json"
  tar -C "$t" -cf "$out" manifest.json blobs; rm -rf "$t" ;;
tag|push) exit 1 ;;
esac
exit 0
EOF
# The pinned registry client: a stub crane in a tarball the stub curl serves.
mkdir -p "$d/cranepkg"
cat > "$d/cranepkg/crane" <<'EOF'
#!/bin/sh
echo "crane $*" >> "$STUB_DIR/log"
[ "$1" = push ] || exit 2
[ "${PUSH_RC:-0}" = 0 ] || exit 1
tar -tf "$2" manifest.json > /dev/null || exit 1
echo "crane-read-archive" >> "$STUB_DIR/log"
: > "$STUB_DIR/pushed"
EOF
chmod +x "$d/cranepkg/crane"
tar -czf "$d/crane.tgz" -C "$d/cranepkg" crane
cat > "$d/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$STUB_DIR/log"
while [ $# -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done
if [ "${CURL_CORRUPT:-0}" = 1 ]; then echo tampered > "$out"; else cp "$STUB_DIR/crane.tgz" "$out"; fi
EOF
# The copy under test pins the stub tarball; the real pin is asserted below.
sed -i "s/crane_sha256=[0-9a-f]*\$/crane_sha256=$(sha256sum "$d/crane.tgz" | cut -c1-64)/" "$d/repo/scripts/ci-image-cache.sh"
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
	(cd "$d/repo" && env "PATH=$d/bin:$PATH" STUB_DIR="$d" BUILT_ID="$ID" PUSHED_CONFIG="$ID" CFG="$CFG" \
		GITHUB_SERVER_URL=https://forge.example CI_IMAGE_NAMESPACE=ns GITHUB_EVENT_NAME=push \
		GITHUB_REF=refs/heads/main RELEASE_REGISTRY_USER=u RELEASE_REGISTRY_TOKEN=fake-token \
		HOME="$d" "$@" bash scripts/ci-image-cache.sh publish)
}
logged() { grep -qE "$1" "$d/log"; }
nolog() { ! grep -qE "$1" "$d/log"; }

NOPUSH='^docker (push|tag|login)|^crane|^curl'
run pub HIST_RC=1
check "publish: a history finding fails" 1 "history check refused"
expect "publish: a history finding makes no push, login or upload call" nolog "$NOPUSH"
expect "publish: a history finding does not reach trivy" nolog '^trivy-in-image'

run pub TRIVY_RC=1
check "publish: a trivy finding fails" 1 "trivy refused"
expect "publish: a trivy finding makes no push, login or upload call" nolog "$NOPUSH"
expect "publish: trivy ran after the history check" logged '^history '

run pub
check "publish: a clean image is published" 0 "checked before the push"
expect "publish: no docker tag or docker push call at all" nolog '^docker (tag|push) '
expect "publish: the client uploads the job's archive, to a staging tag" \
	logged '^crane push [^ ]*/\.ci-image-publish\.[^/ ]+/image\.tar forge.example/ns/repo-toolchain:stage-[0-9]+-[0-9a-f]{16}$'
expect "publish: the upload read the archive" logged '^crane-read-archive'
expect "publish: the client is fetched from its pinned version" \
	logged '^curl .*/releases/download/v0\.22\.1/go-containerregistry_Linux_x86_64\.tar\.gz'
expect "publish: no upload or tag names the trusted tag" nolog '^(docker (tag|push)|crane push) .*:abc-main'
expect "publish: the trusted tag is promoted by the staging manifest digest" \
	logged '^docker buildx imagetools create --tag forge.example/ns/repo-toolchain:abc-main forge.example/ns/repo-toolchain@sha256:0{63}1$'
expect "publish: the checks name the built image ID" logged "^history $ID"
expect "publish: trivy reads the archive, not the daemon" logged '^trivy-in-image .* trivy image --input [^ ]*/image\.tar '
expect "publish: the real script pins crane's version and SHA-256" \
	grep -q 'crane_sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0$' "$ROOT/scripts/ci-image-cache.sh"
if [[ "$OUT" == *fake-token* ]]; then fail "publish: prints no credential" "$OUT"; else pass "publish: prints no credential"; fi

run pub PUSHED_CONFIG="$OTHER"
check "publish: a pushed config digest that is not the checked ID fails" 1 \
	"not the checked image $ID" "nothing was published under forge.example/ns/repo-toolchain:abc-main"
expect "publish: a mismatched registry config never reaches the trusted tag (no create call)" nolog 'imagetools create'

run pub SAVE_CFG='{"os":"swapped"}'
check "publish: an archive whose config is not the checked ID fails" 1 \
	"not the checked image $ID" "nothing was published under forge.example/ns/repo-toolchain:abc-main"
expect "publish: that archive is neither scanned nor uploaded, and no login happens" nolog '^(crane|curl|docker login|trivy-in-image)'

run pub CURL_CORRUPT=1
check "publish: a client download that is not the pinned one fails closed" 1 "not the pinned one"
expect "publish: with a pin mismatch, no client runs and no login happens" nolog '^(crane|docker login)'
expect "publish: with a pin mismatch, nothing is promoted" nolog 'imagetools create'

run pub CREATE_RC=1
check "publish: a failed promotion fails, saying nothing was published" 1 "nothing was published under"

run pub
if grep -qE 'type=registry|--push' "$d/log"; then
	fail "publish: no build call carries type=registry or --push" "$(cat "$d/log")"
else
	pass "publish: no build call carries type=registry or --push"
fi
expect "publish: the build loads the image" logged '^docker buildx build .*--load '
# Order: the build, history and trivy all come before the login and the upload.
order=$(grep -nE '^(docker buildx build|history|trivy-in-image|docker login|crane push)' "$d/log" | cut -d' ' -f1-2 | sed 's/^[0-9]*://' | tr '\n' ',')
expect "publish: build, history, trivy, then login, upload" \
	test "$order" = "docker buildx,history $ID,trivy-in-image $ID,docker login,crane push,"

run pub IMG_NO_BUILDX=1 BUILT_ID=garbage
check "publish: a build with no image ID pushes nothing" 1 "recorded no image ID"
expect "publish: a build with no image ID makes no push or upload call" nolog "$NOPUSH"

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
check "publish: an upload failure fails" 1 "the upload of"
expect "publish: removes the built image after an upload failure" logged "$rmid"
run pub PUSHED_CONFIG="$OTHER"
expect "publish: removes the built image after a config-digest mismatch" logged "$rmid"
run pub
expect "publish: removes the built image after success" logged "$rmid"
expect "publish: the daemon never holds a staging tag, so none is removed" nolog '^docker image rm .*:stage-'
expect "publish: never removes the trusted tag from the daemon" nolog '^docker image rm .*:abc-main'
run pub IMG_NO_BUILDX=1 BUILT_ID=garbage
expect "publish: no image rm when the build gave no ID" nolog '^docker image rm'

finish
