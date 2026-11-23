# syntax=docker/dockerfile:1
#
# The project's one image (handbook devcontainer.md §1): `base`, then
# `toolchain` (every tool the Makefile uses) and `integration` (base plus the
# source only), both FROM base. Every pin is in scripts/tool-pins.sh; the
# ALPINE_IMAGE default below must equal its ALPINE_VERSION@ALPINE_DIGEST,
# which `make build` checks.
#
# No vendor tool is in any stage: the NXP Code Signing Tool is read from
# CST_PATH at build time and never enters the image (docs/references/README.md
# §The Code Signing Tool in the build).

ARG ALPINE_IMAGE=alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

FROM ${ALPINE_IMAGE} AS base
# coreutils: the scripts and tests use GNU date -d. safe.directory: the
# checkout a stage runs on may belong to another uid than the stage's.
# tar: GNU tar, for scripts/in-toolchain-image.sh's --owner/--group/
# --numeric-owner stream (BusyBox tar refuses those options).
RUN apk upgrade --no-cache \
 && apk add --no-cache bash coreutils make git python3 tar xz \
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
# build-base: a host C compiler and libc headers, for test/ele_client_test.sh
# (the secure-key-handling client's unit and backend tests are built on the host).
RUN apk add --no-cache curl jq ca-certificates openssh-keygen uv xz perl gcompat build-base
COPY --from=fetch /out/bin/ /usr/local/bin/
# The verified pinned secure-enclave source, for the backend tests (ELE_SRC).
COPY --from=ele-src /ele-src /opt/ele-src
ENV ELE_SRC=/opt/ele-src
# SPSDK 3.13.0 for make ahab-sign-test (docs/boot-container/signing-pipeline.md):
# scripts/ahab/spsdk-venv.sh installs its closure, every file checked against a
# SHA-256 in scripts/ahab, into /opt/spsdk. CI stages run without network, so
# the venv is built here. py3-pip is needed for the install only.
COPY scripts/ahab/spsdk-venv.sh scripts/ahab/requirements.txt scripts/ahab/build-requirements.txt /pins/ahab/
RUN apk add --no-cache --virtual .spsdk-build py3-pip \
 && SPSDK_VENV=/opt/spsdk bash /pins/ahab/spsdk-venv.sh \
 && apk del --no-cache .spsdk-build \
 && rm -rf /tmp/.cache /pins/ahab
ENV SPSDK_VENV=/opt/spsdk
USER 10001

FROM base AS integration
ARG APK_INDEX_SUM=none
RUN echo "apk index ${APK_INDEX_SUM}" >/dev/null && apk upgrade --no-cache
COPY --chown=10001:10001 . /src
USER 10001
