# shellcheck shell=sh disable=SC2034
# The one pin file (handbook devcontainer.md §2). Read by the Dockerfile's
# fetch stage (scripts/fetch-tools.sh), by the Makefile (`include`) and by
# scripts/deps-check.sh. Plain NAME=value lines only: make and sh read both.
#
# Each tool: <TOOL>_VERSION, <TOOL>_REPO (its GitHub releases), <TOOL>_URL
# (the linux amd64 release asset) and <TOOL>_SHA256 (that asset's digest).
# A pin held behind the latest release carries <TOOL>_HOLD, the documented
# reason (handbook devops.md §9), single-quoted; deps-check then reports it,
# not fails it.

ALPINE_VERSION=3.24.4
ALPINE_DIGEST=sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# The secure-world stage's glibc base (python:<version>-slim-bookworm, glibc 2.36),
# the Debian snapshot its packages come from, and uv from its manylinux wheel.
# Changing one means changing the Dockerfile's ARG defaults to match.
SW_PYTHON_VERSION=3.13
SW_PYTHON_DIGEST=sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
SW_DEBIAN_SNAPSHOT=20261122T000000Z
SW_UV_VERSION=0.13.9
SW_UV_SHA256=d7f459fe4fd247d830351c75686d3996ace3c6f3f728eb0e85a30b7ada0cef19

SHELLCHECK_VERSION=0.11.0
SHELLCHECK_REPO=koalaman/shellcheck
SHELLCHECK_URL=https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz
SHELLCHECK_SHA256=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
SHELLCHECK_HOLD=

ACTIONLINT_VERSION=1.7.12
ACTIONLINT_REPO=rhysd/actionlint
ACTIONLINT_URL=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ACTIONLINT_HOLD=

GITLEAKS_VERSION=8.30.1
GITLEAKS_REPO=gitleaks/gitleaks
GITLEAKS_URL=https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
GITLEAKS_HOLD=

TRIVY_VERSION=0.76.2
TRIVY_REPO=aquasecurity/trivy
TRIVY_URL=https://github.com/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_Linux-64bit.tar.gz
TRIVY_SHA256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
TRIVY_HOLD=

# The tools deps-check compares with their latest release, comma separated.
PINNED_TOOLS=SHELLCHECK,ACTIONLINT,GITLEAKS,TRIVY
