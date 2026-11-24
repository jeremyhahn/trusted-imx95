#!/usr/bin/env bash
# The hsm-self-defence row end to end through make: the row is blocked (owner
# rulings 1243 and 1244, #26), so make hsm-self-defence-check passes on this
# tree, which keeps it as docs/SPEC.md writes it, and fails on copies that
# ship it, unblock it, drop what it names or start building it. Runs offline
# on a read-only root (make integration-test, make
# integration-test-hsm-self-defence); writes only under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# tree <name>: a copy of the files the check reads, under $TMP_ROOT/<name>.
tree() {
	local t="$TMP_ROOT/$1"
	mkdir -p "$t/docs/references" "$t/scripts"
	cp "$ROOT/docs/SPEC.md" "$t/docs/SPEC.md"
	cp "$ROOT/docs/references/README.md" "$t/docs/references/README.md"
	cp "$ROOT/ROADMAP.md" "$ROOT/Makefile" "$t/"
	cp "$ROOT/scripts/hsm-self-defence-check.py" "$t/scripts/"
	echo "$t"
}

# edit <file> <old> <new>: replace the one occurrence of <old>; fails if absent.
edit() {
	python3 - "$@" <<'EOF'
import sys
f, old, new = sys.argv[1:4]
s = open(f, encoding="utf-8").read()
assert s.count(old) == 1, f"{old!r} occurs {s.count(old)} times in {f}"
open(f, "w", encoding="utf-8").write(s.replace(old, new))
EOF
}

run make -s -C "$ROOT" hsm-self-defence-check
check "make hsm-self-defence-check: this tree keeps the row blocked as written" 0 \
	"ok 2 SPEC.md: the row stays planned" "ok 3 SPEC.md: the row stays blocked" \
	"no target builds hsm-self-defence" "hsm-self-defence-check: OK (blocked as written"

t=$(tree same)
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: an unchanged copy passes" 0 "hsm-self-defence-check: OK"

t=$(tree shipped)
edit "$t/docs/SPEC.md" "| hsm-self-defence | planned |" "| hsm-self-defence | shipped |"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a shipped row fails" nonzero "status is 'shipped'"

t=$(tree unblocked)
edit "$t/docs/SPEC.md" "#26): it stays blocked. The HSM" "#26). The HSM"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a row that no longer stays blocked fails" nonzero \
	"FAIL 3 SPEC.md: the row stays blocked"

t=$(tree decided)
edit "$t/docs/SPEC.md" "is not decided, and is an open question for the owner" "is decided"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: deciding the owner's open A55 question fails" nonzero \
	"the Cortex-A55 tamper detector" "phrase missing"

t=$(tree pins)
edit "$t/docs/SPEC.md" "gives the EdgeLock tamper pins; the one that does is missing" "gives the EdgeLock tamper pins"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: dropping the missing tamper-pin document fails" nonzero \
	"the one that does is missing" "phrase missing"

t=$(tree roadmap)
edit "$t/ROADMAP.md" "blocked: owner approval; A55 side open" "in progress"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a ROADMAP line no longer blocked fails" nonzero \
	"ROADMAP.md: blocked on owner approval: not marked blocked"

t=$(tree refs)
edit "$t/docs/references/README.md" "secure-world, hsm-self-defence | Not on the public" "secure-world | Not on the public"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a missing document no longer listed for the row fails" nonzero \
	"'i.MX 95 Security Reference Manual' is missing for hsm-self-defence"

t=$(tree built)
printf '\nhsm-self-defence-image: ## build it\n\t@true\n' >>"$t/Makefile"
: >"$t/scripts/hsm-self-defence-build.sh"
mkdir "$t/hsm-self-defence"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a target, script or source tree that builds the row fails" nonzero \
	"targets hsm-self-defence-image" "found hsm-self-defence-build.sh" "hsm-self-defence/ exists"

t=$(tree nospec)
rm "$t/docs/SPEC.md"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a tree without docs/SPEC.md fails" nonzero "docs/SPEC.md: unreadable"

run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$TMP_ROOT/absent"
check "make hsm-self-defence-check: a root that is not a directory is a usage error" nonzero "usage:"

finish
