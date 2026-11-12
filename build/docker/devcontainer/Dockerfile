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
 && apk add --no-cache bash coreutils make git python3 tar \
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

FROM base AS toolchain
# openssh-keygen: git's SSH signature verification (gpg.format ssh) runs
# ssh-keygen -Y, which test/ci_scripts_test.sh's signature fixtures need;
# Alpine's git package does not supply it. Like every package here, its
# version is the pinned Alpine release's.
RUN apk add --no-cache curl jq ca-certificates openssh-keygen
COPY --from=fetch /out/bin/ /usr/local/bin/
USER 10001

FROM base AS integration
ARG APK_INDEX_SUM=none
RUN echo "apk index ${APK_INDEX_SUM}" >/dev/null && apk upgrade --no-cache
COPY --chown=10001:10001 . /src
USER 10001
