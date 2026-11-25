# syntax=docker/dockerfile:1
#
# The project's one image (handbook devcontainer.md §1): `base`, then
# `toolchain` (every tool the Makefile uses) and `integration` (base plus the
# source only), both FROM base. `secure-world` is the same toolchain on a glibc
# base, for `make secure-world`. Every pin is in scripts/tool-pins.sh; the
# ALPINE_IMAGE and SW_IMAGE defaults below must equal its ALPINE_VERSION@
# ALPINE_DIGEST and SW_PYTHON_VERSION@SW_PYTHON_DIGEST, which `make build` checks.
#
# No vendor tool is in any stage: the NXP Code Signing Tool is read from
# CST_PATH at build time and never enters the image (docs/references/README.md
# §The Code Signing Tool in the build).

ARG ALPINE_IMAGE=alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
# The secure-world stage's glibc base (below). Must equal scripts/tool-pins.sh's
# SW_PYTHON_VERSION@SW_PYTHON_DIGEST, which `make build` checks.
ARG SW_IMAGE=python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72

FROM ${ALPINE_IMAGE} AS base
# coreutils: the scripts and tests use GNU date -d. safe.directory: the
# checkout a stage runs on may belong to another uid than the stage's.
# tar: GNU tar, for scripts/in-toolchain-image.sh's --owner/--group/
# --numeric-owner stream (BusyBox tar refuses those options).
RUN apk upgrade --no-cache \
 && apk add --no-cache bash coreutils make git python3 py3-yaml tar xz \
 && git config --system --add safe.directory '*' \
 && adduser -D -u 10001 dev
ENV HOME=/tmp
WORKDIR /src

# Build-only: fetches the pinned tools and checks their digests. Only the
# binaries leave it.
FROM base AS fetch
RUN apk add --no-cache curl
COPY scripts/tool-pins.sh scripts/fetch-tools.sh /pins/
RUN sh /pins/fetch-tools.sh /pins/tool-pins.sh /out/bin

# Build-only: the pinned imx-secure-enclave source, fetched by the commit in
# secure-key-handling/ele-lib.lock and checked against its archive SHA-256
# (fails closed). Only the unpacked source leaves it.
FROM base AS ele-src
COPY scripts/ele-lib-build.sh /ele/scripts/
COPY secure-key-handling/ele-lib.lock /ele/secure-key-handling/
COPY secure-world/bsp.lock /ele/secure-world/
RUN bash /ele/scripts/ele-lib-build.sh --work /tmp/ele-work --src-only \
 && mv /tmp/ele-work/src /ele-src

FROM base AS toolchain
# openssh-keygen: git's SSH signature verification (gpg.format ssh) runs
# ssh-keygen -Y, which test/ci_scripts_test.sh's signature fixtures need;
# Alpine's git package does not supply it. Like every package here, its
# version is the pinned Alpine release's.
# uv: scripts/secure-world-build.sh's hash-checked wheel install.
# xz, perl: scripts/sm-build.sh and scripts/secure-world-build.sh unpack .tar.xz;
# imx-sm's build requires perl. test/sm_build_test.sh runs it here.
# gcompat: the glibc loader and libc shims. Arm's pinned arm-none-eabi toolchain
# is built for glibc; this image is musl and has no /lib64/ld-linux-x86-64.so.2.
# build-base: a native C compiler (cc), musl-dev's libc headers and binutils, which
# test/hsd_a55_test.sh compiles the A55 host tests with (it fails without cc).
# Also for test/ele_client_test.sh (the secure-key-handling client's unit and backend tests are built on the host).
RUN apk add --no-cache curl jq ca-certificates openssh-keygen uv xz perl gcompat build-base
COPY --from=fetch /out/bin/ /usr/local/bin/
# The verified pinned secure-enclave source, for the backend tests (ELE_SRC).
COPY --from=ele-src /ele-src /opt/ele-src
ENV ELE_SRC=/opt/ele-src
# Where the pinned source is meant to exist, a missing one fails the test.
ENV REQUIRE_ELE_SRC=1
# SPSDK 3.13.0 for make ahab-sign-test (docs/boot-container/signing-pipeline.md):
# scripts/ahab/spsdk-venv.sh installs its closure, every file checked against a
# SHA-256 in scripts/ahab, into /opt/spsdk. CI stages run without network, so
# the venv is built here. py3-pip is a normal package and stays in the image: the
# runner-label bootstrap test (test/runner_labels_test.sh) runs `python3 -I -m pip`.
COPY scripts/ahab/spsdk-venv.sh scripts/ahab/requirements.txt scripts/ahab/build-requirements.txt /pins/ahab/
RUN apk add --no-cache py3-pip \
 && SPSDK_VENV=/opt/spsdk bash /pins/ahab/spsdk-venv.sh \
 && rm -rf /tmp/.cache /pins/ahab
ENV SPSDK_VENV=/opt/spsdk
USER 10001

FROM base AS integration
ARG APK_INDEX_SUM=none
RUN echo "apk index ${APK_INDEX_SUM}" >/dev/null && apk upgrade --no-cache
COPY --chown=10001:10001 . /src
USER 10001

# `make secure-world` (docs/secure-world/build.md): the same project image, on a
# glibc base. secure-world/bsp.lock pins CPython 3.13 wheels for x86_64 glibc
# (cryptography cp311-abi3-manylinux_2_28, cffi cp313-manylinux2014) and Arm's
# toolchain is glibc-hosted, so the Alpine (musl) toolchain stage cannot run it.
# Every pin is in scripts/tool-pins.sh (SW_*); the ARG defaults below must equal
# them, which `make build` checks. Debian packages come from a dated
# snapshot.debian.org archive, so the same Dockerfile resolves the same versions.
FROM ${SW_IMAGE} AS secure-world
ARG SW_DEBIAN_SNAPSHOT=20261122T000000Z
ARG SW_UV_VERSION=0.13.9
ARG SW_UV_SHA256=d7f459fe4fd247d830351c75686d3996ace3c6f3f728eb0e85a30b7ada0cef19
# git: the checkout's own tooling. curl, make, xz-utils: scripts/secure-world-build.sh
# unpacks the pinned .tar.xz sources and toolchain. GNU tar and coreutils come with
# the base; scripts/in-toolchain-image.sh needs GNU tar for its --owner stream.
RUN set -eu; \
    for s in debian:bookworm debian-security:bookworm-security; do \
      printf 'Types: deb\nURIs: https://snapshot.debian.org/archive/%s/%s/\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\n' \
        "${s%%:*}" "$SW_DEBIAN_SNAPSHOT" "${s##*:}"; \
    done > /etc/apt/sources.list.d/debian.sources; \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends git curl make xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    printf '%s\n' "uv==${SW_UV_VERSION} --hash=sha256:${SW_UV_SHA256}" > /tmp/uv-req.txt; \
    python -m pip install -q --no-cache-dir --require-hashes --only-binary :all: -r /tmp/uv-req.txt; \
    rm -f /tmp/uv-req.txt; \
    git config --system --add safe.directory '*'; \
    useradd --uid 10001 --no-create-home dev
# Fail the image build, not the job, when the interpreter cannot take the wheels
# the lock pins: CPython 3.13, x86_64, and glibc 2.28 or later.
RUN python -c 'import sys; assert sys.version_info[:2] == (3, 13), sys.version' \
 && python -m pip debug --verbose >/tmp/tags.txt 2>/dev/null \
 && for t in cp311-abi3-manylinux_2_28_x86_64 cp313-cp313-manylinux2014_x86_64 py3-none-any; do \
      grep -qxE "[[:space:]]*$t" /tmp/tags.txt || { echo "secure-world image: the interpreter does not accept $t" >&2; exit 1; }; \
    done \
 && rm -f /tmp/tags.txt
ENV HOME=/tmp
WORKDIR /src
USER 10001
