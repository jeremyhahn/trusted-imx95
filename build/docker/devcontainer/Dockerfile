# syntax=docker/dockerfile:1
#
# Stages: base, toolchain, integration and secure-world (glibc); every pin is in scripts/tool-pins.sh, which `make build` checks. No vendor tool enters the image.

ARG ALPINE_IMAGE=alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
# The secure-world stage's glibc base (below). Must equal scripts/tool-pins.sh's
# SW_PYTHON_VERSION@SW_PYTHON_DIGEST, which `make build` checks.
ARG SW_IMAGE=python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72

FROM ${ALPINE_IMAGE} AS base
# coreutils for GNU date -d; GNU tar for --owner/--group/--numeric-owner; safe.directory for checkouts owned by another uid.
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

FROM base AS toolchain
# openssh-keygen for SSH signature tests; uv for hash-checked wheels; xz and perl for imx-sm; gcompat for the glibc-built Arm toolchain.
RUN apk add --no-cache curl jq ca-certificates openssh-keygen uv xz perl gcompat
COPY --from=fetch /out/bin/ /usr/local/bin/
# SPSDK 3.13.0 venv for make ahab-sign-test, hash-checked, built here because CI stages run offline.
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

# `make secure-world` on a glibc base: its pinned wheels and the Arm toolchain need glibc; Debian packages come from a dated snapshot.
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
