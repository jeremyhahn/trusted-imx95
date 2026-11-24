# Dependency updates

How a pin moves on `row/178-maintenance` (the standing maintenance row, plan in [`docs/plans/178.md`](../plans/178.md)). It applies to a dependabot bump, a `deps/*` branch and a manual one. Every step is offline except where it says so.

## Two checks, two questions

- `make pins-check` (`scripts/pins-check.sh`, also run by `make build`) says whether a pin is **well formed**: the tool entries of `scripts/tool-pins.sh`, the two requirements files, and the workflow action pins. It needs no network and no pip.
- `make deps-check` (`scripts/deps-check.sh`) says whether a pin is **behind** the latest release. It needs the network, so it is not part of `make build` or `make test`. A pin with a `<TOOL>_HOLD` reason is reported, not failed.

Read `make pins-report` (`scripts/pins-report.sh`) before the network `make deps-check`: it prints, from the files in the tree only, every tool with its version, repo, release tag and `_HOLD` reason, the Alpine, Python, uv and Debian snapshot pins, the requirement count of each requirements file, and every workflow action as `owner/repo@<12 hex> # <tag>`. It reports and does not judge; it exits 1 only when a file is missing.

`make build` and `make pins-check` also run `scripts/pins-drift-check.sh` (rule j): every `python:<ver>-slim` and `alpine:<ver>` restated in `docs/**/*.md`, `scripts/` and `test/` must agree with `SW_PYTHON_VERSION` and `ALPINE_VERSION` (a dotted prefix such as `alpine:3.24` agrees). It fails naming file, line and the pin, so after moving one of those two pins, fix the prose it names. The script lists its few excluded files by name.

A bump is done when `make pins-check` passes and `make deps-check` no longer lists the pin (or the pin carries a `_HOLD` reason).

## A tool in `scripts/tool-pins.sh`

The tools are those named in `PINNED_TOOLS`: SHELLCHECK, ACTIONLINT, GITLEAKS and TRIVY.

1. Set `<TOOL>_VERSION` to the new release.
2. Set `<TOOL>_URL` to the linux amd64 release asset of that version. It keeps the `/<TOOL>_REPO/releases/download/` form and carries the release tag of `<TOOL>_VERSION` (with or without a leading `v`).
3. Set `<TOOL>_SHA256` to the digest in the checksum file the release itself publishes, never one computed from a download of unknown origin. It is 64 lowercase hex.
4. If the new release is not adopted, keep the old pin and put the reason in `<TOOL>_HOLD`, single-quoted; leave it empty otherwise. `<TOOL>_HOLD` must stay defined.
5. For the Alpine, Python and uv pins (`ALPINE_VERSION`, `ALPINE_DIGEST`, `SW_PYTHON_VERSION`, `SW_PYTHON_DIGEST`, `SW_UV_VERSION`, `SW_UV_SHA256`) and for `SW_DEBIAN_SNAPSHOT`, change the matching `ARG` lines of the Dockerfile in the same commit: `make build` fails when the Dockerfile lacks the `ARG ALPINE_IMAGE=`, `ARG SW_IMAGE=`, `ARG SW_DEBIAN_SNAPSHOT=`, `ARG SW_UV_VERSION=` or `ARG SW_UV_SHA256=` line the pin file implies. A base image digest is `sha256:` plus 64 hex; the snapshot is `YYYYMMDDTHHMMSSZ`.
6. Run, in order: `make pins-check`, `make build`, `make lint`, `make test`.

A new tool also needs its name in `PINNED_TOOLS`, or `make pins-check` fails (rule f) because the tool has a `_URL` that `make deps-check` would never compare.

## The Python closure

`scripts/ahab/requirements.txt` is SPSDK and its whole dependency closure, each as `name==version` with a `--hash=sha256:` line for every file pip may pick. `scripts/ahab/build-requirements.txt` is the build backend for the sdists; its header says the pins it shares with `requirements.txt` are equal.

1. Re-resolve the closure for the new version on a machine with network access, then re-hash every file for each pin (all the wheels and the sdist the header of `requirements.txt` lists).
2. Keep a name that appears in both files at one version and one hash set; `make pins-check` fails (rule h) when they differ.
3. Every requirement has at least one hash and no name repeats within a file (rule g).
4. Upgrading SPSDK itself is a reviewed PR, as the header of `requirements.txt` says: re-resolve, re-hash, and run the `ahab_*` tests, which install the closure into the venv cache with `--require-hashes`.
5. Run `make pins-check`, `make build`, `make lint`, `make test`.

## A workflow action

Every `uses:` in `.github/workflows/*.yml` is `owner/repo@<40 lowercase hex> # <tag>`: the commit, never the tag, and the tag it came from as a comment.

1. Take the commit the new tag points to, from the action's own repository.
2. Move **every** workflow to it in one commit: one action repository (for example `actions/checkout`) names one commit across the directory, or `make pins-check` fails (rule i) naming both places.
3. A `uses: ./...` local action is not checked.
4. Editing `.github/` needs `LANE_POLICY_ALLOW` set to `.github/*` for a lane; a maintainer does it by hand.
5. Run `make pins-check`, `make lint` (actionlint reads the workflows), then `make test`.

## Landing it

A `dependabot/*` or `deps/*` branch is merged into `row/178-maintenance` and then deleted; it is never force-pushed, rebased away or lost. The PR from the row carries the checks above; the commit message says `Refs #178`, never a closing keyword.
