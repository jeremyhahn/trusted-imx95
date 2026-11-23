#!/usr/bin/env python3
"""Tests for ci-image-history.sh (Tenant Agent rulings 888, 899 and 901).

A pool build takes the LAN caches as BuildKit secrets, which no layer and no
history entry keeps; a build argument's value is recorded in every RUN of the
image history. (This copy differs from the template's in its publish
fixtures only, adapted to this repository's ci-image-cache.sh; see #159.)
ci-image-history.sh reads each image's history and config and
fails on any RFC 1918 address, naming the image and the entry, never the
address. A stub docker on PATH stands in for the daemon.

  python3 -I software/templates/github-actions/testdata/ci-image-history-tests.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "ci-image-history.sh")

# The stub answers `docker history` with $STUB_DIR/<n>.history and `docker
# image inspect` with $STUB_DIR/<n>.config, n being the image name with ":"
# and "/" turned to "_"; a missing file is a docker failure.
STUB = """#!/bin/sh
for a; do image=$a; done
n=$(printf '%s' "$image" | tr ':/' '__')
case "$1 $2" in
"history --no-trunc") f="$STUB_DIR/$n.history" ;;
"image inspect") f="$STUB_DIR/$n.config" ;;
*) echo "stub docker: unexpected $*" >&2; exit 99 ;;
esac
[ -f "$f" ] || { echo "Error: No such image: $image" >&2; exit 1; }
cat "$f"
"""

CLEAN_HISTORY = "\n".join([
    "RUN |0 /bin/sh -c apk-mirror add --no-cache git # buildkit",
    "RUN /bin/sh -c go install golang.org/x/tools@v0.30.1 # go1.27.4, libfoo 1.10.2.3",
    "ENV PATH=/usr/local/go/bin:/usr/bin",
    "ADD alpine-minirootfs-3.22.1-x86_64.tar.gz / # buildkit",
])
CLEAN_CONFIG = '{"Env":["PATH=/usr/bin","LISTEN=127.0.0.1:8080","PEER=172.32.0.5"],"Labels":{"v":"10.2"}}'
ADDRESSES = ["192.168.", "10.20.30.40", "10.0.0.7", "172.20.0.5"]

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def run(files, *images):
    with tempfile.TemporaryDirectory() as stub:
        path = os.path.join(stub, "docker")
        with open(path, "w") as f:
            f.write(STUB)
        os.chmod(path, 0o700)
        for name, body in files.items():
            with open(os.path.join(stub, name), "w") as f:
                f.write(body + "\n")
        env = {"PATH": stub + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"), "STUB_DIR": stub}
        out = subprocess.run(["bash", SCRIPT, *images], env=env, capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr


def image(history, config):
    return {"a_1.history": history, "a_1.config": config}


# ---- ci.yml v1.45 and ci-image-cache.sh v4 (ruling 901) ----------------------
# Every pool-routable job that builds an image checks the images it will use,
# after its last build step and before its first use, on a pool runner; and
# publish (ci-image-cache.sh, the release runner) checks the toolchain image
# before it logs in and pushes it beyond the LAN.

CI = os.path.join(os.path.dirname(HERE), "ci.yml")
CACHE = os.path.join(os.path.dirname(HERE), "ci-image-cache.sh")
CHECK = "scripts/ci-image-history.sh"
POOL_ONLY = "runner.environment != 'github-hosted'"
# The images each job uses: the toolchain image the build step exports, the
# integration image the lease step exports.
IMAGE_JOBS = {
    "lint": ["$TOOLCHAIN_IMAGE"],
    "lint-gates": ["$TOOLCHAIN_IMAGE"],
    "image": ["$TOOLCHAIN_IMAGE", "$IT_LEASE_ID"],
    "integration": ["$IT_LEASE_ID"],
    "soak": ["$IT_LEASE_ID"],
}


def steps_of(text):
    """{job: [(if, run)]} from the template's ci.yml, steps in order."""
    import yaml
    out = {}
    for name, job in (yaml.safe_load(text).get("jobs") or {}).items():
        out[name] = [(str(st.get("if") or ""), st.get("run") or "") for st in job.get("steps") or []]
    return out


def is_build(run):
    return "docker-build" in run or "ci-image-cache.sh" in run


def is_use(run):
    return "in-toolchain-image.sh" in run or 'IT_IMAGE="$IT_IMAGE"' in run


def wiring_problems(text):
    probs = []
    jobs = steps_of(text)
    for job, images in IMAGE_JOBS.items():
        steps = jobs.get(job)
        if steps is None:
            probs.append(f"ci.yml has no {job} job")
            continue
        at = [i for i, (_, r) in enumerate(steps) if CHECK in r]
        if not at:
            probs.append(f"{job} never runs {CHECK}")
            continue
        c = at[0]
        cond, run = steps[c]
        last_build = max((i for i, (_, r) in enumerate(steps) if is_build(r)), default=-1)
        first_use = min((i for i, (_, r) in enumerate(steps) if is_use(r) and not is_build(r)), default=len(steps))
        if not last_build < c < first_use:
            probs.append(f"{job}: the image check is not after the last build and before the first use")
        if POOL_ONLY not in cond:
            probs.append(f"{job}: the image check runs under {cond!r}, not on pool runners alone")
        for img in images:
            if f'"{img}"' not in run:
                probs.append(f"{job}: the image check does not read {img}")
    return probs


def wiring_cases():
    text = open(CI).read()
    for p in wiring_problems(text):
        failures.append(p)
    lines = text.split("\n")
    # A job that loses its check, or checks after a use, is caught.
    gone = text.replace(f"        run: {CHECK} \"$TOOLCHAIN_IMAGE\"\n", "        run: echo gone\n", 1)
    check(gone != text and wiring_problems(gone), "removing an image check passes the template check")
    late = text.replace('scripts/in-toolchain-image.sh "$TOOLCHAIN_IMAGE" "make lint ', f'{CHECK} "$TOOLCHAIN_IMAGE"; scripts/in-toolchain-image.sh "$TOOLCHAIN_IMAGE" "make lint ', 1)
    late = late.replace(f"        run: {CHECK} \"$TOOLCHAIN_IMAGE\"\n", "        run: echo moved\n", 1)
    check(late != text and wiring_problems(late), "an image check after the first use passes the template check")


# Adapted by this repository (#159); the rest of this file is the template's,
# unchanged. The template's publish fixtures stub its older publish path
# (docker save, a manifest probe, a history check before the push). The
# retained ci-image-cache.sh v5 publishes with `docker buildx build --output
# type=registry`, reads the registry's digest through `docker buildx imagetools
# inspect`, takes the Dockerfile's path from `make`, and runs no history check
# of its own, so these fixtures stub that path: make prints the toolchain tag
# and a Dockerfile path; docker logs each call to $STUB_DIR/log, answers a
# digest probe with a miss until the build has run, and writes the build's
# metadata file; $REG_DIGEST_AFTER is the digest the registry then reports.
CACHE_MAKE = """#!/bin/sh
case "$*" in
*ci-image-cache-dockerfile*) echo Dockerfile; exit 0 ;;
*toolchain-image*) echo repo-toolchain:abc; exit 0 ;;
esac
echo "make $*" >> "$STUB_DIR/log"
"""
GOOD = "sha256:" + "a" * 64
OTHER = "sha256:" + "b" * 64
CACHE_DOCKER = """#!/bin/sh
echo "docker $*" >> "$STUB_DIR/log"
if [ "$1 $2 $3" = "buildx imagetools inspect" ]; then
  [ -f "$STUB_DIR/built" ] || [ -f "$STUB_DIR/held" ] || exit 1
  printf '{"digest":"%s"}\\n' "$REG_DIGEST_AFTER"
  exit 0
fi
case $1 in
login) cat >/dev/null ;;
buildx)
  if [ "$2" = build ]; then
    while [ $# -gt 1 ]; do
      [ "$1" = --metadata-file ] && printf '{"containerimage.digest":"%s"}\\n' "$BUILT_DIGEST" > "$2"
      shift
    done
    : > "$STUB_DIR/built"
  fi ;;
esac
exit 0
"""


def publish_run(held=False, registry_after=GOOD):
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "repo", "scripts"))
        os.makedirs(os.path.join(d, "bin"))
        shutil.copy(CACHE, os.path.join(d, "repo", "scripts", "ci-image-cache.sh"))
        with open(os.path.join(d, "repo", "Dockerfile"), "w") as f:
            f.write("FROM scratch\n")
        if held:
            open(os.path.join(d, "held"), "w").close()
        for path, body in [
            (os.path.join(d, "bin", "make"), CACHE_MAKE),
            (os.path.join(d, "bin", "docker"), CACHE_DOCKER),
        ]:
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        env = {"PATH": os.path.join(d, "bin") + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"), "STUB_DIR": d,
               "BUILT_DIGEST": GOOD, "REG_DIGEST_AFTER": registry_after, "GITHUB_SERVER_URL": "https://forge.example",
               "CI_IMAGE_NAMESPACE": "ns", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
               "RELEASE_REGISTRY_USER": "u", "RELEASE_REGISTRY_TOKEN": "t", "HOME": d}
        out = subprocess.run(["bash", "scripts/ci-image-cache.sh", "publish"], cwd=os.path.join(d, "repo"), env=env, capture_output=True, text=True)
        log = open(os.path.join(d, "log")).read().splitlines() if os.path.exists(os.path.join(d, "log")) else []
        return out.returncode, log, out.stderr + out.stdout


def publish_cases():
    # #159 (verify 16): publish loads, checks, then pushes; the behaviour is
    # held by test/ci_publish_test.sh with stubs. Here: the script's order.
    src = open(CACHE).read()
    body = src.split("  publish)", 1)[1]
    code = "\n".join(l for l in body.split("\n") if not l.lstrip().startswith("#"))
    check("type=registry" not in code and "--push" not in code, "publish builds with type=registry or --push")
    check("docker push" not in code and "docker tag" not in code,
          "publish calls docker push or docker tag (a daemon tag can be retagged)")
    hist, trivy = code.find("ci-image-history.sh"), code.find("trivy image")
    upload, promote = code.find('"$crane" push'), code.find("imagetools create")
    check(0 < hist < trivy < upload < promote,
          "publish does not run history, trivy, the crane upload, then the digest promotion in order")


def main():
    if not os.path.exists(SCRIPT):
        print("FAIL: no ci-image-history.sh beside the template")
        return 1
    rc, out = run(image(CLEAN_HISTORY, CLEAN_CONFIG), "a:1")
    check(rc == 0, f"a clean image fails ({rc}): {out}")
    for name, history, config, want in [
        ("an apk mirror build argument", "RUN |1 APK_MIRROR=http://192.168.77.7:3143/alpine /bin/sh -c apk-mirror add git", CLEAN_CONFIG, "history entry 1"),
        ("an apt proxy in a later entry", CLEAN_HISTORY + "\nRUN |1 APT_PROXY=http://10.20.30.40:3142 /bin/sh -c apt-get update", CLEAN_CONFIG, "history entry 5"),
        ("a 172.16/12 address", "ENV REG=172.20.0.5:5005", CLEAN_CONFIG, "history entry 1"),
        ("an address at the start of an entry", "192.168.254.254", CLEAN_CONFIG, "history entry 1"),
        ("an address in the config", CLEAN_HISTORY, '{"Env":["GOPROXY=http://10.0.0.7:3000|https://proxy.golang.org"]}', "config"),
        ("an address in a label", CLEAN_HISTORY, '{"Labels":{"cache":"192.168.77.7"}}', "config"),
    ]:
        rc, out = run(image(history, config), "a:1")
        check(rc != 0, f"{name}: the image passes: {out}")
        check("a:1" in out and want in out, f"{name}: the failure does not name the image and {want!r}: {out}")
        for addr in ADDRESSES:
            check(addr not in out, f"{name}: the failure prints the address {addr}: {out}")
    two = dict(image(CLEAN_HISTORY, CLEAN_CONFIG))
    two.update({"b_2.history": "RUN |1 APK_MIRROR=http://192.168.77.7:3143/alpine x", "b_2.config": CLEAN_CONFIG})
    rc, out = run(two, "a:1", "b:2")
    check(rc != 0 and "b:2" in out, f"a private address in the second image passes ({rc}): {out}")
    rc, out = run(image(CLEAN_HISTORY, CLEAN_CONFIG), "a:1", "missing:1")
    check(rc != 0 and "missing:1" in out, f"an image docker cannot read passes ({rc}): {out}")
    rc, out = run(image(CLEAN_HISTORY, CLEAN_CONFIG))
    check(rc != 0 and "usage" in out, f"no image passes ({rc}): {out}")
    wiring_cases()
    publish_cases()
    for f in failures:
        print("FAIL:", f)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
