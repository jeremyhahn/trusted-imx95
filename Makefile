# trusted-imx95: the five CI stages of the handbook CI standard
# (software/conventions/ci-standard.md §1) and the targets the canonical
# .github/workflows/ci.yml and the devcontainer image need
# (software/conventions/devcontainer.md §6).
#
# There is no firmware code yet, so each stage checks what the tree holds:
# the scripts, the workflows, the Markdown links, the secrets and the Code
# Signing Tool guard. Each target checks something or fails naming what is
# missing; none passes by doing nothing.
#
# Run every target in the devcontainer image: make docker-run CMD='make test'.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

include scripts/tool-pins.sh

REPO_NAME          ?= trusted-imx95
DOCKERFILE         := build/docker/devcontainer/Dockerfile
COVERAGE_THRESHOLD ?= 100
# Variables the canonical ci.yml passes (devcontainer.md §6). This repository
# has no Go code: GO_BUILD_TAGS stays empty and MODULE_ENV_FILE is unused.
GO_BUILD_TAGS      ?=
MODULE_ENV_FILE    ?=
APK_INDEX_SUM      ?= none
IT_PROJECT         ?= $(REPO_NAME)-local
IT_IMAGE           ?= $(shell scripts/image-tag.sh integration $(REPO_NAME))
TOOLCHAIN_IMAGE    ?= $(shell scripts/image-tag.sh toolchain $(REPO_NAME))
export APK_INDEX_SUM

# The pinned tools outside the devcontainer image: `make tools` installs the
# same digest-checked releases the image's fetch stage does (scripts/
# fetch-tools.sh) into this gitignored directory, which every recipe sees
# first on PATH. A gate whose tool is in neither place fails naming it.
TOOLS_DIR := $(CURDIR)/.tools/bin
export PATH := $(TOOLS_DIR):$(PATH)
NEED_TOOL = command -v $(1) >/dev/null 2>&1 || { echo "$@: $(1) is not on PATH or in .tools/bin; run make tools (or make docker-run CMD='make $@')"; exit 1; }

# Every shell script git tracks, and every Python script under scripts/.
SH_SCRIPTS := $(sort $(wildcard scripts/*.sh test/*.sh test/integration/*.sh))
PY_SCRIPTS := $(sort $(wildcard scripts/*.py))
UNIT_TESTS := $(sort $(wildcard test/*_test.sh))
IT_TESTS   := $(sort $(wildcard test/integration/*_test.sh))

.PHONY: help build test coverage integration-test integration-test-local security gosec \
	deps-check lint lint-shell lint-workflows lint-docs check-tracked-cst cst-check \
	secret-scan-tree secret-scan-history docker-build docker-build-toolchain \
	docker-run toolchain-image it-image toolchain-ref it-ref tools

help: ## List the targets
	@echo "Targets:"
	@while IFS= read -r line; do \
		if [[ "$$line" =~ ^([a-z-]+):.*\#\#\ (.*)$$ ]]; then \
			printf '  %-24s %s\n' "$${BASH_REMATCH[1]}" "$${BASH_REMATCH[2]}"; \
		fi; \
	done < $(firstword $(MAKEFILE_LIST))

## --- The five CI stages (ci-standard.md §1) ---

build: ## Build stage: every script parses, the Dockerfile base matches the pin file
	@[ -n "$(SH_SCRIPTS)" ] || { echo "build: no shell script found"; exit 1; }
	@for f in $(SH_SCRIPTS); do bash -n "$$f" || { echo "build: $$f does not parse"; exit 1; }; done
	@for f in $(PY_SCRIPTS); do \
		python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$$f" \
		|| { echo "build: $$f does not parse"; exit 1; }; done
	@want='ARG ALPINE_IMAGE=alpine:$(ALPINE_VERSION)@$(ALPINE_DIGEST)'; found=0; \
	while IFS= read -r line; do [ "$$line" != "$$want" ] || found=1; done < $(DOCKERFILE); \
	[ "$$found" = 1 ] || { echo "build: $(DOCKERFILE) lacks '$$want' (scripts/tool-pins.sh)"; exit 1; }
	@echo "build: OK ($(words $(SH_SCRIPTS)) shell and $(words $(PY_SCRIPTS)) Python scripts parse)"

test: check-tracked-cst ## Unit tests: the CST guard first, then every test/*_test.sh
	@[ -n "$(UNIT_TESTS)" ] || { echo "test: no test/*_test.sh found"; exit 1; }
	@fail=0; for t in $(UNIT_TESTS); do \
		echo "--- $$t"; bash "$$t" || { echo "FAIL $$t"; fail=1; }; \
	done; exit $$fail

coverage: test ## Unit tests, then the share of project scripts a test runs (COVERAGE_THRESHOLD)
	@scripts/check-script-tests.sh $(COVERAGE_THRESHOLD)

integration-test: ## Integration tests in the integration image (IT_IMAGE_ID if set, else IT_IMAGE), hardened, no network
	@if command -v docker >/dev/null 2>&1; then \
		ref="$(IT_IMAGE_ID)"; \
		if [ -z "$$ref" ]; then \
			$(MAKE) --no-print-directory docker-build IT_IMAGE=$(IT_IMAGE); \
			ref=$$($(MAKE) -s --no-print-directory it-ref IT_IMAGE=$(IT_IMAGE)); \
		elif ! [[ "$$ref" =~ ^sha256:[0-9a-f]{64}$$ ]]; then \
			echo "integration-test: IT_IMAGE_ID must be an image ID (sha256:...), not $$ref"; exit 1; \
		fi; \
		docker run --rm --name $(IT_PROJECT) --network none --read-only \
			--tmpfs /tmp:exec --cap-drop ALL --security-opt no-new-privileges \
			--ulimit core=0 --user 10001 "$$ref" make -C /src integration-test-local; \
	else \
		$(MAKE) --no-print-directory integration-test-local; \
	fi

integration-test-local: ## Integration tests in the current environment (in the image)
	@[ -n "$(IT_TESTS)" ] || { echo "integration-test: no test/integration/*_test.sh found"; exit 1; }
	@fail=0; for t in $(IT_TESTS); do \
		echo "--- $$t"; bash "$$t" || { echo "FAIL $$t"; fail=1; }; \
	done; exit $$fail

security: check-tracked-cst secret-scan-tree secret-scan-history ## Security stage: CST guard and secret scans of the tree and the history

deps-check: ## Latest-version check: every pin in scripts/tool-pins.sh (needs the network)
	@scripts/deps-check.sh scripts/tool-pins.sh

## --- The lint-class gates the canonical ci.yml runs on the PR tier ---

lint: lint-shell lint-workflows lint-docs ## shellcheck, actionlint and the Markdown link check

lint-shell: ## shellcheck every shell script
	@$(call NEED_TOOL,shellcheck)
	@shellcheck -x $(SH_SCRIPTS)
	@echo "lint-shell: OK ($(words $(SH_SCRIPTS)) scripts)"

lint-workflows: ## actionlint every workflow (with shellcheck of their run steps)
	@$(call NEED_TOOL,actionlint)
	@actionlint -config-file .github/actionlint.yaml
	@echo "lint-workflows: OK"

lint-docs: ## Every relative link and anchor in the tracked Markdown resolves
	@python3 scripts/check-doc-links.py .

gosec: check-tracked-cst secret-scan-tree ## The PR tier's security gate (ci.yml's `make gosec`): CST guard and tree secret scan

check-tracked-cst: ## Fails when a tracked path is cst-*.tgz or inside cst-*/
	@scripts/check-tracked-cst.sh .

secret-scan-tree:
	@$(call NEED_TOOL,gitleaks)
	@scripts/secret-scan.sh tree .

secret-scan-history:
	@$(call NEED_TOOL,gitleaks)
	@scripts/secret-scan.sh history .

## --- The pinned tools without the devcontainer image ---

tools: ## Install the pinned, digest-checked tools of scripts/tool-pins.sh into .tools/bin
	@[ "$$(uname -s)-$$(uname -m)" = Linux-x86_64 ] || \
		{ echo "tools: the pins are Linux x86_64 releases, this is $$(uname -s)-$$(uname -m)"; exit 1; }
	@sh scripts/fetch-tools.sh scripts/tool-pins.sh $(TOOLS_DIR)
	@echo "tools: OK ($(PINNED_TOOLS) in .tools/bin)"

## --- The Code Signing Tool (docs/references/README.md) ---

cst-check: ## Prerequisite of any step that needs the CST: CST_PATH names a CST tree
	@scripts/cst-check.sh

## --- The devcontainer image (devcontainer.md §6, ci-standard.md §9) ---

toolchain-image: ## Print the toolchain image tag (by content)
	@echo $(TOOLCHAIN_IMAGE)

it-image: ## Print the integration image tag (by content)
	@echo $(IT_IMAGE)

# A trusted run (CI on any event but a pull request: a push to main, a
# schedule, a dispatch) never trusts a tag the daemon already holds. Pull
# request jobs share the runners' persistent Docker daemon and run their own
# Makefile with Docker access, so a pull request can tag any image with
# main's tag; the same daemon's build cache is just as writable (a committed
# container answers a RUN step's cache lookup). A trusted run therefore uses
# the toolchain image only by the ID scripts/ci-image-cache.sh pulled by
# digest from the registry (TOOLCHAIN_VERIFIED_ID, which that script exports
# to the job), while the daemon holds it, and
# otherwise rebuilds from source with no cache; it always rebuilds the
# integration image that way. Locally, and on a pull request, a tag the
# daemon holds is used as before.
#
# Checking the tag once is not enough (Codex security P1 on #19): every later
# `docker create` or `docker run` would resolve the tag again, and a pull
# request's job can move it in between. So a trusted build records the image
# ID it settles on, the verified pull's or its own `docker build --iidfile`,
# in TOOLCHAIN_ID_FILE (IT_ID_FILE for the integration image), both in the
# job's RUNNER_TEMP. `make -s toolchain-ref` (`it-ref`) prints that ID on a
# trusted run and the tag otherwise; ci.yml exports it as TOOLCHAIN_IMAGE, so
# every container a trusted job starts names an image ID, never a tag.
TRUSTED_RUN := $(if $(filter-out pull_request pull_request_target,$(GITHUB_EVENT_NAME)),1)
TOOLCHAIN_ID_FILE ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/toolchain-image.id)
IT_ID_FILE        ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/it-image.id)
IT_IMAGE_ID       ?=
# NEED_ID_FILE <file> <variable>: a trusted run fails when it has nowhere to
# record the image ID.
NEED_ID_FILE = [ -n "$(1)" ] || { echo "$@: a trusted run ($(GITHUB_EVENT_NAME)) records its image ID; set RUNNER_TEMP or $(2)" >&2; exit 1; }
# READ_ID <file>: print the image ID the file holds, or fail naming it.
READ_ID = id=$$(cat "$(1)" 2>/dev/null || true); \
	[[ "$$id" =~ ^sha256:[0-9a-f]{64}$$ ]] || { echo "$@: $(1) holds no image ID; build the image first" >&2; exit 1; }; \
	echo "$$id"

toolchain-ref: ## Print the toolchain image a stage starts: a trusted CI run's recorded image ID, otherwise the tag
	@if [ -n "$(TRUSTED_RUN)" ]; then \
		$(call NEED_ID_FILE,$(TOOLCHAIN_ID_FILE),TOOLCHAIN_ID_FILE); \
		$(call READ_ID,$(TOOLCHAIN_ID_FILE)); \
	else \
		echo $(TOOLCHAIN_IMAGE); \
	fi

it-ref: ## Print the integration image a stage starts: a trusted CI run's recorded image ID, otherwise the tag
	@if [ -n "$(TRUSTED_RUN)" ]; then \
		$(call NEED_ID_FILE,$(IT_ID_FILE),IT_ID_FILE); \
		$(call READ_ID,$(IT_ID_FILE)); \
	else \
		echo $(IT_IMAGE); \
	fi

docker-build-toolchain: ## Build the toolchain image when the daemon lacks its tag (a trusted CI run: unless verified, recording the ID)
	@if [ -n "$(TRUSTED_RUN)" ]; then \
		$(call NEED_ID_FILE,$(TOOLCHAIN_ID_FILE),TOOLCHAIN_ID_FILE); \
		rm -f "$(TOOLCHAIN_ID_FILE)"; \
		v=$${TOOLCHAIN_VERIFIED_ID:-}; \
		if [[ "$$v" =~ ^sha256:[0-9a-f]{64}$$ ]] && \
			[ "$$(docker image inspect --format '{{.Id}}' "$$v" 2>/dev/null || true)" = "$$v" ]; then \
			echo "docker-build-toolchain: a trusted run uses the image pulled by digest, by its ID ($$v)"; \
			printf '%s\n' "$$v" > "$(TOOLCHAIN_ID_FILE)"; \
		else \
			echo "docker-build-toolchain: a trusted run ($(GITHUB_EVENT_NAME)) rebuilds $(TOOLCHAIN_IMAGE) from source: no verified pull"; \
			docker build --no-cache --iidfile "$(TOOLCHAIN_ID_FILE)" --target toolchain -t $(TOOLCHAIN_IMAGE) -f $(DOCKERFILE) .; \
		fi; \
	else \
		docker image inspect $(TOOLCHAIN_IMAGE) >/dev/null 2>&1 || \
			docker build --target toolchain -t $(TOOLCHAIN_IMAGE) -f $(DOCKERFILE) .; \
	fi

docker-build: docker-build-toolchain ## Build both images, each only when the daemon lacks its tag (a trusted CI run: always, recording the ID)
	@if [ -n "$(TRUSTED_RUN)" ]; then \
		$(call NEED_ID_FILE,$(IT_ID_FILE),IT_ID_FILE); \
		rm -f "$(IT_ID_FILE)"; \
		echo "docker-build: a trusted run ($(GITHUB_EVENT_NAME)) rebuilds $(IT_IMAGE) from source"; \
		docker build --no-cache --iidfile "$(IT_ID_FILE)" --target integration --build-arg "APK_INDEX_SUM=$(APK_INDEX_SUM)" \
			-t $(IT_IMAGE) -f $(DOCKERFILE) .; \
	else \
		docker image inspect $(IT_IMAGE) >/dev/null 2>&1 || \
			docker build --target integration --build-arg "APK_INDEX_SUM=$(APK_INDEX_SUM)" \
				-t $(IT_IMAGE) -f $(DOCKERFILE) .; \
	fi

# The CST extraction lives outside the checkout (scripts/cst-check.sh), so a
# set CST_PATH is bind-mounted read-only at /cst and named there; unset, it
# stays unset in the container and cst-check fails naming it.
# The mount source is the canonical (pwd -P) path. A CST_PATH inside the
# checkout is refused here, as scripts/cst-check.sh refuses it on the host:
# once remapped to /cst, the container's cst-check can no longer tell.
CST_MOUNT = $(if $(CST_PATH),-v "$$(cd "$$CST_PATH" && pwd -P):/cst:ro" -e CST_PATH=/cst)

docker-run: docker-build-toolchain ## Run CMD in the toolchain image, the source and a set CST_PATH (read-only) bind-mounted
	@[ -n "$(CMD)" ] || { echo "docker-run: set CMD, for example CMD='make test'"; exit 1; }
	@[ -z "$${CST_PATH:-}" ] || [ -d "$$CST_PATH" ] || { echo "docker-run: CST_PATH=$$CST_PATH is not a directory"; exit 1; }
	@[ -z "$${CST_PATH:-}" ] || { cst=$$(cd "$$CST_PATH" && pwd -P); repo=$$(cd "$(CURDIR)" && pwd -P); \
		case "$$cst/" in "$$repo"/*) echo "docker-run: CST_PATH=$$CST_PATH ($$cst) is inside this checkout; the CST is never read from this tree. Extract it outside the repository."; exit 1;; esac; }
	ref=$$($(MAKE) -s --no-print-directory toolchain-ref TOOLCHAIN_IMAGE=$(TOOLCHAIN_IMAGE)); \
	docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp $(CST_MOUNT) \
		-v "$(CURDIR):/src" -w /src --ulimit core=0 "$$ref" bash -c '$(CMD)'
